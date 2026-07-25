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
private final class UpdaterDelegate: NSObject, SPUUpdaterDelegate {
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

    /// 사용자가 업데이트 창에서 "이 버전 건너뛰기"를 골랐습니다.
    ///
    /// 이걸 받지 않으면 footer 버튼이 세션 내내 남습니다. Sparkle 은 건너뛰기를
    /// 기록한 뒤 그대로 흐름을 중단하므로 `updaterDidNotFindUpdate(_:)` 가
    /// 호출되지 않고, 그게 지금까지 값을 비우는 유일한 경로였습니다.
    ///
    /// 남은 버튼은 그냥 거슬리는 정도가 아닙니다. 누르면 **사용자 개시** 확인이
    /// 도는데 그 경로는 건너뛰기 목록을 무시하도록 되어 있어, 방금 건너뛴 바로 그
    /// 버전이 다시 제시됩니다. 자동으로 사라지려면 백그라운드 확인이 한 번 돌아야
    /// 하는데 그 주기는 하루(`SUScheduledCheckInterval`)입니다.
    ///
    /// "나중에 알림"은 반대로 그대로 둡니다 — 그건 업데이트가 실제로 남아 있다는
    /// 뜻이므로 버튼도 남아 있는 것이 맞습니다.
    func updater(_ updater: SPUUpdater, userDidSkipThisVersion item: SUAppcastItem) {
        DispatchQueue.main.async { [onUserSkippedVersion] in
            onUserSkippedVersion?()
        }
    }
}
