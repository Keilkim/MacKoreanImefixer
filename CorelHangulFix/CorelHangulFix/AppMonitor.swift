import AppKit
import Carbon.HIToolbox

/// Monitors the frontmost application and current input source to determine
/// whether the Hangul fix should be active (CorelDRAW is frontmost + Korean IME is active).
class AppMonitor: ObservableObject {

    /// Whether the fix is currently active
    @Published var isActive: Bool = false

    /// Whether CorelDRAW is the frontmost app
    @Published var isCorelDRAWFront: Bool = false

    /// Whether Korean IME is the current input source
    @Published var isKoreanIME: Bool = false

    /// User-configurable: enable/disable the fix
    @Published var isEnabled: Bool = true {
        didSet { updateActiveState() }
    }

    /// Detected CorelDRAW bundle ID (auto-discovered)
    @Published var detectedBundleID: String?

    /// Display name of detected CorelDRAW app
    @Published var detectedAppName: String?

    /// All discovered CorelDRAW-like bundle IDs on the system
    @Published var discoveredBundleIDs: [String] = []

    /// Detected CorelDRAW version (e.g. "26.1.0.143")
    @Published var detectedVersion: String?

    /// Known keywords to identify CorelDRAW in bundle IDs or app names
    private let corelKeywords = ["coreldraw", "corel draw", "corel-draw"]

    /// Keywords for folder-level Corel detection (suite folders)
    private let corelFolderKeywords = ["coreldraw", "corel"]

    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        discoverCorelDRAW()
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

    // MARK: - Auto-Discovery

    /// Searches the system for CorelDRAW installations and records their bundle IDs
    private func discoverCorelDRAW() {
        var found: [(bundleID: String, name: String)] = []

        // Method 1: Check currently running apps
        for app in NSWorkspace.shared.runningApplications {
            if isCorelDRAWApp(bundleID: app.bundleIdentifier, appName: app.localizedName) {
                if let bid = app.bundleIdentifier {
                    found.append((bid, app.localizedName ?? bid))
                }
            }
        }

        // Method 2: Recursively search /Applications for CorelDRAW
        // CorelDRAW installs in deep paths like:
        //   /Applications/CorelDRAW Graphics Suite .../26/CorelDRAW 2025.app
        let searchPaths = [
            "/Applications",
            NSHomeDirectory() + "/Applications",
        ]

        for searchPath in searchPaths {
            let url = URL(fileURLWithPath: searchPath)
            findCorelApps(in: url, depth: 0, maxDepth: 4, found: &found)
        }

        // Method 3: Use Spotlight to find CorelDRAW
        discoverViaSpotlight()

        discoveredBundleIDs = found.map { $0.bundleID }

        if let first = found.first {
            detectedBundleID = first.bundleID
            detectedAppName = first.name

            // Extract version from bundle
            if let appPath = findAppPath(bundleID: first.bundleID),
               let bundle = Bundle(url: appPath) {
                detectedVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            }

            print("[CorelHangulFix] Auto-detected: \(first.name) (\(first.bundleID)) v\(detectedVersion ?? "?")")
        }

        if found.isEmpty {
            print("[CorelHangulFix] CorelDRAW not found. Will detect by app name at runtime.")
        }
    }

    /// Recursively search a directory for CorelDRAW .app bundles
    /// maxDepth of 4 handles paths like: /Applications/CorelDRAW Graphics Suite .../26/CorelDRAW 2025.app
    private func findCorelApps(in directory: URL, depth: Int, maxDepth: Int, found: inout [(bundleID: String, name: String)]) {
        guard depth <= maxDepth else { return }

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }

        for itemURL in contents {
            if itemURL.pathExtension == "app" {
                let appName = itemURL.deletingPathExtension().lastPathComponent
                if corelKeywords.contains(where: { appName.localizedCaseInsensitiveContains($0) }) {
                    if let bundle = Bundle(url: itemURL), let bid = bundle.bundleIdentifier {
                        if !found.contains(where: { $0.bundleID == bid }) {
                            found.append((bid, appName))
                        }
                    }
                }
            } else {
                // Recurse into directories that look Corel-related or are version number folders
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: itemURL.path, isDirectory: &isDir), isDir.boolValue {
                    let folderName = itemURL.lastPathComponent.lowercased()
                    let isCorelFolder = corelFolderKeywords.contains(where: { folderName.contains($0) })
                    let isVersionFolder = folderName.allSatisfy { $0.isNumber || $0 == "." }
                    if isCorelFolder || isVersionFolder {
                        findCorelApps(in: itemURL, depth: depth + 1, maxDepth: maxDepth, found: &found)
                    }
                }
            }
        }
    }

    /// Find installed app path by bundle ID (for extracting version info)
    private func findAppPath(bundleID: String) -> URL? {
        if let urls = LSCopyApplicationURLsForBundleIdentifier(bundleID as CFString, nil)?.takeRetainedValue() as? [URL] {
            return urls.first
        }
        return nil
    }

    /// Asynchronously search via Spotlight (mdfind)
    private func discoverViaSpotlight() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            process.arguments = ["kMDItemKind == 'Application' && kMDItemDisplayName == '*CorelDRAW*'"]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8) {
                    let paths = output.components(separatedBy: "\n").filter { !$0.isEmpty }
                    for path in paths {
                        let url = URL(fileURLWithPath: path)
                        if let bundle = Bundle(url: url), let bid = bundle.bundleIdentifier {
                            DispatchQueue.main.async {
                                if !self.discoveredBundleIDs.contains(bid) {
                                    self.discoveredBundleIDs.append(bid)
                                    let name = url.deletingPathExtension().lastPathComponent
                                    print("[CorelHangulFix] Spotlight discovered: \(name) (\(bid))")

                                    if self.detectedBundleID == nil {
                                        self.detectedBundleID = bid
                                        self.detectedAppName = name
                                    }
                                }
                            }
                        }
                    }
                }
            } catch {
                // Spotlight search failed, not critical
            }
        }
    }

    // MARK: - Setup

    private func setupObservers() {
        // Watch for frontmost app changes
        let activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppActivation(notification)
        }
        workspaceObservers.append(activateObserver)

        // Watch for app launches (to discover CorelDRAW if launched after us)
        let launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleAppLaunch(notification)
        }
        workspaceObservers.append(launchObserver)

        // Watch for input source changes
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil
        )
    }

    // MARK: - App Detection

    private func handleAppActivation(_ notification: Notification) {
        checkFrontmostApp()
    }

    /// When a new app launches, check if it's CorelDRAW and auto-register its bundle ID
    private func handleAppLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }

        if isCorelDRAWApp(bundleID: app.bundleIdentifier, appName: app.localizedName) {
            if let bid = app.bundleIdentifier, !discoveredBundleIDs.contains(bid) {
                discoveredBundleIDs.append(bid)
                detectedBundleID = bid
                detectedAppName = app.localizedName ?? bid
                print("[CorelHangulFix] Runtime discovered CorelDRAW: \(detectedAppName ?? "") (\(bid))")
            }
        }
        // Also re-check frontmost in case CorelDRAW just became frontmost
        checkFrontmostApp()
    }

    private func checkFrontmostApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            isCorelDRAWFront = false
            updateActiveState()
            return
        }

        if isCorelDRAWApp(bundleID: frontApp.bundleIdentifier, appName: frontApp.localizedName) {
            // Auto-register this bundle ID if we haven't seen it
            if let bid = frontApp.bundleIdentifier, !discoveredBundleIDs.contains(bid) {
                discoveredBundleIDs.append(bid)
                detectedBundleID = bid
                detectedAppName = frontApp.localizedName ?? bid
                print("[CorelHangulFix] Frontmost app discovered as CorelDRAW: \(detectedAppName ?? "") (\(bid))")
            }
            isCorelDRAWFront = true
        } else {
            isCorelDRAWFront = false
        }
        updateActiveState()
    }

    /// Determines if an app is CorelDRAW by checking bundle ID and app name
    private func isCorelDRAWApp(bundleID: String?, appName: String?) -> Bool {
        // Check against discovered bundle IDs first
        if let bid = bundleID, discoveredBundleIDs.contains(bid) {
            return true
        }

        // Check bundle ID against keywords
        if let bid = bundleID {
            let lower = bid.lowercased()
            if corelKeywords.contains(where: { lower.contains($0.replacingOccurrences(of: " ", with: "")) }) {
                return true
            }
        }

        // Check app name against keywords
        if let name = appName {
            let lower = name.lowercased()
            if corelKeywords.contains(where: { lower.contains($0) }) {
                return true
            }
        }

        return false
    }

    // MARK: - Input Source Detection

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

    // MARK: - State Update

    private func updateActiveState() {
        let newActive = isEnabled && isCorelDRAWFront && isKoreanIME
        if isActive != newActive {
            isActive = newActive
        }
    }
}
