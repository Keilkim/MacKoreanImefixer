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
}
