import XCTest

/// 목록에 올릴 앱을 고르는 규칙. 실제 사용자의 /Applications에서 확인한 번들을
/// 그대로 표본으로 씁니다 — 걸러야 할 것과 남겨야 할 것이 한 화면에 보이도록.
final class MackorAppFilterTests: XCTestCase {

    // MARK: 남겨야 하는 앱

    func testRealTextAppsStayListed() {
        let listed: [(String, String)] = [
            ("com.microsoft.VSCode", "Visual Studio Code"),
            ("com.adobe.illustrator", "Adobe Illustrator"),
            ("com.adobe.InDesign", "Adobe InDesign 2026"),
            ("com.autodesk.AutoCAD2025", "AutoCAD 2025"),
            ("com.kakao.KakaoTalkMac", "KakaoTalk"),
            ("com.hancom.office.hwp12.mac.general", "Hancom Office HWP"),
            ("com.google.Chrome", "Google Chrome"),
            ("com.corel.coreldrawsuite.2025.fontmanager", "Corel Font Manager 2025"),
            ("com.apple.Safari", "Safari"),
        ]
        for (bundleID, name) in listed {
            XCTAssertTrue(
                MackorAppFilter.isListable(bundleID: bundleID, name: name),
                "\(name)은 목록에 남아야 합니다"
            )
        }
    }

    // MARK: 걸러야 하는 앱

    func testInstallAndRemovalToolsAreHidden() {
        let hidden: [(String, String)] = [
            ("com.google.chromeremotedesktop.me2me-host-uninstaller",
             "Chrome Remote Desktop Host Uninstaller"),
            ("com.autodesk.Remove_AutoCAD_2025", "Remove AutoCAD 2025"),
            ("com.example.installer", "Example Installer"),
            ("com.example.updater", "Example Updater"),
            ("com.example.crashreporter", "Example Crash Reporter"),
            ("com.example.tool", "예제 제거 도구"),
        ]
        for (bundleID, name) in hidden {
            XCTAssertFalse(
                MackorAppFilter.isListable(bundleID: bundleID, name: name),
                "\(name)은 목록에서 빠져야 합니다"
            )
        }
    }

    func testRemoveKeywordDoesNotHitOrdinaryAppNames() {
        // "remove "는 뒤 공백이 있어 "Remover"로 끝나는 정상 앱 이름을 건드리지
        // 않습니다. 도구 키워드가 넓어지면 여기가 먼저 깨집니다.
        XCTAssertTrue(
            MackorAppFilter.isListable(
                bundleID: "com.example.bgremover",
                name: "Background Remover"
            )
        )
    }

    func testBackgroundOnlyAppsAreHidden() {
        XCTAssertFalse(
            MackorAppFilter.isListable(
                bundleID: "com.google.drivefs",
                name: "Google Drive",
                isBackgroundOnly: true
            )
        )
        XCTAssertTrue(
            MackorAppFilter.isListable(
                bundleID: "com.google.drivefs",
                name: "Google Drive",
                isBackgroundOnly: false
            ),
            "백그라운드 판정은 Info.plist에서만 오고 이름 규칙과 섞이지 않아야 합니다"
        )
    }

    func testRemoteSessionAppsAreHidden() {
        let hidden: [(String, String)] = [
            ("com.google.Chrome.app.cmkncekebbebpfilplodngbpllndjkfo", "Chrome 원격 데스크톱"),
            ("com.microsoft.rdc.macos", "Microsoft Remote Desktop"),
            ("com.teamviewer.TeamViewer", "TeamViewer"),
        ]
        for (bundleID, name) in hidden {
            XCTAssertFalse(
                MackorAppFilter.isListable(bundleID: bundleID, name: name),
                "\(name)은 키 입력이 원격으로 넘어가 보정 대상이 아닙니다"
            )
        }
    }

    func testWebShortcutBundlesAreHidden() {
        for suffix in ["docs", "sheets", "slides"] {
            XCTAssertFalse(
                MackorAppFilter.isListable(
                    bundleID: "com.google.drivefs.shortcuts.\(suffix)",
                    name: "Google \(suffix.capitalized)"
                )
            )
        }
    }

    /// 브라우저 창을 직접 띄우는 Chrome PWA는 그 번들로 입력이 들어오므로
    /// 남깁니다. 원격 데스크톱만 이름 규칙으로 걸립니다.
    func testOrdinaryChromeAppShimStaysListed() {
        XCTAssertTrue(
            MackorAppFilter.isListable(
                bundleID: "com.google.Chrome.app.aohghmighlieiainnegkcijnfilokake",
                name: "Google 문서"
            )
        )
    }

    // MARK: Apple 규칙과의 분리

    func testAppleRuleIsSeparateFromCapability() {
        // 화이트리스트 밖 Apple 앱은 목록엔 안 나오지만, 보정이 불가능한 부류는
        // 아닙니다(최전면 앱 삽입 경로가 이 구분에 기댑니다).
        XCTAssertFalse(MackorAppFilter.isListable(bundleID: "com.apple.calculator", name: "계산기"))
        XCTAssertTrue(
            MackorAppFilter.isCorrectionCapable(bundleID: "com.apple.calculator", name: "계산기")
        )
        XCTAssertFalse(
            MackorAppFilter.isCorrectionCapable(
                bundleID: "com.autodesk.Remove_AutoCAD_2025",
                name: "Remove AutoCAD 2025"
            )
        )
    }

    // MARK: Info.plist 해석

    func testBackgroundOnlyFlagAcceptsBoolAndStringForms() {
        XCTAssertTrue(MackorAppFilter.isBackgroundOnly(infoDictionary: ["LSUIElement": true]))
        XCTAssertTrue(MackorAppFilter.isBackgroundOnly(infoDictionary: ["LSUIElement": "1"]))
        XCTAssertTrue(MackorAppFilter.isBackgroundOnly(infoDictionary: ["LSUIElement": "YES"]))
        XCTAssertTrue(MackorAppFilter.isBackgroundOnly(infoDictionary: ["LSBackgroundOnly": 1]))
        XCTAssertFalse(MackorAppFilter.isBackgroundOnly(infoDictionary: ["LSUIElement": false]))
        XCTAssertFalse(MackorAppFilter.isBackgroundOnly(infoDictionary: ["LSUIElement": "0"]))
        XCTAssertFalse(MackorAppFilter.isBackgroundOnly(infoDictionary: [:]))
        XCTAssertFalse(MackorAppFilter.isBackgroundOnly(infoDictionary: nil))
    }
}
