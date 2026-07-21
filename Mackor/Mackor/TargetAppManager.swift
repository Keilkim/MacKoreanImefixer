import AppKit
import Combine

enum AutoCorrectionScope: String, Codable, CaseIterable {
    case allApps
    case selectedApps
}

/// 한글 입력 보정 대상 앱 목록을 관리
class TargetAppManager: ObservableObject {

    struct TargetApp: Codable, Identifiable, Equatable {
        let bundleID: String
        let name: String
        var hangulCompositionEnabled: Bool
        var autoCorrectionEnabled: Bool
        var id: String { bundleID }

        init(
            bundleID: String,
            name: String,
            hangulCompositionEnabled: Bool = true,
            autoCorrectionEnabled: Bool = false
        ) {
            self.bundleID = bundleID
            self.name = name
            self.hangulCompositionEnabled = hangulCompositionEnabled
            self.autoCorrectionEnabled = autoCorrectionEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID
            case name
            case hangulCompositionEnabled
            case autoCorrectionEnabled
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            bundleID = try container.decode(String.self, forKey: .bundleID)
            name = try container.decode(String.self, forKey: .name)

            // 이전 버전에는 기능별 설정이 없었습니다. 기존 동작은 유지하되,
            // 새 자동 보정 기능은 사용자가 직접 켜기 전까지 활성화하지 않습니다.
            hangulCompositionEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .hangulCompositionEnabled
            ) ?? true
            autoCorrectionEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .autoCorrectionEnabled
            ) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(name, forKey: .name)
            try container.encode(hangulCompositionEnabled, forKey: .hangulCompositionEnabled)
            try container.encode(autoCorrectionEnabled, forKey: .autoCorrectionEnabled)
        }
    }

    /// 등록된 대상 앱 목록
    @Published var targetApps: [TargetApp] = [] {
        didSet { save() }
    }

    /// 자동 교정 적용 범위. 기존 사용자에게는 앱별 설정을 유지하는 값이
    /// 안전한 기본값이며, 사용자가 명시적으로 바꾼 경우에만 전체 Mac에 적용합니다.
    @Published var autoCorrectionScope: AutoCorrectionScope = .selectedApps {
        didSet { saveAutoCorrectionScope() }
    }

    private let key = "TargetApps"
    private let initializedKey = "TargetAppsInitialized"
    private let autoCorrectionScopeKey = "AutoCorrectionScope"

    init() {
        let defaults = UserDefaults.standard
        let hasStoredSelection = defaults.object(forKey: key) != nil

        if let rawValue = defaults.string(forKey: autoCorrectionScopeKey),
           let storedScope = AutoCorrectionScope(rawValue: rawValue) {
            autoCorrectionScope = storedScope
        } else {
            autoCorrectionScope = .selectedApps
        }

        load()

        // 저장된 선택이 전혀 없는 실제 최초 실행에서만 알려진 문제 앱을 자동 추가합니다.
        // 빈 배열도 사용자가 선택한 유효한 상태이므로 이후 실행에서는 유지합니다.
        if !defaults.bool(forKey: initializedKey) && !hasStoredSelection {
            autoDetectKnownApps()
        }
        defaults.set(true, forKey: initializedKey)
    }

    // MARK: - 앱 추가/삭제

    func addApp(bundleID: String, name: String) {
        guard !targetApps.contains(where: { bundleIDsMatch($0.bundleID, bundleID) }) else { return }
        targetApps.append(TargetApp(bundleID: bundleID, name: name))
    }

    func removeApp(bundleID: String) {
        targetApps.removeAll { bundleIDsMatch($0.bundleID, bundleID) }
    }

    func setHangulCompositionEnabled(_ enabled: Bool, bundleID: String) {
        guard let index = targetApps.firstIndex(where: {
            bundleIDsMatch($0.bundleID, bundleID)
        }) else { return }
        guard targetApps[index].hangulCompositionEnabled != enabled else { return }

        var updatedApp = targetApps[index]
        updatedApp.hangulCompositionEnabled = enabled
        targetApps[index] = updatedApp
    }

    func setAutoCorrectionEnabled(_ enabled: Bool, bundleID: String) {
        guard let index = targetApps.firstIndex(where: {
            bundleIDsMatch($0.bundleID, bundleID)
        }) else { return }
        guard targetApps[index].autoCorrectionEnabled != enabled else { return }

        var updatedApp = targetApps[index]
        updatedApp.autoCorrectionEnabled = enabled
        targetApps[index] = updatedApp
    }

    func setAutoCorrectionScope(_ scope: AutoCorrectionScope) {
        guard autoCorrectionScope != scope else { return }
        autoCorrectionScope = scope
    }

    /// .app 파일 선택 다이얼로그
    func showAppPicker() {
        let panel = NSOpenPanel()
        panel.title = "Mackor 보정 대상 앱 선택"
        panel.message = "한글 조합 또는 한/영 오입력을 보정할 앱을 선택하세요"
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
        targetApp(bundleID: bundleID, appName: appName) != nil
    }

    func isHangulCompositionEnabled(bundleID: String?, appName: String?) -> Bool {
        targetApp(bundleID: bundleID, appName: appName)?.hangulCompositionEnabled ?? false
    }

    func isAutoCorrectionEnabled(bundleID: String?, appName: String?) -> Bool {
        if autoCorrectionScope == .allApps {
            return true
        }
        return targetApp(bundleID: bundleID, appName: appName)?.autoCorrectionEnabled ?? false
    }

    private func targetApp(bundleID: String?, appName: String?) -> TargetApp? {
        if let bundleID {
            return targetApps.first { bundleIDsMatch($0.bundleID, bundleID) }
        }

        // 번들 ID를 얻을 수 없는 앱에 한해서만 이름을 정확히 비교합니다.
        if let appName {
            return targetApps.first { appNamesMatch($0.name, appName) }
        }
        return nil
    }

    private func bundleIDsMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private func appNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedCaseInsensitiveCompare(rhs) == .orderedSame
    }

    // MARK: - 저장/불러오기

    private func save() {
        if let data = try? JSONEncoder().encode(targetApps) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private func saveAutoCorrectionScope() {
        UserDefaults.standard.set(autoCorrectionScope.rawValue, forKey: autoCorrectionScopeKey)
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
