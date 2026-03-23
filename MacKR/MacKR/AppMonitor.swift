import AppKit
import Carbon.HIToolbox

/// 현재 활성 앱과 입력 소스를 감시하여
/// 한글 보정이 필요한 상태인지 판단합니다.
class AppMonitor: ObservableObject {

    /// 한글 보정이 현재 작동 중인지
    @Published var isActive: Bool = false

    /// 대상 앱이 현재 포커스 중인지
    @Published var isTargetAppFront: Bool = false

    /// 한글 IME가 활성 상태인지
    @Published var isKoreanIME: Bool = false

    /// 활성화/비활성화 토글
    @Published var isEnabled: Bool = true {
        didSet { updateActiveState() }
    }

    /// 대상 앱 매니저 (외부에서 주입)
    var targetAppManager: TargetAppManager?

    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        setupObservers()
        checkFrontmostApp()
        checkInputSource()
    }

    deinit {
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        DistributedNotificationCenter.default().removeObserver(self)
    }

    // MARK: - 옵저버 설정

    private func setupObservers() {
        // 활성 앱 변경 감시
        let activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFrontmostApp()
        }
        workspaceObservers.append(activateObserver)

        // 앱 실행 감시
        let launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFrontmostApp()
        }
        workspaceObservers.append(launchObserver)

        // 입력 소스 변경 감시
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil
        )
    }

    // MARK: - 앱 감지

    private func checkFrontmostApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            isTargetAppFront = false
            updateActiveState()
            return
        }

        isTargetAppFront = isTargetApp(bundleID: frontApp.bundleIdentifier, appName: frontApp.localizedName)
        updateActiveState()
    }

    /// 대상 앱인지 확인 (TargetAppManager에 등록된 앱만)
    private func isTargetApp(bundleID: String?, appName: String?) -> Bool {
        guard let manager = targetAppManager else { return false }
        return manager.isTargetApp(bundleID: bundleID, appName: appName)
    }

    // MARK: - 입력 소스 감지

    @objc private func inputSourceChanged() {
        DispatchQueue.main.async { [weak self] in
            self?.checkInputSource()
        }
    }

    private func checkInputSource() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            isKoreanIME = false
            updateActiveState()
            return
        }

        if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            isKoreanIME = sourceID.localizedCaseInsensitiveContains("Korean")
        } else {
            isKoreanIME = false
        }

        updateActiveState()
    }

    // MARK: - 상태 업데이트

    private func updateActiveState() {
        let newActive = isEnabled && isTargetAppFront && isKoreanIME
        if isActive != newActive {
            isActive = newActive
        }
    }
}
