import SwiftUI
import Combine
import ServiceManagement
import AppKit

@main
struct MackorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MackorPanel(coordinator: appDelegate.coordinator)
        } label: {
            MenuBarStatusLabel()
        }
        .menuBarExtraStyle(.window)
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

        2. 메뉴바 "Mackor" 클릭 → 앱 목록에서 원하는 앱의 스위치 켜기
           - 조합: 한글 조합 보정
           - 자판자동: 한/영 오입력 자동 보정 (실험적)
           목록에 없으면 ⚙ 설정 → "목록에 없는 앱 직접 추가"

        3. 앱을 가리지 않고 자동 교정을 적용하려면
           ⚙ 설정 → 자판 자동 교정 → "앱을 가리지 않고 적용"

        4. "미지원"으로 표시된 앱은 접근성(AX)을 지원하지 않아 자판 자동
           교정이 동작하지 않는 앱입니다. 한글 조합 보정은 그래도 됩니다.

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
        - 검색 입력란은 지원하며 비밀번호·주소·보안 입력 필드에서는 작동하지 않습니다
        - 지원하는 입력란에서는 보정 직후 원래 입력을 4~6초간 클릭해 복원할 수 있습니다
        - 결과 8자 이하의 짧은 보정은 원문 칩이 없어도 6초 안에 ⌘Z로 되돌릴 수 있습니다
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
    let installedAppsCatalog = InstalledAppsCatalog()
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

    func setup() {
        appMonitor.targetAppManager = targetAppManager
        refreshLaunchAtLoginStatus()
        refreshReleaseNotesState()
        installedAppsCatalog.refresh()

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

        // 그 앱에서 텍스트 역할을 연속으로 못 본 경우 — 목록에 '미지원'으로
        // 표시해, 켜져 있는데 안 되는 상태를 사용자가 원인 모른 채 겪지 않게 합니다.
        eventTapManager.onAutoCorrectionUnsupported = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.targetAppManager.noteAutoCorrectionUnsupported(
                    bundleID: self.appMonitor.frontAppBundleID
                )
            }
        }

        eventTapManager.onOriginalChoiceAvailable = { [weak self] request in
            DispatchQueue.main.async {
                guard let self else { return }
                // 교정이 실제로 걸려 원문 선택 후보가 만들어졌다는 건 이 앱에서
                // AX가 동작했다는 직접 증거입니다. 자판 자동 교정 '지원 확인'으로
                // 학습해, 목록에서 이 앱을 지원됨으로 표시합니다.
                self.targetAppManager.noteAutoCorrectionSupported(
                    bundleID: self.appMonitor.frontAppBundleID
                )
                guard self.eventTapManager.isOriginalChoiceActive(
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
        // 교정 뒤 입력 소스를 한글로 전환합니다.
        //
        // 한때 이 전환이 첫 단어만 바뀌고 뒤가 다 죽는 원인이었습니다. 시스템
        // (TIS)은 한글로 바뀌는데 앱은 계속 라틴을 찍는 경우가 있고, 그때
        // Mackor가 TIS를 믿고 이후 토큰을 반대 방향으로 판정했기 때문입니다.
        //
        // 이제는 방향을 믿음이 아니라 **화면에 찍힌 글자**로 확정하므로
        // (`EventTapManager.directionCorrectedDecision`) 이 전환이 판정을
        // 어긋내지 못합니다. 그래서 편의 기능을 되살립니다.
        eventTapManager.onInputSourceSwitch = { [weak self] direction in
            self?.appMonitor.switchInputSource(for: direction)
        }
        eventTapManager.onInputSourceRestore = { [weak self] receipt in
            self?.appMonitor.restoreInputSource(receipt) ?? false
        }
        eventTapManager.onInputSourceKindRefresh = { [weak self] in
            self?.appMonitor.refreshInputSourceKind() ?? .unsupported
        }

        // 포커스 앱 추적
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // NotificationCenter가 main queue에서 동기로 호출합니다. 다시 Task로
            // 미루면 새 앱의 첫 keyDown이 이전 앱의 조합 상태를 먼저 볼 수 있습니다.
            MainActor.assumeIsolated {
                self?.handleApplicationActivation()
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
                MainActor.assumeIsolated {
                    self?.eventTapManager.resetComposition()
                    self?.correctionNoticeController.hide()
                }
            }
        }
        startTapWatchdog()
    }

    /// 앱 전환 알림과 같은 main-queue 턴에서 입력 상태를 먼저 폐기합니다.
    /// 첫 keyDown보다 늦어지면 이전 앱의 조합 문자를 새 입력란에서 지울 수 있습니다.
    private func handleApplicationActivation() {
        eventTapManager.resetComposition()
        correctionNoticeController.hide()
        // 전환 직후 첫 AX 읽기는 낡은 캐럿 위치를 돌려줄 수 있습니다. 실제 입력이
        // 오기 전에 버리는 읽기로 캐시를 갱신합니다.
        FocusedInputSafety.warmFocusCache()

        // 무효화된 탭은 앱 전환 시 즉시 재생성해 다음 입력을 놓치지 않습니다.
        guard !eventTapManager.isEventTapHealthy else { return }
        if EventTapManager.checkAccessibilityPermission(prompt: false) {
            hasAccessibility = eventTapManager.start()
        } else {
            hasAccessibility = false
        }
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
        // `prompt: false`로 **확인만** 합니다.
        //
        // 여기서 prompt를 켜면 macOS가 자체 권한 창을 띄우는데, 이 함수는 이미
        // 우리 안내 창("설정을 마무리해 주세요")에서 사용자가 버튼을 누른 뒤에
        // 불립니다. 그래서 창이 연달아 두 번 떴습니다 — 사용자가 반복해서
        // 불편을 호소한 지점입니다. 우리 창이 이유와 개인정보 처리까지 설명하고
        // 곧바로 시스템 설정을 열어 주므로 macOS 기본 창은 중복입니다.
        guard EventTapManager.checkAccessibilityPermission(prompt: false) else {
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

// MARK: - 설치된 앱 카탈로그

/// 목록에 보여줄 설치된 앱 하나.
struct InstalledApp: Identifiable, Equatable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID }
}

/// /Applications·시스템·홈 응용프로그램 폴더와 실행 중인 앱을 훑어 목록을 만듭니다.
/// 번들ID·아이콘 조회는 느릴 수 있어 백그라운드에서 스캔한 뒤 메인에서 발행합니다.
@MainActor
final class InstalledAppsCatalog: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var isLoading = false

    func refresh() {
        guard !isLoading else { return }
        isLoading = true
        let selfBundleID = Bundle.main.bundleIdentifier
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                Self.scan(excludingBundleID: selfBundleID)
            }.value
            self.apps = found
            self.isLoading = false
        }
    }

    nonisolated private static func scan(excludingBundleID: String?) -> [InstalledApp] {
        var byBundleID: [String: InstalledApp] = [:]
        let fm = FileManager.default

        func consider(_ url: URL) {
            guard url.pathExtension == "app",
                  let bundle = Bundle(url: url),
                  let bundleID = bundle.bundleIdentifier,
                  bundleID != excludingBundleID else { return }
            let key = bundleID.lowercased()
            guard byBundleID[key] == nil else { return }
            let name = url.deletingPathExtension().lastPathComponent
            // Info.plist를 이미 열었으므로 창 없는 백그라운드 앱까지 여기서
            // 걸러냅니다(실행 중 앱 경로는 activationPolicy가 같은 일을 합니다).
            guard MackorAppFilter.isListable(
                bundleID: bundleID,
                name: name,
                isBackgroundOnly: MackorAppFilter.isBackgroundOnly(
                    infoDictionary: bundle.infoDictionary
                )
            ) else { return }
            byBundleID[key] = InstalledApp(bundleID: bundleID, name: name, url: url)
        }

        func walk(_ directory: URL, depth: Int) {
            guard let items = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { return }
            for item in items {
                if item.pathExtension == "app" {
                    consider(item)
                } else if depth > 0 {
                    var isDir: ObjCBool = false
                    if fm.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                        walk(item, depth: depth - 1)
                    }
                }
            }
        }

        let roots = [
            "/Applications",
            "/System/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications"),
        ]
        for root in roots {
            walk(URL(fileURLWithPath: root), depth: 2)
        }

        // 위 폴더에 없지만 지금 실행 중인 일반 앱도 포함합니다.
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier,
                  bundleID != excludingBundleID,
                  byBundleID[bundleID.lowercased()] == nil,
                  let url = app.bundleURL else { continue }
            let name = app.localizedName ?? url.deletingPathExtension().lastPathComponent
            guard MackorAppFilter.isListable(bundleID: bundleID, name: name) else { continue }
            byBundleID[bundleID.lowercased()] = InstalledApp(bundleID: bundleID, name: name, url: url)
        }

        // 걸러내기는 두 수집 경로에서 이미 끝났습니다(애플 기본 앱 무더기, 설치·
        // 제거 도구, 백그라운드 도우미, 원격 세션, 웹 바로가기). 목록과 opt-out
        // 기본값이 같은 기준을 쓰도록 공용 MackorAppFilter를 사용합니다.
        return byBundleID.values
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

/// 아이콘을 경로별로 한 번만 불러 캐시합니다. 재렌더마다 NSWorkspace를 다시
/// 때리면 목록이 무거워집니다.
@MainActor
enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    static func icon(for path: String) -> NSImage {
        if let cached = cache[path] { return cached }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}

// MARK: - Mackor 패널 (메뉴바 window)

struct MackorPanel: View {
    @ObservedObject var coordinator: AppCoordinator
    @ObservedObject private var appMonitor: AppMonitor
    @ObservedObject private var targetAppManager: TargetAppManager
    @ObservedObject private var updaterController: UpdaterController
    @ObservedObject private var catalog: InstalledAppsCatalog

    @State private var query = ""
    @State private var showingSettings = false
    @State private var pendingAutoApp: PanelAppItem?
    @State private var pendingAllAppsScope = false

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        _appMonitor = ObservedObject(wrappedValue: coordinator.appMonitor)
        _targetAppManager = ObservedObject(wrappedValue: coordinator.targetAppManager)
        _updaterController = ObservedObject(wrappedValue: coordinator.updaterController)
        _catalog = ObservedObject(wrappedValue: coordinator.installedAppsCatalog)
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
        Group {
            if showingSettings {
                settingsScreen
            } else {
                appsScreen
            }
        }
        .frame(width: 380)
        // 메뉴바 앱은 며칠씩 떠 있어 한 번 스캔한 목록이 굳습니다. 패널을 열 때마다
        // 다시 스캔해 그 사이 설치·실행한 앱도 나타나게 합니다(비어 있지 않으면
        // 로딩 표시 없이 제자리에서 갱신되어 깜빡이지 않습니다).
        .onAppear { coordinator.installedAppsCatalog.refresh() }
        // 확인창은 NSAlert.runModal 대신 SwiftUI .alert로 띄웁니다. window 스타일
        // 메뉴바 패널에서 runModal은 패널을 닫고 런루프를 막습니다.
        .alert(
            "자동 교정을 켤까요?",
            isPresented: Binding(
                get: { pendingAutoApp != nil },
                set: { if !$0 { pendingAutoApp = nil } }
            ),
            presenting: pendingAutoApp
        ) { item in
            Button("켜기") {
                targetAppManager.setAutoCorrection(true, bundleID: item.bundleID, name: item.name)
                pendingAutoApp = nil
            }
            Button("취소", role: .cancel) { pendingAutoApp = nil }
        } message: { item in
            Text("\(item.name) 전체에 적용됩니다. 브라우저라면 모든 웹사이트가 같은 설정을 씁니다. 검색 입력란은 지원하며 비밀번호·주소·보안 필드에서는 작동하지 않습니다.")
        }
        .alert("지원하는 모든 앱에서 자동 교정을 켤까요?", isPresented: $pendingAllAppsScope) {
            Button("모든 앱에 적용") {
                targetAppManager.setAutoCorrectionScope(.allApps)
                pendingAllAppsScope = false
            }
            Button("취소", role: .cancel) { pendingAllAppsScope = false }
        } message: {
            Text("모든 앱·웹사이트의 지원되는 입력란에 적용됩니다. 비밀번호·주소·보안 필드는 제외됩니다.")
        }
    }

    // MARK: 메인 (앱 목록)

    private var appsScreen: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            appList
            Divider()
            footer
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Mackor").font(.headline)
                Spacer()
                Text(appMonitor.isKoreanIME ? "두벌식 ✓" : "두벌식 –")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text(statusLine)
                .font(.caption)
                .foregroundColor(coordinator.hasAccessibility ? .secondary : .orange)
            if !coordinator.hasAccessibility {
                Button("손쉬운 사용 권한 열기") { openAccessibilitySettings() }
                    .font(.caption)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusLine: String {
        if !coordinator.hasAccessibility { return "권한 없어 보정 중지" }
        if !appMonitor.isEnabled { return "Mackor 전체 꺼짐" }
        if coordinator.isActive && coordinator.isAutoCorrectionActive {
            return "한글 조합 · 한/영 자동 보정 작동 중"
        }
        if isAllAppsAutoCorrection {
            // "전체 Mac"이라고 쓰지 않습니다. 이 범위가 뜻하는 것은 "앱 목록으로
            // 제한하지 않는다"이지 "어느 앱에서나 된다"가 아닙니다. 접근성으로
            // 글자를 읽을 수 없는 앱(Adobe Illustrator는 AX에 텍스트 요소가
            // 0개)에서는 원리적으로 동작할 수 없는데, 전체라고 적으면 사용자는
            // 되는 줄 알고 기다리다 원인을 못 찾습니다.
            return coordinator.isAutoCorrectionActive
                ? "지원하는 모든 앱에서 한/영 자동 보정 작동 중"
                : "지원하는 모든 앱에서 한/영 자동 보정 활성"
        }
        if coordinator.isAutoCorrectionActive { return "한/영 자동 보정 대기 중" }
        if coordinator.isActive { return "한글 조합 보정 작동 중" }
        if appMonitor.isTargetAppFront { return "대상 앱 활성 중" }
        return "대상 앱 비활성"
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundColor(.secondary)
            TextField("앱 검색", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var appList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if catalog.apps.isEmpty && catalog.isLoading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .padding(.vertical, 24)
                } else if filteredItems.isEmpty {
                    Text(query.isEmpty ? "표시할 앱이 없습니다" : "검색 결과 없음")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 24)
                }
                ForEach(filteredItems) { item in
                    appRow(item)
                    Divider().padding(.leading, 50)
                }
            }
        }
        .frame(height: 360)
    }

    private var footer: some View {
        HStack {
            Text("\(targetAppManager.targetApps.count)개 앱에서 켜짐")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
            Button {
                showingSettings = true
            } label: {
                Label("설정", systemImage: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .padding(12)
    }

    // MARK: 앱 행

    @ViewBuilder
    private func appRow(_ item: PanelAppItem) -> some View {
        let isFront = appMonitor.frontAppBundleID?.lowercased() == item.bundleID.lowercased()
        HStack(spacing: 10) {
            appIcon(item)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    if isFront {
                        Text("● 사용 중")
                            .font(.system(size: 10))
                            .foregroundColor(.blue)
                    }
                }
                HStack(spacing: 16) {
                    Toggle(isOn: hangulBinding(item)) {
                        Text("조합").font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)

                    autoToggle(item)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 전체 앱 범위에서 자판자동 칸이 뭐라고 말할지.
    ///
    /// 세 상태를 **구분해야** 합니다. 예전에는 범위가 전체면 전부 "켜짐·전체 Mac"으로
    /// 그렸는데, 그건 모르는 것을 된다고 말하는 표시였습니다.
    ///
    /// "확인 중"이라고 적었더니 "그래서 뭘 기다리라는 거냐"는 질문이 나왔습니다.
    /// 정당한 질문입니다 — 기다린다고 풀리지 않습니다. "확인 중"은 앱이 뭔가 하고
    /// 있다는 뜻으로 읽히는데 실제로는 아무것도 안 합니다. 그래서 **"미확인"**으로
    /// 적습니다. 모르는 것은 모른다고만 말하고, 없는 진행을 암시하지 않습니다.
    ///
    /// 미리 판별하는 방법은 없습니다(실측). AX 트리의 텍스트 역할 개수는 지원
    /// 여부와 무관합니다 — Illustrator는 27개인데 안 되고, Xcode·VS Code·터미널은
    /// 0개인데 됩니다. 캔버스에 직접 그리는 텍스트는 AX 요소가 아니고, 반대로
    /// Electron·Xcode는 포커스된 순간에만 요소를 만들기 때문입니다.
    static func allAppsAutoStyle(
        for support: TargetAppManager.AXAutoCorrectionSupport
    ) -> (label: String, opacity: Double) {
        // 여기 적는 것은 **범위가 아니라 능력**입니다. 범위("앱을 가리지 않고
        // 적용")는 이미 패널 머리말이 말하므로, 줄마다 반복하면 자리만 차지하고
        // 정작 그 앱에서 되는지는 여전히 안 알려줍니다. 예전 "전체 Mac" 표기가
        // 정확히 그 문제였습니다.
        switch support {
        case .supported:                      // 실제로 동작을 관찰함
            return ("동작 확인", 1)
        case .unknown:                        // 아직 관찰 못 함 — 모른다고 말한다
            return ("미확인", 0.6)
        case .unsupported:                    // 그 앱에서 반복해서 실패함
            return ("미지원", 0.4)
        }
    }

    /// 미지원 줄에서 저장소로 바로 요청을 보내는 버튼.
    ///
    /// "안 됨"에서 끝나면 사용자가 할 수 있는 게 없습니다. 요청 경로가 있어야
    /// 막다른 길이 아니라 다음 단계가 됩니다. 이슈 본문은 앱 이름·번들 ID·버전만
    /// 채우고 **입력한 글자나 파일 경로는 넣지 않습니다**(`AppSupportRequest`).
    /// 제출은 브라우저에서 사용자가 직접 누릅니다 — 앱이 대신 보내지 않습니다.
    @ViewBuilder
    private func supportRequestButton(_ item: PanelAppItem) -> some View {
        Button {
            AppSupportRequest.open(
                appName: item.name,
                bundleID: item.bundleID,
                support: targetAppManager.axAutoCorrectionSupport(
                    bundleID: item.bundleID, name: item.name
                )
            )
        } label: {
            Text("요청").font(.system(size: 9))
        }
        .buttonStyle(.link)
        .help("이 앱을 지원해 달라고 GitHub에 요청합니다")
    }

    @ViewBuilder
    private func autoToggle(_ item: PanelAppItem) -> some View {
        if isAllAppsAutoCorrection {
            // 전체 Mac 범위에서도 **미지원 앱은 미지원으로 표시**합니다.
            //
            // 예전에는 범위만 보고 무조건 "켜짐·전체 Mac"으로 그렸는데, 그건
            // 범위(어느 앱을 대상으로 하는가)와 능력(그 앱에서 실제로 되는가)을
            // 뒤섞은 표시였습니다. AX에 텍스트 요소를 하나도 노출하지 않는 앱
            // (Adobe Illustrator는 메뉴 2,976개 외에 AXTextField·AXTextArea·
            // AXComboBox가 0개)에서도 켜진 것처럼 보여, 사용자는 되는 줄 알고
            // 기다리다 "설정은 켜져 있는데 안 된다"를 겪었습니다. 표시가
            // 사실이 아니면 사용자는 원인을 찾을 단서를 잃습니다.
            let support = targetAppManager.axAutoCorrectionSupport(
                bundleID: item.bundleID, name: item.name
            )
            // 세 상태를 **구분해서** 보여줍니다. 예전에는 범위가 전체 Mac이면
            // 전부 "켜짐·전체 Mac"으로 그렸는데, 그건 모르는 것을 된다고
            // 말하는 표시였습니다. 확인되지 않은 앱을 된다고 적으면, 안 되는
            // 앱에서 사용자는 원인을 찾을 단서 없이 기다리게 됩니다.
            //
            //   supported   실제로 동작을 관찰함        → 켜짐 · "전체 Mac"
            //   unknown     아직 관찰 못 함             → 켜짐(흐림) · "확인 중"
            //   unsupported 텍스트 역할을 반복해서 못 봄 → 꺼짐 · "미지원"
            let style = Self.allAppsAutoStyle(for: support)
            HStack(spacing: 4) {
                Toggle(isOn: .constant(support != .unsupported)) {
                    Text("자판자동").font(.system(size: 11))
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(true)
                Text(style.label).font(.system(size: 9)).foregroundColor(.secondary)
                if support == .unsupported {
                    supportRequestButton(item)
                }
            }
            .opacity(style.opacity)
        } else {
            switch targetAppManager.axAutoCorrectionSupport(bundleID: item.bundleID, name: item.name) {
            case .unsupported:
                // 이미 켜져 있으면(과거·수동 설정) 끌 수 있게 실제 값을 그대로
                // 두고, 꺼져 있을 때만 잠급니다. 표시가 저장·엔진 상태와 어긋나
                // "꺼짐처럼 보이는데 실제론 켜져 동작"하는 거짓을 막습니다.
                let isOn = targetAppManager.autoCorrectionIsOn(
                    bundleID: item.bundleID, name: item.name
                )
                HStack(spacing: 4) {
                    Toggle(isOn: isOn ? autoBinding(item) : .constant(false)) {
                        Text("자판자동").font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(!isOn)
                    Text(isOn ? "미지원·켜짐" : "미지원")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                    supportRequestButton(item)
                }
                .opacity(isOn ? 0.75 : 0.4)
            case .supported:
                // 지원 확인된 앱은 opt-out 기본 ON(사용자가 끄기 전까지 켜짐).
                HStack(spacing: 4) {
                    Toggle(isOn: autoBinding(item)) {
                        Text("자판자동").font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Text("동작 확인").font(.system(size: 9)).foregroundColor(.green)
                }
            case .unknown:
                // 아직 지원 미확인 — 기본 꺼짐. 그 앱에서 실제로 쳐 보면 판정됩니다.
                // 여기도 상태를 적습니다. 예전에는 아무 표시가 없어서, 같은 앱이
                // 범위 설정에 따라 어떤 때는 상태가 보이고 어떤 때는 안 보였습니다.
                HStack(spacing: 4) {
                    Toggle(isOn: autoBinding(item)) {
                        Text("자판자동").font(.system(size: 11))
                    }
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    Text("미확인").font(.system(size: 9)).foregroundColor(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private func appIcon(_ item: PanelAppItem) -> some View {
        if let url = item.iconURL {
            Image(nsImage: AppIconCache.icon(for: url.path))
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Image(systemName: "app.dashed")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.secondary)
        }
    }

    // MARK: 목록 데이터

    struct PanelAppItem: Identifiable, Equatable {
        let bundleID: String
        let name: String
        let iconURL: URL?
        var id: String { bundleID }
    }

    private var mergedItems: [PanelAppItem] {
        var byID: [String: PanelAppItem] = [:]
        for app in catalog.apps {
            byID[app.bundleID.lowercased()] = PanelAppItem(
                bundleID: app.bundleID, name: app.name, iconURL: app.url
            )
        }
        // 지금 쓰는 앱은 카탈로그에 없어도 늘 목록에 있게 합니다(스캔 이후 실행했거나
        // 화이트리스트 밖 Apple 앱 등). bundleURL은 디스크 조회가 아니라 속성입니다.
        // 다만 보정이 성립하지 않는 부류(설치·제거 도구, 원격 세션, 웹 바로가기)는
        // 최전면이어도 끼워 넣지 않습니다 — 이 경로가 그 필터의 뒷문이 되지 않도록.
        if let front = NSWorkspace.shared.frontmostApplication,
           let frontBID = front.bundleIdentifier,
           frontBID != Bundle.main.bundleIdentifier,
           MackorAppFilter.isCorrectionCapable(bundleID: frontBID, name: front.localizedName),
           byID[frontBID.lowercased()] == nil {
            byID[frontBID.lowercased()] = PanelAppItem(
                bundleID: frontBID,
                name: front.localizedName ?? frontBID,
                iconURL: front.bundleURL
            )
        }
        // 켜져 있는데 목록에 없는 앱도 빠뜨리지 않습니다. 렌더 경로에서 디스크
        // 조회(urlForApplication)를 피하려 아이콘은 생략(제네릭)합니다.
        for app in targetAppManager.targetApps where byID[app.bundleID.lowercased()] == nil {
            byID[app.bundleID.lowercased()] = PanelAppItem(
                bundleID: app.bundleID, name: app.name, iconURL: nil
            )
        }
        return Array(byID.values)
    }

    private var filteredItems: [PanelAppItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let items = mergedItems.filter {
            trimmed.isEmpty || $0.name.localizedCaseInsensitiveContains(trimmed)
        }
        let front = appMonitor.frontAppBundleID?.lowercased()
        return items.sorted { lhs, rhs in
            let lf = lhs.bundleID.lowercased() == front
            let rf = rhs.bundleID.lowercased() == front
            if lf != rf { return lf }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func hangulBinding(_ item: PanelAppItem) -> Binding<Bool> {
        Binding(
            get: {
                targetAppManager.isHangulCompositionEnabled(
                    bundleID: item.bundleID, appName: item.name
                )
            },
            set: {
                targetAppManager.setHangulComposition(
                    $0, bundleID: item.bundleID, name: item.name
                )
            }
        )
    }

    private func autoBinding(_ item: PanelAppItem) -> Binding<Bool> {
        Binding(
            get: {
                targetAppManager.autoCorrectionIsOn(bundleID: item.bundleID, name: item.name)
            },
            set: { enable in
                if enable {
                    // 지원 확인된 앱을 다시 켜는 건(opt-out 해제) 경고가 불필요합니다.
                    // 미확인 앱을 수동으로 처음 켜는 경우에만 실험적 경고를 띄웁니다.
                    if targetAppManager.axAutoCorrectionSupport(
                        bundleID: item.bundleID, name: item.name
                    ) == .supported {
                        targetAppManager.setAutoCorrectionByUser(
                            true, bundleID: item.bundleID, name: item.name
                        )
                    } else {
                        pendingAutoApp = item   // 확인 alert를 띄우고, 켜기는 거기서 확정
                    }
                } else {
                    targetAppManager.setAutoCorrectionByUser(
                        false, bundleID: item.bundleID, name: item.name
                    )
                }
            }
        )
    }

    // MARK: 설정 화면

    private var settingsScreen: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    showingSettings = false
                } label: {
                    Label("뒤로", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                Spacer()
                Text("설정").font(.headline)
                Spacer()
                Color.clear.frame(width: 44, height: 1)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    settingsAutoCorrectionSection
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        Button("＋ 목록에 없는 앱 직접 추가…") {
                            targetAppManager.showAppPicker()
                        }
                        Text("Apple 기본 앱이나 특수 경로 앱 등 목록에 없는 앱을 파일에서 골라 추가합니다.")
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    Divider()
                    if !coordinator.hasAccessibility {
                        Button("손쉬운 사용 권한 열기") { openAccessibilitySettings() }
                        Divider()
                    }
                    Toggle("Mackor 전체 활성화", isOn: Binding(
                        get: { appMonitor.isEnabled },
                        set: { appMonitor.isEnabled = $0 }
                    ))
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
                    Divider()
                    Button("사용법 보기") { AppDelegate.showUsageGuide() }
                    if let unread = coordinator.unreadReleaseVersion {
                        Button("● Mackor v\(unread) 변경사항") {
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
                    .disabled(!updaterController.isConfigured || !updaterController.canCheckForUpdates)
                    Divider()
                    Button("앱 삭제 (Uninstall)") { showUninstallConfirm() }
                        .foregroundColor(.red)
                    Divider()
                    Text("Mackor v\(appVersion) (빌드 \(buildNumber))")
                        .font(.caption).foregroundColor(.secondary)
                    Text(developer).font(.caption2).foregroundColor(.secondary)
                    Text(developerDetail).font(.caption2).foregroundColor(.secondary)
                    Button("종료") { NSApplication.shared.terminate(nil) }
                        .keyboardShortcut("q", modifiers: .command)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 460)
        }
    }

    private var settingsAutoCorrectionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("자판 자동 교정 (실험적)")
                .font(.caption).foregroundColor(.secondary)
            Toggle("앱을 가리지 않고 적용", isOn: Binding(
                get: { targetAppManager.autoCorrectionScope == .allApps },
                set: { setAllAppsAutoCorrection($0) }
            ))
            Text("켜면 앱 목록으로 제한하지 않고, 지원하는 모든 앱·웹사이트의 입력란에서 한/영 오입력을 자동 보정합니다. 접근성으로 글자를 읽을 수 없는 앱(목록에 '미지원'으로 표시)에서는 동작하지 않습니다. 비밀번호·주소·보안 필드도 제외됩니다. 앱별로만 켜려면 이 스위치를 끄고 목록에서 앱마다 '자판자동'을 켜세요.")
                .font(.caption2).foregroundColor(.secondary)
        }
    }

    // MARK: 동작

    private func openAccessibilitySettings() {
        coordinator.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    private func setAllAppsAutoCorrection(_ on: Bool) {
        let scope: AutoCorrectionScope = on ? .allApps : .selectedApps
        guard scope != targetAppManager.autoCorrectionScope else { return }
        if scope == .allApps {
            pendingAllAppsScope = true   // 확인 alert를 띄우고, 적용은 거기서 확정
        } else {
            targetAppManager.setAutoCorrectionScope(.selectedApps)
        }
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

    private func showUninstallError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Mackor 삭제 실패"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}
