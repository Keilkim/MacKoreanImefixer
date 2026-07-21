import XCTest
import Combine

final class TargetAppManagerTests: XCTestCase {
    private let targetAppsKey = "TargetApps"
    private let initializedKey = "TargetAppsInitialized"
    private let autoCorrectionScopeKey = "AutoCorrectionScope"

    private var defaults: UserDefaults {
        .standard
    }

    override func setUp() {
        super.setUp()
        clearStoredState()
        // 테스트 중 실제 /Applications 자동 탐색이 결과에 영향을 주지 않도록 합니다.
        defaults.set(true, forKey: initializedKey)
    }

    override func tearDown() {
        clearStoredState()
        super.tearDown()
    }

    func testBundleIDAndFallbackNameMatchingAreExact() {
        let manager = TargetAppManager()
        manager.addApp(bundleID: "com.example.Code", name: "Code")

        XCTAssertTrue(manager.isTargetApp(bundleID: "com.example.Code", appName: "Code"))
        XCTAssertFalse(manager.isTargetApp(bundleID: "com.example.Code.Insiders", appName: "Code"))
        XCTAssertFalse(manager.isTargetApp(bundleID: "com.example", appName: "Code"))

        XCTAssertTrue(manager.isTargetApp(bundleID: nil, appName: "Code"))
        XCTAssertFalse(manager.isTargetApp(bundleID: nil, appName: "Xcode"))
        XCTAssertFalse(manager.isTargetApp(bundleID: nil, appName: "Visual Studio Code"))

        // 번들 ID가 있으면 같은 이름보다 번들 ID를 우선합니다.
        XCTAssertFalse(manager.isTargetApp(bundleID: "com.apple.dt.Xcode", appName: "Code"))
    }

    func testAddingSameBundleIDTwiceDoesNotCreateDuplicate() {
        let manager = TargetAppManager()

        manager.addApp(bundleID: "com.example.Code", name: "Code")
        manager.addApp(bundleID: "com.example.Code", name: "Renamed Code")

        XCTAssertEqual(manager.targetApps.count, 1)
        XCTAssertEqual(manager.targetApps.first?.name, "Code")
    }

    func testRemovingAppMatchesBundleIDCaseInsensitively() {
        let manager = TargetAppManager()
        manager.addApp(bundleID: "com.Example.Editor", name: "Editor")

        manager.removeApp(bundleID: "COM.EXAMPLE.EDITOR")

        XCTAssertTrue(manager.targetApps.isEmpty)
    }

    func testNewAppUsesSafeCapabilityDefaults() throws {
        let manager = TargetAppManager()

        manager.addApp(bundleID: "com.example.Editor", name: "Editor")

        let app = try XCTUnwrap(manager.targetApps.first)
        XCTAssertTrue(app.hangulCompositionEnabled)
        XCTAssertFalse(app.autoCorrectionEnabled)
        XCTAssertTrue(manager.isHangulCompositionEnabled(
            bundleID: "com.example.Editor",
            appName: "Editor"
        ))
        XCTAssertFalse(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Editor",
            appName: "Editor"
        ))
        XCTAssertEqual(manager.autoCorrectionScope, .selectedApps)
    }

    func testExistingUserDefaultsToSelectedAppsScope() throws {
        let storedApps = try JSONEncoder().encode([
            TargetAppManager.TargetApp(
                bundleID: "com.example.Editor",
                name: "Editor",
                autoCorrectionEnabled: true
            ),
        ])
        defaults.set(storedApps, forKey: targetAppsKey)

        let manager = TargetAppManager()

        XCTAssertEqual(manager.autoCorrectionScope, .selectedApps)
        XCTAssertTrue(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Editor",
            appName: nil
        ))
        XCTAssertTrue(manager.isHangulCompositionEnabled(
            bundleID: "com.example.Editor",
            appName: nil
        ))
        XCTAssertFalse(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Other",
            appName: "Other"
        ))
    }

    func testScopePersistsAndRestores() {
        let manager = TargetAppManager()

        manager.setAutoCorrectionScope(.allApps)

        XCTAssertEqual(defaults.string(forKey: autoCorrectionScopeKey), "allApps")
        XCTAssertEqual(TargetAppManager().autoCorrectionScope, .allApps)
    }

    func testScopeChangesArePublished() {
        let manager = TargetAppManager()
        var observedScopes: [AutoCorrectionScope] = []
        let cancellable = manager.$autoCorrectionScope.sink {
            observedScopes.append($0)
        }

        manager.setAutoCorrectionScope(.allApps)

        XCTAssertEqual(observedScopes, [.selectedApps, .allApps])
        withExtendedLifetime(cancellable) {}
    }

    func testInvalidStoredScopeFailsClosedToSelectedApps() {
        defaults.set("future-unknown-scope", forKey: autoCorrectionScopeKey)

        let manager = TargetAppManager()

        XCTAssertEqual(manager.autoCorrectionScope, .selectedApps)
        XCTAssertFalse(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Unknown",
            appName: "Unknown"
        ))
    }

    func testAllAppsScopeEnablesAutomaticCorrectionWithoutRegistration() {
        let manager = TargetAppManager()
        XCTAssertTrue(manager.targetApps.isEmpty)

        manager.setAutoCorrectionScope(.allApps)

        XCTAssertTrue(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Unregistered",
            appName: "Unregistered"
        ))
        XCTAssertTrue(manager.isAutoCorrectionEnabled(bundleID: nil, appName: nil))

        manager.setAutoCorrectionScope(.selectedApps)
        XCTAssertFalse(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Unregistered",
            appName: "Unregistered"
        ))
    }

    func testLegacyStoredAppMigratesToSafeCapabilityDefaults() throws {
        let legacyData = try XCTUnwrap(
            """
            [{"bundleID":"com.example.Legacy","name":"Legacy"}]
            """.data(using: .utf8)
        )
        defaults.set(legacyData, forKey: targetAppsKey)

        let manager = TargetAppManager()

        let app = try XCTUnwrap(manager.targetApps.first)
        XCTAssertEqual(app.bundleID, "com.example.Legacy")
        XCTAssertTrue(app.hangulCompositionEnabled)
        XCTAssertFalse(app.autoCorrectionEnabled)
    }

    func testCapabilityUpdatesPersistAndRestore() throws {
        let manager = TargetAppManager()
        manager.addApp(bundleID: "com.example.Editor", name: "Editor")

        manager.setHangulCompositionEnabled(false, bundleID: "COM.EXAMPLE.EDITOR")
        manager.setAutoCorrectionEnabled(true, bundleID: "com.example.Editor")

        XCTAssertFalse(manager.isHangulCompositionEnabled(
            bundleID: "com.example.Editor",
            appName: nil
        ))
        XCTAssertTrue(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Editor",
            appName: nil
        ))
        XCTAssertFalse(manager.isAutoCorrectionEnabled(
            bundleID: "com.example.Editor.Beta",
            appName: "Editor"
        ))

        let storedData = try XCTUnwrap(defaults.data(forKey: targetAppsKey))
        let storedApps = try JSONDecoder().decode(
            [TargetAppManager.TargetApp].self,
            from: storedData
        )
        let storedApp = try XCTUnwrap(storedApps.first)
        XCTAssertFalse(storedApp.hangulCompositionEnabled)
        XCTAssertTrue(storedApp.autoCorrectionEnabled)

        let restoredManager = TargetAppManager()
        XCTAssertFalse(restoredManager.isHangulCompositionEnabled(
            bundleID: "com.example.Editor",
            appName: nil
        ))
        XCTAssertTrue(restoredManager.isAutoCorrectionEnabled(
            bundleID: "com.example.Editor",
            appName: nil
        ))

        restoredManager.setHangulCompositionEnabled(true, bundleID: "com.example.Editor")
        restoredManager.setHangulCompositionEnabled(false, bundleID: "com.example.Editor")
        XCTAssertTrue(restoredManager.isAutoCorrectionEnabled(
            bundleID: "com.example.Editor",
            appName: nil
        ))
    }

    func testRemovingLastAppPersistsAndRestoresEmptySelection() throws {
        let manager = TargetAppManager()
        manager.addApp(bundleID: "com.example.Code", name: "Code")
        manager.removeApp(bundleID: "com.example.Code")

        XCTAssertTrue(manager.targetApps.isEmpty)

        let storedData = try XCTUnwrap(defaults.data(forKey: targetAppsKey))
        let storedApps = try JSONDecoder().decode(
            [TargetAppManager.TargetApp].self,
            from: storedData
        )
        XCTAssertTrue(storedApps.isEmpty)

        let restoredManager = TargetAppManager()
        XCTAssertTrue(restoredManager.targetApps.isEmpty)
    }

    func testStoredEmptySelectionWithoutLegacyInitializationFlagIsPreserved() throws {
        let emptySelection = try JSONEncoder().encode([TargetAppManager.TargetApp]())
        defaults.set(emptySelection, forKey: targetAppsKey)
        defaults.removeObject(forKey: initializedKey)

        let manager = TargetAppManager()

        XCTAssertTrue(manager.targetApps.isEmpty)
        XCTAssertTrue(defaults.bool(forKey: initializedKey))
    }

    private func clearStoredState() {
        defaults.removeObject(forKey: targetAppsKey)
        defaults.removeObject(forKey: initializedKey)
        defaults.removeObject(forKey: autoCorrectionScopeKey)
    }
}
