import Foundation

/// 동결 엔진 **밖**의 최종 거부권·강화 계층.
///
/// v4 규칙 엔진(`LayoutCorrectionPolicy`)은 사전 없이 구조만으로 판정하는데,
/// 그 결과 "조합만 되면 바꾸는" 파괴적 오교정이 남습니다. 실사용 예:
/// - `ㅁㅊ`(미친) → `ac` — `ac`는 실제 단어가 아닌데 굳어진 자모 표현을 파괴
/// - `dns` → `운` — `dns`는 실사용 약어인데 `운`은 단독으로 쓰지 않음
///
/// 엔진 자산은 pre-imk 태그와 바이트 단위로 동결돼 있어(engine-freeze.sha256,
/// CI가 태그 diff로 강제) 규칙 자체를 고칠 수 없습니다. 이 계층은 동결 밖에서,
/// 엔진이 이미 낸 `.correct` 판정에 대해서만 개입합니다.
///
/// ## 예시 나열이 아니라 구조와 데이터로 판정한다
///
/// `ㅁㅊ`·`ㅇㅈ`·`dns`·`sns`를 손으로 나열하면 끝이 없습니다. 대신:
///
/// 1. **영→한 구조 거부**: 결과가 한 음절뿐이고 원문에 영어 모음(aeiou)이
///    하나도 없으면 교정하지 않습니다. `dns`→운, `sns`→눈, `xml`·`css`류
///    소문자 약어가 정확히 이 형태입니다(모음 없는 라틴 → 단음절). 반대로
///    `dho`→왜, `anf`→물 같은 정상 단음절 교정은 모음이 있어 통과합니다.
///    사전이 전혀 필요 없는 순수 구조 규칙입니다.
/// 2. **한→영 사전 게이트**: 원문이 순수 자음 자모(`ㅁㅊ`, `ㅈㄷ`)면 결과가
///    실제 영어 단어일 때만 교정합니다. `we`·`see`·`test`는 사전에 있어
///    교정되고(신뢰가 확인됐으므로 `medium→high`), `ac`·`tq`는 없어 보존됩니다.
///    굳어진 한국어 자모 표현을 나열하지 않아도, 그 영어 대응물이 단어가
///    아니라는 사실이 자동으로 지켜줍니다.
///
/// 사전은 손 목록이 아니라 `scripts/lexicon/make_guard_lexicon.py`가 OS 영어
/// 사전(`/usr/share/dict/words`)에서 생성한 투영입니다. 순수 자음 자모가 되는
/// 단어는 자음 자판 글자({q,w,e,r,t,a,s,d,f,g,z,x,c,v})만으로 적힌 단어뿐이라,
/// 그 부분집합만 남기면 이 게이트에 대해 무손실입니다 — `LexicalTiebreaker`의
/// 투영 철학 그대로입니다. 자산은 lexicon-freeze.sha256으로 고정합니다.
///
/// ## 개입 계약 — 기준은 여전히 규칙이다
///
/// - 거부권과 `medium→high` 강화만 행사합니다. `preserve`를 `correct`로 바꾸는
///   일은 없습니다(새 교정 생성 금지). 원문·교정문·방향도 바꾸지 않습니다.
/// - 사전으로 이미 확정된 판정(`ambiguousBothValid`, LexicalTiebreaker 경유)에는
///   개입하지 않습니다 — 거기는 실단어 확인이 끝난 곳입니다.
/// - 사전 자산이 없으면 순수 자음 게이트는 fail-closed(보존)입니다. 파괴를
///   막는 쪽이 교정을 놓치는 쪽보다 우선합니다.
///
/// 호출 지점은 `EventTapManager.resolveBoundary` 하나 — 엔진·어휘·방향 재판정
/// 세 경로가 전부 그 출구를 지나므로, 일반 경로와 방향 재판정 경로가 같은
/// 최종 resolver를 쓴다는 요구가 구조적으로 충족됩니다.
enum LexicalGuard {

    /// 번들된 guard 사전을 읽습니다. 자산이 없으면 `nil` — 호출자는 순수 자음
    /// 게이트를 fail-closed(보존)로 운용합니다.
    static func loadEnglishEvidence(bundle: Bundle) -> Set<String>? {
        guard let url = bundle.url(forResource: "en-guard.v1", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return nil
        }
        return parseEnglishEvidence(text)
    }

    static func parseEnglishEvidence(_ text: String) -> Set<String> {
        Set(text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }

    /// 엔진이 낸 `.correct` 결정에 거부권·강화를 적용합니다.
    ///
    /// - 반환 `nil`: 교정하지 않고 보존합니다(원문 무사).
    /// - 반환 결정: 통과(그대로) 또는 등급만 올린 사본.
    static func apply(
        _ decision: CorrectionDecision,
        englishEvidence: Set<String>?
    ) -> CorrectionDecision? {
        // LexicalTiebreaker가 실단어 확인을 끝낸 판정에는 개입하지 않습니다.
        guard decision.rule != .ambiguousBothValid else { return decision }

        switch decision.direction {
        case .latinToKorean:
            // 구조 거부: 모음 없는 라틴 → 단음절 한글은 약어(dns·sns·xml)의
            // 형태다. 단음절은 원래 증거가 약한데(2키 하한이 이미 그 이유로
            // 존재) 모음까지 없으면 영어 쪽 실사용 약어일 개연성이 더 높다.
            let original = decision.original.lowercased()
            let isVowelless = !original.contains(where: { "aeiou".contains($0) })
            if isVowelless, hangulSyllableCount(decision.replacement) == 1 {
                return nil
            }
            return decision

        case .koreanToLatin:
            // 순수 자음 자모 원문은 (a) 자음 자판 글자만으로 친 실제 영어
            // 단어이거나 (b) 굳어진 한국어 자모 표현·매시다. 사전이 (a)를
            // 확인해 주면 확신을 올려 교정하고, 아니면 원문을 보존한다.
            guard isAllCompatibilityConsonants(decision.original) else {
                return decision
            }
            guard let evidence = englishEvidence,
                  let key = LexicalTiebreaker.englishLookupKey(decision.replacement),
                  evidence.contains(key) else {
                return nil
            }
            guard decision.tier == .medium else { return decision }
            return CorrectionDecision(
                original: decision.original,
                replacement: decision.replacement,
                direction: decision.direction,
                tier: .high,
                rule: decision.rule,
                diagnostic: decision.diagnostic
            )
        }
    }

    // MARK: - 문자 분류

    private static func hangulSyllableCount(_ text: String) -> Int {
        text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count
    }

    private static func isAllCompatibilityConsonants(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { (0x3131...0x314E).contains($0.value) }
    }
}
