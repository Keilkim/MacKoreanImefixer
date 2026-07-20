import XCTest

final class EnglishPhonotacticsTests: XCTestCase {

    private func plausible(_ word: String) -> Bool {
        EnglishPhonotactics.evaluate(word).isPlausible
    }

    private func cost(_ word: String) -> Int {
        EnglishPhonotactics.evaluate(word).cost
    }

    // MARK: - 통과해야 하는 형태

    func testAcceptsOrdinaryEnglishStructure() {
        for word in ["hello", "world", "project", "meeting", "code", "coffee", "good", "test"] {
            XCTAssertTrue(plausible(word), "정상 영어 구조여야 합니다: \(word)")
        }
    }

    func testAcceptsWordsAbsentFromAnyDictionary() {
        // 규칙 기반이므로 사전 등재 여부와 무관하게 구조만 보고 통과시킨다.
        for word in ["kubernetes", "quora", "blorping", "strandle", "vexipop"] {
            XCTAssertTrue(plausible(word), "구조가 정상이면 통과해야 합니다: \(word)")
        }
    }

    func testAcceptsGeneratedThreeConsonantOnsets() {
        // onset 목록을 두지 않고 s + 무성폐쇄음 + 유음 규칙에서 생성된다.
        for word in ["strength", "splash", "scream", "squint"] {
            XCTAssertTrue(plausible(word), "합법 3자음 onset이어야 합니다: \(word)")
        }
    }

    func testAcceptsInflectionalAppendixCodas() {
        // R-E5 굴절 접미 자음 스트리핑.
        for word in ["sixths", "texts", "lapsed", "worlds"] {
            XCTAssertTrue(plausible(word), "굴절 어미가 붙은 coda여야 합니다: \(word)")
        }
    }

    func testAcceptsSyllabicNasalCodas() {
        // R-E9 어말 마찰음 + m.
        for word in ["prism", "chasm", "rhythm", "autism"] {
            XCTAssertTrue(plausible(word), "음절성 비음 coda여야 합니다: \(word)")
        }
    }

    func testAcceptsGlideConsonantsBetweenVowels() {
        // R-E12 모음 사이 y/w 는 자음이다.
        for word in ["sawyer", "abeyant", "away", "lawyer", "beyond"] {
            XCTAssertTrue(plausible(word), "활음 onset이어야 합니다: \(word)")
        }
    }

    func testAcceptsSilentClassicalOnsets() {
        // R-E3d 어두 한정 묵음 조합.
        for word in ["knee", "gnome", "wrist", "psalm", "pterodactyl"] {
            XCTAssertTrue(plausible(word), "어두 묵음 onset이어야 합니다: \(word)")
        }
    }

    func testAcceptsSilentGBeforeN() {
        // R-E11.
        for word in ["sign", "reign", "foreign", "design"] {
            XCTAssertTrue(plausible(word), "모음 뒤 gn 이어야 합니다: \(word)")
        }
    }

    // MARK: - 막아야 하는 형태

    func testRejectsTokensWithoutAnyVowel() {
        // R-E2. 한국어를 영문 자판으로 친 결과는 대개 영어 모음이 없다.
        for word in ["tkfkd", "gksrmf", "whgdk", "qlfem"] {
            XCTAssertFalse(plausible(word), "핵이 없으므로 실패해야 합니다: \(word)")
        }
    }

    func testRejectsIllegalStopSequencesInCoda() {
        // T1. 같은 공명도의 폐쇄음 연쇄는 무성 t 로만 닫힌다.
        XCTAssertTrue(plausible("act"), "-ct 는 합법입니다")
        XCTAssertTrue(plausible("adept"), "-pt 는 합법입니다")
        for word in ["ekdma", "goekd", "eogks"] {
            XCTAssertFalse(plausible(word), "불법 폐쇄음 연쇄여야 합니다: \(word)")
        }
    }

    func testRejectsVoicingMismatchInObstruentClusters() {
        // T3. 장애음끼리는 유성성이 일치해야 한다.
        // 마찰음 뒤 폐쇄음이라 공명도는 하강하지만 유성성이 어긋난다.
        for word in ["azk", "asg", "azp", "asb"] {
            XCTAssertFalse(plausible(word), "유성성 불일치여야 합니다: \(word)")
        }
        // 일치하면 통과한다.
        for word in ["ask", "asp", "act"] {
            XCTAssertTrue(plausible(word), "유성성이 일치합니다: \(word)")
        }
    }

    func testInflectionalAppendixDoesNotBypassVoicingRules() {
        // -ed 는 철자에 모음 e 가 들어가므로 t/d 는 맨자음 접미가 아니다.
        // `해당`(goekd), `ㅁㄴㅇ`(asd) 가 이 규칙으로 막힌다.
        for word in ["goekd", "asd"] {
            XCTAssertFalse(plausible(word), "접미로 우회되면 안 됩니다: \(word)")
        }
        // 실제 굴절형은 그대로 통과한다.
        for word in ["asked", "lapsed", "texts", "sixths", "worlds"] {
            XCTAssertTrue(plausible(word), "정상 굴절형입니다: \(word)")
        }
    }

    func testAcceptsGreekInitialDigraph() {
        // rh- 가 없으면 이 단어들이 한글로 오교정된다.
        for word in ["rhythm", "rhyme", "rhino", "rhapsody"] {
            XCTAssertTrue(plausible(word), "그리스계 어두 이중자입니다: \(word)")
        }
    }

    func testRejectsIllegalDoubledLetters() {
        // R-E7.
        for word in ["ajjo", "avvit", "ahhem", "aqqle"] {
            XCTAssertFalse(plausible(word), "겹칠 수 없는 글자입니다: \(word)")
        }
    }

    func testRejectsWordFinalJQV() {
        // R-E6.
        for word in ["baj", "iraq", "abv"] {
            XCTAssertFalse(plausible(word), "어말 j/q/v 는 불가합니다: \(word)")
        }
    }

    func testRejectsBareQWithoutFollowingVowel() {
        // R-E8.
        XCTAssertTrue(plausible("quiet"))
        XCTAssertFalse(plausible("qbert"))
    }

    func testRejectsExcessiveVowelRuns() {
        // R-C2.
        XCTAssertFalse(plausible("baaaad"))
    }

    // MARK: - 비용 (마진 판정의 근거)

    func testUnmarkedWordsCostNothing() {
        for word in ["hello", "project", "strength", "code"] {
            XCTAssertEqual(cost(word), 0, "유표적이지 않아야 합니다: \(word)")
        }
    }

    func testTrailingVowelHIsMarked() {
        // R-E10. `메모` 가 `apah` 로 읽히는 경우를 medium 으로 끌어내리는 규칙.
        let evaluation = EnglishPhonotactics.evaluate("apah")
        XCTAssertTrue(evaluation.isPlausible)
        XCTAssertGreaterThanOrEqual(evaluation.cost, 1)
    }

    func testNonStandardInitialVowelPairIsMarked() {
        // R-C1.
        let evaluation = EnglishPhonotactics.evaluate("eoan")
        XCTAssertTrue(evaluation.isPlausible)
        XCTAssertGreaterThanOrEqual(evaluation.cost, 1)
    }

    func testTripleVowelRunIsMarked() {
        // R-C2.
        let evaluation = EnglishPhonotactics.evaluate("beau")
        XCTAssertTrue(evaluation.isPlausible)
        XCTAssertGreaterThanOrEqual(evaluation.cost, 1)
    }

    // MARK: - 방어

    func testRejectsEmptyAndNonLetterInput() {
        XCTAssertFalse(plausible(""))
        XCTAssertFalse(plausible("ab1"))
        XCTAssertFalse(plausible("한글"))
    }

    func testEvaluationIsCaseInsensitive() {
        XCTAssertEqual(
            EnglishPhonotactics.evaluate("Hello"),
            EnglishPhonotactics.evaluate("hello")
        )
        XCTAssertEqual(
            EnglishPhonotactics.evaluate("PROJECT"),
            EnglishPhonotactics.evaluate("project")
        )
    }
}
