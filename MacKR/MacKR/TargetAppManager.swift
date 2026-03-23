import AppKit
import Combine

/// 한글 입력 보정 대상 앱 목록을 관리
class TargetAppManager: ObservableObject {

    struct TargetApp: Codable, Identifiable, Equatable {
        let bundleID: String
        let name: String
        var id: String { bundleID }
    }

    /// 등록된 대상 앱 목록
    @Published var targetApps: [TargetApp] = [] {
        didSet { save() }
    }

    private let key = "TargetApps"

    init() {
        load()
        // 첫 실행이면 알려진 문제 앱 자동 추가
        if targetApps.isEmpty {
            autoDetectKnownApps()
        }
    }

    // MARK: - 앱 추가/삭제

    func addApp(bundleID: String, name: String) {
        guard !targetApps.contains(where: { $0.bundleID == bundleID }) else { return }
        targetApps.append(TargetApp(bundleID: bundleID, name: name))
    }

    func removeApp(bundleID: String) {
        targetApps.removeAll { $0.bundleID == bundleID }
    }

    /// .app 파일 선택 다이얼로그
    func showAppPicker() {
        let panel = NSOpenPanel()
        panel.title = "한글 보정할 앱 선택"
        panel.message = "한글 입력이 깨지는 앱을 선택하세요"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")

        if panel.runModal() == .OK {
            for url in panel.urls {
                if let bundle = Bundle(url: url),
                   let bundleID = bundle.bundleIdentifier {
                    let name = url.deletingPathExtension().lastPathComponent
                    addApp(bundleID: bundleID, name: name)
                }
            }
        }
    }

    /// 현재 앱이 대상인지 확인
    func isTargetApp(bundleID: String?, appName: String?) -> Bool {
        if let bid = bundleID {
            if targetApps.contains(where: { bid.localizedCaseInsensitiveContains($0.bundleID) || $0.bundleID.localizedCaseInsensitiveContains(bid) }) {
                return true
            }
        }
        if let name = appName {
            if targetApps.contains(where: { name.localizedCaseInsensitiveContains($0.name) }) {
                return true
            }
        }
        return false
    }

    // MARK: - 저장/불러오기

    private func save() {
        if let data = try? JSONEncoder().encode(targetApps) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: key),
           let apps = try? JSONDecoder().decode([TargetApp].self, from: data) {
            targetApps = apps
        }
    }

    // MARK: - 알려진 문제 앱 자동 감지

    private func autoDetectKnownApps() {
        // /Applications에서 재귀 탐색
        let searchPaths = ["/Applications", NSHomeDirectory() + "/Applications"]
        let keywords = ["coreldraw", "intellij"]

        for searchPath in searchPaths {
            findApps(in: URL(fileURLWithPath: searchPath), depth: 0, maxDepth: 4, keywords: keywords)
        }
    }

    private func findApps(in directory: URL, depth: Int, maxDepth: Int, keywords: [String]) {
        guard depth <= maxDepth else { return }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return }

        for item in contents {
            if item.pathExtension == "app" {
                let name = item.deletingPathExtension().lastPathComponent
                if keywords.contains(where: { name.localizedCaseInsensitiveContains($0) }) {
                    if let bundle = Bundle(url: item), let bid = bundle.bundleIdentifier {
                        addApp(bundleID: bid, name: name)
                    }
                }
            } else {
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: item.path, isDirectory: &isDir), isDir.boolValue {
                    let folderName = item.lastPathComponent.lowercased()
                    let isRelevant = keywords.contains(where: { folderName.contains($0) })
                        || folderName.allSatisfy({ $0.isNumber || $0 == "." })
                        || folderName.contains("corel") || folderName.contains("jetbrains")
                    if isRelevant {
                        findApps(in: item, depth: depth + 1, maxDepth: maxDepth, keywords: keywords)
                    }
                }
            }
        }
    }
}
