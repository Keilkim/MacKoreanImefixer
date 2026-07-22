import XCTest

/// 동결 엔진 밖 최종 거부권·강화 계층(LexicalGuard)의 계약을 고정한다.
///
/// 핵심 계약: 거부권과 medium→high 강화만 행사하고, preserve를 correct로
/// 바꾸는 일(새 교정 생성)은 절대 없다. 예시 나열이 아니라 구조(모음 없는
/// 라틴→단음절)와 데이터(자음 자판 투영 사전)로 판정한다.
final class LexicalGuardTests: XCTestCase {

    private func decision(
        original: String,
        replacement: String,
        direction: CorrectionDirection,
        tier: LayoutCorrectionPolicy.Tier = .medium,
        rule: LayoutCorrectionPolicy.Rule
    ) -> CorrectionDecision {
        CorrectionDecision(
            original: original,
            replacement: replacement,
            direction: direction,
            tier: tier,
            rule: rule
        )
    }

    // MARK: - 영→한 구조 거부 (사전 불필요)

    /// `dns`→운: 모음 없는 라틴이 단음절이 되는 것은 약어의 형태 — 보존.
    func testVowellessLatinToSingleSyllableIsVetoed() {
        let vetoed = LexicalGuard.apply(
            decision(
                original: "dns", replacement: "운",
                direction: .latinToKorean, tier: .high, rule: .koreanStructure
            ),
            englishEvidence: nil
        )
        XCTAssertNil(vetoed, "모음 없는 단음절 교정(약어 파괴)이 통과했습니다")
    }

    /// `dho`→왜: 원문에 모음(o)이 있으면 정상 단음절 교정 — 통과.
    func testSingleSyllableWithVowelPasses() {
        let original = decision(
            original: "dho", replacement: "왜",
            direction: .latinToKorean, tier: .high, rule: .koreanStructure
        )
        XCTAssertEqual(
            LexicalGuard.apply(original, englishEvidence: nil), original,
            "모음 있는 정상 단음절 교정이 거부됐습니다"
        )
    }

    /// `dkwn`→아주: 2음절이면 모음이 없어도 통과.
    func testMultiSyllablePassesEvenWithoutVowel() {
        let original = decision(
            original: "dkwn", replacement: "아주",
            direction: .latinToKorean, tier: .high, rule: .koreanStructure
        )
        XCTAssertEqual(LexicalGuard.apply(original, englishEvidence: nil), original)
    }

    /// LexicalTiebreaker가 실단어로 확정한 판정(ambiguousBothValid)에는
    /// 단음절이어도 개입하지 않는다.
    func testAmbiguousDictionaryDecisionIsExempt() {
        let original = decision(
            original: "rhk", replacement: "과",
            direction: .latinToKorean, tier: .high, rule: .ambiguousBothValid
        )
        XCTAssertEqual(LexicalGuard.apply(original, englishEvidence: nil), original)
    }

    // MARK: - 한→영 순수 자음 사전 게이트

    /// `ㅁㅊ`→ac: 결과가 사전에 없으면 굳어진 자모 표현 — 보존.
    /// ㅁㅊ을 나열하지 않아도 ac가 단어가 아니라는 사실이 지켜준다.
    func testConsonantOriginalWithNonWordResultIsVetoed() {
        let vetoed = LexicalGuard.apply(
            decision(
                original: "ㅁㅊ", replacement: "ac",
                direction: .koreanToLatin, rule: .markedEnglishForm
            ),
            englishEvidence: ["we", "see"]
        )
        XCTAssertNil(vetoed, "비단어 결과로의 자모 표현 파괴가 통과했습니다")
    }

    /// `ㅈㄷ`→we: 결과가 실단어면 교정하되 확신이 확인됐으므로 medium→high.
    func testConsonantOriginalWithRealWordUpgradesToHigh() {
        let resolved = LexicalGuard.apply(
            decision(
                original: "ㅈㄷ", replacement: "we",
                direction: .koreanToLatin, rule: .markedEnglishForm
            ),
            englishEvidence: ["we"]
        )
        XCTAssertEqual(resolved?.tier, .high, "실단어 결과의 등급 강화가 안 됐습니다")
        XCTAssertEqual(resolved?.replacement, "we")
        XCTAssertEqual(resolved?.original, "ㅈㄷ")
    }

    /// 사전 자산이 없으면 순수 자음 게이트는 fail-closed(보존) — 파괴를 막는
    /// 쪽이 교정을 놓치는 쪽보다 우선한다.
    func testConsonantGateFailsClosedWithoutEvidence() {
        let vetoed = LexicalGuard.apply(
            decision(
                original: "ㅈㄷ", replacement: "we",
                direction: .koreanToLatin, rule: .markedEnglishForm
            ),
            englishEvidence: nil
        )
        XCTAssertNil(vetoed)
    }

    /// 순수 자음이 아닌 원문(솓→the)은 사전 없이도 기존대로 통과한다 —
    /// 고유명사·미등재 토큰 교정(github류)을 사전이 막지 않는다.
    func testNonConsonantOriginalPassesWithoutEvidence() {
        let original = decision(
            original: "솓", replacement: "the",
            direction: .koreanToLatin, rule: .markedEnglishForm
        )
        XCTAssertEqual(LexicalGuard.apply(original, englishEvidence: nil), original)
    }

    /// 저장소의 실제 guard 투영을 읽어 파괴 사례와 교정 사례를 함께 고정한다.
    func testRepositoryProjectionCoversTheMotivatingCases() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        let url = root.appendingPathComponent("scripts/lexicon/en-guard.v1.txt")
        let evidence = LexicalGuard.parseEnglishEvidence(
            try String(contentsOf: url, encoding: .utf8)
        )
        for word in ["we", "see", "test", "wet"] {
            XCTAssertTrue(evidence.contains(word), "\(word)가 투영에 없습니다")
        }
        for junk in ["ac", "tq", "dw"] {
            XCTAssertFalse(evidence.contains(junk), "\(junk)이 투영에 있습니다")
        }
    }
}
