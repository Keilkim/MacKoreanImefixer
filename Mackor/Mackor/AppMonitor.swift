import AppKit
import Carbon.HIToolbox
import Combine

/// 현재 활성 앱과 입력 소스를 감시하여
/// 한글 보정이 필요한 상태인지 판단합니다.
class AppMonitor: ObservableObject {

    /// 기존 한글 직접 조합 보정이 현재 작동 중인지
    @Published var isActive: Bool = false

    /// 한/영 오입력 자동 보정이 현재 입력 소스를 관찰 중인지
    @Published private(set) var isAutoCorrectionActive: Bool = false

    /// 대상 앱이 현재 포커스 중인지
    @Published var isTargetAppFront: Bool = false

    /// 한글 IME가 활성 상태인지
    @Published var isKoreanIME: Bool = false

    /// 자동 보정 엔진이 구분해서 처리할 현재 입력 소스 종류
    @Published private(set) var inputSourceKind: InputSourceKind = .unsupported

    /// Undo에서 사용자의 별도 ABC↔U.S. 전환까지 구분하기 위한 정확한 ID
    @Published private(set) var inputSourceID: String?

    /// 활성화/비활성화 토글
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            updateActiveState()
        }
    }

    /// 대상 앱 매니저 (외부에서 주입)
    var targetAppManager: TargetAppManager? {
        didSet {
            observeTargetApps()
            checkFrontmostApp()
        }
    }

    private static let enabledKey = "AppMonitorIsEnabled"
    private static let supportedKoreanInputSourceID = "com.apple.inputmethod.Korean.2SetKorean"
    private static let supportedLatinInputSourceIDs: Set<String> = [
        "com.apple.keylayout.ABC",
        "com.apple.keylayout.US",
    ]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var targetSettingsCancellable: AnyCancellable?
    private var frontAppBundleID: String?
    private var frontAppName: String?
    private var manuallyAccessibleProcessIDs: Set<pid_t> = []
    private let inputSourceController = InputSourceController()

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
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

        let terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else {
                return
            }
            self?.manuallyAccessibleProcessIDs.remove(application.processIdentifier)
        }
        workspaceObservers.append(terminateObserver)

        // 입력 소스 변경 감시
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(enabledInputSourcesChanged),
            name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil
        )
    }

    // MARK: - 앱 감지

    private func observeTargetApps() {
        guard let targetAppManager else {
            targetSettingsCancellable = nil
            return
        }

        targetSettingsCancellable = Publishers.CombineLatest(
            targetAppManager.$targetApps,
            targetAppManager.$autoCorrectionScope
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in
                // @Published는 값이 설정되기 전에 발행하므로 메인 큐에서 새 설정 반영 후 재평가합니다.
                self?.checkFrontmostApp()
            }
    }

    private func checkFrontmostApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            frontAppBundleID = nil
            frontAppName = nil
            isTargetAppFront = false
            updateActiveState()
            return
        }

        frontAppBundleID = frontApp.bundleIdentifier
        frontAppName = frontApp.localizedName
        prepareLazyAccessibilityIfNeeded(for: frontApp)
        isTargetAppFront = isTargetApp(bundleID: frontAppBundleID, appName: frontAppName)
        updateActiveState()
    }

    /// Chromium/Electron 계열 앱은 VoiceOver 같은 보조 기술이 감지되기 전까지
    /// 편집기 AX 트리를 만들지 않을 수 있습니다. Electron이 제3자 보조 앱에
    /// 제공하는 macOS 계약인 `AXManualAccessibility`를 현재 자동 교정 대상
    /// 프로세스에 한 번 설정해, 앱별 접근성 모드를 사용자가 켜지 않아도 표준
    /// 텍스트 역할과 선택 범위를 노출하게 합니다.
    ///
    /// 이 속성을 지원하지 않는 네이티브 앱에서는 호출이 실패할 뿐이며 기존 AX
    /// 경로를 그대로 사용합니다. 입력 내용이나 필드 값은 읽지 않습니다.
    private func prepareLazyAccessibilityIfNeeded(for app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !manuallyAccessibleProcessIDs.contains(app.processIdentifier),
              isEnabled,
              targetAppManager?.isAutoCorrectionEnabled(
                bundleID: app.bundleIdentifier,
                appName: app.localizedName
              ) == true else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        let result = AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        if result == .success {
            manuallyAccessibleProcessIDs.insert(app.processIdentifier)
        }
        if ProcessInfo.processInfo.environment["MACKOR_DIAGNOSTICS"] == "1" {
            print(
                "[Mackor][diagnostic] lazy accessibility pid=\(app.processIdentifier) "
                    + "result=\(result.rawValue)"
            )
        }
    }

    /// 대상 앱인지 확인 (TargetAppManager에 등록된 앱만)
    private func isTargetApp(bundleID: String?, appName: String?) -> Bool {
        guard let manager = targetAppManager else { return false }
        return manager.isTargetApp(bundleID: bundleID, appName: appName)
    }

    // MARK: - 입력 소스 감지

    @objc private func inputSourceChanged() {
        if Thread.isMainThread {
            checkInputSource()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.checkInputSource()
            }
        }
    }

    @objc private func enabledInputSourcesChanged() {
        if Thread.isMainThread {
            inputSourceController.refreshSelectableInputSources()
            checkInputSource()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.inputSourceController.refreshSelectableInputSources()
                self?.checkInputSource()
            }
        }
    }

    private func checkInputSource() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            inputSourceID = nil
            isKoreanIME = false
            inputSourceKind = .unsupported
            updateActiveState()
            return
        }

        if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            inputSourceID = sourceID
            inputSourceController.noteCurrentInputSource(sourceID)
            if sourceID.caseInsensitiveCompare(Self.supportedKoreanInputSourceID) == .orderedSame {
                inputSourceKind = .koreanTwoSet
                isKoreanIME = true
            } else if Self.supportedLatinInputSourceIDs.contains(where: {
                sourceID.caseInsensitiveCompare($0) == .orderedSame
            }) {
                inputSourceKind = .supportedLatin
                isKoreanIME = false
            } else {
                inputSourceKind = .unsupported
                isKoreanIME = false
            }
        } else {
            inputSourceID = nil
            isKoreanIME = false
            inputSourceKind = .unsupported
        }

        updateActiveState()
    }

    func switchInputSource(for direction: CorrectionDirection) -> InputSourceSwitchReceipt? {
        guard let receipt = inputSourceController.switchInputSource(for: direction) else {
            return nil
        }
        checkInputSource()
        return receipt
    }

    @discardableResult
    func restoreInputSource(_ receipt: InputSourceSwitchReceipt) -> Bool {
        guard inputSourceController.restoreInputSource(receipt) else { return false }
        checkInputSource()
        return true
    }

    // MARK: - 상태 업데이트

    private func updateActiveState() {
        let compositionEnabled = targetAppManager?.autoCorrectionScope == .selectedApps
            && (targetAppManager?.isHangulCompositionEnabled(
                bundleID: frontAppBundleID,
                appName: frontAppName
            ) ?? false)
        let autoCorrectionEnabled = targetAppManager?.isAutoCorrectionEnabled(
            bundleID: frontAppBundleID,
            appName: frontAppName
        ) ?? false

        // 직접 한글 조합은 사용자가 명시적으로 켠 대상 앱에서만 활성화합니다.
        // 전체 Mac 자동 교정에 필요한 임시 조합은 EventTapManager가 안전한
        // 일반 텍스트 입력란임을 확인한 뒤 별도로 처리합니다.
        let newCompositionActive = isEnabled
            && isTargetAppFront
            && isKoreanIME
            && compositionEnabled
        if isActive != newCompositionActive {
            isActive = newCompositionActive
        }

        let newAutoCorrectionActive = isEnabled
            && autoCorrectionEnabled
            && inputSourceKind != .unsupported
        if isAutoCorrectionActive != newAutoCorrectionActive {
            isAutoCorrectionActive = newAutoCorrectionActive
        }
    }
}
