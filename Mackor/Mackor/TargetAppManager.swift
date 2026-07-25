import AppKit
import Combine

enum AutoCorrectionScope: String, Codable, CaseIterable {
    case allApps
    case selectedApps
}

/// 자판 자동 교정을 "제안"할 앱 범위. 목록 표시와 opt-out 기본값이 같은 기준을
/// 쓰도록 한 곳에 모읍니다. Apple 기본 앱 무더기(계산기·주식·날씨…)는 한글 입력이
/// 잦은 소수만 남깁니다. 여기 없는 Apple 앱은 목록에도 안 나오고 기본 ON 대상도
/// 아닙니다(예: Terminal에서 명령어가 교정되지 않도록).
///
/// Apple 앱 외에도, 한글을 칠 일이 **구조적으로 없는** 번들이 목록을 채웁니다.
/// 설치·제거 도구, 창 없이 도는 백그라운드 도우미, 원격 세션, 브라우저를 열기만
/// 하는 웹 바로가기가 그렇습니다. 이들은 켜고 끌 이유 자체가 없으므로 목록에
/// 아예 올리지 않습니다.
enum MackorAppFilter {
    /// 소문자 번들 ID.
    static let appleWhitelist: Set<String> = [
        "com.apple.safari",
        "com.apple.mail",
        "com.apple.mobilesms",       // 메시지
        "com.apple.notes",
        "com.apple.reminders",
        "com.apple.textedit",
        "com.apple.iwork.pages",
        "com.apple.iwork.keynote",
        "com.apple.iwork.numbers",
        "com.apple.freeform",
    ]

    /// 앱이 아니라 **도구**인 번들의 이름/번들ID 키워드. 실제 사용자 목록에서
    /// 확인한 예: "Remove AutoCAD 2025", "Chrome Remote Desktop Host
    /// Uninstaller". `install`은 uninstall/installer/Install macOS를 함께
    /// 덮습니다. `remove `는 뒤 공백이 있어 "Background Remover" 같은 정상
    /// 앱 이름에는 걸리지 않습니다.
    private static let toolKeywords = [
        "install", "setup assistant",
        "updater", "autoupdate", "software update",
        "crash report", "crashreport", "diagnostic", "troubleshoot",
        "helper", "daemon", "launch agent",
        "remove ", "제거", "설치", "도우미",
    ]

    /// 키 입력이 원격 호스트로 그대로 전달되는 앱. 로컬에는 교정할 텍스트 필드가
    /// 없어 자판 자동 교정도, 지웠다 다시 넣는 조합 보정도 성립하지 않습니다.
    private static let remoteSessionKeywords = [
        "remote desktop", "원격 데스크톱", "teamviewer", "anydesk",
        "rustdesk", "splashtop", "vnc",
    ]

    /// 브라우저를 열기만 하고 스스로 창을 띄우지 않는 웹 바로가기 번들
    /// (Google Drive가 만드는 Docs/Sheets/Slides 바로가기 등). 입력은 실제
    /// 브라우저로 들어가므로 이 번들에는 설정할 것이 없습니다.
    private static let shortcutBundlePrefixes = [
        "com.google.drivefs.shortcuts.",
    ]

    /// 한글 보정이 **원리적으로 성립하는** 번들인지. Apple 기본 앱 규칙과는
    /// 별개라, 지금 쓰는 앱을 목록에 끼워 넣는 자리처럼 화이트리스트를 일부러
    /// 건너뛰는 경로에서도 이 판정만 따로 씁니다.
    static func isCorrectionCapable(
        bundleID: String,
        name: String? = nil,
        isBackgroundOnly: Bool = false
    ) -> Bool {
        guard !isBackgroundOnly else { return false }
        let normalizedBundleID = bundleID.lowercased()
        guard !shortcutBundlePrefixes.contains(where: normalizedBundleID.hasPrefix) else {
            return false
        }
        let haystack = "\(name ?? "") \(bundleID)".lowercased()
        guard !toolKeywords.contains(where: haystack.contains),
              !remoteSessionKeywords.contains(where: haystack.contains) else {
            return false
        }
        return true
    }

    /// 목록에 보이고 opt-out 기본 ON 대상이 되는 앱인지.
    static func isListable(
        bundleID: String,
        name: String? = nil,
        isBackgroundOnly: Bool = false
    ) -> Bool {
        guard isCorrectionCapable(
            bundleID: bundleID,
            name: name,
            isBackgroundOnly: isBackgroundOnly
        ) else { return false }
        let normalized = bundleID.lowercased()
        return !normalized.hasPrefix("com.apple.") || appleWhitelist.contains(normalized)
    }

    /// Info.plist의 `LSUIElement`/`LSBackgroundOnly` — Dock에 뜨지 않고 창도
    /// 없이 도는 백그라운드 앱. 값이 Bool로도 "1"/"YES" 문자열로도 들어오므로
    /// 둘 다 같게 해석합니다.
    static func isBackgroundOnly(infoDictionary: [String: Any]?) -> Bool {
        guard let infoDictionary else { return false }
        return ["LSUIElement", "LSBackgroundOnly"].contains { key in
            switch infoDictionary[key] {
            case let flag as Bool: return flag
            case let number as NSNumber: return number.boolValue
            case let text as String: return ["1", "true", "yes"].contains(text.lowercased())
            default: return false
            }
        }
    }
}

/// 한글 입력 보정 대상 앱 목록을 관리
class TargetAppManager: ObservableObject {

    struct TargetApp: Codable, Identifiable, Equatable {
        let bundleID: String
        let name: String
        var hangulCompositionEnabled: Bool
        var autoCorrectionEnabled: Bool
        /// AX가 텍스트를 안 내놓는 앱(한컴 등)에서 사용자가 위험을 알고 켜는
        /// 검증 없는 교정. 기본 꺼짐 — "파괴 전 검증" 완화라 명시적 opt-in만
        /// 허용합니다.
        var blindAutoCorrectionEnabled: Bool
        var id: String { bundleID }

        init(
            bundleID: String,
            name: String,
            hangulCompositionEnabled: Bool = true,
            autoCorrectionEnabled: Bool = false,
            blindAutoCorrectionEnabled: Bool = false
        ) {
            self.bundleID = bundleID
            self.name = name
            self.hangulCompositionEnabled = hangulCompositionEnabled
            self.autoCorrectionEnabled = autoCorrectionEnabled
            self.blindAutoCorrectionEnabled = blindAutoCorrectionEnabled
        }

        private enum CodingKeys: String, CodingKey {
            case bundleID
            case name
            case hangulCompositionEnabled
            case autoCorrectionEnabled
            case blindAutoCorrectionEnabled
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
            blindAutoCorrectionEnabled = try container.decodeIfPresent(
                Bool.self,
                forKey: .blindAutoCorrectionEnabled
            ) ?? false
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(bundleID, forKey: .bundleID)
            try container.encode(name, forKey: .name)
            try container.encode(hangulCompositionEnabled, forKey: .hangulCompositionEnabled)
            try container.encode(autoCorrectionEnabled, forKey: .autoCorrectionEnabled)
            try container.encode(blindAutoCorrectionEnabled, forKey: .blindAutoCorrectionEnabled)
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
        loadAXSupport()
        loadOptOut()

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

    func setBlindAutoCorrectionEnabled(_ enabled: Bool, bundleID: String) {
        guard let index = targetApps.firstIndex(where: {
            bundleIDsMatch($0.bundleID, bundleID)
        }) else { return }
        guard targetApps[index].blindAutoCorrectionEnabled != enabled else { return }

        var updatedApp = targetApps[index]
        updatedApp.blindAutoCorrectionEnabled = enabled
        targetApps[index] = updatedApp
    }

    func setAutoCorrectionScope(_ scope: AutoCorrectionScope) {
        guard autoCorrectionScope != scope else { return }
        autoCorrectionScope = scope
    }

    // MARK: - 목록 UI용 토글 (create-if-absent / prune-if-off)

    /// 새 패널은 설치된 **모든** 앱을 보여주고 각 행에서 바로 토글합니다. 저장
    /// 항목(`targetApps`)은 "무언가 켜진 앱"만 유지하는 게 자연스러우므로, 없으면
    /// 만들고 두 토글이 모두 꺼지면 목록에서 지웁니다. 기존 `setHangul...`/
    /// `setAutoCorrection...Enabled`는 등록된 앱만 갱신하는 계약(테스트 고정)이라
    /// 그대로 두고, UI 진입점은 이 메서드로 분리합니다.
    func setHangulComposition(_ enabled: Bool, bundleID: String, name: String) {
        updateOrCreate(bundleID: bundleID, name: name) { $0.hangulCompositionEnabled = enabled }
    }

    func setAutoCorrection(_ enabled: Bool, bundleID: String, name: String) {
        updateOrCreate(bundleID: bundleID, name: name) { $0.autoCorrectionEnabled = enabled }
    }

    func setBlindAutoCorrection(_ enabled: Bool, bundleID: String, name: String) {
        updateOrCreate(bundleID: bundleID, name: name) { $0.blindAutoCorrectionEnabled = enabled }
    }

    /// UI 토글이 보여줄 **앱별 저장값**. `isAutoCorrectionEnabled`는 전체 Mac
    /// 범위에서 무조건 true를 돌려주므로(엔진용 유효값), 토글 표시는 이 저장값을
    /// 씁니다. 조합은 범위 영향이 없어 `isHangulCompositionEnabled`를 그대로 씁니다.
    func storedAutoCorrectionEnabled(bundleID: String?, name: String?) -> Bool {
        targetApp(bundleID: bundleID, appName: name)?.autoCorrectionEnabled ?? false
    }

    private func updateOrCreate(
        bundleID: String,
        name: String,
        _ mutate: (inout TargetApp) -> Void
    ) {
        if let index = targetApps.firstIndex(where: { bundleIDsMatch($0.bundleID, bundleID) }) {
            var app = targetApps[index]
            mutate(&app)
            if !app.hangulCompositionEnabled && !app.autoCorrectionEnabled
                && !app.blindAutoCorrectionEnabled {
                targetApps.remove(at: index)
            } else {
                targetApps[index] = app
            }
        } else {
            // 새로 만들 땐 세 토글 모두 꺼진 상태에서 시작해, 요청한 것만 켭니다.
            // (addApp의 조합=기본 켜짐과 달리, 자동만 켜려는 의도를 훼손하지 않도록.)
            var app = TargetApp(
                bundleID: bundleID,
                name: name,
                hangulCompositionEnabled: false,
                autoCorrectionEnabled: false,
                blindAutoCorrectionEnabled: false
            )
            mutate(&app)
            guard app.hangulCompositionEnabled || app.autoCorrectionEnabled
                || app.blindAutoCorrectionEnabled else { return }
            targetApps.append(app)
        }
    }

    // MARK: - 자판 자동 교정 AX 지원 상태 (실제 사용으로 학습 + 알려진 시드)

    /// 자판 자동 교정은 AX(접근성)로 포커스 필드를 읽어야 동작합니다. 그 지원
    /// 여부는 앱의 고정 속성이 아니라 "실행 중 + 입력란 포커스" 순간에만 알 수
    /// 있어(설치 목록만으론 미리 판별 불가) 실제 사용에서 학습합니다. 조합 보정은
    /// AX가 필요 없어 이 상태와 무관하게 동작합니다.
    enum AXAutoCorrectionSupport: String, Codable {
        case unknown
        case supported
        case unsupported
    }

    /// 번들 ID(소문자) → 학습된 지원 상태. `.eligible` 프로브가 실제로 관찰되면
    /// `.supported`로 승격합니다. `.unknown`은 저장하지 않습니다.
    @Published private(set) var axSupportByBundleID: [String: AXAutoCorrectionSupport] = [:] {
        didSet { saveAXSupport() }
    }

    private let axSupportKey = "AXAutoCorrectionSupport"

    /// 사용자가 명시적으로 끈(opt-out) 앱들의 번들 ID(소문자). AX 지원이 확인돼
    /// 기본 ON이 된 앱을 다시 켜지 않도록 예외로 기억합니다.
    @Published private(set) var autoCorrectionOptOut: Set<String> = [] {
        didSet { saveOptOut() }
    }

    private let optOutKey = "AutoCorrectionOptOut"

    /// AX가 빈약해 자판 자동 교정이 안 되는 것으로 **알려진** 앱 이름/번들 키워드
    /// 시드. 여기 걸리면 관찰 전에도 자동 토글을 미지원으로 표시합니다. 조합 보정은
    /// 계속 됩니다. 학습으로 `.supported`가 관찰되면 그 값이 이 시드를 이깁니다.
    ///
    /// `illustrator`는 **실사용에서 반복 확인**해 넣었습니다. 문자 도구로 캔버스에
    /// 친 글자가 교정되지 않고, 포커스 요소가 `AXUnknown`으로 나옵니다.
    ///
    /// 근거를 정정합니다(2026-07-24): 처음에는 "AX 트리에 텍스트 요소가 0개라서"를
    /// 근거로 적었는데 **그건 틀렸습니다.** 다시 재면 Illustrator는 텍스트 요소를
    /// 27개(AXTextField 5 · AXTextArea 3 · AXComboBox 19) 안정적으로 내놓습니다 —
    /// 도구 패널·옵션 바의 입력란들입니다. 반대로 Xcode·VS Code·터미널·메시지는
    /// **0개인데도 교정이 잘 됩니다.**
    ///
    /// 즉 트리에 텍스트 역할이 있느냐는 지원 여부와 상관이 없습니다. 캔버스에
    /// 직접 그리는 텍스트는 AX 요소가 아니고, 반대로 Electron·Xcode는 포커스된
    /// 순간에만 요소를 만듭니다. **밖에서 미리 판별할 방법은 없고**, 판별은
    /// 그 앱에서 실제로 쳐 봐야만 가능합니다. 그래서 이 시드는 "구조로 유도한
    /// 판정"이 아니라 "실사용으로 확인된 예외 목록"입니다.
    ///
    /// 다른 캔버스 앱(InDesign·Photoshop·AutoCAD 등)은 **확인하지 않았으므로
    /// 넣지 않았습니다.** 추측으로 넣으면 되는 앱을 미지원으로 만듭니다 —
    /// 실사용에서 학습이 판정합니다.
    private static let knownAutoCorrectionUnsupportedKeywords = [
        "coreldraw", "intellij", "illustrator", "hwp",
    ]

    /// 앱의 자판 자동 교정 지원 상태. 학습값 > 시드 > unknown 순으로 판단합니다.
    func axAutoCorrectionSupport(bundleID: String?, name: String?) -> AXAutoCorrectionSupport {
        if let bundleID,
           let learned = axSupportByBundleID[bundleID.lowercased()],
           learned != .unknown {
            return learned
        }
        let haystack = "\(name ?? "") \(bundleID ?? "")".lowercased()
        if Self.knownAutoCorrectionUnsupportedKeywords.contains(where: haystack.contains) {
            return .unsupported
        }
        return .unknown
    }

    /// 실제 교정이 걸리거나 수동 프로브가 통과한 순간(AX 확실히 동작) 호출해
    /// 지원을 학습합니다. 이 시점부터 opt-out 기본값에 따라 자동으로 켜집니다.
    func noteAutoCorrectionSupported(bundleID: String?) {
        guard let bundleID else { return }
        let normalized = bundleID.lowercased()
        guard axSupportByBundleID[normalized] != .supported else { return }
        axSupportByBundleID[normalized] = .supported
    }

    /// 그 앱에서 **텍스트 역할 자체를 못 봤다**가 반복 관찰됐을 때 호출해 미지원을
    /// 학습합니다.
    ///
    /// 이 경로가 없어서 그동안 미지원 앱은 영원히 `.unknown`에 머물렀고, UI는
    /// 정상 토글을 보여줬습니다. 시드 목록(`coreldraw`·`intellij`)에 없는 앱은
    /// 전부 그랬습니다 — Adobe Illustrator처럼 AX에 메뉴만 내놓고 텍스트 요소를
    /// 하나도 안 내놓는 앱에서 "켜져 있는데 안 된다"가 나온 원인입니다.
    ///
    /// 되돌릴 수 있게 둡니다: `.supported`가 한 번이라도 관찰되면 그쪽이 이깁니다
    /// (`noteAutoCorrectionSupported`가 무조건 덮어씁니다). 앱 업데이트로 AX가
    /// 생기면 다음 실사용에서 자동으로 복구됩니다.
    func noteAutoCorrectionUnsupported(bundleID: String?) {
        guard let bundleID else { return }
        let normalized = bundleID.lowercased()
        // 이미 지원이 확인된 앱은 강등하지 않습니다. 한 번이라도 실제로 동작했다면
        // 버튼에 포커스가 갔을 뿐인 상황과 구분해야 합니다.
        guard axSupportByBundleID[normalized] != .supported else { return }
        guard axSupportByBundleID[normalized] != .unsupported else { return }
        axSupportByBundleID[normalized] = .unsupported
    }

    /// UI 토글이 보여줄 자판 자동 교정의 **유효 상태**. 전체 Mac 범위는 별개이며
    /// 여기서는 앱별 관점(지원 기본 ON + opt-out, 또는 미확인 수동 저장값)만 봅니다.
    func autoCorrectionIsOn(bundleID: String?, name: String?) -> Bool {
        if let bundleID,
           axAutoCorrectionSupport(bundleID: bundleID, name: name) == .supported,
           MackorAppFilter.isListable(bundleID: bundleID, name: name),
           !autoCorrectionOptOut.contains(bundleID.lowercased()) {
            return true
        }
        return targetApp(bundleID: bundleID, appName: name)?.autoCorrectionEnabled ?? false
    }

    /// 목록에서 사용자가 자판 자동 교정을 켜고 끕니다(opt-out 모델).
    /// - 지원 확인된 앱: 끄면 opt-out 예외에 넣고, 켜면 예외에서 뺍니다(기본 ON 복귀).
    /// - 미확인 앱: 저장값으로 직접 켜고 끕니다(수동 opt-in).
    func setAutoCorrectionByUser(_ on: Bool, bundleID: String, name: String) {
        let normalized = bundleID.lowercased()
        if on {
            autoCorrectionOptOut.remove(normalized)
            // 지원 확인 앱은 예외 해제만으로 켜지고(엔진 파생), 미확인 앱은
            // 실제 저장값이 필요합니다.
            //
            // `isListable`을 함께 보는 이유: 목록에는 최전면 앱이
            // `isCorrectionCapable`만으로 끼어들 수 있어(MackorApp의 mergedItems)
            // 화이트리스트 밖 Apple 앱처럼 `.supported`이면서 비-listable인 앱이
            // 토글에 보입니다. 그런 앱은 `autoCorrectionIsOn`·`isAutoCorrectionEnabled`
            // 의 첫 분기가 `isListable`에서 걸리므로, 예외 해제만으로는 켜지지 않고
            // 저장값이 필요합니다. 이 검사가 없으면 토글이 켜자마자 되돌아옵니다.
            if axAutoCorrectionSupport(bundleID: bundleID, name: name) != .supported
                || !MackorAppFilter.isListable(bundleID: bundleID, name: name) {
                setAutoCorrection(true, bundleID: bundleID, name: name)
            }
        } else {
            autoCorrectionOptOut.insert(normalized)
            // 수동으로 켜둔 저장값이 있으면 함께 끕니다(없으면 no-op).
            setAutoCorrection(false, bundleID: bundleID, name: name)
        }
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

    /// AX 없는 앱에서 검증 없는 blind 교정을 켰는가. 저장값만 봅니다 — 이 기능은
    /// 자동 켜짐이 없고 사용자가 명시적으로 켠 앱에서만 동작합니다.
    func isBlindAutoCorrectionEnabled(bundleID: String?, appName: String?) -> Bool {
        targetApp(bundleID: bundleID, appName: appName)?.blindAutoCorrectionEnabled ?? false
    }

    func isAutoCorrectionEnabled(bundleID: String?, appName: String?) -> Bool {
        if autoCorrectionScope == .allApps {
            return true
        }
        // opt-out 기본값: AX 지원이 확인됐고 목록 대상인 앱은, 사용자가 끄지 않은
        // 한 자동으로 켭니다. 미확인·미지원 앱은 사용자가 직접 켠 경우(저장값)에만
        // 켜집니다. 지원 확인은 AppMonitor의 수동 프로브가 실제 사용에서 학습합니다.
        if let bundleID,
           axAutoCorrectionSupport(bundleID: bundleID, name: appName) == .supported,
           MackorAppFilter.isListable(bundleID: bundleID, name: appName),
           !autoCorrectionOptOut.contains(bundleID.lowercased()) {
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

    private func saveAXSupport() {
        if let data = try? JSONEncoder().encode(axSupportByBundleID) {
            UserDefaults.standard.set(data, forKey: axSupportKey)
        }
    }

    private func loadAXSupport() {
        if let data = UserDefaults.standard.data(forKey: axSupportKey),
           let decoded = try? JSONDecoder().decode(
            [String: AXAutoCorrectionSupport].self,
            from: data
           ) {
            axSupportByBundleID = decoded
        }
    }

    private func saveOptOut() {
        if let data = try? JSONEncoder().encode(autoCorrectionOptOut) {
            UserDefaults.standard.set(data, forKey: optOutKey)
        }
    }

    private func loadOptOut() {
        if let data = UserDefaults.standard.data(forKey: optOutKey),
           let decoded = try? JSONDecoder().decode(Set<String>.self, from: data) {
            autoCorrectionOptOut = decoded
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
