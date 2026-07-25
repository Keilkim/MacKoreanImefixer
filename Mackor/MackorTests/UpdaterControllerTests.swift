import Sparkle
import XCTest

/// `SPUUpdaterDelegate` 는 메서드가 전부 **선택**인 @objc 프로토콜이다. 그래서
/// 시그니처를 한 글자만 틀려도 컴파일은 통과하고, Sparkle 은 `respondsToSelector:`
/// 로 물어본 뒤 없다고 판단해 그냥 안 부른다. 조용히 죽은 메서드가 된다.
///
/// 실제로 그럴 뻔했다 — 1.10 에서 "이 버전 건너뛰기" 를 받으려고
/// `updater(_:userDidSkipThisVersion:)` 을 넣었는데, 이 파일이 생기기 전에는
/// 그게 살아 있는지 확인할 수단이 프로젝트에 없었다. 실기에서 눌러 보는 것 말고는.
///
/// 여기서는 셀렉터 문자열을 **손으로 적어** 대조한다. Swift 시그니처에서 유도하면
/// 같이 틀려서 검사가 무의미해진다. 아래 문자열은 Sparkle 헤더의 것과 같아야 한다.
final class UpdaterControllerTests: XCTestCase {

    /// Sparkle 이 실제로 보내는 셀렉터. 하나라도 빠지면 그 기능이 죽는다.
    private static let requiredSelectors: [(name: String, purpose: String)] = [
        ("updater:didFindValidUpdate:", "새 버전을 찾았을 때 — footer 업데이트 버튼이 뜨는 근거"),
        ("updaterDidNotFindUpdate:", "새 버전이 없을 때 — 버튼을 감춘다"),
        ("updater:userDidMakeChoice:forUpdate:state:", "건너뛰기/나중에/설치 선택 — 건너뛰기면 버튼을 감춘다"),
    ]

    /// 구현하면 **안 되는** 셀렉터. Sparkle 의 디스패치가 배타라서 그렇다.
    ///
    /// `SPUUIBasedUpdateDriver.m:257-262`
    /// ```objc
    /// if ([d respondsToSelector:@selector(updater:userDidMakeChoice:forUpdate:state:)]) { ... }
    /// else if (choice == Skip && [d respondsToSelector:@selector(updater:userDidSkipThisVersion:)]) { ... }
    /// ```
    /// 둘 다 두면 아래쪽이 조용히 죽는다. 죽은 채로 남아 있으면 나중에 "deprecated
    /// 니까 지우자"가 안전해 보이는데, 실제로는 이미 아무 일도 안 하고 있었을 뿐이라
    /// 사람을 헷갈리게 한다.
    private static let forbiddenSelectors: [(name: String, reason: String)] = [
        (
            "updater:userDidSkipThisVersion:",
            "deprecated 이고, updater:userDidMakeChoice:forUpdate:state: 가 있으면 절대 호출되지 않습니다"
        ),
    ]

    func testDelegateRespondsToEverySelectorSparkleSends() {
        let delegate = UpdaterDelegate()
        for entry in UpdaterControllerTests.requiredSelectors {
            XCTAssertTrue(
                delegate.responds(to: Selector((entry.name))),
                """
                UpdaterDelegate 가 \(entry.name) 에 응답하지 않습니다.
                Sparkle 은 이 셀렉터를 보내므로 지금 상태로는 그냥 안 불립니다: \(entry.purpose)
                """
            )
        }
    }

    /// 위 목록이 Sparkle 프로토콜에 실재하는 셀렉터인지 반대 방향으로도 확인한다.
    /// 우리가 목록을 틀리게 적으면 위 테스트는 통과하는데(우리 구현도 같이 틀리므로)
    /// Sparkle 은 여전히 안 부른다.
    func testRequiredSelectorsExistInSparkleProtocol() {
        let proto = SPUUpdaterDelegate.self
        for entry in UpdaterControllerTests.requiredSelectors {
            let selector = Selector((entry.name))
            let found = protocol_getMethodDescription(proto, selector, false, true).name != nil
                || protocol_getMethodDescription(proto, selector, true, true).name != nil
            XCTAssertTrue(
                found,
                "\(entry.name) 이 SPUUpdaterDelegate 에 없습니다. Sparkle 이 올라가며 이름이 바뀌었을 수 있습니다."
            )
        }
    }

    func testDelegateDoesNotImplementSupersededSelectors() {
        let delegate = UpdaterDelegate()
        for entry in UpdaterControllerTests.forbiddenSelectors {
            XCTAssertFalse(
                delegate.responds(to: Selector((entry.name))),
                "UpdaterDelegate 가 \(entry.name) 을 구현합니다 — \(entry.reason)"
            )
        }
    }

    /// **건너뛰기만** 버튼을 지운다.
    ///
    /// "나중에 알림"에서도 지우면 실제로 남아 있는 업데이트를 감추게 되고,
    /// 반대로 건너뛰기에서 안 지우면 누를 때마다 방금 건너뛴 버전이 다시 나온다.
    func testOnlySkipClearsTheAvailableVersion() {
        let delegate = UpdaterDelegate()
        var cleared = 0
        delegate.onUserSkippedVersion = { cleared += 1 }

        for choice in [SPUUserUpdateChoice.dismiss, .install] {
            delegate.handleUserChoice(choice)
        }
        let afterNonSkip = expectation(description: "건너뛰기 아닌 선택 처리")
        DispatchQueue.main.async { afterNonSkip.fulfill() }
        wait(for: [afterNonSkip], timeout: 2)
        XCTAssertEqual(cleared, 0, "건너뛰기가 아닌데 업데이트 표시를 지웠습니다")

        delegate.handleUserChoice(.skip)
        let afterSkip = expectation(description: "건너뛰기 처리")
        DispatchQueue.main.async { afterSkip.fulfill() }
        wait(for: [afterSkip], timeout: 2)
        XCTAssertEqual(cleared, 1, "건너뛰기인데 업데이트 표시를 안 지웠습니다")
    }

    /// 릴리스 설정이 없는 번들에서는 updater 를 아예 만들지 않는다.
    ///
    /// 이게 깨지면 로컬 빌드가 실제 appcast 를 조회하려 든다. 테스트 번들에는
    /// `SUFeedURL`·`SUPublicEDKey` 가 없으므로 여기가 그 조건이다.
    @MainActor
    func testStaysInertWithoutReleaseConfiguration() {
        let controller = UpdaterController(bundle: Bundle(for: UpdaterControllerTests.self))
        XCTAssertFalse(controller.isConfigured, "릴리스 설정이 없는데 updater 를 만들었습니다")
        XCTAssertFalse(controller.canCheckForUpdates)
        XCTAssertNil(controller.availableUpdateVersion, "설정도 없는데 업데이트가 있다고 표시했습니다")
    }

    /// 설정되지 않은 상태에서 확인을 눌러도 죽지 않는다(패널이 버튼을 숨기지만,
    /// 숨김 조건이 바뀌어도 크래시로 이어지지 않아야 한다).
    @MainActor
    func testCheckForUpdatesIsSafeWhenUnconfigured() {
        let controller = UpdaterController(bundle: Bundle(for: UpdaterControllerTests.self))
        controller.checkForUpdates()
    }
}
