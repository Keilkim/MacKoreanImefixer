import XCTest

final class HangulCompositionTests: XCTestCase {

    private let vowels: Set<Character> = [
        "ㅏ", "ㅐ", "ㅑ", "ㅒ", "ㅓ", "ㅔ", "ㅕ", "ㅖ", "ㅗ", "ㅛ",
        "ㅜ", "ㅠ", "ㅡ", "ㅣ",
    ]

    private func jamo(_ character: Character) -> Jamo {
        Jamo(
            type: vowels.contains(character) ? .vowel : .consonant,
            character: character,
            keycode: 0,
            shifted: false
        )
    }

    @discardableResult
    private func type(
        _ sequence: String,
        with tracker: HangulCompositionTracker,
        into text: inout String
    ) -> [CompositionResult] {
        sequence.map { character in
            let result = tracker.processJamo(jamo(character))
            apply(result, to: &text)
            return result
        }
    }

    private func apply(_ result: CompositionResult, to text: inout String) {
        XCTAssertFalse(result.passthrough)
        for _ in 0..<result.deleteCount {
            XCTAssertFalse(text.isEmpty, "조합기가 화면에 없는 문자를 삭제하려고 함")
            if !text.isEmpty {
                text.removeLast()
            }
        }
        text.append(contentsOf: result.insertText)
    }

    func testStandaloneVowelThenConsonantStartsNewChoseong() {
        let tracker = HangulCompositionTracker()
        var text = ""

        let results = type("ㅏㄴ", with: tracker, into: &text)

        XCTAssertEqual(text, "ㅏㄴ")
        XCTAssertEqual(results.last, .handled(delete: 0, insert: "ㄴ"))
        XCTAssertEqual(tracker.state, .choseong)

        type("ㅏ", with: tracker, into: &text)
        XCTAssertEqual(text, "ㅏ나")
        XCTAssertEqual(tracker.state, .syllable)
    }

    func testStandaloneCompoundVowelThenConsonantDoesNotLoseConsonant() {
        let tracker = HangulCompositionTracker()
        var text = ""

        type("ㅗㅏㅣㄴ", with: tracker, into: &text)

        XCTAssertEqual(text, "ㅙㄴ")
        XCTAssertEqual(tracker.state, .choseong)
    }

    func testThreeStepWaeUsesCurrentCompoundVowel() {
        let tracker = HangulCompositionTracker()
        var text = ""

        type("ㄱㅗㅏㅣ", with: tracker, into: &text)

        XCTAssertEqual(text, "괘")
        XCTAssertNotEqual(text, "괴")
        XCTAssertEqual(tracker.state, .syllable)
    }

    func testThreeStepWeUsesCurrentCompoundVowel() {
        let tracker = HangulCompositionTracker()
        var text = ""

        type("ㄱㅜㅓㅣ", with: tracker, into: &text)

        XCTAssertEqual(text, "궤")
        XCTAssertEqual(tracker.state, .syllable)
    }

    func testThreeStepCompoundVowelBackspaceRestoresEveryInputStage() {
        let tracker = HangulCompositionTracker()
        var text = ""
        type("ㄱㅗㅏㅣ", with: tracker, into: &text)

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "과")

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "고")

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "ㄱ")

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "")
        XCTAssertEqual(tracker.state, .idle)
        XCTAssertTrue(tracker.processBackspace().passthrough)
    }

    func testThreeStepWeBackspaceRestoresEveryInputStage() {
        let tracker = HangulCompositionTracker()
        var text = ""
        type("ㄱㅜㅓㅣ", with: tracker, into: &text)

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "궈")

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "구")
    }

    func testBackspaceUsesActualVowelInputPath() {
        let directTracker = HangulCompositionTracker()
        var directText = ""
        type("ㄱㅗㅐ", with: directTracker, into: &directText)
        XCTAssertEqual(directText, "괘")
        apply(directTracker.processBackspace(), to: &directText)
        XCTAssertEqual(directText, "고")

        let steppedTracker = HangulCompositionTracker()
        var steppedText = ""
        type("ㄱㅗㅏㅣ", with: steppedTracker, into: &steppedText)
        XCTAssertEqual(steppedText, "괘")
        apply(steppedTracker.processBackspace(), to: &steppedText)
        XCTAssertEqual(steppedText, "과")
    }

    func testCompoundVowelHistorySurvivesJongseongBackspace() {
        let tracker = HangulCompositionTracker()
        var text = ""
        type("ㄱㅗㅏㅣㄴ", with: tracker, into: &text)
        XCTAssertEqual(text, "괜")

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "괘")

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "과")

        apply(tracker.processBackspace(), to: &text)
        XCTAssertEqual(text, "고")
    }

    func testResetPreventsDeletingTextAtANewInsertionPoint() {
        let tracker = HangulCompositionTracker()
        var oldText = ""
        type("ㄱㅏ", with: tracker, into: &oldText)
        XCTAssertEqual(oldText, "가")

        tracker.reset()
        var newInsertionPointText = ""
        let result = tracker.processJamo(jamo("ㄴ"))
        apply(result, to: &newInsertionPointText)

        XCTAssertEqual(result.deleteCount, 0)
        XCTAssertEqual(newInsertionPointText, "ㄴ")
        XCTAssertEqual(oldText, "가")
    }

    func testNonJamoCommitsAndResetsComposition() {
        let tracker = HangulCompositionTracker()
        var text = ""
        type("ㄱㅏ", with: tracker, into: &text)

        XCTAssertTrue(tracker.processNonJamo().passthrough)
        XCTAssertEqual(tracker.state, .idle)

        let result = tracker.processJamo(jamo("ㄴ"))
        XCTAssertEqual(result, .handled(delete: 0, insert: "ㄴ"))
    }

    func testCompoundJongseongSplitStillWorks() {
        let tracker = HangulCompositionTracker()
        var text = ""

        type("ㄷㅏㄹㄱㅏ", with: tracker, into: &text)

        XCTAssertEqual(text, "달가")
        XCTAssertEqual(tracker.state, .syllable)
    }
}
