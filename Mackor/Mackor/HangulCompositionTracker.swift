import Foundation

// MARK: - 조합 결과

struct CompositionResult: Equatable {
    /// 백스페이스 횟수 (현재 조합 중인 글자 삭제)
    let deleteCount: Int
    /// 백스페이스 후 입력할 텍스트
    let insertText: String
    /// true이면 원래 키 이벤트를 그대로 앱에 전달 (우리가 처리하지 않음)
    let passthrough: Bool

    static func pass() -> CompositionResult {
        CompositionResult(deleteCount: 0, insertText: "", passthrough: true)
    }

    static func handled(delete: Int, insert: String) -> CompositionResult {
        CompositionResult(deleteCount: delete, insertText: insert, passthrough: false)
    }
}

// MARK: - 조합 상태 추적기

/// 키 입력을 가로채서 직접 한글 조합을 수행하는 상태 머신.
/// macOS IME 조합을 지원하지 않는 앱을 위해,
/// 우리가 직접 자모를 조합하여 완성된 유니코드 문자를 보낸다.
class HangulCompositionTracker {

    enum State: Equatable {
        case idle               // 조합 없음
        case choseong           // 초성만 (ㅎ)
        case syllable           // 초성+중성 또는 중성만 (하, ㅏ)
        case syllableJong       // 초+중+종 (한) — 종성은 아직 확정 아님
        case syllableCompJong   // 초+중+복합종성 (닭)
    }

    private(set) var state: State = .idle

    // 현재 조합 중인 자모
    private var cho: Character?
    private var jung: Character?
    // 복합 모음이 만들어진 경로. ㅗ+ㅏ+ㅣ→ㅙ이면 [ㅗ, ㅘ]를 보존해
    // 백스페이스가 ㅙ→ㅘ→ㅗ 순서로 되돌아가게 한다.
    private var jungHistory: [Character] = []
    private var jong: Character?         // 현재 종성 (복합 포함)
    private var jongFirst: Character?    // 복합 종성의 첫 자음

    // MARK: - 현재 조합 문자

    private var currentComposing: String {
        HangulUnicode.buildString(cho: cho, jung: jung, jong: jong)
    }

    // MARK: - 초기화

    func reset() {
        state = .idle
        cho = nil; jung = nil; jungHistory.removeAll(keepingCapacity: true)
        jong = nil; jongFirst = nil
    }

    // MARK: - 자모 입력 처리

    func processJamo(_ jamo: Jamo) -> CompositionResult {
        switch state {
        case .idle:           return handleIdle(jamo)
        case .choseong:       return handleChoseong(jamo)
        case .syllable:       return handleSyllable(jamo)
        case .syllableJong:   return handleSyllableJong(jamo)
        case .syllableCompJong: return handleSyllableCompJong(jamo)
        }
    }

    /// 자모가 아닌 키 (스페이스, 엔터, 방향키 등) — 현재 조합 확정 후 통과
    func processNonJamo() -> CompositionResult {
        reset()
        return .pass()
    }

    /// 백스페이스 처리
    func processBackspace() -> CompositionResult {
        switch state {
        case .idle:
            return .pass()

        case .choseong:
            // ㅎ → 삭제
            reset()
            return .handled(delete: 1, insert: "")

        case .syllable:
            if let previous = jungHistory.popLast() {
                // 복합 모음 → 직전 모음으로 한 단계 복귀 (ㅙ→ㅘ→ㅗ)
                jung = previous
                return .handled(delete: 1, insert: currentComposing)
            } else if cho != nil {
                // 초+중 → 초성만 (하→ㅎ)
                jung = nil
                state = .choseong
                return .handled(delete: 1, insert: currentComposing)
            } else {
                // 모음만 → 삭제
                reset()
                return .handled(delete: 1, insert: "")
            }

        case .syllableJong:
            // 초+중+종 → 초+중 (한→하)
            jong = nil; jongFirst = nil
            state = .syllable
            return .handled(delete: 1, insert: currentComposing)

        case .syllableCompJong:
            // 복합종성 → 단일종성 (닭→달)
            if let first = jongFirst {
                jong = first
                // `jongFirst`는 `jong`과 **세트**로 유지해야 합니다. 정방향
                // 경로(handleSyllable)도 둘을 같은 값으로 함께 세팅합니다.
                // 여기서 nil로 비우면 `.syllableJong`으로 돌아온 뒤
                // handleSyllableJong의 겹받침 결합 분기(`if let first = jongFirst`)가
                // 실패해, 결합 가능한 상황인데도 음절을 확정하고 새 초성을
                // 시작합니다 — 닭→BS→달→ㄱ이 "닭"이 아니라 "달ㄱ"이 됐습니다.
                jongFirst = first
                state = .syllableJong
                return .handled(delete: 1, insert: currentComposing)
            } else {
                jong = nil; jongFirst = nil
                state = .syllable
                return .handled(delete: 1, insert: currentComposing)
            }
        }
    }

    // MARK: - 상태별 핸들러

    // [IDLE] 아무것도 없는 상태
    private func handleIdle(_ jamo: Jamo) -> CompositionResult {
        if jamo.isConsonant {
            cho = jamo.character
            state = .choseong
            return .handled(delete: 0, insert: String(jamo.character))
        } else {
            cho = nil
            jung = jamo.character
            jungHistory.removeAll(keepingCapacity: true)
            state = .syllable
            return .handled(delete: 0, insert: String(jamo.character))
        }
    }

    // [CHOSEONG] 초성만 있는 상태 (화면에 "ㅎ")
    private func handleChoseong(_ jamo: Jamo) -> CompositionResult {
        if jamo.isVowel {
            // ㅎ + ㅏ → 하 (음절 시작)
            jung = jamo.character
            jungHistory.removeAll(keepingCapacity: true)
            state = .syllable
            return .handled(delete: 1, insert: currentComposing)
        } else {
            // ㅎ + ㄱ → "ㅎ" 확정, "ㄱ" 새 조합
            // "ㅎ"은 이미 화면에 있으므로 그대로 두고 "ㄱ"만 추가
            cho = jamo.character
            state = .choseong
            return .handled(delete: 0, insert: String(jamo.character))
        }
    }

    // [SYLLABLE] 초+중 또는 중만 (화면에 "하" 또는 "ㅏ")
    private func handleSyllable(_ jamo: Jamo) -> CompositionResult {
        if jamo.isVowel {
            // 복합 모음 체크 (ㅗ+ㅏ→ㅘ)
            if let currentJung = jung,
               let compound = HangulUnicode.compoundVowel(first: currentJung, second: jamo.character) {
                jungHistory.append(currentJung)
                jung = compound
                return .handled(delete: 1, insert: currentComposing)
            } else {
                // 복합 불가 → 현재 음절 확정, 새 모음 시작
                let committed = currentComposing
                cho = nil; jung = jamo.character; jungHistory.removeAll(keepingCapacity: true); jong = nil
                state = .syllable
                return .handled(delete: 1, insert: committed + currentComposing)
            }
        } else {
            guard cho != nil else {
                // 단독 모음 뒤 자음은 종성이 될 수 없다. 모음은 그대로 확정하고
                // 자음을 새 초성으로 추가한다. (ㅏ+ㄴ → ㅏㄴ)
                cho = jamo.character
                jung = nil
                jungHistory.removeAll(keepingCapacity: true)
                jong = nil; jongFirst = nil
                state = .choseong
                return .handled(delete: 0, insert: String(jamo.character))
            }

            // 자음 → 종성 후보
            if HangulUnicode.canBeJongseong(jamo.character) {
                jong = jamo.character
                jongFirst = jamo.character
                state = .syllableJong
                return .handled(delete: 1, insert: currentComposing)
            } else {
                // ㄸ, ㅃ, ㅉ은 종성 불가 → 현재 확정, 새 초성
                let committed = currentComposing
                cho = jamo.character; jung = nil; jungHistory.removeAll(keepingCapacity: true); jong = nil
                state = .choseong
                return .handled(delete: 1, insert: committed + currentComposing)
            }
        }
    }

    // [SYLLABLE_JONG] 초+중+종 (화면에 "한") — 종성 아직 미확정
    private func handleSyllableJong(_ jamo: Jamo) -> CompositionResult {
        if jamo.isVowel {
            // 종성이 다음 음절의 초성으로 이동! (한+ㅏ → 하+나)
            // "한" 삭제 → "하" + "나" 입력
            let commitCho = cho
            let commitJung = jung
            cho = jong
            jung = jamo.character
            jungHistory.removeAll(keepingCapacity: true)
            jong = nil; jongFirst = nil
            state = .syllable

            let committed = HangulUnicode.buildString(cho: commitCho, jung: commitJung, jong: nil)
            return .handled(delete: 1, insert: committed + currentComposing)

        } else {
            // 복합 종성 체크 (ㄹ+ㄱ→ㄺ)
            if let first = jongFirst,
               let compound = HangulUnicode.compoundJongseong(first: first, second: jamo.character) {
                jong = compound
                state = .syllableCompJong
                return .handled(delete: 1, insert: currentComposing)
            } else {
                // 복합 불가 → 현재 음절 확정 (종성 포함), 새 초성 시작
                let committed = currentComposing
                cho = jamo.character; jung = nil; jungHistory.removeAll(keepingCapacity: true)
                jong = nil; jongFirst = nil
                state = .choseong
                return .handled(delete: 1, insert: committed + currentComposing)
            }
        }
    }

    // [SYLLABLE_COMP_JONG] 초+중+복합종성 (화면에 "닭")
    private func handleSyllableCompJong(_ jamo: Jamo) -> CompositionResult {
        if jamo.isVowel {
            // 복합종성 분리: 앞=종성 유지, 뒤=다음 초성 (닭+ㅏ → 달+가)
            guard let split = HangulUnicode.splitCompoundJongseong(jong!) else {
                // 분리 실패 → 단순 종성으로 처리
                return handleSyllableJong(jamo)
            }

            let commitCho = cho
            let commitJung = jung
            let commitJong = split.first

            cho = split.second
            jung = jamo.character
            jungHistory.removeAll(keepingCapacity: true)
            jong = nil; jongFirst = nil
            state = .syllable

            let committed = HangulUnicode.buildString(cho: commitCho, jung: commitJung, jong: commitJong)
            return .handled(delete: 1, insert: committed + currentComposing)

        } else {
            // 자음 → 현재 음절 확정, 새 초성
            let committed = currentComposing
            cho = jamo.character; jung = nil; jungHistory.removeAll(keepingCapacity: true)
            jong = nil; jongFirst = nil
            state = .choseong
            return .handled(delete: 1, insert: committed + currentComposing)
        }
    }
}
