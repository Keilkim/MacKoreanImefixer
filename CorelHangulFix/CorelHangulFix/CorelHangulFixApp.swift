import SwiftUI
import Combine
import ServiceManagement

@main
struct CorelHangulFixApp: App {
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

        if !coordinator.hasAccessibility {
            showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "손쉬운 사용 권한이 필요합니다"
        alert.informativeText = """
        한글 입력 보정을 위해 키보드 접근 권한이 필요합니다.

        다음 화면에서:
        1. 왼쪽 아래 ＋ 버튼 클릭
        2. MacKoreanImefixer (CorelHangulFix) 선택
        3. 토글 켜기

        이미 목록에 있으면 토글만 켜주세요.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "설정 열기")
        alert.addButton(withTitle: "나중에")

        if alert.runModal() == .alertFirstButtonReturn {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
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

    func setup() {
        // AppMonitor에 TargetAppManager 연결
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
                HStack {
                    Text("  \(app.name)")
                    Spacer()
                    Button("✕") {
                        coordinator.targetAppManager.removeApp(bundleID: app.bundleID)
                    }
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

        Button("로그인 시 자동 실행 설정") {
            if #available(macOS 13.0, *) {
                SMAppService.openSystemSettingsLoginItems()
            }
        }

        Divider()

        Button("종료") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
