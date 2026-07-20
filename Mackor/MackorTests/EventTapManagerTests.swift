import XCTest
import CoreGraphics

final class EventTapManagerTests: XCTestCase {
    func testSpaceCorrectionReplacesTokenAndRequestsKoreanSource() throws {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var switchedDirections: [CorrectionDirection] = []
        manager.onInputSourceSwitch = { direction in
            switchedDirections.append(direction)
            return InputSourceSwitchReceipt(
                fromInputSourceID: "com.apple.keylayout.ABC",
                toInputSourceID: InputSourceController.koreanTwoSetInputSourceID,
                selectedSourceGeneration: 2
            )
        }

        type("dho", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("왜"),
            .key(0x31, false),
        ])
        XCTAssertEqual(switchedDirections, [.latinToKorean])
    }

    func testScreenshotExampleDkwnReplacesWithAju() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dkwn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("아주"),
            .key(0x31, false),
        ])
    }

    func testShortRuleDerivedCorrectionsReachThePostBoundaryFlow() {
        let examples: [(
            physical: String,
            source: InputSourceKind,
            replacement: String,
            originalCharacterCount: Int,
            direction: CorrectionDirection
        )] = [
            ("anjwl", .supportedLatin, "뭐지", 5, .latinToKorean),
            ("no", .koreanTwoSet, "no", 2, .koreanToLatin),
        ]

        for example in examples {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = example.source
            manager.isAutoCorrectionEnabled = true
            var switchedDirections: [CorrectionDirection] = []
            manager.onInputSourceSwitch = { direction in
                switchedDirections.append(direction)
                return nil
            }

            type(example.physical, into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: example.originalCharacterCount + 1
            )
            expected.append(.text(example.replacement))
            expected.append(.key(0x31, false))
            XCTAssertEqual(output.actions, expected, example.physical)
            XCTAssertEqual(switchedDirections, [example.direction], example.physical)
        }
    }

    func testQuestionMarkBoundaryPreservesShift() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("dksehlsmsrjsep", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        XCTAssertEqual(Array(output.actions.suffix(2)), [
            .text("안되는건데"),
            .key(0x2C, true),
        ])
    }

    func testImmediateBoundariesPreserveTheirPhysicalModifier() {
        let boundaries: [(UInt16, Bool)] = [
            (0x31, false), // Space
            (0x2B, false), // ,
            (0x2C, true),  // ?
            (0x12, true),  // !
        ]

        for (keycode, shift) in boundaries {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            XCTAssertNotNil(manager.handleKeyDown(keyDown(keycode, shift: shift)))
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
            XCTAssertEqual(output.actions.last, .key(keycode, shift))
        }
    }

    func testOneToThreePeriodsDeferUntilSpaceAndReinjectWholeSequence() {
        for periodCount in 1...3 {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            var scheduledCorrections: [() -> Void] = []
            let manager = makeManager(
                output: output,
                focus: focus,
                scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
            )
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            for _ in 0..<periodCount {
                XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
                XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
                XCTAssertTrue(scheduledCorrections.isEmpty)
                XCTAssertTrue(output.actions.isEmpty)
            }

            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertTrue(scheduledCorrections.isEmpty)
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertEqual(scheduledCorrections.count, 1)
            scheduledCorrections.removeFirst()()

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: 6 + periodCount + 1
            )
            expected.append(.text("한글"))
            expected.append(contentsOf: Array(
                repeating: .key(0x2F, false),
                count: periodCount
            ))
            expected.append(.key(0x31, false))
            XCTAssertEqual(output.actions, expected)
            XCTAssertEqual(focus.currentFocusOffsets, [6 + periodCount + 1])
        }
    }

    func testPeriodsCanBeFinalizedByEveryImmediateBoundary() {
        let finalBoundaries: [(UInt16, Bool)] = [
            (0x31, false), // Space
            (0x2B, false), // ,
            (0x2C, true),  // ?
            (0x12, true),  // !
        ]

        for (triggerKeycode, triggerShift) in finalBoundaries {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(
                triggerKeycode,
                shift: triggerShift
            )))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(triggerKeycode)))

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: 8
            )
            expected.append(.text("한글"))
            expected.append(.key(0x2F, false))
            expected.append(.key(triggerKeycode, triggerShift))
            XCTAssertEqual(output.actions, expected)
            XCTAssertEqual(focus.currentFocusOffsets, [8])
        }
    }

    func testKoreanSourceMultiBoundaryUsesCharacterAndUTF16CountsNotStrokeCount() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true
        type("hello", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        // `hello`의 한글 원문은 5 strokes가 4 Characters/UTF-16 units로
        // 표시됩니다. 삭제와 caret 검증은 물리 stroke 수를 사용하면 안 됩니다.
        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("hello"),
            .key(0x2F, false),
            .key(0x2F, false),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])
    }

    func testFourthPeriodDiscardsWholeRunAtFollowingSpace() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        for _ in 0..<4 {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
    }

    func testLetterDigitAndInternalSymbolsAfterPeriodDiscardWholeRun() {
        let internalCharacters: [(UInt16, Bool, String)] = [
            (Self.keycodes["c"]!, false, "letter"),
            (0x12, false, "digit"),
            (0x1B, true, "underscore"),
            (0x2C, false, "slash"),
            (0x13, true, "at sign"),
        ]

        for (keycode, shift, label) in internalCharacters {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))

            XCTAssertNotNil(manager.handleKeyDown(keyDown(keycode, shift: shift)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

            XCTAssertTrue(output.actions.isEmpty, label)
            XCTAssertTrue(focus.currentFocusOffsets.isEmpty, label)
        }
    }

    func testBackspacePopsOnlyOneBufferedPeriodBeforeEvaluation() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))

        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x33)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        var expected = Array(
            repeating: FakeKeyboardOutput.Action.key(0x33, false),
            count: 8
        )
        expected.append(.text("한글"))
        expected.append(.key(0x2F, false))
        expected.append(.key(0x31, false))
        XCTAssertEqual(output.actions, expected)
        XCTAssertEqual(focus.currentFocusOffsets, [8])
    }

    func testBackspaceRemovesLetterStrokeAfterAllPeriodsArePopped() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))

        // 첫 Backspace는 period, 둘째는 마지막 `f` stroke를 제거합니다.
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x33)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x33)))
        type("f", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
    }

    func testEnterAndTabCorrectBeforeTheKeyReachesTheApp() {
        // 제출 키는 앱에 먼저 전달하면 안 됩니다. 메시지가 이미 전송된 뒤에는
        // 지우고 다시 쓸 수 없기 때문입니다. 따라서 교정할 것이 있으면 키를
        // 붙잡고, 교정한 다음 그 키를 주입합니다.
        for submitKeycode: UInt16 in [0x24, 0x4C, 0x30] {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            XCTAssertNil(
                manager.handleKeyDown(keyDown(submitKeycode)),
                "교정이 있으면 제출 키를 붙잡아야 합니다"
            )

            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: 6
            )
            expected.append(.text("한글"))
            expected.append(.key(submitKeycode, false))
            XCTAssertEqual(output.actions, expected, "keycode \(submitKeycode)")

            // 커서는 원문 끝(경계 문자 없음)에서 확인해야 합니다.
            XCTAssertEqual(focus.currentFocusOffsets, [6])
        }
    }

    func testSubmitCorrectionDoesNotUseTheDelayedPostBoundaryScheduler() {
        // Space 계열의 20ms 정착 scheduler를 제출 키에도 사용하면, 그 사이
        // 다음 물리 키가 Enter를 추월할 수 있습니다. 제출 교정은 keyDown
        // 처리 안에서 끝나야 합니다.
        let output = FakeKeyboardOutput()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))
        XCTAssertTrue(scheduledCorrections.isEmpty)
        XCTAssertEqual(Array(output.actions.suffix(2)), [
            .text("한글"),
            .key(0x24, false),
        ])
    }

    func testSubmitAfterTrailingPeriodsPreservesTheWholeBoundarySequence() {
        for submitKeycode: UInt16 in [0x24, 0x4C, 0x30] {
            for periodCount in 1...3 {
                let output = FakeKeyboardOutput()
                let focus = FakeFocusInspector()
                let manager = makeManager(output: output, focus: focus)
                manager.inputSourceKind = .supportedLatin
                manager.isAutoCorrectionEnabled = true
                type("gksrmf", into: manager)

                for _ in 0..<periodCount {
                    XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
                    XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
                }
                XCTAssertTrue(output.actions.isEmpty)

                XCTAssertNil(manager.handleKeyDown(keyDown(submitKeycode)))

                var expected = Array(
                    repeating: FakeKeyboardOutput.Action.key(0x33, false),
                    count: 6 + periodCount
                )
                expected.append(.text("한글"))
                expected.append(contentsOf: Array(
                    repeating: .key(0x2F, false),
                    count: periodCount
                ))
                expected.append(.key(submitKeycode, false))
                XCTAssertEqual(output.actions, expected)
                XCTAssertEqual(focus.currentFocusOffsets, [6 + periodCount])
            }
        }
    }

    func testSubmitKeyIsAlwaysDeliveredEvenWhenTheCorrectionIsAbandoned() {
        // 포커스가 어긋나 교정을 포기하더라도 사용자의 Enter 를 삼키면 안 됩니다.
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))
        XCTAssertEqual(
            output.actions,
            [.key(0x24, false)],
            "교정 없이 Enter만 주입되어야 합니다"
        )
    }

    func testSubmitKeyPassesThroughUntouchedWhenThereIsNothingToCorrect() {
        // 가장 흔한 경로. 교정 후보가 없으면 키를 붙잡지 않아 기존 동작과 같습니다.
        for submitKeycode: UInt16 in [0x24, 0x4C, 0x30] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("hello", into: manager)  // 중의적이라 교정하지 않음

            XCTAssertNotNil(manager.handleKeyDown(keyDown(submitKeycode)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(submitKeycode)))
            XCTAssertTrue(output.actions.isEmpty, "keycode \(submitKeycode)")
        }
    }

    func testShiftTabIsNeverTreatedAsASubmitBoundary() {
        // Shift+Tab 은 역방향 포커스 이동이라 교정 경계로 쓰지 않습니다.
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)

        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x30, shift: true)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testTokenCollectionResumesAfterASubmitBoundary() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNil(manager.handleKeyDown(keyDown(0x24)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x24)))

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(output.actions.last, .key(0x31, false))
    }

    func testEnterAndTabResetDiscardStateWithoutCorrectionOrReplay() {
        for commitKeycode: UInt16 in [0x24, 0x30] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["c"]!)))

            XCTAssertNotNil(manager.handleKeyDown(keyDown(commitKeycode)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(commitKeycode)))
            XCTAssertTrue(output.actions.isEmpty)

            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertEqual(output.actions.last, .key(0x31, false))
        }
    }

    func testMultiBoundaryUndoUsesSameSequenceAndUTF16CaretOffset() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        for _ in 0..<3 {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))
        XCTAssertEqual(focus.currentFocusOffsets, [10])

        output.actions.removeAll()
        focus.currentFocusOffsets.removeAll()
        XCTAssertNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("gksrmf"),
            .key(0x2F, false),
            .key(0x2F, false),
            .key(0x2F, false),
            .key(0x2C, true),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [6])
    }

    func testMultiBoundaryCaretMismatchPreservesEverything() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatches = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        for _ in 0..<3 {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        }
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [10, 10, 10])
    }

    func testUnsafeFieldNeverRecordsInjectsOrSwitches() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.tokenAvailable = false
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        var switchCount = 0
        manager.onInputSourceSwitch = { _ in
            switchCount += 1
            return nil
        }

        for character in "excuse" {
            let event = keyDown(try! XCTUnwrap(Self.keycodes[character]))
            XCTAssertNotNil(manager.handleKeyDown(event))
        }
        let boundary = keyDown(0x2C, shift: true)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(switchCount, 0)
    }

    func testKoreanBoundaryFocusBecomingUnsafeLeavesNativeTextUntouched() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("hello", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        focus.tokenAvailable = false
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [5, 5, 5])
    }

    func testImmediateUndoRestoresPunctuationAndRequestsOriginalSource() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        let receipt = InputSourceSwitchReceipt(
            fromInputSourceID: "com.apple.keylayout.ABC",
            toInputSourceID: InputSourceController.koreanTwoSetInputSourceID,
            selectedSourceGeneration: 2
        )
        manager.onInputSourceSwitch = { _ in receipt }

        type("dho", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        var restoredReceipt: InputSourceSwitchReceipt?
        manager.onInputSourceRestore = {
            restoredReceipt = $0
            return true
        }
        let undo = keyDown(0x06, flags: .maskCommand)
        XCTAssertNil(manager.handleKeyDown(undo))

        XCTAssertEqual(Array(output.actions.suffix(4)), [
            .key(0x33, false),
            .key(0x33, false),
            .text("dho"),
            .key(0x2C, true),
        ])
        XCTAssertEqual(restoredReceipt, receipt)
    }

    func testLatinGksrmfSpacePassesPhysicalBoundaryAndCorrectsOnKeyUp() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        let boundary = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundary))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])

        // The physical boundary was never suppressed, so a stray duplicate
        // keyUp also passes and cannot repeat the already-consumed correction.
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(output.actions.count, 9)
    }

    func testMatchingBoundaryKeyUpSchedulesCorrectionBeforeProducingOutput() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertTrue(focus.currentFocusOffsets.isEmpty)
        XCTAssertEqual(scheduledCorrections.count, 1)

        scheduledCorrections.removeFirst()()

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])
    }

    func testNextPhysicalKeyDownCancelsScheduledBoundaryCorrection() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)
        XCTAssertTrue(output.actions.isEmpty)

        focus.currentFocusMatches = false
        scheduledCorrections.removeFirst()()
        XCTAssertEqual(scheduledCorrections.count, 1)
        XCTAssertEqual(focus.currentFocusOffsets, [7])

        XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["a"]!)))
        scheduledCorrections.removeFirst()()

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7])
    }

    func testMouseDownCancelsScheduledBoundaryCorrectionWithoutSideEffects() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var sourceSwitchCount = 0
        manager.onInputSourceSwitch = { _ in
            sourceSwitchCount += 1
            return nil
        }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)

        focus.currentFocusMatches = false
        scheduledCorrections.removeFirst()()
        XCTAssertEqual(scheduledCorrections.count, 1)
        XCTAssertEqual(focus.currentFocusOffsets, [7])

        manager.handleMouseDown()
        scheduledCorrections.removeFirst()()

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7])
        XCTAssertEqual(sourceSwitchCount, 0)
    }

    func testOriginalChoiceRequestUsesPhysicalOriginalAndBoundaryLength() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2F)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        let unwrapped = try XCTUnwrap(request)
        XCTAssertEqual(unwrapped.original, "gksrmf")
        XCTAssertEqual(unwrapped.replacement, "한글")
        XCTAssertEqual(unwrapped.boundaryUTF16Count, 3)
        XCTAssertTrue(manager.isOriginalChoiceActive(generation: unwrapped.generation))
    }

    func testPrimaryMouseDownInsideChipPreservesOnlyRestoreTransaction() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        let unwrapped = try XCTUnwrap(request)
        XCTAssertTrue(manager.markOriginalChoiceChipVisible(
            generation: unwrapped.generation
        ))
        manager.originalChoiceHitTest = { point, generation in
            point == CGPoint(x: 10, y: 20) && generation == unwrapped.generation
        }
        output.actions.removeAll()

        manager.handleMouseDown(
            at: CGPoint(x: 10, y: 20),
            isPrimaryButton: true
        )
        XCTAssertTrue(manager.restoreOriginalChoice(
            generation: unwrapped.generation
        ))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("gksrmf"),
            .key(0x31, false),
        ])
    }

    func testMouseDownOutsideChipOrNonPrimaryClickCancelsRestore() throws {
        for isPrimaryButton in [true, false] {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            var request: OriginalChoiceRequest?
            manager.onOriginalChoiceAvailable = { request = $0 }

            type("gksrmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            let unwrapped = try XCTUnwrap(request)
            XCTAssertTrue(manager.markOriginalChoiceChipVisible(
                generation: unwrapped.generation
            ))
            manager.originalChoiceHitTest = { point, _ in
                point == CGPoint(x: 10, y: 20)
            }
            output.actions.removeAll()

            manager.handleMouseDown(
                at: isPrimaryButton
                    ? CGPoint(x: 99, y: 99)
                    : CGPoint(x: 10, y: 20),
                isPrimaryButton: isPrimaryButton
            )

            XCTAssertFalse(manager.restoreOriginalChoice(
                generation: unwrapped.generation
            ))
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testChipExpirationLeavesCommandZTransactionActive() throws {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        var request: OriginalChoiceRequest?
        manager.onOriginalChoiceAvailable = { request = $0 }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        let unwrapped = try XCTUnwrap(request)
        XCTAssertTrue(manager.markOriginalChoiceChipVisible(
            generation: unwrapped.generation
        ))
        manager.originalChoiceChipDidExpire(generation: unwrapped.generation)
        output.actions.removeAll()

        XCTAssertNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertEqual(output.actions.last, .key(0x31, false))
    }

    func testInputSourceChangeCancelsScheduledBoundaryCorrectionWithoutSideEffects() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var sourceSwitchCount = 0
        manager.onInputSourceSwitch = { _ in
            sourceSwitchCount += 1
            return nil
        }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)

        focus.currentFocusMatches = false
        scheduledCorrections.removeFirst()()
        XCTAssertEqual(scheduledCorrections.count, 1)
        XCTAssertEqual(focus.currentFocusOffsets, [7])

        manager.inputSourceKind = .koreanTwoSet
        scheduledCorrections.removeFirst()()

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7])
        XCTAssertEqual(sourceSwitchCount, 0)
    }

    func testNumberAndSymbolInvalidateWholeTokenInsteadOfCorrectingSuffix() {
        for invalidKeycode: UInt16 in [0x12, 0x1B] { // 1, hyphen
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true

            type("gks", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(invalidKeycode)))
            type("rmf", into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testKoreanAutoOnlyOverflowNeverInterceptsNativeComposition() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        for index in 0..<33 {
            XCTAssertNotNil(
                manager.handleKeyDown(keyDown(Self.keycodes["a"]!)),
                "physical keyDown \(index + 1) must remain native"
            )
        }
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testLatinBoundaryCaretMismatchOnKeyUpFailsClosedWithoutPosting() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        type("gksrmf", into: manager)
        focus.currentFocusMatches = false
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [7, 7, 7])
    }

    func testBoundaryFocusRetriesTwiceAndCorrectsExactlyOnceOnThirdMatch() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        focus.currentFocusMatchResponses = [false, false, true]
        var scheduledCorrections: [() -> Void] = []
        let manager = makeManager(
            output: output,
            focus: focus,
            scheduleBoundaryCorrection: { scheduledCorrections.append($0) }
        )
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        var switchedDirections: [CorrectionDirection] = []
        manager.onInputSourceSwitch = { direction in
            switchedDirections.append(direction)
            return nil
        }

        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        XCTAssertEqual(scheduledCorrections.count, 1)

        for attempt in 1...2 {
            scheduledCorrections.removeFirst()()
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertTrue(switchedDirections.isEmpty)
            XCTAssertEqual(focus.currentFocusOffsets, Array(repeating: 7, count: attempt))
            XCTAssertEqual(scheduledCorrections.count, 1)
        }

        scheduledCorrections.removeFirst()()

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("한글"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7, 7, 7])
        XCTAssertEqual(switchedDirections, [.latinToKorean])
        XCTAssertTrue(scheduledCorrections.isEmpty)
    }

    func testFastShiftedLatinDkssudQuestionMarkCorrectsOnlyOnMatchingKeyUp() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true

        for (index, character) in "dkssud".enumerated() {
            let keycode = Self.keycodes[character]!
            XCTAssertNotNil(manager.handleKeyDown(keyDown(keycode, shift: index == 0)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
        }
        XCTAssertTrue(output.actions.isEmpty)

        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x2C, shift: true)))
        XCTAssertTrue(output.actions.isEmpty)

        // An unrelated keyUp must not apply the pending replacement.
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2F)))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x2C)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("안녕"),
            .key(0x2C, true),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [7])
    }

    func testKoreanBoundaryCaretMoveFailsClosedWithoutPosting() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("hello", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        focus.currentFocusMatches = false
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.currentFocusOffsets, [5, 5, 5])
    }

    func testKoreanAutoOnlyUsesNativeIMEAndCorrectsAfterBoundaryKeyUp() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        var switchedDirections: [CorrectionDirection] = []
        manager.onInputSourceSwitch = { direction in
            switchedDirections.append(direction)
            return nil
        }

        for character in "hello" {
            XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes[character]!)))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(Self.keycodes[character]!)))
        }
        XCTAssertTrue(output.actions.isEmpty)

        let boundaryDown = keyDown(0x31)
        XCTAssertNotNil(manager.handleKeyDown(boundaryDown))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertEqual(output.actions, [
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .key(0x33, false),
            .text("hello"),
            .key(0x31, false),
        ])
        XCTAssertEqual(focus.currentFocusOffsets, [5])
        XCTAssertEqual(switchedDirections, [.koreanToLatin])
    }

    func testSystemDictionaryBackedKoreanCorrectionsReachThePostBoundaryFlow() {
        let examples: [(
            physical: String,
            original: String,
            originalCharacterCount: Int,
            boundaryKeycode: UInt16,
            boundaryShift: Bool
        )] = [
            ("vocal", "팿미", 2, 0x31, false), // Space
            ("good", "해ㅐㅇ", 3, 0x2C, true), // ?
        ]

        for example in examples {
            let output = FakeKeyboardOutput()
            let focus = FakeFocusInspector()
            // 규칙만으로 결정되므로 사전 근거를 주입하지 않습니다.
            let manager = makeManager(output: output, focus: focus)
            manager.inputSourceKind = .koreanTwoSet
            manager.isAutoCorrectionEnabled = true
            var originalChoiceRequest: OriginalChoiceRequest?
            var switchedDirections: [CorrectionDirection] = []
            manager.onOriginalChoiceAvailable = { originalChoiceRequest = $0 }
            manager.onInputSourceSwitch = { direction in
                switchedDirections.append(direction)
                return nil
            }

            type(example.physical, into: manager)
            XCTAssertNotNil(manager.handleKeyDown(keyDown(
                example.boundaryKeycode,
                shift: example.boundaryShift
            )))
            XCTAssertNotNil(manager.handleKeyUp(keyUp(example.boundaryKeycode)))

            let deleteCount = example.originalCharacterCount + 1
            var expected = Array(
                repeating: FakeKeyboardOutput.Action.key(0x33, false),
                count: deleteCount
            )
            expected.append(.text(example.physical))
            expected.append(.key(example.boundaryKeycode, example.boundaryShift))
            XCTAssertEqual(output.actions, expected, example.physical)
            XCTAssertEqual(focus.currentFocusOffsets, [deleteCount], example.physical)
            XCTAssertEqual(originalChoiceRequest?.original, example.original)
            XCTAssertEqual(originalChoiceRequest?.replacement, example.physical)
            XCTAssertEqual(switchedDirections, [.koreanToLatin])
        }
    }

    func testModernKoreanSourcePreservesWithoutPostBoundaryEffects() {
        // `worn` 은 두벌식으로 `재구` 가 되고, 두 음절 모두 현대 국어 음절이라
        // 한국어로도 완전히 성립한다. 키열만으로는 어느 쪽 의도인지 알 수 없으므로
        // 규칙은 화면을 그대로 둔다 (R-D1).
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true
        var originalChoiceRequest: OriginalChoiceRequest?
        var sourceSwitchCount = 0
        manager.onOriginalChoiceAvailable = { originalChoiceRequest = $0 }
        manager.onInputSourceSwitch = { _ in
            sourceSwitchCount += 1
            return nil
        }

        type("worn", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertNil(originalChoiceRequest)
        XCTAssertEqual(sourceSwitchCount, 0)
    }

    func testKoreanDeferredCorrectionIsCancelledByAnotherKeyDown() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true

        type("hello", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyDown(keyDown(Self.keycodes["a"]!)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        XCTAssertTrue(output.actions.isEmpty)
    }

    func testExpiredUndoPassesThroughWithoutPosting() {
        var now = Date(timeIntervalSince1970: 1_000)
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output, now: { now })
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        output.actions.removeAll()

        now = now.addingTimeInterval(7)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testFocusMismatchUndoPassesThroughWithoutPosting() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))
        output.actions.removeAll()

        focus.currentFocusMatches = false
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x06, flags: .maskCommand)))
        XCTAssertTrue(output.actions.isEmpty)
    }

    func testInjectedEventsPassAndSuppressedPhysicalKeyUpDoesNotLeak() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isActive = true
        let keycode = Self.keycodes["r"]!

        let injectedDown = keyDown(keycode)
        EventTapManager.tagAsInjected(injectedDown)
        XCTAssertNotNil(manager.handleKeyDown(injectedDown))
        XCTAssertTrue(output.actions.isEmpty)

        let injectedUp = keyUp(keycode)
        EventTapManager.tagAsInjected(injectedUp)
        XCTAssertNotNil(manager.handleKeyUp(injectedUp))

        let physicalDown = keyDown(keycode)
        XCTAssertNil(manager.handleKeyDown(physicalDown))
        manager.noteSuppressedKeyDown(physicalDown)
        XCTAssertNotNil(manager.handleKeyUp(injectedUp))
        XCTAssertNil(manager.handleKeyUp(keyUp(keycode)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
    }

    func testBoundaryAutorepeatBeforeKeyUpCancelsDeferredCorrection() {
        let boundaries: [(UInt16, Bool)] = [
            (0x31, false), // Space
            (0x2B, false), // comma
        ]

        for (keycode, shift) in boundaries {
            let output = FakeKeyboardOutput()
            let manager = makeManager(output: output)
            manager.inputSourceKind = .supportedLatin
            manager.isAutoCorrectionEnabled = true
            type("gksrmf", into: manager)

            let boundary = keyDown(keycode, shift: shift)
            XCTAssertNotNil(manager.handleKeyDown(boundary))
            XCTAssertTrue(output.actions.isEmpty)

            let repeatedBoundary = keyDown(
                keycode,
                shift: shift,
                autorepeat: true
            )
            XCTAssertNotNil(manager.handleKeyDown(repeatedBoundary))
            XCTAssertTrue(output.actions.isEmpty)
            XCTAssertNotNil(manager.handleKeyUp(keyUp(keycode)))
            XCTAssertTrue(output.actions.isEmpty)
        }
    }

    func testSuccessfulUndoSuppressesAutorepeatUntilPhysicalKeyUp() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .supportedLatin
        manager.isAutoCorrectionEnabled = true
        type("gksrmf", into: manager)
        XCTAssertNotNil(manager.handleKeyDown(keyDown(0x31)))
        XCTAssertNotNil(manager.handleKeyUp(keyUp(0x31)))

        let undo = keyDown(0x06, flags: .maskCommand)
        XCTAssertNil(manager.handleKeyDown(undo))
        manager.noteSuppressedKeyDown(undo)
        let outputAfterUndo = output.actions

        let repeatedUndo = keyDown(
            0x06,
            flags: .maskCommand,
            autorepeat: true
        )
        XCTAssertNil(manager.handleKeyDown(repeatedUndo))
        manager.noteSuppressedKeyDown(repeatedUndo)
        XCTAssertEqual(output.actions, outputAfterUndo)
        XCTAssertNil(manager.handleKeyUp(keyUp(0x06)))
    }

    func testDirectCompositionLetterAutorepeatKeepsComposing() {
        let output = FakeKeyboardOutput()
        let manager = makeManager(output: output)
        manager.inputSourceKind = .koreanTwoSet
        manager.isActive = true
        let keycode = Self.keycodes["r"]!

        let firstDown = keyDown(keycode)
        XCTAssertNil(manager.handleKeyDown(firstDown))
        manager.noteSuppressedKeyDown(firstDown)
        let firstOutputCount = output.actions.count

        let repeatedDown = keyDown(keycode, autorepeat: true)
        XCTAssertNil(manager.handleKeyDown(repeatedDown))
        manager.noteSuppressedKeyDown(repeatedDown)
        XCTAssertGreaterThan(output.actions.count, firstOutputCount)
        XCTAssertNil(manager.handleKeyUp(keyUp(keycode)))
    }

    func testFnModifiedLetterPassesWithoutBufferingOrComposition() {
        let output = FakeKeyboardOutput()
        let focus = FakeFocusInspector()
        let manager = makeManager(output: output, focus: focus)
        manager.inputSourceKind = .koreanTwoSet
        manager.isAutoCorrectionEnabled = true
        manager.isActive = true

        XCTAssertNotNil(manager.handleKeyDown(keyDown(
            Self.keycodes["r"]!,
            flags: .maskSecondaryFn
        )))
        XCTAssertTrue(output.actions.isEmpty)
        XCTAssertEqual(focus.tokenRequestCount, 0)
    }

    private func makeManager(
        output: FakeKeyboardOutput,
        focus: FakeFocusInspector = FakeFocusInspector(),
        now: @escaping () -> Date = { Date(timeIntervalSince1970: 1_000) },
        scheduleBoundaryCorrection: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) -> EventTapManager {
        EventTapManager(
            keyboardOutput: output,
            focusInspector: focus,
            now: now,
            pause: { _ in },
            scheduleBoundaryCorrection: scheduleBoundaryCorrection
        )
    }

    private func type(_ text: String, into manager: EventTapManager) {
        for character in text {
            guard let keycode = Self.keycodes[character] else {
                XCTFail("정의되지 않은 테스트 키: \(character)")
                return
            }
            _ = manager.handleKeyDown(keyDown(keycode))
        }
    }

    private func keyDown(
        _ keycode: UInt16,
        shift: Bool = false,
        flags: CGEventFlags = [],
        autorepeat: Bool = false
    ) -> CGEvent {
        let event = CGEvent(
            keyboardEventSource: nil,
            virtualKey: keycode,
            keyDown: true
        )!
        event.flags = flags
        if shift { event.flags.insert(.maskShift) }
        if autorepeat {
            event.setIntegerValueField(.keyboardEventAutorepeat, value: 1)
        }
        return event
    }

    private func keyUp(_ keycode: UInt16) -> CGEvent {
        CGEvent(
            keyboardEventSource: nil,
            virtualKey: keycode,
            keyDown: false
        )!
    }

    private static let keycodes: [Character: UInt16] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05,
        "z": 0x06, "x": 0x07, "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C,
        "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10, "t": 0x11, "o": 0x1F,
        "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
    ]
}

private final class FakeKeyboardOutput: EventTapKeyboardOutputting {
    enum Action: Equatable {
        case key(UInt16, Bool)
        case text(String)
    }

    var actions: [Action] = []

    func sendKeyEvent(keycode: UInt16, shift: Bool) {
        actions.append(.key(keycode, shift))
    }

    func sendUnicodeText(_ text: String) {
        actions.append(.text(text))
    }
}

private final class FakeFocusInspector: EventTapFocusInspecting {
    let token = FocusedInputSafety.FocusToken(syntheticSelectionLocation: 0)
    var tokenAvailable = true
    var currentFocusMatches = true
    var currentFocusMatchResponses: [Bool] = []
    var tokenRequestCount = 0
    var currentFocusOffsets: [Int] = []

    func automaticCorrectionFocusToken() -> FocusedInputSafety.FocusToken? {
        tokenRequestCount += 1
        return tokenAvailable ? token : nil
    }

    func isCurrentFocus(
        _ token: FocusedInputSafety.FocusToken,
        utf16Offset: Int
    ) -> Bool {
        currentFocusOffsets.append(utf16Offset)
        guard tokenAvailable else { return false }
        if !currentFocusMatchResponses.isEmpty {
            return currentFocusMatchResponses.removeFirst()
        }
        return currentFocusMatches
    }
}
