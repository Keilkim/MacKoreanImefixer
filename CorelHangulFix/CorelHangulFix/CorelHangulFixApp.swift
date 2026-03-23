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

        // 권한 없으면 첫 실행 시 바로 안내 팝업 + 설정 열기
        if !coordinator.hasAccessibility {
            showPermissionAlert()
        }
    }

    private func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "손쉬운 사용 권한이 필요합니다"
        alert.informativeText = """
        CorelDRAW 한글 입력 보정을 위해 키보드 접근 권한이 필요합니다.

        다음 화면에서:
        1. 왼쪽 아래 ＋ 버튼 클릭
        2. CorelHangulFix 선택
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

/// Coordinates AppMonitor and EventTapManager
class AppCoordinator: ObservableObject {
    let appMonitor = AppMonitor()
    private let eventTapManager = EventTapManager()
    private var cancellables = Set<AnyCancellable>()

    @Published var isActive: Bool = false
    @Published var hasAccessibility: Bool = false

    func setup() {
        // 권한 체크와 무관하게 event tap 시도 — 성공하면 권한 있는 것
        let started = eventTapManager.start()
        hasAccessibility = started

        if !started {
            // 권한 없으면 프롬프트 표시
            hasAccessibility = EventTapManager.checkAccessibilityPermission()
            if hasAccessibility {
                _ = eventTapManager.start()
            }
        }

        // Sync AppMonitor.isActive → EventTapManager.isActive
        appMonitor.$isActive
            .sink { [weak self] active in
                self?.eventTapManager.isActive = active
                self?.isActive = active
            }
            .store(in: &cancellables)

        // 주기적으로 권한 재확인 (5초마다, 권한 없을 때만)
        if !hasAccessibility {
            Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] timer in
                guard let self = self else { timer.invalidate(); return }
                if self.eventTapManager.eventTap == nil {
                    let started = self.eventTapManager.start()
                    if started {
                        DispatchQueue.main.async {
                            self.hasAccessibility = true
                        }
                        timer.invalidate()
                    }
                } else {
                    timer.invalidate()
                }
            }
        }
    }

    func requestPermission() {
        // 먼저 직접 시도
        if eventTapManager.eventTap == nil {
            let started = eventTapManager.start()
            hasAccessibility = started
            if started { return }
        }
        // 안 되면 프롬프트
        hasAccessibility = EventTapManager.checkAccessibilityPermission()
        if hasAccessibility && eventTapManager.eventTap == nil {
            _ = eventTapManager.start()
        }
    }
}

// MARK: - Menu Content

struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
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

        if coordinator.appMonitor.isCorelDRAWFront {
            if let name = coordinator.appMonitor.detectedAppName {
                Text("✓ \(name) 활성 중")
            } else {
                Text("✓ CorelDRAW 활성 중")
            }
        } else if let name = coordinator.appMonitor.detectedAppName {
            let version = coordinator.appMonitor.detectedVersion ?? ""
            Text("CorelDRAW 발견: \(name) \(version)")
        } else {
            Text("– CorelDRAW 미감지")
        }

        if coordinator.appMonitor.isKoreanIME {
            Text("✓ 한글 입력 활성")
        } else {
            Text("– 한글 입력 비활성")
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
