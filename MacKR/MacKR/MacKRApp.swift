import SwiftUI
import Combine
import ServiceManagement

@main
struct MacKRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuContent(coordinator: appDelegate.coordinator)
        } label: {
            if appDelegate.coordinator.isActive {
                Text("한✓")
            } else {
                Text("한")
            }
        }
    }
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.setup()

        // 첫 실행: 로그인 시 자동 실행 등록
        if !UserDefaults.standard.bool(forKey: "loginItemRegistered") {
            if #available(macOS 13.0, *) {
                try? SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: "loginItemRegistered")
        }

        if !coordinator.hasAccessibility {
            showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        AppDelegate.showUsageGuide()
    }

    static func showUsageGuide() {
        let alert = NSAlert()
        alert.messageText = "MacKR 사용법"
        alert.informativeText = """
        macOS에서 한글 IME를 제대로 지원하지 않는 앱의 한글 입력을 보정합니다.

        [설정 방법]
        1. 손쉬운 사용 권한 허용
           시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용
           → ＋ 버튼 → MacKR 선택 → 토글 켜기

        2. 대상 앱 등록
           메뉴바 "한" 클릭 → ＋ 앱 추가
           또는 해당 앱을 열고 → ＋ 현재 앱 추가

        3. 대상 앱에서 한글 입력하면 자동 보정!

        [참고]
        - 대상 앱이 아닌 곳에서는 개입하지 않습니다
        - 메뉴바에서 활성화/비활성화 가능
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "확인")
        alert.runModal()
    }
}

// MARK: - App Coordinator

class AppCoordinator: ObservableObject {
    let appMonitor = AppMonitor()
    let targetAppManager = TargetAppManager()
    private let eventTapManager = EventTapManager()
    private var cancellables = Set<AnyCancellable>()

    @Published var isActive: Bool = false
    @Published var hasAccessibility: Bool = false

    /// 현재 포커스된 앱의 번들 ID
    @Published var frontAppBundleID: String?

    func setup() {
        appMonitor.targetAppManager = targetAppManager

        let started = eventTapManager.start()
        hasAccessibility = started

        if !started {
            hasAccessibility = EventTapManager.checkAccessibilityPermission()
            if hasAccessibility {
                _ = eventTapManager.start()
            }
        }

        appMonitor.$isActive
            .sink { [weak self] active in
                self?.eventTapManager.isActive = active
                self?.isActive = active
            }
            .store(in: &cancellables)

        // 포커스 앱 추적
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        }
        frontAppBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        if !hasAccessibility {
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if self.eventTapManager.eventTap == nil {
                    if self.eventTapManager.start() {
                        DispatchQueue.main.async { self.hasAccessibility = true }
                        timer.invalidate()
                    }
                } else {
                    timer.invalidate()
                }
            }
        }
    }

    func requestPermission() {
        if eventTapManager.eventTap == nil {
            let started = eventTapManager.start()
            hasAccessibility = started
            if started { return }
        }
        hasAccessibility = EventTapManager.checkAccessibilityPermission()
        if hasAccessibility && eventTapManager.eventTap == nil {
            _ = eventTapManager.start()
        }
    }
}

// MARK: - 메뉴 콘텐츠

struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator

    private let appVersion = "1.1"
    private let buildDate = "2026-03-24"
    private let developer = "CO., Ltd. SEDG"
    private let developerDetail = "Kimseunghun / AX Leader"

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
        if coordinator.isActive {
            Text("✓ 한글 보정 작동 중")
        } else if coordinator.appMonitor.isCorelDRAWFront {
            Text("✓ 대상 앱 활성 중")
        } else {
            Text("– 대상 앱 비활성")
        }

        if coordinator.appMonitor.isKoreanIME {
            Text("✓ 한글 입력 활성")
        } else {
            Text("– 한글 입력 비활성")
        }

        Divider()

        // 대상 앱 목록
        Text("대상 앱:").font(.caption)
        if coordinator.targetAppManager.targetApps.isEmpty {
            Text("  (없음)").foregroundColor(.secondary)
        } else {
            ForEach(coordinator.targetAppManager.targetApps) { app in
                let isFocused = coordinator.frontAppBundleID == app.bundleID

                Button {
                    // 앱 이름 클릭은 아무 동작 없음
                } label: {
                    HStack {
                        if isFocused {
                            Text("● \(app.name)")
                                .foregroundColor(.blue)
                        } else {
                            Text("  \(app.name)")
                        }
                        Spacer()
                        Text("삭제")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                }
                .onTapGesture {
                    coordinator.targetAppManager.removeApp(bundleID: app.bundleID)
                }
            }
        }

        Button("＋ 앱 추가...") {
            coordinator.targetAppManager.showAppPicker()
        }

        // 현재 활성 앱 바로 추가
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let bid = frontApp.bundleIdentifier,
           let name = frontApp.localizedName,
           !coordinator.targetAppManager.isTargetApp(bundleID: bid, appName: name),
           bid != Bundle.main.bundleIdentifier {
            Button("＋ 현재 앱 추가 (\(name))") {
                coordinator.targetAppManager.addApp(bundleID: bid, name: name)
            }
        }

        Divider()

        Toggle("활성화", isOn: Binding(
            get: { coordinator.appMonitor.isEnabled },
            set: { coordinator.appMonitor.isEnabled = $0 }
        ))

        Divider()

        Button("사용법 보기") {
            AppDelegate.showUsageGuide()
        }

        Button("로그인 시 자동 실행 설정") {
            if #available(macOS 13.0, *) {
                SMAppService.openSystemSettingsLoginItems()
            }
        }

        Button("앱 삭제 (Uninstall)") {
            showUninstallConfirm()
        }

        Divider()

        // 개발 정보
        Text("MacKR v\(appVersion) (\(buildDate))").font(.caption).foregroundColor(.secondary)
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
        alert.messageText = "MacKR을 삭제하시겠습니까?"
        alert.informativeText = "앱이 종료되고 /Applications에서 삭제됩니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "삭제")
        alert.addButton(withTitle: "취소")

        if alert.runModal() == .alertFirstButtonReturn {
            // 삭제 스크립트 실행
            let script = """
            do shell script "rm -rf /Applications/MacKR.app && pkgutil --forget com.mackr.app 2>/dev/null" with administrator privileges
            """
            if let appleScript = NSAppleScript(source: script) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
            NSApplication.shared.terminate(nil)
        }
    }
}
