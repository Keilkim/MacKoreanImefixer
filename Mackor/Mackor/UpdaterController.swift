import Combine
import Foundation
import Sparkle

/// Owns Sparkle's standard updater for the lifetime of the application.
///
/// The updater deliberately remains disabled when release configuration has
/// not been injected. This keeps ordinary local builds usable without a live
/// appcast or a production EdDSA public key.
@MainActor
final class UpdaterController: ObservableObject {
    @Published private(set) var canCheckForUpdates = false

    /// 새 버전이 **실제로 있다고 확인된** 경우의 버전 문자열.
    ///
    /// 패널 footer 의 업데이트 버튼은 이 값이 있을 때만 나타난다. 평소에는 아무
    /// 것도 보여주지 않는 것이 맞다 — 누를 이유가 없는 버튼이 상시 자리를
    /// 차지하면 새 소식 종처럼 "뭔가 있다"는 신호로 오해된다.
    ///
    /// 이 값은 **물어본 뒤에만** 채워진다. Sparkle 이 하루 한 번 자동 확인을 돌고
    /// (`SUEnableAutomaticChecks`), 그때 새 버전을 찾으면 델리게이트로 알려준다.
    /// 그래서 앱을 방금 켠 직후에는 새 버전이 있어도 잠시 비어 있을 수 있다.
    /// 그건 숨기는 쪽이 안전한 오차다 — 없는 업데이트를 있다고 하는 것보다
    /// 있는 업데이트를 늦게 알리는 편이 낫다.
    @Published private(set) var availableUpdateVersion: String?

    private var standardUpdaterController: SPUStandardUpdaterController?
    private let delegate = UpdaterDelegate()

    var isConfigured: Bool {
        standardUpdaterController != nil
    }

    init(bundle: Bundle = .main) {
        guard (try? SparkleUpdateConfiguration(
            infoDictionary: bundle.infoDictionary
        )) != nil else {
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: delegate,
            userDriverDelegate: nil
        )
        standardUpdaterController = controller

        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .assign(to: &$canCheckForUpdates)

        delegate.onUpdateFound = { [weak self] version in
            self?.availableUpdateVersion = version
        }
        delegate.onNoUpdate = { [weak self] in
            self?.availableUpdateVersion = nil
        }
        delegate.onUserSkippedVersion = { [weak self] in
            self?.availableUpdateVersion = nil
        }
    }

    /// Presents Sparkle's user-initiated update UI, including release notes.
    func checkForUpdates() {
        standardUpdaterController?.checkForUpdates(nil)
    }
}

/// Sparkle 의 확인 결과만 받아 전달한다. 업데이트 흐름 자체는 Sparkle 의 표준
/// UI 에 그대로 맡긴다 — 설치 여부는 언제나 사용자가 정한다
/// (`SUAutomaticallyUpdate = false`).
///
/// `NSObject` 서브클래스이고 `@MainActor` 가 아닌 이유: Sparkle 이 이 델리게이트를
/// 자기 스케줄러에서 호출하므로 격리를 붙이면 호출 규약이 어긋난다. 대신 콜백을
/// 메인 큐로 넘겨 발행한다.
/// `private` 이 아닌 이유: 테스트 타깃이 이 파일을 직접 컴파일해서, Sparkle 이
/// 실제로 부를 셀렉터에 이 클래스가 응답하는지 확인한다. `SPUUpdaterDelegate` 는
/// 전부 선택 메서드인 @objc 프로토콜이라 **시그니처를 잘못 써도 컴파일은 통과하고
/// 그냥 안 불린다.** 그 죽은 메서드를 잡을 방법은 셀렉터 대조뿐이다.
final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
    var onUpdateFound: ((String) -> Void)?
    var onNoUpdate: (() -> Void)?
    var onUserSkippedVersion: (() -> Void)?

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        DispatchQueue.main.async { [onUpdateFound] in
            onUpdateFound?(version)
        }
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        DispatchQueue.main.async { [onNoUpdate] in
            onNoUpdate?()
        }
    }

    /// 사용자가 업데이트 창에서 고른 것을 받습니다.
    ///
    /// 건너뛰기를 받지 않으면 footer 버튼이 세션 내내 남습니다. Sparkle 은
    /// 건너뛰기를 기록한 뒤 그대로 흐름을 중단하므로 `updaterDidNotFindUpdate(_:)`
    /// 가 호출되지 않고, 그게 값을 비우는 다른 유일한 경로입니다.
    ///
    /// 남은 버튼은 그냥 거슬리는 정도가 아닙니다. 누르면 **사용자 개시** 확인이
    /// 도는데 그 경로는 건너뛰기 목록을 무시하도록 되어 있어, 방금 건너뛴 바로 그
    /// 버전이 다시 제시됩니다. 자동으로 사라지려면 백그라운드 확인이 한 번 돌아야
    /// 하는데 그 주기는 하루(`SUScheduledCheckInterval`)입니다.
    ///
    /// **`updater:userDidSkipThisVersion:` 을 쓰지 않는 이유.** 그쪽이 하는 일은
    /// 같지만 deprecated 이고, 무엇보다 Sparkle 의 디스패치가 배타입니다
    /// (`SPUUIBasedUpdateDriver.m:257-262` — 이 메서드가 있으면 저쪽은 `else if`
    /// 라 **영영 안 불립니다**). 그래서 둘을 함께 두면 한쪽이 조용히 죽고, 나중에
    /// deprecated 쪽만 정리하다 보면 동작이 통째로 사라집니다. 한 곳으로 모읍니다.
    /// Swift 이름은 `userDidMake` 로 줄어듭니다(임포터가 `Choice` 를 떼어냅니다).
    /// Obj-C 셀렉터는 그대로 `updater:userDidMakeChoice:forUpdate:state:` 이고,
    /// Sparkle 이 보내는 것은 그쪽입니다 — 테스트가 그 문자열로 대조합니다.
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        handleUserChoice(choice)
    }

    /// 선택 처리의 알맹이. Sparkle 타입 없이 부를 수 있게 떼어 둡니다 —
    /// `SPUUserUpdateState` 는 테스트가 만들 수 없어서, 이게 없으면 "건너뛰기만
    /// 버튼을 지운다"를 검증할 방법이 없습니다.
    func handleUserChoice(_ choice: SPUUserUpdateChoice) {
        // 건너뛰기만 버튼을 지웁니다.
        //
        // dismiss("나중에 알림")는 업데이트가 실제로 남아 있다는 뜻이므로 버튼도
        // 남아 있는 것이 맞습니다. install 은 곧 앱이 다시 뜨므로 굳이 건드리지
        // 않습니다.
        guard choice == .skip else { return }
        DispatchQueue.main.async { [onUserSkippedVersion] in
            onUserSkippedVersion?()
        }
    }
}
