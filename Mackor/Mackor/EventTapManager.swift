import Foundation
import CoreGraphics
import Carbon.HIToolbox

protocol EventTapKeyboardOutputting {
    func sendKeyEvent(keycode: UInt16, shift: Bool)
    func sendUnicodeText(_ text: String)
}

protocol EventTapFocusInspecting {
    func automaticCorrectionFocusToken() -> FocusedInputSafety.FocusToken?
    func isCurrentFocus(
        _ token: FocusedInputSafety.FocusToken,
        utf16Offset: Int
    ) -> Bool
}

private struct AccessibilityEventTapFocusInspector: EventTapFocusInspecting {
    func automaticCorrectionFocusToken() -> FocusedInputSafety.FocusToken? {
        FocusedInputSafety.automaticCorrectionFocusToken()
    }

    func isCurrentFocus(
        _ token: FocusedInputSafety.FocusToken,
        utf16Offset: Int
    ) -> Bool {
        FocusedInputSafety.isCurrentFocus(token, utf16Offset: utf16Offset)
    }
}

/// Presentation data for the best-effort original-only recovery chip. The
/// strings already live in the six-second undo transaction and are never
/// persisted or logged.
struct OriginalChoiceRequest {
    let original: String
    let replacement: String
    let generation: UInt64
    let focusToken: FocusedInputSafety.FocusToken
    let boundaryUTF16Count: Int
    /// How strongly the rule system backed this replacement. The UI layer uses
    /// it to decide how prominently to offer the original back.
    let tier: LayoutCorrectionPolicy.Tier
}

/// 키보드 이벤트를 관찰해 선택 앱의 한글 조합과 전체 Mac의
/// 한/영 오입력 자동 교정을 수행하는 핵심 매니저.
///
/// 동작 원리:
/// 1. 선택 앱에서는 자모 키를 직접 조합해 완성된 한글을 전달
/// 2. 자동 교정 중에는 실제 키 위치만 짧게 기록하고 원래 입력은 통과
/// 3. 단어 경계가 확정된 뒤 안전한 경우에만 반대 자판 문자열로 교체
class EventTapManager {

    private final class QuartzKeyboardOutput: EventTapKeyboardOutputting {
        func sendKeyEvent(keycode: UInt16, shift: Bool) {
            let source = CGEventSource(stateID: .privateState)
            source?.userData = EventTapManager.injectionMarker

            if let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: keycode,
                keyDown: true
            ) {
                if shift { keyDown.flags.insert(.maskShift) }
                EventTapManager.tagAsInjected(keyDown)
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: keycode,
                keyDown: false
            ) {
                if shift { keyUp.flags.insert(.maskShift) }
                EventTapManager.tagAsInjected(keyUp)
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }

        func sendUnicodeText(_ text: String) {
            guard !text.isEmpty else { return }
            let source = CGEventSource(stateID: .privateState)
            source?.userData = EventTapManager.injectionMarker

            var utf16Units = Array(text.utf16)
            let length = utf16Units.count

            // 더미 키코드로 keyDown 이벤트 생성 후 유니코드 문자열 설정
            if let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x09,
                keyDown: true
            ) {
                keyDown.keyboardSetUnicodeString(
                    stringLength: length,
                    unicodeString: &utf16Units
                )
                keyDown.flags = []
                EventTapManager.tagAsInjected(keyDown)
                keyDown.post(tap: .cgAnnotatedSessionEventTap)
            }
            if let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x09,
                keyDown: false
            ) {
                EventTapManager.tagAsInjected(keyUp)
                keyUp.post(tap: .cgAnnotatedSessionEventTap)
            }
        }
    }

    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tracker = HangulCompositionTracker()
    private let autoCorrectionEngine: WrongLayoutCorrectionEngine
    private var _isActive: Bool = false
    private var _isAutoCorrectionEnabled: Bool = false
    private var automaticCorrectionFieldAllowed: Bool?
    private var automaticCorrectionFocusToken: FocusedInputSafety.FocusToken?
    private var tokenCaptureState: TokenCaptureState = .idle
    private var pendingCorrectionState: PendingCorrectionState = .none
    private var originalChoiceState: OriginalChoiceState = .none
    private var undoTransaction: UndoTransaction?
    private var undoExpirationWorkItem: DispatchWorkItem?
    private var suppressedPhysicalKeyUps: Set<UInt16> = []
    private var suppressedPhysicalRepeatKeyDowns: Set<UInt16> = []
    private var preserveUndoAcrossNextInputSourceChange = false
    private let keyboardOutput: EventTapKeyboardOutputting
    private let focusInspector: EventTapFocusInspecting
    private let now: () -> Date
    private let pause: (useconds_t) -> Void
    private let scheduleBoundaryCorrection: (@escaping () -> Void) -> Void
    private var boundaryCorrectionGeneration: UInt64 = 0
    private var originalChoiceGeneration: UInt64 = 0

    var onOriginalChoiceAvailable: ((OriginalChoiceRequest) -> Void)?
    var originalChoiceHitTest: ((CGPoint, UInt64) -> Bool)?
    var onCorrectionUndone: (() -> Void)?
    var onInputSourceSwitch: ((CorrectionDirection) -> InputSourceSwitchReceipt?)?
    var onInputSourceRestore: ((InputSourceSwitchReceipt) -> Bool)?

    /// 우리가 주입한 이벤트를 식별하기 위한 마커값
    private static let injectionMarker: Int64 = 0x48474C46  // "HGLF"
    private static let userDataField = CGEventField(rawValue: 42)!  // kCGEventSourceUserData
    private static let diagnosticsEnabled =
        ProcessInfo.processInfo.environment["MACKOR_DIAGNOSTICS"] == "1"

    /// 백스페이스 키코드
    private static let backspaceKeycode: UInt16 = 0x33
    private static let commandZKeycode: UInt16 = 0x06
    private static let undoLifetime: TimeInterval = 6
    private static let maximumBoundaryFocusCheckAttempts = 3

    /// 앱에 실제로 입력된 경계 하나입니다. 현재 지원 경계는 모두 ASCII 한
    /// 문자지만, AX caret 계산(UTF-16)과 Backspace 횟수(Character)는 서로
    /// 다른 단위이므로 둘을 합치지 않습니다.
    private struct BoundaryStroke {
        let keycode: UInt16
        let shift: Bool
        let producedCharacterCount: Int
        let producedUTF16Count: Int
    }

    /// 마침표 유예 중 이미 통과시킨 경계와 최종 trigger를 입력 순서대로
    /// 보관합니다. 교정과 Undo가 반드시 같은 배열을 공유해야 경계가 빠지거나
    /// 중복되지 않습니다.
    private struct BoundarySequence {
        let strokes: [BoundaryStroke]
        let triggerKeycode: UInt16

        init(strokes: [BoundaryStroke]) {
            precondition(!strokes.isEmpty)
            self.strokes = strokes
            triggerKeycode = strokes[strokes.count - 1].keycode
        }

        var producedCharacterCount: Int {
            strokes.reduce(0) { $0 + $1.producedCharacterCount }
        }

        var producedUTF16Count: Int {
            strokes.reduce(0) { $0 + $1.producedUTF16Count }
        }
    }

    private enum TokenCaptureState {
        case idle
        case collecting(letterStrokeCount: Int)
        case trailingPeriods(letterStrokeCount: Int, periods: [BoundaryStroke])
        case discardUntilBoundary
    }

    private struct UndoTransaction {
        let decision: CorrectionDecision
        let boundarySequence: BoundarySequence
        let focusToken: FocusedInputSafety.FocusToken
        let generation: UInt64
        let createdAt: Date
        let inputSourceSwitchReceipt: InputSourceSwitchReceipt?
    }

    /// 원래 문자와 한글 IME의 marked text는 공백/문장부호 keyDown을 대상
    /// 앱이 처리한 뒤에야 모두 확정됩니다. 그 전에는 AX 커서가 아직 단어
    /// 끝을 가리키지 않을 수 있으므로 양방향 교정을 대응 keyUp까지 보류합니다.
    private struct PendingBoundaryCorrection {
        let decision: CorrectionDecision
        let boundarySequence: BoundarySequence
        let focusToken: FocusedInputSafety.FocusToken
    }

    private enum PendingCorrectionState {
        case none
        case awaitingTriggerKeyUp(PendingBoundaryCorrection)
        case awaitingFocusCheck(PendingBoundaryCorrection)
        case applying
    }

    /// Return/Enter/Tab can submit content or move focus, so the correction has
    /// to happen before the key reaches the app. The key is withheld only when
    /// there is actually something to correct, and it is always re-injected.
    private struct PendingSubmitCorrection {
        let decision: CorrectionDecision
        /// 제출 키보다 먼저 앱에 전달된 후행 마침표입니다. 제출 키 자체는 아직
        /// 앱에 닿지 않았으므로 여기에 포함하지 않습니다.
        let precedingBoundaryStrokes: [BoundaryStroke]
        let submitStroke: BoundaryStroke
        let focusToken: FocusedInputSafety.FocusToken
    }

    private enum OriginalChoiceState {
        case none
        case chipVisible(generation: UInt64)
        case shortcutOnly(generation: UInt64)
    }

    /// 조합을 확정시키는 키들 (방향키, 엔터 등)
    private static let commitKeycodes: Set<UInt16> = [
        0x7C, 0x7B, 0x7E, 0x7D,  // 방향키 (우좌상하)
        0x24, 0x4C,               // Return, Enter(숫자패드)
        0x35,                     // Escape
        0x30,                     // Tab
    ]

    var isActive: Bool {
        get { _isActive }
        set {
            _isActive = newValue
            if !newValue {
                tracker.reset()
            }
        }
    }

    var isAutoCorrectionEnabled: Bool {
        get { _isAutoCorrectionEnabled }
        set {
            _isAutoCorrectionEnabled = newValue
            if !newValue {
                tracker.reset()
                resetAutomaticCorrectionState()
            }
        }
    }

    var inputSourceKind: InputSourceKind = .unsupported {
        didSet {
            if oldValue != inputSourceKind {
                tracker.reset()
                invalidatePendingBoundaryCorrection()
                resetAutomaticCorrectionToken()
                if preserveUndoAcrossNextInputSourceChange {
                    preserveUndoAcrossNextInputSourceChange = false
                } else {
                    clearUndoTransaction(notify: true)
                }
            }
        }
    }

    init() {
        // 현대 음절표는 규칙에서 유도하므로 최초 접근 비용만 미리 치릅니다.
        // 실패해도 입력을 막지 않습니다.
        KSX1001Table.prepare()
        autoCorrectionEngine = WrongLayoutCorrectionEngine()
        keyboardOutput = QuartzKeyboardOutput()
        focusInspector = AccessibilityEventTapFocusInspector()
        now = Date.init
        pause = { microseconds in
            _ = usleep(microseconds)
        }
        scheduleBoundaryCorrection = { correction in
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(20),
                execute: correction
            )
        }
    }

    init(
        keyboardOutput: EventTapKeyboardOutputting,
        focusInspector: EventTapFocusInspecting,
        now: @escaping () -> Date,
        pause: @escaping (useconds_t) -> Void,
        scheduleBoundaryCorrection: @escaping (@escaping () -> Void) -> Void = { $0() }
    ) {
        autoCorrectionEngine = WrongLayoutCorrectionEngine()
        self.keyboardOutput = keyboardOutput
        self.focusInspector = focusInspector
        self.now = now
        self.pause = pause
        self.scheduleBoundaryCorrection = scheduleBoundaryCorrection
    }
    deinit { stop() }

    // MARK: - 시작/중지

    /// 이벤트 탭이 살아 있는지 확인합니다.
    ///
    /// 손쉬운 사용 권한 토글, TCC 초기화, 실행 중 바이너리 교체(Sparkle 업데이트),
    /// 빠른 사용자 전환 뒤에는 포트가 무효화되지만 `eventTap`은 non-nil로 남습니다.
    /// nil 검사만으로는 이 상태를 정상으로 오인하므로 포트 유효성까지 확인합니다.
    var isEventTapHealthy: Bool {
        guard let tap = eventTap else { return false }
        return CFMachPortIsValid(tap)
    }

    func start() -> Bool {
        if eventTap != nil {
            if isEventTapHealthy { return true }
            // 죽은 포트가 남아 있으면 정리한 뒤 새로 만듭니다.
            print("[Mackor] Event tap이 무효화되어 재생성합니다.")
            stop()
        }

        let eventMask: CGEventMask = [
            CGEventType.keyDown,
            .keyUp,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown,
        ].reduce(0) { mask, type in
            mask | (CGEventMask(1) << type.rawValue)
        }
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            print("[Mackor] Event tap 생성 실패. 손쉬운 사용 권한을 확인하세요.")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[Mackor] Event tap 시작됨.")
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
        resetTransientState()
        clearSuppressedKeyUps()
        print("[Mackor] Event tap 중지됨.")
    }

    // MARK: - 이벤트 처리

    /// 같은 앱 안에서 입력 위치가 바뀌면 화면의 마지막 글자는 더 이상
    /// tracker가 추적하던 조합 문자가 아니므로 이전 조합을 폐기한다.
    func handleMouseDown(
        at quartzPoint: CGPoint? = nil,
        isPrimaryButton: Bool = false
    ) {
        guard isActive || isAutoCorrectionEnabled else { return }

        let preserveOriginalChoice: Bool
        if isPrimaryButton,
           let quartzPoint,
           case .chipVisible(let generation) = originalChoiceState,
           undoTransaction?.generation == generation,
           originalChoiceHitTest?(quartzPoint, generation) == true {
            preserveOriginalChoice = true
        } else {
            preserveOriginalChoice = false
        }

        // Every click invalidates composition, token capture and pending
        // correction. Only a primary click inside the active chip may retain
        // the already-applied original-choice transaction until button action.
        tracker.reset()
        invalidatePendingBoundaryCorrection()
        resetAutomaticCorrectionToken()
        if !preserveOriginalChoice {
            clearUndoTransaction(notify: true)
        }
    }

    /// 앱 전환이나 이벤트 탭 복구 뒤에는 화면의 마지막 글자를 더 이상
    /// 안전하게 교체할 수 없으므로 진행 중인 조합만 확정 상태로 돌린다.
    func resetComposition() {
        resetTransientState()
    }

    func handleKeyDown(_ event: CGEvent) -> CGEvent? {
        // 두 기능이 모두 비활성 상태면 통과
        guard isActive || isAutoCorrectionEnabled else { return event }

        // 우리가 주입한 이벤트면 통과
        if EventTapManager.isInjected(event) {
            return event
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // 정상적인 키 순서에서는 보류한 경계 keyDown 다음에 같은 키의 keyUp이
        // 옵니다. 그 전에 다른 keyDown이 도착하면 사용자가 계속 입력한 것이므로
        // 이전 단어를 뒤늦게 고치지 않고 fail-closed로 폐기합니다.
        invalidatePendingBoundaryCorrection()

        // Space/문장부호 교정과 성공한 자체 Undo는 한 물리 키 입력당 한 번만
        // 실행합니다. 그 keyUp이 오기 전의 autorepeat keyDown도 함께 차단합니다.
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
           suppressedPhysicalRepeatKeyDowns.contains(keycode) {
            return nil
        }

        // 자동 교정 직후의 ⌘Z만 자체적으로 되돌립니다. 그 외 ⌘Z는 대상
        // 앱의 원래 Undo 동작으로 그대로 전달합니다.
        if isImmediateUndoShortcut(keycode: keycode, flags: flags), undoLastCorrectionIfPossible() {
            return nil
        }

        // 다른 실제 입력이 들어오면 직전 교정 트랜잭션은 더 이상 안전하게
        // 되돌릴 수 없습니다.
        clearUndoTransaction(notify: true)

        // Cmd, Ctrl, Option 키가 눌려있으면 조합 확정 후 통과 (단축키)
        if flags.contains(.maskCommand)
            || flags.contains(.maskControl)
            || flags.contains(.maskAlternate)
            || flags.contains(.maskSecondaryFn) {
            commitCompositionIfNeeded()
            resetAutomaticCorrectionToken()
            return event
        }

        let shiftPressed = flags.contains(.maskShift)
        // 실제 Shift는 ㅆ·ㄲ 같은 올바른 두벌식 입력에도 필요하므로 후보에
        // 보존합니다. Caps Lock만 대소문자 의도가 불분명해 자동 교정에서
        // 제외하며, 직접 한글 조합에도 Shift로 전달하지 않습니다.
        let capsLockPressed = flags.contains(.maskAlphaShift)

        // Space, 쉼표, 물음표, 느낌표는 즉시 평가합니다. 마침표는 URL과
        // 식별자의 내부 기호일 수 있으므로 아래의 별도 trailingPeriods 상태로
        // 최대 세 개까지 유예합니다.
        if let (boundary, boundaryStroke) = immediateCorrectionBoundary(
            for: keycode,
            shift: shiftPressed
        ) {
            processImmediateBoundary(
                boundary,
                stroke: boundaryStroke
            )
            commitCompositionIfNeeded()
            return event
        }

        // Return/Enter/Tab. 교정할 것이 있을 때만 키를 붙잡습니다. 그 외에는
        // 아래 commitKeycodes 경로로 내려가 지금까지와 똑같이 동작합니다.
        if let submitStroke = submitBoundaryStroke(for: keycode, shift: shiftPressed),
           let pending = makeSubmitCorrection(stroke: submitStroke) {
            commitCompositionIfNeeded()
            performSubmitCorrection(pending)
            return nil
        }

        if let periodStroke = trailingPeriodStroke(
            for: keycode,
            shift: shiftPressed
        ) {
            if isAutoCorrectionEnabled {
                processTrailingPeriod(periodStroke)
            }
            // 직접 조합 중인 마지막 음절은 마침표가 앱에 도착하기 전에
            // 확정하되, 자동 교정 엔진의 letter stroke는 그대로 보존합니다.
            commitCompositionIfNeeded()
            return event
        }

        // 백스페이스
        if keycode == EventTapManager.backspaceKeycode {
            // 직접 조합과 자동 교정이 함께 켜진 앱에서는 백스페이스가 두 모델을
            // 어긋나게 만든다. 엔진은 스트로크 하나를 지운 뒤 남은 키열을 새
            // 트래커로 재생해 decision.original을 만들지만(HangulStructure.evaluate),
            // 화면의 트래커는 이미 커밋한 음절을 다시 열지 못한다.
            // 예: g, e, Backspace, o, o, d
            //   화면  ㅎㄷ → BS → ㅎ → ㅎㅐㅐㅇ  (4자)
            //   엔진  g,o,o,d 재생 → 해ㅐㅇ        (3자)
            // 이 상태로 교정을 발사하면 백스페이스 수가 하나 모자라 유출 문자가
            // 교정 단어에 붙는다. 그래서 이 토큰의 교정은 포기한다.
            // 교정 기회만 잃고 텍스트는 손상되지 않는다.
            // (근본 해결은 트래커/엔진의 스냅샷 공유 — 별도 단계)
            if isAutoCorrectionEnabled, shouldDirectlyComposeCurrentInput {
                invalidateAutomaticCorrectionTokenUntilBoundary()
                guard shouldDirectlyComposeCurrentInput else { return event }
                let result = tracker.processBackspace()
                if result.passthrough {
                    return event
                }
                executeResult(result)
                return nil
            }

            if isAutoCorrectionEnabled, processTrailingPeriodBackspace() {
                // 화면의 마지막 period는 원래 Backspace가 지우도록 그대로
                // 통과시킵니다. 엔진의 마지막 letter stroke는 건드리지 않습니다.
                return event
            }

            if isAutoCorrectionEnabled, automaticCorrectionFieldAllowed == true {
                switch tokenCaptureState {
                case .collecting(let letterStrokeCount):
                    autoCorrectionEngine.processBackspace()
                    if letterStrokeCount <= 1 {
                        tokenCaptureState = .idle
                        clearAutomaticCorrectionFocus()
                    } else {
                        tokenCaptureState = .collecting(
                            letterStrokeCount: letterStrokeCount - 1
                        )
                    }
                case .idle, .discardUntilBoundary:
                    break
                case .trailingPeriods:
                    // processTrailingPeriodBackspace()가 먼저 처리합니다.
                    break
                }
            }

            guard shouldDirectlyComposeCurrentInput else {
                return event
            }
            let result = tracker.processBackspace()
            if result.passthrough {
                return event
            }
            executeResult(result)
            return nil  // 원래 백스페이스는 차단
        }

        // 방향키, Escape 등은 현재 위치/단어를 확정하고 버퍼를 폐기합니다.
        if EventTapManager.commitKeycodes.contains(keycode) {
            commitCompositionIfNeeded()
            resetAutomaticCorrectionToken()
            return event
        }

        // 자모 키 확인
        guard let jamo = KeycodeToJamoMap.jamo(for: keycode, shift: shiftPressed) else {
            // 숫자나 지원하지 않는 기호가 같은 공백 토큰에 섞이면 뒤쪽의
            // 사전 단어만 따로 교정하지 않도록 다음 경계까지 후보를 폐기합니다.
            // 안전한 한국어 입력란에서는 직접 조합 상태를 유지해 토큰 도중
            // 네이티브 IME로 처리 방식이 바뀌지 않게 합니다.
            commitCompositionIfNeeded()
            if isAutoCorrectionEnabled {
                invalidateAutomaticCorrectionTokenUntilBoundary()
            }
            return event
        }

        if isAutoCorrectionEnabled {
            if case .trailingPeriods = tokenCaptureState {
                // `gksrmf.com`처럼 period 뒤에 letter가 이어지면 앞부분만
                // 소급 교정하지 않도록 이 공백 run 전체를 폐기합니다.
                invalidateAutomaticCorrectionTokenUntilBoundary()
            }

            let isAlreadyDiscarding: Bool
            if case .discardUntilBoundary = tokenCaptureState {
                isAlreadyDiscarding = true
            } else {
                isAlreadyDiscarding = false
            }

            if !isAlreadyDiscarding, automaticCorrectionFieldAllowed == nil {
                let focusToken = focusInspector.automaticCorrectionFocusToken()
                automaticCorrectionFocusToken = focusToken
                automaticCorrectionFieldAllowed = focusToken != nil
            }

            if !isAlreadyDiscarding, automaticCorrectionFieldAllowed == true {
                // false는 overflow/지원하지 않는 토큰으로 이번 후보가 폐기됐다는
                // 뜻입니다. AX 필드 안전성은 그대로이므로 직접 조합은 경계까지
                // 유지해 입력 방식이 단어 중간에 바뀌지 않게 합니다.
                // Caps Lock은 영문 자판에서만 확실하게 대문자를 만듭니다. 그
                // 경우 후보의 대소문자를 화면과 일치시켜야 Undo가 원문을 그대로
                // 되돌릴 수 있고, 전대문자 토큰은 정책의 약어 규칙이 보존합니다.
                // 한글 자판에서는 Caps Lock이 IME 출력에 어떻게 반영되는지
                // 보장할 수 없으므로 기존대로 토큰을 폐기합니다.
                let capsLockIsAmbiguous = capsLockPressed
                    && inputSourceKind != .supportedLatin
                if capsLockIsAmbiguous {
                    invalidateAutomaticCorrectionTokenUntilBoundary()
                } else {
                    let effectiveShift = shiftPressed
                        || (capsLockPressed && inputSourceKind == .supportedLatin)
                    let wasRecorded = autoCorrectionEngine.record(
                        PhysicalKeystroke(keycode: keycode, shift: effectiveShift),
                        inputSource: inputSourceKind
                    )
                    if wasRecorded {
                        switch tokenCaptureState {
                        case .idle:
                            tokenCaptureState = .collecting(letterStrokeCount: 1)
                        case .collecting(let letterStrokeCount):
                            tokenCaptureState = .collecting(
                                letterStrokeCount: letterStrokeCount + 1
                            )
                        case .trailingPeriods, .discardUntilBoundary:
                            // 위에서 먼저 폐기하므로 도달하지 않습니다.
                            break
                        }
                    } else {
                        tokenCaptureState = .discardUntilBoundary
                        clearAutomaticCorrectionFocus()
                    }
                }
            }
        }

        // 영문 입력 소스에서는 원래 키를 앱에 전달하고 단어 경계에서만
        // 후보를 평가합니다.
        guard shouldDirectlyComposeCurrentInput else {
            return event
        }

        // 자모 처리
        let result = tracker.processJamo(jamo)
        if result.passthrough {
            return event
        }
        executeResult(result)
        return nil  // 원래 키 이벤트는 차단
    }

    /// 차단한 물리 keyDown과 짝인 keyUp도 차단해 대상 앱에 고아 keyUp이
    /// 전달되지 않도록 합니다. 우리가 합성한 이벤트는 마커로 통과시킵니다.
    func handleKeyUp(_ event: CGEvent) -> CGEvent? {
        if EventTapManager.isInjected(event) {
            return event
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if case .awaitingTriggerKeyUp(let pending) = pendingCorrectionState,
           pending.boundarySequence.triggerKeycode == keycode {
            EventTapManager.diagnostic("matched deferred keyUp key=\(keycode)")
            pendingCorrectionState = .awaitingFocusCheck(pending)
            let generation = boundaryCorrectionGeneration
            schedulePendingBoundaryCorrection(
                pending,
                generation: generation,
                attempt: 1
            )
        }

        suppressedPhysicalRepeatKeyDowns.remove(keycode)
        return suppressedPhysicalKeyUps.remove(keycode) == nil ? event : nil
    }

    func noteSuppressedKeyDown(_ event: CGEvent) {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        suppressedPhysicalKeyUps.insert(keycode)
        if shouldSuppressAutorepeat(for: event) {
            suppressedPhysicalRepeatKeyDowns.insert(keycode)
        }
    }

    func clearSuppressedKeyUps() {
        suppressedPhysicalKeyUps.removeAll(keepingCapacity: true)
        suppressedPhysicalRepeatKeyDowns.removeAll(keepingCapacity: true)
    }

    // MARK: - 한/영 오입력 자동 교정

    private func immediateCorrectionBoundary(
        for keycode: UInt16,
        shift: Bool
    ) -> (CorrectionBoundary, BoundaryStroke)? {
        let boundary: CorrectionBoundary
        switch (keycode, shift) {
        case (0x31, false):       // Space
            boundary = .space
        case (0x2B, false),       // ,
             (0x2C, true),        // ? (Shift+/)
             (0x12, true):        // ! (Shift+1)
            boundary = .punctuation
        default:
            return nil
        }
        return (
            boundary,
            BoundaryStroke(
                keycode: keycode,
                shift: shift,
                producedCharacterCount: 1,
                producedUTF16Count: 1
            )
        )
    }

    private func trailingPeriodStroke(
        for keycode: UInt16,
        shift: Bool
    ) -> BoundaryStroke? {
        guard keycode == 0x2F, !shift else { return nil }
        return BoundaryStroke(
            keycode: keycode,
            shift: false,
            producedCharacterCount: 1,
            producedUTF16Count: 1
        )
    }

    /// Return/Enter/Tab 인지. Shift+Tab 은 역방향 포커스 이동이라 제외합니다.
    private func submitBoundaryStroke(
        for keycode: UInt16,
        shift: Bool
    ) -> BoundaryStroke? {
        guard !shift else { return nil }
        switch keycode {
        case 0x24, 0x4C, 0x30:  // Return, 숫자패드 Enter, Tab
            return BoundaryStroke(
                keycode: keycode,
                shift: false,
                producedCharacterCount: 1,
                producedUTF16Count: 1
            )
        default:
            return nil
        }
    }

    /// 제출 키로 확정된 토큰을 평가합니다. 교정할 것이 없으면 `nil` 을 돌려
    /// 호출자가 키를 그대로 통과시키게 합니다 — 대부분의 입력이 이 경로입니다.
    private func makeSubmitCorrection(
        stroke: BoundaryStroke
    ) -> PendingSubmitCorrection? {
        let hasEligibleToken: Bool
        let precedingBoundaryStrokes: [BoundaryStroke]
        switch tokenCaptureState {
        case .collecting:
            hasEligibleToken = true
            precedingBoundaryStrokes = []
        case .trailingPeriods(_, let periods):
            hasEligibleToken = true
            precedingBoundaryStrokes = periods
        case .idle, .discardUntilBoundary:
            hasEligibleToken = false
            precedingBoundaryStrokes = []
        }

        let focusToken = automaticCorrectionFocusToken
        let decision: CorrectionDecision?
        if isAutoCorrectionEnabled,
           hasEligibleToken,
           automaticCorrectionFieldAllowed == true,
           focusToken != nil {
            decision = autoCorrectionEngine.processBoundary(.submit)
        } else {
            autoCorrectionEngine.reset()
            decision = nil
        }
        tokenCaptureState = .idle
        clearAutomaticCorrectionFocus()

        guard let decision, let focusToken else { return nil }
        EventTapManager.diagnostic(
            "submit boundary direction=\(decision.direction) "
                + "originalUTF16=\(decision.original.utf16.count) "
                + "key=\(stroke.keycode)"
        )
        return PendingSubmitCorrection(
            decision: decision,
            precedingBoundaryStrokes: precedingBoundaryStrokes,
            submitStroke: stroke,
            focusToken: focusToken
        )
    }

    /// 교정을 적용한 뒤 사용자가 누른 제출 키를 주입합니다. 이 작업은 물리
    /// keyDown 콜백 안에서 동기적으로 끝냅니다. 제출 키만 지연시키면 그 사이
    /// 들어온 다음 물리 키가 Enter/Tab 을 추월할 수 있기 때문입니다.
    ///
    /// 포커스가 어긋나 교정을 포기하더라도 제출 키는 반드시 주입합니다. 사용자의
    /// Enter 를 삼키는 것이 잘못 교정하는 것보다 나쁘기 때문입니다.
    private func performSubmitCorrection(_ pending: PendingSubmitCorrection) {
        defer {
            sendKeyEvent(
                keycode: pending.submitStroke.keycode,
                shift: pending.submitStroke.shift
            )
        }

        // 제출 키는 아직 앱에 도달하지 않았습니다. 다만 앞서 통과시킨 후행
        // 마침표가 있다면 실제 커서는 그 길이만큼 원문 뒤에 있습니다.
        let precedingBoundaryUTF16Count = pending.precedingBoundaryStrokes.reduce(0) {
            $0 + $1.producedUTF16Count
        }
        let expectedOffset = pending.decision.original.utf16.count
            + precedingBoundaryUTF16Count
        guard focusInspector.isCurrentFocus(
            pending.focusToken,
            utf16Offset: expectedOffset
        ) else {
            EventTapManager.diagnostic(
                "submit focus mismatch expectedOffset=\(expectedOffset)"
            )
            return
        }

        applySubmitCorrection(pending)
    }

    private func applySubmitCorrection(_ pending: PendingSubmitCorrection) {
        let decision = pending.decision
        if !pending.precedingBoundaryStrokes.isEmpty {
            deleteBoundarySequence(BoundarySequence(
                strokes: pending.precedingBoundaryStrokes
            ))
        }
        for _ in 0..<decision.originalCharacterCount {
            sendKeyEvent(keycode: EventTapManager.backspaceKeycode, shift: false)
            pause(3000)
        }
        sendUnicodeText(decision.replacement)
        pause(3000)
        for stroke in pending.precedingBoundaryStrokes {
            sendKeyEvent(keycode: stroke.keycode, shift: stroke.shift)
        }

        preserveUndoAcrossNextInputSourceChange = true
        let inputSourceSwitchReceipt = onInputSourceSwitch?(decision.direction)
        preserveUndoAcrossNextInputSourceChange = false

        // 제출 키는 호출자가 주입하므로 경계 배열에 포함해 Undo 산술을 맞춥니다.
        let boundarySequence = BoundarySequence(
            strokes: pending.precedingBoundaryStrokes + [pending.submitStroke]
        )
        originalChoiceGeneration &+= 1
        let generation = originalChoiceGeneration
        undoTransaction = UndoTransaction(
            decision: decision,
            boundarySequence: boundarySequence,
            focusToken: pending.focusToken,
            generation: generation,
            createdAt: now(),
            inputSourceSwitchReceipt: inputSourceSwitchReceipt
        )
        originalChoiceState = .shortcutOnly(generation: generation)
        scheduleUndoExpiration(for: generation)
        // 제출 뒤에는 원문 칩의 앵커를 잡을 수 없는 경우가 많습니다. UI 계층이
        // 정확한 범위를 다시 확인하고 실패하면 조용히 칩을 띄우지 않습니다.
        onOriginalChoiceAvailable?(
            OriginalChoiceRequest(
                original: decision.original,
                replacement: decision.replacement,
                generation: generation,
                focusToken: pending.focusToken,
                boundaryUTF16Count: boundarySequence.producedUTF16Count,
                tier: decision.tier
            )
        )
    }

    private func processImmediateBoundary(
        _ boundary: CorrectionBoundary,
        stroke: BoundaryStroke
    ) {
        let sequence: BoundarySequence
        let hasEligibleToken: Bool
        switch tokenCaptureState {
        case .collecting:
            sequence = BoundarySequence(strokes: [stroke])
            hasEligibleToken = true
        case .trailingPeriods(_, let periods):
            sequence = BoundarySequence(strokes: periods + [stroke])
            hasEligibleToken = true
        case .idle, .discardUntilBoundary:
            sequence = BoundarySequence(strokes: [stroke])
            hasEligibleToken = false
        }

        let focusToken = automaticCorrectionFocusToken
        let decision: CorrectionDecision?
        if isAutoCorrectionEnabled,
           hasEligibleToken,
           automaticCorrectionFieldAllowed == true,
           focusToken != nil {
            decision = autoCorrectionEngine.processBoundary(boundary)
        } else {
            // 실제 경계는 discard 상태도 끝냅니다.
            autoCorrectionEngine.reset()
            decision = nil
        }
        tokenCaptureState = .idle
        clearAutomaticCorrectionFocus()

        guard let decision, let focusToken else { return }
        EventTapManager.diagnostic(
            "defer direction=\(decision.direction) "
                + "originalUTF16=\(decision.original.utf16.count) "
                + "boundaries=\(sequence.strokes.count) "
                + "trigger=\(sequence.triggerKeycode)"
        )
        pendingCorrectionState = .awaitingTriggerKeyUp(
            PendingBoundaryCorrection(
                decision: decision,
                boundarySequence: sequence,
                focusToken: focusToken
            )
        )
    }

    private func processTrailingPeriod(_ period: BoundaryStroke) {
        switch tokenCaptureState {
        case .collecting(let letterStrokeCount):
            tokenCaptureState = .trailingPeriods(
                letterStrokeCount: letterStrokeCount,
                periods: [period]
            )
        case .trailingPeriods(let letterStrokeCount, let periods):
            guard periods.count < 3 else {
                invalidateAutomaticCorrectionTokenUntilBoundary()
                return
            }
            tokenCaptureState = .trailingPeriods(
                letterStrokeCount: letterStrokeCount,
                periods: periods + [period]
            )
        case .idle, .discardUntilBoundary:
            break
        }
    }

    /// `true`이면 화면의 period 하나만 원래 Backspace로 지워야 합니다.
    private func processTrailingPeriodBackspace() -> Bool {
        guard case .trailingPeriods(let letterStrokeCount, var periods) = tokenCaptureState,
              !periods.isEmpty else {
            return false
        }
        periods.removeLast()
        if periods.isEmpty {
            tokenCaptureState = .collecting(letterStrokeCount: letterStrokeCount)
        } else {
            tokenCaptureState = .trailingPeriods(
                letterStrokeCount: letterStrokeCount,
                periods: periods
            )
        }
        return true
    }

    private func shouldSuppressAutorepeat(for event: CGEvent) -> Bool {
        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags
        return immediateCorrectionBoundary(
            for: keycode,
            shift: flags.contains(.maskShift)
        ) != nil
            || trailingPeriodStroke(
                for: keycode,
                shift: flags.contains(.maskShift)
            ) != nil
            || submitBoundaryStroke(
                for: keycode,
                shift: flags.contains(.maskShift)
            ) != nil
            || isImmediateUndoShortcut(keycode: keycode, flags: flags)
    }

    private func commitCompositionIfNeeded() {
        guard shouldDirectlyComposeCurrentInput else {
            tracker.reset()
            return
        }
        executeResult(tracker.processNonJamo())
    }

    /// 직접 조합은 사용자가 명시적으로 등록한 문제 앱에서만 사용합니다.
    /// 전체 Mac 자동 교정은 정상 앱의 macOS 네이티브 IME를 그대로 둡니다.
    private var shouldDirectlyComposeCurrentInput: Bool {
        isActive && inputSourceKind == .koreanTwoSet
    }

    private func schedulePendingBoundaryCorrection(
        _ pending: PendingBoundaryCorrection,
        generation: UInt64,
        attempt: Int
    ) {
        scheduleBoundaryCorrection { [weak self] in
            guard let self,
                  self.boundaryCorrectionGeneration == generation,
                  case .awaitingFocusCheck = self.pendingCorrectionState else {
                return
            }
            if self.applyPendingBoundaryCorrection(pending, attempt: attempt) {
                if self.boundaryCorrectionGeneration == generation {
                    self.pendingCorrectionState = .none
                }
                return
            }
            guard attempt < EventTapManager.maximumBoundaryFocusCheckAttempts else {
                self.pendingCorrectionState = .none
                return
            }
            self.schedulePendingBoundaryCorrection(
                pending,
                generation: generation,
                attempt: attempt + 1
            )
        }
    }

    @discardableResult
    private func applyPendingBoundaryCorrection(
        _ pending: PendingBoundaryCorrection,
        attempt: Int
    ) -> Bool {
        // 물리 keyUp까지 대상 앱에 전달하고 메인 큐를 한 번 양보한 뒤 실행됩니다.
        // 그 사이 새 키·마우스·입력 소스 변경이 오면 generation이 달라져 이
        // 작업은 취소됩니다. 느린 앱은 최대 세 번까지 경계 위치만 다시 확인하고,
        // 일치하기 전에는 어떤 삭제나 입력 소스 변경도 수행하지 않습니다.
        let expectedOffset = pending.decision.original.utf16.count
            + pending.boundarySequence.producedUTF16Count
        let focusMatches = focusInspector.isCurrentFocus(
            pending.focusToken,
            utf16Offset: expectedOffset
        )
        EventTapManager.diagnostic(
            "deferred focus match=\(focusMatches) expectedOffset=\(expectedOffset) attempt=\(attempt)"
        )
        guard focusMatches else {
            return false
        }

        pendingCorrectionState = .applying
        // 대상 앱이 이미 원문과 모든 경계 문자를 처리했으므로 경계를 역순으로
        // 지운 뒤 원문을 지우고, 교정문과 같은 경계 배열을 다시 넣습니다.
        deleteBoundarySequence(pending.boundarySequence)
        applyCorrection(
            pending.decision,
            boundarySequence: pending.boundarySequence,
            focusToken: pending.focusToken
        )
        return true
    }

    private func applyCorrection(
        _ decision: CorrectionDecision,
        boundarySequence: BoundarySequence,
        focusToken: FocusedInputSafety.FocusToken
    ) {
        for _ in 0..<decision.originalCharacterCount {
            sendKeyEvent(keycode: EventTapManager.backspaceKeycode, shift: false)
            pause(3000)
        }

        sendUnicodeText(decision.replacement)
        pause(3000)
        reinjectBoundarySequence(boundarySequence)

        preserveUndoAcrossNextInputSourceChange = true
        let inputSourceSwitchReceipt = onInputSourceSwitch?(decision.direction)
        preserveUndoAcrossNextInputSourceChange = false

        originalChoiceGeneration &+= 1
        let generation = originalChoiceGeneration
        let transaction = UndoTransaction(
            decision: decision,
            boundarySequence: boundarySequence,
            focusToken: focusToken,
            generation: generation,
            createdAt: now(),
            inputSourceSwitchReceipt: inputSourceSwitchReceipt
        )
        undoTransaction = transaction
        originalChoiceState = .shortcutOnly(generation: generation)
        scheduleUndoExpiration(for: generation)
        onOriginalChoiceAvailable?(
            OriginalChoiceRequest(
                original: decision.original,
                replacement: decision.replacement,
                generation: generation,
                focusToken: focusToken,
                boundaryUTF16Count: boundarySequence.producedUTF16Count,
                tier: decision.tier
            )
        )
    }

    private func deleteBoundarySequence(_ boundarySequence: BoundarySequence) {
        for stroke in boundarySequence.strokes.reversed() {
            for _ in 0..<stroke.producedCharacterCount {
                sendKeyEvent(keycode: EventTapManager.backspaceKeycode, shift: false)
                pause(3000)
            }
        }
    }

    private func reinjectBoundarySequence(_ boundarySequence: BoundarySequence) {
        for stroke in boundarySequence.strokes {
            sendKeyEvent(keycode: stroke.keycode, shift: stroke.shift)
        }
    }

    private func isImmediateUndoShortcut(keycode: UInt16, flags: CGEventFlags) -> Bool {
        keycode == EventTapManager.commandZKeycode
            && flags.contains(.maskCommand)
            && !flags.contains(.maskShift)
            && !flags.contains(.maskControl)
            && !flags.contains(.maskAlternate)
            && !flags.contains(.maskSecondaryFn)
    }

    private func undoLastCorrectionIfPossible(
        expectedGeneration: UInt64? = nil
    ) -> Bool {
        if let expectedGeneration,
           undoTransaction?.generation != expectedGeneration {
            return false
        }

        guard let transaction = undoTransaction,
              now().timeIntervalSince(transaction.createdAt) <= EventTapManager.undoLifetime,
              focusInspector.isCurrentFocus(
                  transaction.focusToken,
                  utf16Offset: transaction.decision.replacement.utf16.count
                    + transaction.boundarySequence.producedUTF16Count
              ) else {
            clearUndoTransaction(notify: true)
            return false
        }

        // 교정 뒤에 다시 주입한 경계 배열을 역순으로 지운 뒤 결과 단어를
        // 원래 입력으로 복원하고 배열 순서대로 같은 경계를 되돌려 놓습니다.
        deleteBoundarySequence(transaction.boundarySequence)
        for _ in 0..<transaction.decision.replacementCharacterCount {
            sendKeyEvent(keycode: EventTapManager.backspaceKeycode, shift: false)
            pause(3000)
        }
        sendUnicodeText(transaction.decision.original)
        pause(3000)
        reinjectBoundarySequence(transaction.boundarySequence)

        resetAutomaticCorrectionToken()
        tracker.reset()
        clearUndoTransaction(notify: false)

        if let receipt = transaction.inputSourceSwitchReceipt {
            preserveUndoAcrossNextInputSourceChange = true
            _ = onInputSourceRestore?(receipt)
            preserveUndoAcrossNextInputSourceChange = false
        }

        onCorrectionUndone?()
        return true
    }

    /// True only while the exact generation still owns the current six-second
    /// transaction. The coordinator uses this to avoid presenting stale UI.
    func isOriginalChoiceActive(generation: UInt64) -> Bool {
        guard let transaction = undoTransaction,
              transaction.generation == generation,
              now().timeIntervalSince(transaction.createdAt) <= EventTapManager.undoLifetime else {
            return false
        }
        return true
    }

    /// Marks the best-effort chip visible only if its transaction is still the
    /// current generation. Unsupported AX fields simply remain shortcut-only.
    @discardableResult
    func markOriginalChoiceChipVisible(generation: UInt64) -> Bool {
        guard isOriginalChoiceActive(generation: generation) else { return false }
        originalChoiceState = .chipVisible(generation: generation)
        return true
    }

    func originalChoiceChipDidExpire(generation: UInt64) {
        guard case .chipVisible(let activeGeneration) = originalChoiceState,
              activeGeneration == generation,
              undoTransaction?.generation == generation else {
            return
        }
        originalChoiceState = .shortcutOnly(generation: generation)
    }

    /// Cancels only the matching generation. A stale panel action must never
    /// destroy a newer correction transaction.
    func cancelOriginalChoice(generation: UInt64) {
        guard undoTransaction?.generation == generation else { return }
        clearUndoTransaction(notify: true)
    }

    /// Called after the UI layer has revalidated Secure Input, exact range text
    /// and panel generation. Focus/caret/time are checked again here before any
    /// synthetic deletion is emitted.
    @discardableResult
    func restoreOriginalChoice(generation: UInt64) -> Bool {
        undoLastCorrectionIfPossible(expectedGeneration: generation)
    }

    private func scheduleUndoExpiration(for generation: UInt64) {
        undoExpirationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.undoTransaction?.generation == generation else { return }
            self.clearUndoTransaction(notify: true)
        }
        undoExpirationWorkItem = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + EventTapManager.undoLifetime,
            execute: workItem
        )
    }

    private func clearUndoTransaction(notify: Bool) {
        let hadTransaction = undoTransaction != nil
        undoExpirationWorkItem?.cancel()
        undoExpirationWorkItem = nil
        undoTransaction = nil
        originalChoiceState = .none
        if notify && hadTransaction {
            onCorrectionUndone?()
        }
    }

    private func resetAutomaticCorrectionToken() {
        autoCorrectionEngine.reset()
        tokenCaptureState = .idle
        clearAutomaticCorrectionFocus()
    }

    private func invalidateAutomaticCorrectionTokenUntilBoundary() {
        autoCorrectionEngine.invalidateCurrentTokenUntilBoundary()
        tokenCaptureState = .discardUntilBoundary
        clearAutomaticCorrectionFocus()
    }

    private func clearAutomaticCorrectionFocus() {
        automaticCorrectionFieldAllowed = nil
        automaticCorrectionFocusToken = nil
    }

    private func resetAutomaticCorrectionState() {
        invalidatePendingBoundaryCorrection()
        resetAutomaticCorrectionToken()
        clearUndoTransaction(notify: true)
    }

    private func invalidatePendingBoundaryCorrection() {
        pendingCorrectionState = .none
        boundaryCorrectionGeneration &+= 1
    }

    private func resetTransientState() {
        tracker.reset()
        resetAutomaticCorrectionState()
        // 차단한 keyDown의 짝 keyUp 대기 목록도 함께 비운다. 남겨두면 앱 전환 뒤
        // 같은 keycode의 물리 keyUp이 handleKeyUp에서 삼켜지고(:663), 자동반복
        // keyDown도 차단된다(:440). stop()과 탭 재활성 콜백은 이미 두 호출을
        // 짝으로 하고 있었는데 앱 전환 경로(MackorApp의 resetComposition)만
        // 빠져 있었다.
        clearSuppressedKeyUps()
    }

    // MARK: - 결과 실행 (백스페이스 + 문자 전송)

    private func executeResult(_ result: CompositionResult) {
        if result.deleteCount == 0 && result.insertText.isEmpty { return }

        // 백스페이스 전송
        for _ in 0..<result.deleteCount {
            sendKeyEvent(keycode: EventTapManager.backspaceKeycode, shift: false)
            pause(3000)  // 3ms — 대상 앱이 처리할 시간
        }

        // 유니코드 문자 전송
        if !result.insertText.isEmpty {
            for char in result.insertText {
                sendUnicodeCharacter(char)
                pause(3000)
            }
        }
    }

    // MARK: - 키 이벤트 전송

    /// 일반 키 이벤트 전송 (백스페이스 등)
    private func sendKeyEvent(keycode: UInt16, shift: Bool) {
        keyboardOutput.sendKeyEvent(keycode: keycode, shift: shift)
    }

    /// 유니코드 문자를 직접 전송 (IME를 거치지 않음)
    private func sendUnicodeCharacter(_ char: Character) {
        sendUnicodeText(String(char))
    }

    /// 자동 교정 문자열은 이벤트 탭 timeout을 피하도록 한 이벤트로 보냅니다.
    private func sendUnicodeText(_ text: String) {
        keyboardOutput.sendUnicodeText(text)
    }

    static func tagAsInjected(_ event: CGEvent) {
        event.setIntegerValueField(userDataField, value: injectionMarker)
    }

    private static func isInjected(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(userDataField) == injectionMarker
    }

    private static func diagnostic(_ message: @autoclosure () -> String) {
        guard diagnosticsEnabled else { return }
        print("[Mackor][diagnostic] \(message())")
    }

    // MARK: - 권한 확인

    static func checkAccessibilityPermission(prompt: Bool = true) -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - C 콜백 (CGEventTap)

private func eventTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {

    // 시스템에 의해 tap이 비활성화된 경우 재활성화
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.resetComposition()
            manager.clearSuppressedKeyUps()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

    if type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown {
        manager.handleMouseDown(
            at: event.location,
            isPrimaryButton: type == .leftMouseDown
        )
        return Unmanaged.passUnretained(event)
    }

    if type == .keyUp {
        if let resultEvent = manager.handleKeyUp(event) {
            return Unmanaged.passUnretained(resultEvent)
        }
        return nil
    }

    guard type == .keyDown else {
        return Unmanaged.passUnretained(event)
    }

    if let resultEvent = manager.handleKeyDown(event) {
        return Unmanaged.passUnretained(resultEvent)
    } else {
        manager.noteSuppressedKeyDown(event)
        return nil  // 이벤트 차단
    }
}
