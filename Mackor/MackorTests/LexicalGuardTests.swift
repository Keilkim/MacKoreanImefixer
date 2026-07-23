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

    /// 단음절 관문 시험용 최소 자산. 실제 자산은 `MonosyllableLexiconTests`가 다룬다.
    private let stub = MonosyllableLexicon(entries: [
        "fmf": "를", "sms": "는", "dho": "왜", "fh": "로", "Qns": "뿐",
    ])

    // MARK: - 영→한 단음절 관문

    /// `dns`→운: 자산에 없는 단음절은 보존. 약어 파괴가 여기서 멈춘다.
    func testVowellessLatinToSingleSyllableIsVetoed() {
        let vetoed = LexicalGuard.apply(
            decision(
                original: "dns", replacement: "운",
                direction: .latinToKorean, tier: .high, rule: .koreanStructure
            ),
            englishEvidence: nil,
            monosyllables: stub
        )
        XCTAssertNil(vetoed, "자산 밖 단음절 교정(약어 파괴)이 통과했습니다")
    }

    /// 자산이 확인해 준 단음절은 통과한다. 모음 유무는 더 이상 기준이 아니다 —
    /// `fmf`(를)·`sms`(는)는 무모음인데도 통과하고, `dho`(왜)는 모음이 있어서가
    /// 아니라 자산에 있어서 통과한다.
    func testSingleSyllableInLexiconPasses() {
        for (latin, korean) in [("fmf", "를"), ("sms", "는"), ("dho", "왜")] {
            let resolved = LexicalGuard.apply(
                decision(
                    original: latin, replacement: korean,
                    direction: .latinToKorean, tier: .high, rule: .koreanStructure
                ),
                englishEvidence: nil,
                monosyllables: stub
            )
            XCTAssertEqual(resolved?.replacement, korean, "\(latin) 가 거부됐습니다")
            XCTAssertEqual(resolved?.original, latin)
            XCTAssertEqual(resolved?.direction, .latinToKorean)
            XCTAssertEqual(resolved?.rule, .koreanStructure)
        }
    }

    /// 단음절은 `.medium`으로 강등된다 — 판정이 아니라 되돌릴 창을 넓히는 변경이다.
    /// 진단도 함께 갱신돼야 로그가 결정과 다른 등급을 말하지 않는다.
    func testSingleSyllableIsDemotedToMedium() {
        let diagnostic = CorrectionDiagnostic(
            direction: .latinToKorean, tier: .high,
            rule: .koreanStructure, tokenLength: 3, boundary: .space
        )
        let resolved = LexicalGuard.apply(
            CorrectionDecision(
                original: "fmf", replacement: "를",
                direction: .latinToKorean, tier: .high,
                rule: .koreanStructure, diagnostic: diagnostic
            ),
            englishEvidence: nil,
            monosyllables: stub
        )
        XCTAssertEqual(resolved?.tier, .medium, "단음절이 강등되지 않았습니다")
        XCTAssertEqual(resolved?.diagnostic?.tier, .medium, "진단이 결정과 다른 등급을 말합니다")
        XCTAssertEqual(resolved?.diagnostic?.rule, .koreanStructure)
        XCTAssertEqual(resolved?.diagnostic?.tokenLength, 3)
        XCTAssertEqual(resolved?.originalCharacterCount, 3)
        XCTAssertEqual(resolved?.replacementCharacterCount, 1)
    }

    /// **오늘 실제로 파괴 중인 사례.** `cma`에는 라틴 모음 `a`가 있어 옛 무모음
    /// 게이트를 그냥 통과했고, 빈도 0의 비단어 `츰`으로 바뀌고 있었다.
    /// 관문이 그것을 닫는다.
    func testVowelBearingSingleSyllableOutsideLexiconIsVetoed() {
        for (latin, korean) in [("cma", "츰"), ("aht", "못"), ("dha", "옴")] {
            let vetoed = LexicalGuard.apply(
                decision(
                    original: latin, replacement: korean,
                    direction: .latinToKorean, tier: .high, rule: .koreanStructure
                ),
                englishEvidence: nil,
                monosyllables: stub
            )
            XCTAssertNil(vetoed, "\(latin)→\(korean) 파괴가 통과했습니다")
        }
    }

    /// 자산과 엔진이 **다른 음절**을 가리키면 어느 쪽도 믿지 않는다.
    func testLexiconDisagreementIsVetoed() {
        let vetoed = LexicalGuard.apply(
            decision(
                original: "fmf", replacement: "륿",
                direction: .latinToKorean, tier: .high, rule: .koreanStructure
            ),
            englishEvidence: nil,
            monosyllables: stub
        )
        XCTAssertNil(vetoed, "자산과 어긋난 음절이 통과했습니다")
    }

    /// 대소문자를 접으면 다른 자모가 된다. 자산에 `Qns`(뿐)만 있을 때
    /// `qns`(분)는 조회에 실패해야 한다.
    func testExemptionIsCaseExact() {
        let vetoed = LexicalGuard.apply(
            decision(
                original: "qns", replacement: "분",
                direction: .latinToKorean, tier: .high, rule: .koreanStructure
            ),
            englishEvidence: nil,
            monosyllables: stub
        )
        XCTAssertNil(vetoed, "대소문자를 접어 다른 음절을 통과시켰습니다")
    }

    /// 자산이 없으면 단음절 교정이 **전부** 사라진다(fail-closed).
    func testMissingLexiconFailsClosed() {
        for (latin, korean) in [("fh", "로"), ("dho", "왜"), ("fmf", "를")] {
            XCTAssertNil(
                LexicalGuard.apply(
                    decision(
                        original: latin, replacement: korean,
                        direction: .latinToKorean, tier: .high, rule: .koreanStructure
                    ),
                    englishEvidence: nil
                ),
                "\(latin): 자산 없이 단음절이 통과했습니다"
            )
        }
    }

    /// `css`는 두벌식으로 `ㅊㄴㄴ`(음절 0)이라 이 계층에 **도달조차 하지 않는다.**
    /// 옛 주석이 css를 무모음 게이트의 보호 대상으로 적은 것은 사실 오류였고,
    /// 그 사실을 테스트로 고정한다.
    func testCssNeverReachesThisLayer() {
        guard let keystrokes = PhysicalKeystrokeFixture.keystrokes("css") else {
            return XCTFail("키열을 만들지 못했습니다")
        }
        guard case .preserve(let rule) = LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: .supportedLatin
        ) else {
            return XCTFail("css 가 교정 판정을 받았습니다")
        }
        XCTAssertEqual(rule, .weakKoreanStructure, "css 는 단음절조차 아닙니다")
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

    /// 자음 매시 구제(`consonantJamoMash`)는 medium을 유지한다 — 구조가
    /// '보존'으로 판정한 것을 사전만으로 뒤집은 결정이라 확신이 낮고, 원문 칩을
    /// 6초 내내 강조해 되돌리기를 열어 둔다. 엔진이 이미 교정하기로 한 순수 자음
    /// (`markedEnglishForm`)의 medium→high 승격과 구분한다.
    func testConsonantMashRescueStaysMedium() {
        let resolved = LexicalGuard.apply(
            decision(
                original: "ㅊㅁㄱㅇ", replacement: "card",
                direction: .koreanToLatin, rule: .consonantJamoMash
            ),
            englishEvidence: ["card"]
        )
        XCTAssertEqual(resolved?.tier, .medium, "매시 구제가 high로 승격됐습니다")
        XCTAssertEqual(resolved?.diagnostic?.tier ?? .medium, .medium)
        XCTAssertEqual(resolved?.replacement, "card")
        XCTAssertEqual(resolved?.original, "ㅊㅁㄱㅇ")
    }

    /// 매시 구제도 사전 게이트를 그대로 지난다 — 결과가 사전에 없으면 보존.
    func testConsonantMashRescueVetoedWhenNotAWord() {
        let vetoed = LexicalGuard.apply(
            decision(
                original: "ㅁㄴㅇㄹ", replacement: "asdf",
                direction: .koreanToLatin, rule: .consonantJamoMash
            ),
            englishEvidence: ["card", "water"]
        )
        XCTAssertNil(vetoed, "사전에 없는 매시 결과가 통과했습니다")
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
