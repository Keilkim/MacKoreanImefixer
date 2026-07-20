import SwiftUI
import Combine
import ServiceManagement

@main
struct MackorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator)
        } label: {
            MenuBarStatusLabel()
        }
    }
}

private struct MenuBarStatusLabel: View {
    var body: some View {
        Text("Mackor")
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.setup()

        if !coordinator.hasAccessibility {
            showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Mackor 설정을 마무리해 주세요"
        alert.informativeText = "키 입력을 안전하게 보정하려면 macOS 손쉬운 사용 권한이 한 번 필요합니다. 입력 내용은 저장하거나 전송하지 않습니다. 설정 화면에서 Mackor를 켜면 앱이 권한 상태를 자동으로 확인합니다."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "손쉬운 사용 설정 열기")
        alert.addButton(withTitle: "나중에")

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        coordinator.requestPermission()
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    static func showUsageGuide() {
        let alert = NSAlert()
        alert.messageText = "Mackor 사용법"
        alert.informativeText = """
        macOS에서 한글 IME를 제대로 지원하지 않는 앱의 두벌식 한글 입력을 보정합니다.

        [설정 방법]
        1. 손쉬운 사용 권한 허용
           시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용
           → ＋ 버튼 → Mackor 선택 → 토글 켜기

        2. 자동 교정 적용 범위 선택
           - 전체 Mac: 모든 앱과 브라우저 웹사이트에서 자동 교정
           - 선택한 앱만: 앱 이름의 하위 메뉴에서 자동 교정 켜기

        3. 선택한 앱만 사용할 때 대상 앱 등록
           메뉴바 "Mackor" 클릭 → ＋ 앱 추가
           또는 해당 앱을 열고 → ＋ 현재 앱 추가

        4. 선택한 앱의 하위 메뉴에서 사용할 기능 선택
           - 한글 조합 보정
           - 한/영 오입력 자동 보정 (실험적)

        [한/영 오입력 예시]
        gksrmf → 한글
        dkwn → 아주
        whgsp → 좋네
        ㅗ디ㅣㅐ → hello

        [참고]
        - 한글 조합 보정은 등록한 대상 앱에서만 작동합니다
        - 자동 교정은 기본적으로 꺼져 있습니다
        - 공백·,·?·!에서 평가하며 마침표는 URL 보호를 위해 잠시 유예합니다
        - 영문 입력 소스에서 실제 Shift로 친 ALL CAPS 단어는 보존합니다
        - 보정 뒤 시스템 한/영 입력 소스도 의도한 언어로 바뀝니다
        - 비밀번호·주소·검색·보안 입력 필드에서는 작동하지 않습니다
        - 지원하는 입력란에서는 보정 직후 원래 입력을 4초간 클릭해 복원할 수 있습니다
        - 원문 칩이 없더라도 6초 안에 ⌘Z로 되돌릴 수 있습니다
        - 입력 내용은 저장하거나 외부로 전송하지 않습니다
        - 메뉴바에서 활성화/비활성화 가능
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

// MARK: - App Coordinator

@MainActor
class AppCoordinator: ObservableObject {
    let appMonitor = AppMonitor()
    let targetAppManager = TargetAppManager()
    let updaterController = UpdaterController()
    private let eventTapManager = EventTapManager()
    private let correctionNoticeController = CorrectionNoticeController()
    private var cancellables = Set<AnyCancellable>()
    private var permissionPollingTask: Task<Void, Never>?
    private let acknowledgedReleaseBuildKey = "MackorAcknowledgedReleaseBuild"

    @Published var isActive: Bool = false
    @Published var isAutoCorrectionActive: Bool = false
    @Published var hasAccessibility: Bool = false
    @Published private(set) var launchAtLoginEnabled: Bool = false
    @Published private(set) var launchAtLoginRequiresApproval: Bool = false
    @Published private(set) var unreadReleaseVersion: String?

    /// 현재 포커스된 앱의 번들 ID
    @Published var frontAppBundleID: String?

    var isAnyCorrectionActive: Bool {
        isActive || isAutoCorrectionActive
    }

    func setup() {
        appMonitor.targetAppManager = targetAppManager
        refreshLaunchAtLoginStatus()
        refreshReleaseNotesState()
        FocusedInputSafety.prepare()

        // 메뉴가 중첩 ObservableObject의 변경도 즉시 다시 그리도록 전달합니다.
        appMonitor.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        targetAppManager.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        let started = eventTapManager.start()
        hasAccessibility = started

        if !started {
            if EventTapManager.checkAccessibilityPermission(prompt: false) {
                hasAccessibility = eventTapManager.start()
            } else {
                hasAccessibility = false
            }
        }

        appMonitor.$isActive
            .combineLatest($hasAccessibility)
            .map { monitorActive, hasAccessibility in
                monitorActive && hasAccessibility
            }
            .removeDuplicates()
            .sink { [weak self] active in
                self?.eventTapManager.isActive = active
                self?.isActive = active
            }
            .store(in: &cancellables)

        appMonitor.$isAutoCorrectionActive
            .combineLatest($hasAccessibility)
            .map { monitorActive, hasAccessibility in
                monitorActive && hasAccessibility
            }
            .removeDuplicates()
            .sink { [weak self] active in
                self?.eventTapManager.isAutoCorrectionEnabled = active
                self?.isAutoCorrectionActive = active
                if !active {
                    self?.correctionNoticeController.hide()
                }
            }
            .store(in: &cancellables)

        appMonitor.$inputSourceKind
            .removeDuplicates()
            .sink { [weak self] inputSourceKind in
                self?.eventTapManager.inputSourceKind = inputSourceKind
            }
            .store(in: &cancellables)

        eventTapManager.onOriginalChoiceAvailable = { [weak self] request in
            DispatchQueue.main.async {
                guard let self,
                      self.eventTapManager.isOriginalChoiceActive(
                        generation: request.generation
                      ),
                      let replacementRect = FocusedInputSafety.exactReplacementRect(
                        request.focusToken,
                        replacement: request.replacement,
                        boundaryUTF16Count: request.boundaryUTF16Count
                      ) else {
                    return
                }

                let didShow = self.correctionNoticeController.show(
                    original: request.original,
                    generation: request.generation,
                    replacementRect: replacementRect,
                    emphasis: CorrectionNoticeController.Emphasis(request.tier)
                ) { [weak self] generation in
                    guard let self else { return }
                    guard generation == request.generation,
                          FocusedInputSafety.exactReplacementIsCurrent(
                            request.focusToken,
                            replacement: request.replacement,
                            boundaryUTF16Count: request.boundaryUTF16Count
                          ) else {
                        self.eventTapManager.cancelOriginalChoice(
                            generation: generation
                        )
                        return
                    }
                    _ = self.eventTapManager.restoreOriginalChoice(
                        generation: generation
                    )
                }
                if didShow,
                   !self.eventTapManager.markOriginalChoiceChipVisible(
                    generation: request.generation
                   ) {
                    self.correctionNoticeController.hide()
                }
            }
        }
        eventTapManager.originalChoiceHitTest = { [weak self] point, generation in
            self?.correctionNoticeController.contains(
                quartzPoint: point,
                generation: generation
            ) ?? false
        }
        correctionNoticeController.onExpiration = { [weak self] generation in
            self?.eventTapManager.originalChoiceChipDidExpire(
                generation: generation
            )
        }
        eventTapManager.onCorrectionUndone = { [weak self] in
            DispatchQueue.main.async {
                self?.correctionNoticeController.hide()
            }
        }
        eventTapManager.onInputSourceSwitch = { [weak self] direction in
            self?.appMonitor.switchInputSource(for: direction)
        }
        eventTapManager.onInputSourceRestore = { [weak self] receipt in
            self?.appMonitor.restoreInputSource(receipt) ?? false
        }

        // 포커스 앱 추적
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.eventTapManager.resetComposition()
                self.correctionNoticeController.hide()
                self.frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
                // 탭이 무효화된 채로 남으면 메뉴바는 켜져 있는데 어떤 앱에서도
                // 키를 관찰하지 못합니다. 앱 전환은 입력 직전에 반드시 발생하므로
                // 여기서 상태를 확인해 필요하면 재생성합니다.
                if self.hasAccessibility, !self.eventTapManager.isEventTapHealthy {
                    self.hasAccessibility = self.eventTapManager.start()
                }
            }
        }
        for notificationName in [
            NSWorkspace.sessionDidResignActiveNotification,
            NSWorkspace.screensDidSleepNotification,
        ] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: notificationName,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventTapManager.resetComposition()
                    self?.correctionNoticeController.hide()
                }
            }
        }
        frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        startTapWatchdog()
    }

    /// 탭 상태를 주기적으로 감시합니다.
    ///
    /// 실행 중 손쉬운 사용 권한을 회수하면 탭 포트가 죽지만 시스템은
    /// `tapDisabledByTimeout`/`tapDisabledByUserInput` 콜백을 보내주지 않을 수 있습니다.
    /// 그러면 무효화된 헤드 삽입 세션 탭이 입력 경로에 남아 **맥 전체 입력이 멈춥니다.**
    ///
    /// 이전 구현은 (1) 시작 시 권한이 없을 때만 폴링을 걸고 (2) 한 번 건강해지면
    /// 영구 종료했으며 (3) 그 밖의 복구는 `didActivateApplication`(앱 전환)에만
    /// 묶여 있었습니다. 권한을 가진 채 시작한 뒤 회수당하면 폴링이 아예 돌지 않고,
    /// 복구하려면 앱을 전환해야 하는데 입력이 이미 얼어 전환할 수 없는 교착이었습니다.
    ///
    /// 그래서 권한 유무와 무관하게 **항상·계속** 감시하고, 죽은 포트를 발견하면
    /// 재생성보다 **정리(`stop()`)를 먼저** 해 입력 경로부터 풀어줍니다.
    ///
    /// 주의: 이 감시는 메인 액터에서 돌므로 메인 스레드가 막힌 경우(교정 중
    /// `usleep`·AX IPC)에는 스스로 뜨지 못합니다. 그 경로는 탭을 전용 스레드로
    /// 옮기는 후속 단계에서 다룹니다.
    private func startTapWatchdog() {
        permissionPollingTask?.cancel()
        permissionPollingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self else { return }
                guard !self.eventTapManager.isEventTapHealthy else { continue }

                // 죽은 능동 탭을 먼저 떼어내 입력 경로를 푼다. 권한이 회수된
                // 상태라면 재생성은 실패하지만, 정리만으로도 멈춤은 풀린다.
                // 탭을 만든 적이 없으면(권한 없이 실행 중) 떼어낼 것도 없다.
                if self.eventTapManager.eventTap != nil {
                    self.eventTapManager.stop()
                }

                if EventTapManager.checkAccessibilityPermission(prompt: false) {
                    self.hasAccessibility = self.eventTapManager.start()
                } else {
                    self.hasAccessibility = false
                }
            }
        }
    }

    func requestPermission() {
        if !eventTapManager.isEventTapHealthy {
            let started = eventTapManager.start()
            hasAccessibility = started
            if started { return }
        }
        guard EventTapManager.checkAccessibilityPermission() else {
            hasAccessibility = false
            return
        }
        hasAccessibility = eventTapManager.isEventTapHealthy || eventTapManager.start()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else if SMAppService.mainApp.status == .enabled
                        || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            showError(title: "로그인 항목 설정 실패", message: error.localizedDescription)
        }

        refreshLaunchAtLoginStatus()
        if enabled && launchAtLoginRequiresApproval {
            SMAppService.openSystemSettingsLoginItems()
        }
    }

    func refreshLaunchAtLoginStatus() {
        let status = SMAppService.mainApp.status
        launchAtLoginEnabled = status == .enabled
        launchAtLoginRequiresApproval = status == .requiresApproval
    }

    func showCurrentReleaseNotes() {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String
        guard let releasesURL = URL(
            string: "https://github.com/Keilkim/MacKoreanImefixer/releases"
        ) else {
            showError(title: "변경사항 열기 실패", message: "릴리스 주소를 만들지 못했습니다.")
            return
        }
        let versionURL = version.map {
            releasesURL
                .appending(path: "tag", directoryHint: .notDirectory)
                .appending(path: "v\($0)", directoryHint: .notDirectory)
        }
        guard NSWorkspace.shared.open(versionURL ?? releasesURL) else {
            showError(
                title: "변경사항 열기 실패",
                message: "기본 웹 브라우저에서 GitHub 릴리스 페이지를 열지 못했습니다."
            )
            return
        }

        if let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String {
            UserDefaults.standard.set(build, forKey: acknowledgedReleaseBuildKey)
        }
        unreadReleaseVersion = nil
    }

    private func refreshReleaseNotesState() {
        guard let currentBuild = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String,
              let currentVersion = Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
              ) as? String else {
            return
        }

        let defaults = UserDefaults.standard
        guard let acknowledgedBuild = defaults.string(
            forKey: acknowledgedReleaseBuildKey
        ) else {
            // 최초 설치는 업데이트로 오인하지 않습니다.
            defaults.set(currentBuild, forKey: acknowledgedReleaseBuildKey)
            return
        }

        unreadReleaseVersion = acknowledgedBuild == currentBuild
            ? nil
            : currentVersion
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

// MARK: - 메뉴 콘텐츠

struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var appMonitor: AppMonitor
    @ObservedObject private var targetAppManager: TargetAppManager
    @ObservedObject private var updaterController: UpdaterController

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _appMonitor = ObservedObject(wrappedValue: coordinator.appMonitor)
        _targetAppManager = ObservedObject(wrappedValue: coordinator.targetAppManager)
        _updaterController = ObservedObject(
            wrappedValue: coordinator.updaterController
        )
    }

    private let developer = "Draftup"
    private let developerDetail = "SEONGHUN KIM / draftup@naver.com"

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–"
    }

    private var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    }

    private var isAllAppsAutoCorrection: Bool {
        targetAppManager.autoCorrectionScope == .allApps
    }

    var body: some View {
        // 권한 경고
        if !coordinator.hasAccessibility {
            Text("⚠ 손쉬운 사용 권한 필요")
            Button("권한 설정 열기") {
                coordinator.requestPermission()
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            Divider()
        }

        // 상태 표시
        if !coordinator.hasAccessibility {
            Text("– 권한 없어 보정 중지")
        } else if !appMonitor.isEnabled {
            Text("– Mackor 전체 꺼짐")
        } else if isAllAppsAutoCorrection {
            if coordinator.isAutoCorrectionActive {
                Text("✓ 전체 Mac 한/영 자동 보정 작동 중")
            } else {
                Text("✓ 전체 Mac 한/영 자동 보정 활성")
            }
        } else if coordinator.isActive && coordinator.isAutoCorrectionActive {
            Text("✓ 한글 조합 · 한/영 자동 보정")
        } else if coordinator.isAutoCorrectionActive {
            Text("✓ 한/영 자동 보정 대기 중")
        } else if coordinator.isActive {
            Text("✓ 한글 조합 보정 작동 중")
        } else if appMonitor.isTargetAppFront {
            Text("✓ 대상 앱 활성 중")
        } else {
            Text("– 대상 앱 비활성")
        }

        if appMonitor.isKoreanIME {
            Text("✓ 두벌식 한글 입력 활성")
        } else {
            Text("– 두벌식 한글 입력 비활성")
        }

        Divider()

        Text("자동 교정 적용 범위:").font(.caption)
        Picker("자동 교정 적용 범위", selection: Binding(
            get: { targetAppManager.autoCorrectionScope },
            set: { setAutoCorrectionScope($0) }
        )) {
            Text("전체 Mac").tag(AutoCorrectionScope.allApps)
            Text("선택한 앱만").tag(AutoCorrectionScope.selectedApps)
        }
        .labelsHidden()
        .pickerStyle(.inline)

        if isAllAppsAutoCorrection {
            Text("모든 앱과 브라우저의 모든 웹사이트에 적용")
                .font(.caption2)
                .foregroundColor(.secondary)
            Text("비밀번호·주소·검색·보안 입력 필드는 제외")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            Text("등록한 앱에서 앱별로 켠 경우에만 적용")
                .font(.caption2)
                .foregroundColor(.secondary)
        }

        Divider()

        if isAllAppsAutoCorrection {
            Text("전체 Mac 모드에서는 앱을 추가할 필요가 없습니다.")
                .font(.caption2)
                .foregroundColor(.secondary)
        } else {
            // 대상 앱 목록은 ‘선택한 앱만’ 범위에서만 관리합니다. 저장된
            // 목록은 그대로 유지되므로 범위를 되돌리면 다시 나타납니다.
            Text("대상 앱:").font(.caption)
            if targetAppManager.targetApps.isEmpty {
                Text("  (없음)").foregroundColor(.secondary)
            } else {
                ForEach(targetAppManager.targetApps) { app in
                    let isFocused = coordinator.frontAppBundleID == app.bundleID

                    Menu {
                        Toggle("한글 조합 보정", isOn: Binding(
                            get: { app.hangulCompositionEnabled },
                            set: {
                                targetAppManager.setHangulCompositionEnabled(
                                    $0,
                                    bundleID: app.bundleID
                                )
                            }
                        ))

                        Toggle("한/영 오입력 자동 보정 (실험적)", isOn: Binding(
                            get: { app.autoCorrectionEnabled },
                            set: { setAutoCorrection($0, for: app) }
                        ))

                        Divider()

                        Button("목록에서 제거", role: .destructive) {
                            targetAppManager.removeApp(bundleID: app.bundleID)
                        }
                    } label: {
                        HStack {
                            if isFocused {
                                Text("● \(app.name)")
                                    .foregroundColor(.blue)
                            } else {
                                Text("  \(app.name)")
                            }
                            Spacer()
                            Text(
                                app.autoCorrectionEnabled
                                    ? "조합 · 자동"
                                    : (app.hangulCompositionEnabled ? "조합" : "꺼짐")
                            )
                                .foregroundColor(.secondary)
                                .font(.caption2)
                        }
                    }
                    .accessibilityLabel("\(app.name) 보정 설정")
                    .accessibilityHint("한글 조합 및 한영 오입력 자동 보정 설정을 엽니다")
                }
            }

            Button("＋ 앱 추가...") {
                targetAppManager.showAppPicker()
            }

            // 현재 활성 앱 바로 추가
            if let frontApp = NSWorkspace.shared.frontmostApplication,
               let bid = frontApp.bundleIdentifier,
               let name = frontApp.localizedName,
               !targetAppManager.isTargetApp(bundleID: bid, appName: name),
               bid != Bundle.main.bundleIdentifier {
                Button("＋ 현재 앱 추가 (\(name))") {
                    targetAppManager.addApp(bundleID: bid, name: name)
                }
            }
        }

        Divider()

        Text("공백·,·?·!에서 평가하고 마침표는 URL 보호를 위해 유예합니다.")
            .font(.caption2)
            .foregroundColor(.secondary)
        Text("지원 입력란에서는 원래 입력만 최대 4초 표시합니다.")
            .font(.caption2)
            .foregroundColor(.secondary)
        Text("입력 내용은 저장하거나 전송하지 않습니다.")
            .font(.caption2)
            .foregroundColor(.secondary)

        Divider()

        Toggle("Mackor 전체 활성화", isOn: Binding(
            get: { appMonitor.isEnabled },
            set: { appMonitor.isEnabled = $0 }
        ))

        Divider()

        Button("사용법 보기") {
            AppDelegate.showUsageGuide()
        }

        if let unreadVersion = coordinator.unreadReleaseVersion {
            Button("● Mackor v\(unreadVersion) 변경사항") {
                coordinator.showCurrentReleaseNotes()
            }
        } else {
            Button("이번 버전 변경사항…") {
                coordinator.showCurrentReleaseNotes()
            }
        }

        Button("업데이트 확인…") {
            updaterController.checkForUpdates()
        }
        .disabled(
            !updaterController.isConfigured
                || !updaterController.canCheckForUpdates
        )

        Toggle("로그인 시 자동 실행", isOn: Binding(
            get: { coordinator.launchAtLoginEnabled },
            set: { coordinator.setLaunchAtLogin($0) }
        ))
        .onAppear { coordinator.refreshLaunchAtLoginStatus() }

        if coordinator.launchAtLoginRequiresApproval {
            Button("로그인 항목 승인 열기") {
                SMAppService.openSystemSettingsLoginItems()
            }
        }

        Button("앱 삭제 (Uninstall)") {
            showUninstallConfirm()
        }

        Divider()

        // 개발 정보
        Text("Mackor v\(appVersion) (빌드 \(buildNumber))").font(.caption).foregroundColor(.secondary)
        Text(developer).font(.caption2).foregroundColor(.secondary)
        Text(developerDetail).font(.caption2).foregroundColor(.secondary)

        Divider()

        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }

    private func showUninstallConfirm() {
        let alert = NSAlert()
        alert.messageText = "Mackor을 삭제하시겠습니까?"
        alert.informativeText = "로그인 항목을 해제하고 앱과 저장된 설정을 삭제합니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")

        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let appPath = Bundle.main.bundleURL.standardizedFileURL.path
        guard appPath == "/Applications/Mackor.app" else {
            showUninstallError("/Applications/Mackor.app에서 실행 중일 때만 앱 내 삭제를 사용할 수 있습니다. 현재 앱은 Finder에서 휴지통으로 옮겨주세요.")
            return
        }

        do {
            if SMAppService.mainApp.status == .enabled
                || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
                coordinator.refreshLaunchAtLoginStatus()
            }
        } catch {
            showUninstallError("로그인 항목 해제에 실패했습니다: \(error.localizedDescription)")
            return
        }

        let script = """
        do shell script "/bin/rm -rf /Applications/Mackor.app && (/usr/sbin/pkgutil --forget com.mackor.app >/dev/null 2>&1 || true)" with administrator privileges
        """
        guard let appleScript = NSAppleScript(source: script) else {
            showUninstallError("삭제 명령을 준비하지 못했습니다.")
            return
        }

        var scriptError: NSDictionary?
        appleScript.executeAndReturnError(&scriptError)
        if let scriptError {
            let message = scriptError["NSAppleScriptErrorMessage"] as? String ?? "알 수 없는 오류"
            showUninstallError("앱 삭제에 실패했습니다: \(message)")
            return
        }

        if let bundleID = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleID)
        }
        NSApplication.shared.terminate(nil)
    }

    private func setAutoCorrection(
        _ enabled: Bool,
        for app: TargetAppManager.TargetApp
    ) {
        if enabled {
            let alert = NSAlert()
            alert.messageText = "\(app.name) 전체에서 자동 교정을 켤까요?"
            alert.informativeText = "웹사이트·탭·문서별 설정이 아니라 이 앱 전체에 적용됩니다. 브라우저라면 모든 웹사이트가 같은 설정을 사용합니다. Secure Input, 비밀번호·검색·주소 필드와 역할 또는 커서 위치를 확인할 수 없는 필드에서는 작동하지 않습니다."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "켜기")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        targetAppManager.setAutoCorrectionEnabled(
            enabled,
            bundleID: app.bundleID
        )
    }

    private func setAutoCorrectionScope(_ scope: AutoCorrectionScope) {
        guard scope != targetAppManager.autoCorrectionScope else { return }

        if scope == .allApps {
            let alert = NSAlert()
            alert.messageText = "전체 Mac에서 자동 교정을 켤까요?"
            alert.informativeText = "모든 앱과 브라우저의 모든 웹사이트에 적용됩니다. Secure Input과 비밀번호·주소·검색 필드 및 역할이나 커서 위치를 안전하게 확인할 수 없는 입력란에서는 작동하지 않습니다."
            alert.alertStyle = .informational
            alert.addButton(withTitle: "전체 Mac에 적용")
            alert.addButton(withTitle: "취소")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        targetAppManager.setAutoCorrectionScope(scope)
    }

    private func showUninstallError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Mackor 삭제 실패"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
