import Foundation

/// 한/영 오입력 교정의 결정 규칙.
///
/// 같은 물리 키열을 두 개의 독립된 제약계로 채점한다.
/// - `HangulStructure` — 두벌식으로 읽었을 때 정상 한국어 구조인가
/// - `EnglishPhonotactics` — QWERTY로 읽었을 때 정상 영어 구조인가
///
/// 두 판정의 **상호 배타성**과 **위반 비용 마진**으로 교정 여부와 신뢰 등급을
/// 정한다. 사전도, 시스템 맞춤법 서비스도 참조하지 않는다.
/// 규칙 ID는 `STRUCTURE_CORRECTION_DESIGN4.md` §2.3과 대응한다.
enum LayoutCorrectionPolicy {

    /// 교정 신뢰 등급.
    ///
    /// `high`는 즉시 교정 후 단축키 Undo만 제공하고, `medium`은 원문 칩을
    /// 함께 노출해 사용자가 한 번에 되돌릴 수 있게 한다.
    enum Tier: Equatable {
        case high
        case medium
    }

    /// 결정을 내린 근거. 후보 문자열을 담지 않으므로 진단 로그에 안전하다.
    enum Rule: Equatable {
        // 교정 승인
        case koreanStructure        // 영→한: 영어 구조 위반이 명확
        case englishCostMargin      // 영→한: 영어로도 가능하나 유표적
        case englishStructure       // 한→영: 영어 구조가 무결
        case markedEnglishForm      // 한→영: 영어 구조가 유표적

        // 보존
        case acronymConvention      // R-D3 전대문자 = 약어 표기
        case weakKoreanStructure    // R-K1~K4 미달
        case ambiguousBothValid     // 두 문법 모두 무결 — 키열만으로 구분 불가
        case modernKoreanPreserved  // R-D1 현대 음절로 완전 조합됨
        case expressiveRepetition   // R-K5a 반복 표현
        case consonantJamoMash      // R-K5b 자음 자모 나열
        case implausibleEnglish     // 영어 구조 위반
        case unsupportedSource
        case compositionUnavailable
    }

    enum Decision: Equatable {
        case correct(tier: Tier, original: String, replacement: String, rule: Rule)
        case preserve(rule: Rule)

        var isCorrection: Bool {
            if case .correct = self { return true }
            return false
        }
    }

    // MARK: - 진입점

    static func evaluate(
        keystrokes: [PhysicalKeystroke],
        inputSource: InputSourceKind
    ) -> Decision {
        guard !keystrokes.isEmpty else { return .preserve(rule: .unsupportedSource) }
        guard let latin = latinCandidate(for: keystrokes) else {
            return .preserve(rule: .unsupportedSource)
        }

        switch inputSource {
        case .supportedLatin:
            return evaluateLatinSource(keystrokes: keystrokes, latin: latin)
        case .koreanTwoSet:
            return evaluateKoreanSource(keystrokes: keystrokes, latin: latin)
        case .unsupported:
            return .preserve(rule: .unsupportedSource)
        }
    }

    // MARK: - 영→한 (화면에 라틴 문자가 있음)

    private static func evaluateLatinSource(
        keystrokes: [PhysicalKeystroke],
        latin: String
    ) -> Decision {
        // R-D3 두 글자 이상 전부 대문자면 약어 표기 관례로 본다.
        // `GKSK`, `DHCP`, `NASA` 가 여기서 보존된다.
        if keystrokes.count >= 2, keystrokes.allSatisfy(\.shift) {
            return .preserve(rule: .acronymConvention)
        }

        guard let korean = HangulStructure.evaluate(keystrokes) else {
            return .preserve(rule: .compositionUnavailable)
        }
        // R-K1~K4
        guard korean.isStrongKoreanCandidate else {
            return .preserve(rule: .weakKoreanStructure)
        }

        let english = EnglishPhonotactics.evaluate(latin)
        if !english.isPlausible {
            return .correct(
                tier: .high,
                original: latin,
                replacement: korean.text,
                rule: .koreanStructure
            )
        }
        if english.cost >= 1 {
            // 영어로 읽는 것도 가능하지만 유표적이다. 한국어 쪽이 무결하므로
            // 마진이 한국어를 가리킨다.
            return .correct(
                tier: .medium,
                original: latin,
                replacement: korean.text,
                rule: .englishCostMargin
            )
        }
        // 두 문법 모두 무결 — `world` / `재깅` 같은 진짜 중의성.
        return .preserve(rule: .ambiguousBothValid)
    }

    // MARK: - 한→영 (화면에 한글이 있음)

    private static func evaluateKoreanSource(
        keystrokes: [PhysicalKeystroke],
        latin: String
    ) -> Decision {
        guard let korean = HangulStructure.evaluate(keystrokes) else {
            return .preserve(rule: .compositionUnavailable)
        }

        // R-D1 현대 음절로 완전히 조합되면 정상 한국어일 수 있으므로 건드리지 않는다.
        if korean.isModernKorean {
            return .preserve(rule: .modernKoreanPreserved)
        }
        // R-K5a 반복 표현 (ㅋㅋㅋ, ㅠㅠ, ㄷㄷ).
        if korean.isWholeRepetition {
            return .preserve(rule: .expressiveRepetition)
        }
        // R-K5b 자음 자모 나열 (ㅁㄴㅇ, ㅁㄴㅇㄹ).
        if korean.isConsonantJamoMash {
            return .preserve(rule: .consonantJamoMash)
        }

        let english = EnglishPhonotactics.evaluate(latin)
        guard english.isPlausible else {
            return .preserve(rule: .implausibleEnglish)
        }

        // 자음 자모만 남은 짧은 토큰(ㅈㄷ = `we`, ㄴㄷㄷ = `see`)은 실제 단어일
        // 가능성이 있어 교정하되, 확신을 낮춰 원문 칩을 함께 보인다.
        let isBareConsonantRun = korean.isAllConsonantJamo
        if english.cost == 0, !isBareConsonantRun {
            return .correct(
                tier: .high,
                original: korean.text,
                replacement: latin,
                rule: .englishStructure
            )
        }
        return .correct(
            tier: .medium,
            original: korean.text,
            replacement: latin,
            rule: .markedEnglishForm
        )
    }

    // MARK: - 물리 키 → 라틴 문자

    /// 물리 키열을 QWERTY로 읽은 문자열. 지원하지 않는 키가 있으면 `nil`.
    static func latinCandidate(for keystrokes: [PhysicalKeystroke]) -> String? {
        var result = ""
        result.reserveCapacity(keystrokes.count)
        for keystroke in keystrokes {
            guard let character = latinCharacter(
                for: keystroke.keycode,
                shift: keystroke.shift
            ) else { return nil }
            result.append(character)
        }
        return result
    }

    /// 물리 키 하나를 QWERTY 문자로 읽는다.
    static func latinCharacter(for keycode: UInt16, shift: Bool) -> Character? {
        guard let lowercase = qwertyLetters[keycode] else { return nil }
        return shift ? Character(lowercase.uppercased()) : Character(lowercase)
    }

    private static let qwertyLetters: [UInt16: String] = [
        0x00: "a", 0x01: "s", 0x02: "d", 0x03: "f", 0x04: "h", 0x05: "g",
        0x06: "z", 0x07: "x", 0x08: "c", 0x09: "v", 0x0B: "b", 0x0C: "q",
        0x0D: "w", 0x0E: "e", 0x0F: "r", 0x10: "y", 0x11: "t", 0x1F: "o",
        0x20: "u", 0x22: "i", 0x23: "p", 0x25: "l", 0x26: "j", 0x28: "k",
        0x2D: "n", 0x2E: "m",
    ]
}
