import XCTest

/// 문자열을 물리 키열로 바꾸는 테스트 픽스처. 대문자는 물리 Shift를 뜻한다.
/// 테스트 타깃 전체가 공유한다.
enum PhysicalKeystrokeFixture {
    static let keycodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
    ]

    static func keystrokes(_ letters: String) -> [PhysicalKeystroke]? {
        var result: [PhysicalKeystroke] = []
        for character in letters {
            let lowercase = Character(character.lowercased())
            guard let keycode = keycodes[lowercase] else { return nil }
            result.append(
                PhysicalKeystroke(keycode: keycode, shift: character.isUppercase)
            )
        }
        return result
    }
}

final class LayoutCorrectionPolicyTests: XCTestCase {

    private func decide(
        _ letters: String,
        _ source: InputSourceKind
    ) -> LayoutCorrectionPolicy.Decision {
        guard let keystrokes = PhysicalKeystrokeFixture.keystrokes(letters) else {
            XCTFail("지원하지 않는 키: \(letters)")
            return .preserve(rule: .unsupportedSource)
        }
        return LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: source
        )
    }

    private func assertCorrects(
        _ letters: String,
        _ source: InputSourceKind,
        to replacement: String,
        tier: LayoutCorrectionPolicy.Tier,
        rule: LayoutCorrectionPolicy.Rule,
        line: UInt = #line
    ) {
        guard case .correct(let actualTier, _, let actualReplacement, let actualRule)
            = decide(letters, source) else {
            return XCTFail("교정되어야 합니다: \(letters)", line: line)
        }
        XCTAssertEqual(actualReplacement, replacement, line: line)
        XCTAssertEqual(actualTier, tier, line: line)
        XCTAssertEqual(actualRule, rule, line: line)
    }

    private func assertPreserves(
        _ letters: String,
        _ source: InputSourceKind,
        rule: LayoutCorrectionPolicy.Rule,
        line: UInt = #line
    ) {
        guard case .preserve(let actualRule) = decide(letters, source) else {
            return XCTFail("보존되어야 합니다: \(letters)", line: line)
        }
        XCTAssertEqual(actualRule, rule, line: line)
    }

    // MARK: - 영→한

    func testRestoresKoreanTypedOnTheLatinLayout() {
        assertCorrects("dkssudgktpdy", .supportedLatin, to: "안녕하세요",
                       tier: .high, rule: .koreanStructure)
        assertCorrects("rkatkgkqslek", .supportedLatin, to: "감사합니다",
                       tier: .high, rule: .koreanStructure)
        assertCorrects("tkfkd", .supportedLatin, to: "사랑",
                       tier: .high, rule: .koreanStructure)
        assertCorrects("gksrmf", .supportedLatin, to: "한글",
                       tier: .high, rule: .koreanStructure)
        assertCorrects("qlfem", .supportedLatin, to: "빌드",
                       tier: .high, rule: .koreanStructure)
        assertCorrects("whgdk", .supportedLatin, to: "좋아",
                       tier: .high, rule: .koreanStructure)
        // 회귀 fixture일 뿐 production 단어 목록이 아니다. `anjwl`의 영어
        // 구조가 깨지고 같은 키열의 한국어 구조가 완전하다는 일반 규칙을 검증한다.
        assertCorrects("anjwl", .supportedLatin, to: "뭐지",
                       tier: .high, rule: .koreanStructure)
    }

    func testMarkedEnglishReadingYieldsMediumConfidence() {
        // `메모` 는 `apah` 로도 읽히지만 어말 모음+h 가 유표적이라 마진이 한국어를
        // 가리킨다. 다만 확신을 낮춰 원문을 함께 노출한다.
        assertCorrects("apah", .supportedLatin, to: "메모",
                       tier: .medium, rule: .englishCostMargin)
    }

    func testPlausibleEnglishIsNeverRewritten() {
        // 대부분은 두벌식으로 읽어도 낱자모가 남아 애초에 강한 후보가 아니다.
        for word in ["hello", "quora", "rohan", "schmidt", "project"] {
            assertPreserves(word, .supportedLatin, rule: .weakKoreanStructure)
        }
        // `cory` 는 완전 조합(초갸)까지 되지만 영어로도 무결해 중의적이다.
        assertPreserves("cory", .supportedLatin, rule: .ambiguousBothValid)
    }

    func testAllCapsTokensAreTreatedAsAcronyms() {
        // 사전 조회 없이 표기 관례만으로 보존한다.
        for word in ["GKSK", "DHCP", "NASA", "TLS"] {
            assertPreserves(word, .supportedLatin, rule: .acronymConvention)
        }
    }

    func testShortOrStructurallyWeakTokensAreNotRewritten() {
        // 단음절 2키 조합은 무작위 충돌이 잦아 후보에서 제외한다.
        assertPreserves("go", .supportedLatin, rule: .weakKoreanStructure)
        assertPreserves("nth", .supportedLatin, rule: .weakKoreanStructure)
    }

    // MARK: - 한→영

    func testRestoresEnglishTypedOnTheKoreanLayout() {
        assertCorrects("hello", .koreanTwoSet, to: "hello",
                       tier: .high, rule: .englishStructure)
        assertCorrects("coffee", .koreanTwoSet, to: "coffee",
                       tier: .high, rule: .englishStructure)
        assertCorrects("code", .koreanTwoSet, to: "code",
                       tier: .high, rule: .englishStructure)
        assertCorrects("good", .koreanTwoSet, to: "good",
                       tier: .high, rule: .englishStructure)
        assertCorrects("vocal", .koreanTwoSet, to: "vocal",
                       tier: .high, rule: .englishStructure)
        // 두 모음 자모가 남는 짧은 토큰도 영어 음소배열이 무결하면 같은
        // 한→영 구조 규칙으로 복구한다. `no` 전용 production 분기는 없다.
        assertCorrects("no", .koreanTwoSet, to: "no",
                       tier: .high, rule: .englishStructure)
    }

    func testCorrectsTheOriginalTextThatIsActuallyOnScreen() {
        // 교정은 화면의 한글을 지우고 영문을 넣는다. original 이 화면과
        // 일치하지 않으면 삭제 개수가 어긋난다.
        guard case .correct(_, let original, let replacement, _)
            = decide("hello", .koreanTwoSet) else {
            return XCTFail("교정되어야 합니다")
        }
        XCTAssertEqual(original, "ㅗ디ㅣㅐ")
        XCTAssertEqual(replacement, "hello")
    }

    func testBareConsonantRunsAreCorrectedWithLowerConfidence() {
        // ㅈㄷ = `we`, ㄴㄷㄷ = `see`. 실제 단어일 수 있으므로 교정하되 확신을 낮춘다.
        assertCorrects("we", .koreanTwoSet, to: "we",
                       tier: .medium, rule: .markedEnglishForm)
        assertCorrects("see", .koreanTwoSet, to: "see",
                       tier: .medium, rule: .markedEnglishForm)
        assertCorrects("test", .koreanTwoSet, to: "test",
                       tier: .medium, rule: .markedEnglishForm)
    }

    func testModernKoreanIsNeverRewrittenIntoEnglish() {
        // 현대 음절로 완전 조합되면 정상 한국어일 수 있어 건드리지 않는다.
        // `world` -> 재깅, `auto` -> 며새 는 두 문법 모두 만족하는 진짜 중의성.
        for word in ["world", "auto", "and", "worn"] {
            assertPreserves(word, .koreanTwoSet, rule: .modernKoreanPreserved)
        }
    }

    func testRepeatedJamoExpressionsArePreserved() {
        // ㅋㅋ, ㅠㅠ, ㄷㄷㄷ. 특정 표현을 나열하지 않고 형태로 판정한다.
        for word in ["zz", "bb", "eee", "ggg", "ee"] {
            assertPreserves(word, .koreanTwoSet, rule: .expressiveRepetition)
        }
    }

    func testConsonantJamoMashIsPreserved() {
        // ㅁㄴㅇ, ㅁㄴㅇㄹ 같은 키보드 매시.
        for word in ["asd", "asdf"] {
            assertPreserves(word, .koreanTwoSet, rule: .consonantJamoMash)
        }
    }

    func testNonPhonotacticTokensArePreserved() {
        assertPreserves("nth", .koreanTwoSet, rule: .implausibleEnglish)
    }

    func testLeadingShiftKeepsItsKoreanTenseConsonantMeaning() {
        // Shift+T 는 ㅆ 이므로 화면 글자가 소문자 `test`(ㅅㄷㄴㅅ) 와 다르다.
        // ㅆㄷㄴㅅ 은 서로 다른 자음 자모 넷이라 매시로 보존된다.
        assertPreserves("Test", .koreanTwoSet, rule: .consonantJamoMash)
    }

    func testSyllableThatIsNotModernKoreanIsRestoredToEnglish() {
        // `the` 는 두벌식으로 `솓` 이 되는데, 이 음절은 현대 국어에 쓰이지 않는다.
        // KS X 1001 규칙이 없으면 여기서 잘못 보존된다.
        assertCorrects("the", .koreanTwoSet, to: "the",
                       tier: .high, rule: .englishStructure)
    }

    // MARK: - 방어

    func testUnsupportedSourceNeverCorrects() {
        assertPreserves("hello", .unsupported, rule: .unsupportedSource)
    }

    func testEmptyKeystrokesNeverCorrect() {
        guard case .preserve = LayoutCorrectionPolicy.evaluate(
            keystrokes: [],
            inputSource: .supportedLatin
        ) else {
            return XCTFail("빈 입력은 보존되어야 합니다")
        }
    }

    func testDecisionNeverDependsOnAnyDictionaryOrSystemService() {
        // 규칙만으로 결정되므로 같은 입력은 언제나 같은 결과를 낸다.
        for _ in 0..<3 {
            assertCorrects("tkfkd", .supportedLatin, to: "사랑",
                           tier: .high, rule: .koreanStructure)
        }
    }
}
