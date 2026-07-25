import AppKit
import Carbon.HIToolbox
import Combine

/// 현재 활성 앱과 입력 소스를 감시하여
/// 한글 보정이 필요한 상태인지 판단합니다.
class AppMonitor: ObservableObject {

    /// 기존 한글 직접 조합 보정이 현재 작동 중인지
    @Published private(set) var isActive: Bool = false

    /// 한/영 오입력 자동 보정이 현재 입력 소스를 관찰 중인지
    @Published private(set) var isAutoCorrectionActive: Bool = false

    /// 현재 앱에서 AX 없는 blind 교정이 사용자에 의해 켜져 있는지.
    /// EventTapManager는 필드가 AX 미지원 role일 때만 이 값으로 blind 교정을
    /// 발동합니다(보안 필드·정상 AX 필드는 이 값과 무관하게 기존 경로).
    @Published private(set) var isBlindAutoCorrectionActive: Bool = false

    /// 대상 앱이 현재 포커스 중인지
    @Published private(set) var isTargetAppFront: Bool = false

    /// 엔진이 쓰는 **실제** 앞쪽 앱 번들 ID. Mackor 자신도 그대로 들어옵니다.
    ///
    /// 패널을 열면 Mackor이 앞쪽 앱이 되고, 그때 `isTargetAppFront`가 false가 되어
    /// 조합·교정이 꺼집니다. 그게 맞습니다 — 사용자가 지금 치는 곳은 Mackor의
    /// 앱 검색창이지 대상 앱이 아니므로, 여기에 한글 조합을 밀어 넣으면 안 됩니다.
    @Published private(set) var frontAppBundleID: String?

    /// 목록 UI가 쓰는 "사용자가 방금까지 쓰던 앱". Mackor 자신은 넣지 않습니다.
    ///
    /// 패널을 열면 위 `frontAppBundleID`는 Mackor이 되지만, 사용자가 목록에서
    /// 찾는 앱은 여전히 직전에 쓰던 앱입니다. 이 값을 따로 두지 않으면 패널을
    /// 여는 순간 "● 사용 중" 배지가 사라지고 그 앱이 목록 맨 위에서 밀려납니다.
    @Published private(set) var uiFrontAppBundleID: String?

    /// 한글 IME가 활성 상태인지
    @Published private(set) var isKoreanIME: Bool = false

    /// 자동 보정 엔진이 구분해서 처리할 현재 입력 소스 종류
    @Published private(set) var inputSourceKind: InputSourceKind = .unsupported

    /// 활성화/비활성화 토글
    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            // 비활성 중 열린 Chromium 앱은 아직 AX 트리를 노출하지 않았을 수
            // 있으므로, 다시 켤 때 현재 앱의 접근성 준비도 함께 수행합니다.
            checkFrontmostApp()
        }
    }

    /// 대상 앱 매니저 (외부에서 주입)
    var targetAppManager: TargetAppManager? {
        didSet {
            observeTargetApps()
            checkFrontmostApp()
        }
    }

    private static let enabledKey = "AppMonitorIsEnabled"
    /// 지원 학습 프로브 사다리의 rung 지연(ms). 자세한 근거는
    /// `schedulePassiveSupportProbe` 주석 참고 — 요지는 Chrome처럼 웹 AX 트리를
    /// 비동기로 짓는 앱은 250ms 한 번으로는 절대 잡히지 않는다는 것.
    /// (`computeActiveState`와 같은 이유로 internal — 테스트가 사다리 모양을
    /// 고정해 one-shot으로 되돌아가는 회귀를 막습니다.)
    static let passiveSupportProbeDelaysMs = [250, 600, 1200, 2500]
    private var workspaceObservers: [NSObjectProtocol] = []
    private var targetSettingsCancellable: AnyCancellable?
    private var frontAppName: String?
    private var manuallyAccessibleProcessIDs: Set<pid_t> = []
    /// 앱 전환마다 증가시켜, 이전 앱을 향해 예약해 둔 예열 사다리 rung들을
    /// 조기 취소합니다. EventTapManager.boundaryCorrectionGeneration와 같은 패턴.
    private var warmGeneration: UInt64 = 0
    private let inputSourceController = InputSourceController()

    init() {
        isEnabled = UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
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

    // MARK: - 옵저버 설정

    private func setupObservers() {
        // 활성 앱 변경 감시
        let activateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFrontmostApp()
        }
        workspaceObservers.append(activateObserver)

        // 앱 실행 감시
        let launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.checkFrontmostApp()
        }
        workspaceObservers.append(launchObserver)

        let terminateObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else {
                return
            }
            self?.manuallyAccessibleProcessIDs.remove(application.processIdentifier)
        }
        workspaceObservers.append(terminateObserver)

        // 입력 소스 변경 감시
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name("com.apple.Carbon.TISNotifySelectedKeyboardInputSourceChanged"),
            object: nil
        )
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(enabledInputSourcesChanged),
            name: NSNotification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String),
            object: nil
        )
    }

    // MARK: - 앱 감지

    private func observeTargetApps() {
        guard let targetAppManager else {
            targetSettingsCancellable = nil
            return
        }

        // 지원 학습(axSupport)과 opt-out 예외가 바뀌어도 유효 활성 상태가
        // 달라지므로 함께 관찰합니다. 수동 프로브가 앱을 지원으로 학습하면 이
        // 경로로 자판 자동 교정이 켜집니다.
        targetSettingsCancellable = Publishers.CombineLatest4(
            targetAppManager.$targetApps,
            targetAppManager.$autoCorrectionScope,
            targetAppManager.$axSupportByBundleID,
            targetAppManager.$autoCorrectionOptOut
        )
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                // @Published는 값이 설정되기 전에 발행하므로 메인 큐에서 새 설정 반영 후 재평가합니다.
                self?.checkFrontmostApp()
            }
    }

    private func checkFrontmostApp() {
        guard let frontApp = NSWorkspace.shared.frontmostApplication else {
            frontAppBundleID = nil
            frontAppName = nil
            isTargetAppFront = false
            updateActiveState()
            return
        }

        frontAppBundleID = frontApp.bundleIdentifier
        frontAppName = frontApp.localizedName
        // 목록 UI용 값은 Mackor 자신일 때 갱신하지 않아, 패널을 열어도 직전에
        // 쓰던 앱이 "사용 중"으로 남고 목록 맨 위 자리를 지킵니다.
        if frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            uiFrontAppBundleID = frontApp.bundleIdentifier
        }
        prepareLazyAccessibilityIfNeeded(for: frontApp)
        // 전환할 때마다 세대를 올려 이전 앱 사다리를 취소하고, 대상 앱이면 새
        // 사다리를 예약합니다. 비대상/자기 앱으로 가면 세대만 오르고 예약은
        // 안 해, 그쪽으로 예열이 새지 않습니다.
        warmGeneration &+= 1
        if isEnabled,
           frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           targetAppManager?.isAutoCorrectionEnabled(
               bundleID: frontApp.bundleIdentifier,
               appName: frontApp.localizedName
           ) == true {
            scheduleWarmLadder(generation: warmGeneration)
        }

        // opt-out 모델: 아직 지원 여부를 모르는(그리고 목록 대상인) 앱은, 실제로
        // 입력란이 포커스됐을 때 AX를 한 번 확인해(교정은 하지 않음) 지원되면
        // 학습합니다. 그 순간부터 자판 자동 교정이 기본으로 켜집니다.
        if isEnabled,
           let bundleID = frontApp.bundleIdentifier,
           frontApp.processIdentifier != ProcessInfo.processInfo.processIdentifier,
           MackorAppFilter.isListable(bundleID: bundleID, name: frontApp.localizedName),
           targetAppManager?.axAutoCorrectionSupport(
               bundleID: bundleID,
               name: frontApp.localizedName
           ) == .unknown {
            schedulePassiveSupportProbe(generation: warmGeneration)
        }
        isTargetAppFront = targetAppManager?.isTargetApp(
            bundleID: frontAppBundleID,
            appName: frontAppName
        ) ?? false
        updateActiveState()
    }

    /// 앱 전환 직후, 첫 키가 오기 전에 대상 앱의 AX 트리를 짧은 간격으로 몇 번
    /// 미리 데웁니다. Chromium/Electron은 `AXManualAccessibility`를 켠 뒤에도
    /// 트리를 비동기로 지어, 활성화 시점의 1회 예열만으로는 첫 단어가 콜드
    /// 트리에 걸립니다(사용자가 VS Code에서 겪은 "첫 단어 씹힘").
    ///
    /// 간격은 콜드 예열 1회 최대 실측(57ms)보다 크게 벌려 rung이 겹치지 않게
    /// 하고, 3개로 250ms를 덮어 cmd-tab→타이핑의 통상 인간 반응(>200ms)을
    /// 커버합니다. `usleep`이 아니라 `asyncAfter`인 이유: 탭이 얹힌 메인 런루프를
    /// 막지 않고 키 사이에 양보하기 위함(EventTapManager의 예열 규율과 동일).
    ///
    /// 못 고치는 것: cmd-tab 후 ~50ms 안에 치는 즉시 첫 키, 트리 빌드가 250ms를
    /// 넘는 거대 워크스페이스. 그 경우는 기존 in-key 프로브 재시도가 뒤 키에서
    /// 복구합니다.
    private func scheduleWarmLadder(generation: UInt64) {
        for delayMs in [50, 120, 250] {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delayMs)
            ) { [weak self] in
                guard let self, self.warmGeneration == generation else { return }
                FocusedInputSafety.warmFocusCache()
            }
        }
    }

    /// 지원 미확인 앱에서 입력란이 실제로 포커스됐는지 잠시 뒤 확인합니다.
    /// 교정은 하지 않고 AX 적격 여부만 읽어(fail-closed 프로브와 같은 판정) 적격이면
    /// 지원으로 학습합니다. 다른 앱으로 전환하면(세대 변경) 취소됩니다.
    ///
    /// **한 번이 아니라 사다리인 이유** — Chrome 실측:
    ///
    /// Chrome은 `AXManualAccessibility`도(`-25205` attributeUnsupported)
    /// `AXEnhancedUserInterface`도(`-25208` notImplemented) 받지 않습니다. 위
    /// `prepareLazyAccessibilityIfNeeded`가 Electron(VS Code)에서는 통하지만
    /// Chrome에는 통하지 않는다는 뜻입니다. 대신 Chrome은 보조 기술이 트리를
    /// 실제로 조회하면 그때부터 웹 AX 트리를 **비동기로** 짓습니다.
    ///
    /// 그래서 250ms 한 번짜리 프로브는 차가운 Chrome을 거의 언제나 놓쳤고,
    /// 놓치면 `.unknown`으로 남아 다음 활성화에서 또 한 번만 봅니다. 결과적으로
    /// Chrome은 **영영 지원으로 학습되지 않아**, 사용자가 손수 목록에 추가하지
    /// 않는 한 자판 자동 교정이 켜지지 않았습니다.
    ///
    /// 사다리는 두 몫을 합니다 — 조회 자체가 Chrome의 트리 생성을 깨우는
    /// 신호이고, 뒤쪽 rung이 그렇게 지어진 트리를 잡습니다. 간격은 웹 트리가
    /// 서기까지의 실측 지연을 덮도록 2.5초까지 벌립니다.
    ///
    /// 이 프로브는 탭 콜백이 아니라 asyncAfter로 메인에서 돌아 입력 경로를 직접
    /// 막지 않습니다. 한 번 지원으로 확정되면 아래 `.unknown` 가드에서 남은
    /// rung이 전부 걸러지고, 위 호출부 가드가 다음 활성화도 막습니다.
    private func schedulePassiveSupportProbe(generation: UInt64) {
        for delayMs in AppMonitor.passiveSupportProbeDelaysMs {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(delayMs)
            ) { [weak self] in
                guard let self, self.warmGeneration == generation else { return }
                guard let bundleID = self.frontAppBundleID,
                      self.targetAppManager?.axAutoCorrectionSupport(
                        bundleID: bundleID,
                        name: self.frontAppName
                      ) == .unknown else { return }
                if case .eligible = FocusedInputSafety.probeAutomaticCorrectionFocus() {
                    self.targetAppManager?.noteAutoCorrectionSupported(bundleID: bundleID)
                }
            }
        }
    }

    /// Chromium/Electron 계열 앱은 VoiceOver 같은 보조 기술이 감지되기 전까지
    /// 편집기 AX 트리를 만들지 않을 수 있습니다. Electron이 제3자 보조 앱에
    /// 제공하는 macOS 계약인 `AXManualAccessibility`를 현재 자동 교정 대상
    /// 프로세스에 한 번 설정해, 앱별 접근성 모드를 사용자가 켜지 않아도 표준
    /// 텍스트 역할과 선택 범위를 노출하게 합니다.
    ///
    /// 이 속성을 지원하지 않는 네이티브 앱에서는 호출이 실패할 뿐이며 기존 AX
    /// 경로를 그대로 사용합니다. 입력 내용이나 필드 값은 읽지 않습니다.
    private func prepareLazyAccessibilityIfNeeded(for app: NSRunningApplication) {
        guard app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              !manuallyAccessibleProcessIDs.contains(app.processIdentifier),
              isEnabled,
              targetAppManager?.isAutoCorrectionEnabled(
                bundleID: app.bundleIdentifier,
                appName: app.localizedName
              ) == true else {
            return
        }

        let applicationElement = AXUIElementCreateApplication(app.processIdentifier)
        FocusedInputSafety.limitMessagingTime(for: applicationElement)
        let result = AXUIElementSetAttributeValue(
            applicationElement,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        if result == .success {
            manuallyAccessibleProcessIDs.insert(app.processIdentifier)
            // manual AX를 켠 직후 첫 키가 연결 준비 비용을 떠안지 않게 합니다.
            FocusedInputSafety.warmFocusCache()
        }
        if ProcessInfo.processInfo.environment["MACKOR_DIAGNOSTICS"] == "1" {
            print(
                "[Mackor][diagnostic] lazy accessibility pid=\(app.processIdentifier) "
                    + "result=\(result.rawValue)"
            )
        }
    }

    // MARK: - 입력 소스 감지

    @objc private func inputSourceChanged() {
        if Thread.isMainThread {
            checkInputSource()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.checkInputSource()
            }
        }
    }

    @objc private func enabledInputSourcesChanged() {
        if Thread.isMainThread {
            inputSourceController.refreshSelectableInputSources()
            checkInputSource()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.inputSourceController.refreshSelectableInputSources()
                self?.checkInputSource()
            }
        }
    }

    private func checkInputSource() {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            updateInputSourceState(sourceID: nil)
            return
        }

        if let idPtr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceID = Unmanaged<CFString>.fromOpaque(idPtr).takeUnretainedValue() as String
            updateInputSourceState(sourceID: sourceID)
        } else {
            updateInputSourceState(sourceID: nil)
        }
    }

    /// 이벤트 탭의 첫 keyDown이 TIS 알림을 추월할 때 쓰는 동기 새로고침입니다.
    @discardableResult
    func refreshInputSourceKind() -> InputSourceKind {
        checkInputSource()
        return inputSourceKind
    }

    private func updateInputSourceState(sourceID: String?) {
        inputSourceController.noteCurrentInputSource(sourceID)

        let kind: InputSourceKind
        if let sourceID,
           sourceID.caseInsensitiveCompare(
            InputSourceController.koreanTwoSetInputSourceID
           ) == .orderedSame {
            kind = .koreanTwoSet
        } else if let sourceID,
                  InputSourceController.supportedLatinInputSourceIDs.contains(where: {
                    sourceID.caseInsensitiveCompare($0) == .orderedSame
                  }) {
            kind = .supportedLatin
        } else {
            kind = .unsupported
        }

        if inputSourceKind != kind {
            inputSourceKind = kind
        }
        let koreanIME = kind == .koreanTwoSet
        if isKoreanIME != koreanIME {
            isKoreanIME = koreanIME
        }
        updateActiveState()
    }

    func switchInputSource(for direction: CorrectionDirection) -> InputSourceSwitchReceipt? {
        guard let receipt = inputSourceController.switchInputSource(for: direction) else {
            return nil
        }
        checkInputSource()
        return receipt
    }

    @discardableResult
    func restoreInputSource(_ receipt: InputSourceSwitchReceipt) -> Bool {
        guard inputSourceController.restoreInputSource(receipt) else { return false }
        checkInputSource()
        return true
    }

    // MARK: - 상태 업데이트

    /// 두 기능의 활성 여부.
    struct ActiveState: Equatable {
        /// 한글 직접 조합 (R2)
        let composition: Bool
        /// 한/영 오입력 자동 교정 (R3)
        let autoCorrection: Bool
    }

    /// 활성 판정 순수 함수.
    ///
    /// `AppMonitor`의 실제 초기화는 NSWorkspace와 TIS를 읽으므로(init 참조)
    /// 인스턴스 기반 테스트가 비결정적이다. 판정 로직만 떼어내 전 조합을
    /// 결정론적으로 검증할 수 있게 한다.
    ///
    /// **R2와 R3는 배타가 아니라 D3 계층 관계다** — 조합이 확정된 뒤 그 확정
    /// 문자열에 교정을 판정한다. 이전에는 조합에 `scope == .selectedApps`를
    /// 요구해서 `.allApps`를 켜면 조합이 통째로 꺼졌고, 그것이 CorelDRAW
    /// 회귀의 직접 원인이었다.
    static func computeActiveState(
        isEnabled: Bool,
        isTargetAppFront: Bool,
        isKoreanIME: Bool,
        hangulCompositionEnabled: Bool,
        autoCorrectionEnabled: Bool,
        inputSourceKind: InputSourceKind
    ) -> ActiveState {
        // 직접 한글 조합은 명시적으로 등록되고(isTargetAppFront) 앱별 토글이 켜진
        // 앱에서만 활성화됩니다. 자동 교정 엔진이 후보를 만들 때 쓰는 "임시 조합"은
        // HangulStructure.evaluate 안의 메모리 재생이며(화면을 건드리지 않음) 이
        // 플래그와 무관합니다. 따라서 scope로 둘을 배타시킬 이유가 없습니다.
        let composition = isEnabled
            && isTargetAppFront
            && isKoreanIME
            && hangulCompositionEnabled

        let autoCorrection = isEnabled
            && autoCorrectionEnabled
            && inputSourceKind != .unsupported

        return ActiveState(composition: composition, autoCorrection: autoCorrection)
    }

    private func updateActiveState() {
        let state = Self.computeActiveState(
            isEnabled: isEnabled,
            isTargetAppFront: isTargetAppFront,
            isKoreanIME: isKoreanIME,
            hangulCompositionEnabled: targetAppManager?.isHangulCompositionEnabled(
                bundleID: frontAppBundleID,
                appName: frontAppName
            ) ?? false,
            autoCorrectionEnabled: targetAppManager?.isAutoCorrectionEnabled(
                bundleID: frontAppBundleID,
                appName: frontAppName
            ) ?? false,
            inputSourceKind: inputSourceKind
        )

        if isActive != state.composition {
            isActive = state.composition
        }

        // blind 교정은 사용자가 이 앱에 명시적으로 켠 경우에만. 실제 발동은
        // EventTapManager가 필드 role 미지원까지 확인해 결정합니다(여기서는
        // "이 앱에 사용자가 켰는가 + Mackor 켜짐 + 입력 소스 지원"까지만).
        let blindActive = isEnabled
            && (targetAppManager?.isBlindAutoCorrectionEnabled(
                bundleID: frontAppBundleID,
                appName: frontAppName
            ) ?? false)
            && inputSourceKind != .unsupported

        // blind를 켜면 탭의 자동 교정 기계 자체가 돌아야 하므로(키열 버퍼링·경계),
        // 자동 교정 활성에 blind를 OR합니다. AX 미지원 앱은 storedAutoCorrection이
        // 꺼져 있어도 blind opt-in만으로 엔진이 켜집니다.
        let autoActive = state.autoCorrection || blindActive
        if isAutoCorrectionActive != autoActive {
            isAutoCorrectionActive = autoActive
        }
        if isBlindAutoCorrectionActive != blindActive {
            isBlindAutoCorrectionActive = blindActive
        }
    }
}
