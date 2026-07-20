import XCTest
import AppKit
import CoreGraphics

final class CorrectionNoticeControllerTests: XCTestCase {
    func testDisabledExperimentDoesNotPresentAChip() {
        let controller = CorrectionNoticeController(featureEnabled: false)

        XCTAssertFalse(controller.show(
            original: "gksk",
            generation: 1,
            replacementRect: CGRect(x: 100, y: 100, width: 24, height: 18),
            onSelect: { _ in XCTFail("disabled chip must not select") }
        ))
        XCTAssertNil(controller.activeGeneration)
        XCTAssertNil(controller.visibleOriginal)
    }

    func testVisibleChipContainsOnlyOriginalAndHitTestsButtonContent() throws {
        _ = NSApplication.shared
        let controller = CorrectionNoticeController(featureEnabled: true)
        addTeardownBlock { controller.hide() }

        XCTAssertTrue(controller.show(
            original: "qlfem",
            generation: 7,
            replacementRect: CGRect(x: 120, y: 120, width: 36, height: 18),
            onSelect: { _ in }
        ))
        XCTAssertEqual(controller.visibleOriginal, "qlfem")
        XCTAssertEqual(controller.activeGeneration, 7)
        XCTAssertTrue(controller.isVisibleNonactivatingAndInteractive)

        let buttonRect = try XCTUnwrap(controller.visibleButtonScreenRect)
        let mainScreen = try XCTUnwrap(NSScreen.screens.first(where: { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value == CGMainDisplayID()
        }) ?? NSScreen.main)
        let appKitPoint = CGPoint(x: buttonRect.midX, y: buttonRect.midY)
        let quartzPoint = CGPoint(
            x: appKitPoint.x,
            y: mainScreen.frame.maxY - appKitPoint.y
        )

        XCTAssertTrue(controller.contains(quartzPoint: quartzPoint, generation: 7))
        XCTAssertFalse(controller.contains(quartzPoint: quartzPoint, generation: 8))

        controller.hide()
        XCTAssertNil(controller.activeGeneration)
        XCTAssertNil(controller.visibleOriginal)
        XCTAssertNil(controller.visibleButtonScreenRect)
    }

    func testEmphasisMapsFromCorrectionTier() {
        // high 는 규칙이 확신하는 교정이라 기본 노출, medium 은 반대 읽기도
        // 가능했던 교정이라 사용자가 되돌릴 가능성이 높다.
        XCTAssertEqual(CorrectionNoticeController.Emphasis(.high), .standard)
        XCTAssertEqual(CorrectionNoticeController.Emphasis(.medium), .prominent)
    }

    func testProminentChipLivesForTheWholeUndoWindow() {
        // 기본 칩은 4초 뒤 사라지지만 ⌘Z 트랜잭션은 6초간 유효하다. medium
        // 교정은 그 간극을 없애 복구 기회를 놓치지 않게 한다.
        XCTAssertEqual(CorrectionNoticeController.Emphasis.standard.lifetime, 4)
        XCTAssertEqual(CorrectionNoticeController.Emphasis.prominent.lifetime, 6)
    }

    func testVisibleEmphasisIsReportedAndClearedOnHide() {
        _ = NSApplication.shared
        let controller = CorrectionNoticeController(featureEnabled: true)
        addTeardownBlock { controller.hide() }

        XCTAssertNil(controller.visibleEmphasis)
        XCTAssertTrue(controller.show(
            original: "we",
            generation: 3,
            replacementRect: CGRect(x: 80, y: 80, width: 20, height: 18),
            emphasis: .prominent,
            onSelect: { _ in }
        ))
        XCTAssertEqual(controller.visibleEmphasis, .prominent)

        controller.hide()
        XCTAssertNil(controller.visibleEmphasis)
    }

    func testEmphasisDefaultsToStandard() {
        _ = NSApplication.shared
        let controller = CorrectionNoticeController(featureEnabled: true)
        addTeardownBlock { controller.hide() }

        XCTAssertTrue(controller.show(
            original: "gksrmf",
            generation: 4,
            replacementRect: CGRect(x: 80, y: 80, width: 20, height: 18),
            onSelect: { _ in }
        ))
        XCTAssertEqual(controller.visibleEmphasis, .standard)
    }
}
