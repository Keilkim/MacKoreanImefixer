import XCTest

final class InputSourceControllerTests: XCTestCase {
    func testLatinToKoreanSelectsExactTwoSetSource() {
        let system = FakeInputSourceSystem(
            current: "com.apple.keylayout.ABC",
            selectable: [
                "com.apple.keylayout.ABC",
                InputSourceController.koreanTwoSetInputSourceID,
            ]
        )
        let controller = InputSourceController(system: system)

        let receipt = controller.switchInputSource(for: .latinToKorean)

        XCTAssertEqual(receipt?.fromInputSourceID, "com.apple.keylayout.ABC")
        XCTAssertEqual(
            receipt?.toInputSourceID,
            InputSourceController.koreanTwoSetInputSourceID
        )
        XCTAssertEqual(system.selectCalls, [InputSourceController.koreanTwoSetInputSourceID])
    }

    func testKoreanToLatinPrefersLastObservedSupportedSource() {
        let system = FakeInputSourceSystem(
            current: "com.apple.keylayout.US",
            ascii: "com.apple.keylayout.ABC",
            selectable: [
                "com.apple.keylayout.ABC",
                "com.apple.keylayout.US",
                InputSourceController.koreanTwoSetInputSourceID,
            ]
        )
        let controller = InputSourceController(system: system)
        system.current = InputSourceController.koreanTwoSetInputSourceID

        let receipt = controller.switchInputSource(for: .koreanToLatin)

        XCTAssertEqual(receipt?.toInputSourceID, "com.apple.keylayout.US")
    }

    func testKoreanToLatinFallsBackToAvailableABC() {
        let system = FakeInputSourceSystem(
            current: InputSourceController.koreanTwoSetInputSourceID,
            ascii: "com.apple.keylayout.Dvorak",
            selectable: [
                "com.apple.keylayout.ABC",
                InputSourceController.koreanTwoSetInputSourceID,
            ]
        )
        let controller = InputSourceController(system: system)

        XCTAssertEqual(
            controller.switchInputSource(for: .koreanToLatin)?.toInputSourceID,
            "com.apple.keylayout.ABC"
        )
    }

    func testSwitchFailureReturnsNoReceipt() {
        let system = FakeInputSourceSystem(
            current: "com.apple.keylayout.ABC",
            selectable: [InputSourceController.koreanTwoSetInputSourceID]
        )
        system.failingIDs = [InputSourceController.koreanTwoSetInputSourceID]
        let controller = InputSourceController(system: system)

        XCTAssertNil(controller.switchInputSource(for: .latinToKorean))
    }

    func testUndoRestoreDoesNotOverwriteManualSourceChange() {
        let system = FakeInputSourceSystem(
            current: InputSourceController.koreanTwoSetInputSourceID,
            selectable: [
                "com.apple.keylayout.ABC",
                "com.apple.keylayout.US",
                InputSourceController.koreanTwoSetInputSourceID,
            ]
        )
        let controller = InputSourceController(system: system)
        let receipt = InputSourceSwitchReceipt(
            fromInputSourceID: "com.apple.keylayout.ABC",
            toInputSourceID: InputSourceController.koreanTwoSetInputSourceID,
            selectedSourceGeneration: 1
        )
        system.current = "com.apple.keylayout.US"

        XCTAssertFalse(controller.restoreInputSource(receipt))
        XCTAssertEqual(system.current, "com.apple.keylayout.US")
        XCTAssertTrue(system.selectCalls.isEmpty)
    }

    func testUndoRestoreDetectsManualRoundTripBackToAutomaticSource() {
        let koreanID = InputSourceController.koreanTwoSetInputSourceID
        let system = FakeInputSourceSystem(
            current: "com.apple.keylayout.ABC",
            selectable: [
                "com.apple.keylayout.ABC",
                "com.apple.keylayout.US",
                koreanID,
            ]
        )
        let controller = InputSourceController(system: system)
        let receipt = try! XCTUnwrap(controller.switchInputSource(for: .latinToKorean))

        system.current = "com.apple.keylayout.US"
        controller.noteCurrentInputSource(system.current)
        system.current = koreanID
        controller.noteCurrentInputSource(system.current)

        XCTAssertFalse(controller.restoreInputSource(receipt))
        XCTAssertEqual(system.current, koreanID)
    }
}

private final class FakeInputSourceSystem: InputSourceSystem {
    var current: String
    var ascii: String?
    var selectable: Set<String>
    var failingIDs: Set<String> = []
    var selectCalls: [String] = []

    init(current: String, ascii: String? = nil, selectable: Set<String>) {
        self.current = current
        self.ascii = ascii
        self.selectable = selectable
    }

    var currentInputSourceID: String? { current }
    var currentASCIICapableInputSourceID: String? { ascii }

    func refreshSelectableInputSources() {}

    func canSelectInputSource(withID sourceID: String) -> Bool {
        selectable.contains(sourceID)
    }

    func selectInputSource(withID sourceID: String) -> Bool {
        selectCalls.append(sourceID)
        guard selectable.contains(sourceID), !failingIDs.contains(sourceID) else {
            return false
        }
        current = sourceID
        return true
    }
}
