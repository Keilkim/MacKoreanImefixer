import Foundation
import CoreGraphics
import Carbon.HIToolbox

protocol EventTapKeyboardOutputting {
    func sendKeyEvent(keycode: UInt16, shift: Bool)
    func sendUnicodeText(_ text: String)
}

protocol EventTapFocusInspecting {
    /// 조회 실패와 확정 거부를 구분해 돌려줍니다.
    func probeAutomaticCorrectionFocus() -> FocusedInputSafety.FocusProbe
    /// 캡처한 토큰 시작점, 현재 캐럿, 원문 문자열이 모두 일치할 때만
    /// 해당 시작점에 앵커링된 토큰을 돌려줍니다.
    func anchoredOriginalFocusToken(
        _ token: FocusedInputSafety.FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> FocusedInputSafety.FocusToken?
    /// 캡처 앵커를 쓰지 않고, 현재 포커스된 같은 입력란의 캐럿
    /// 바로 앞 글자가 원문과 같은지 확인한 뒤 원문 시작점으로
    /// 다시 앵커링한 포커스 토큰을 돌려줍니다.
    func reanchoredFocusToken(
        _ token: FocusedInputSafety.FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> FocusedInputSafety.FocusToken?
    /// 화면에 실제로 찍힌 글자로 판단한 방향. 못 읽으면 nil.
    func scriptBeforeCaret(
        _ token: FocusedInputSafety.FocusToken,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> CorrectionDirection?
}

private struct AccessibilityEventTapFocusInspector: EventTapFocusInspecting {
    func probeAutomaticCorrectionFocus() -> FocusedInputSafety.FocusProbe {
        FocusedInputSafety.probeAutomaticCorrectionFocus()
    }

    func anchoredOriginalFocusToken(
        _ token: FocusedInputSafety.FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> FocusedInputSafety.FocusToken? {
        FocusedInputSafety.anchoredOriginalFocusToken(
            token,
            original: original,
            boundaryUTF16Count: boundaryUTF16Count,
            shouldContinue: shouldContinue
        )
    }

    func reanchoredFocusToken(
        _ token: FocusedInputSafety.FocusToken,
        original: String,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> FocusedInputSafety.FocusToken? {
        FocusedInputSafety.reanchoredFocusToken(
            token,
            original: original,
            boundaryUTF16Count: boundaryUTF16Count,
            shouldContinue: shouldContinue
        )
    }

    func scriptBeforeCaret(
        _ token: FocusedInputSafety.FocusToken,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> CorrectionDirection? {
        FocusedInputSafety.scriptBeforeCaret(
            token,
            boundaryUTF16Count: boundaryUTF16Count,
            shouldContinue: shouldContinue
        )
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

    /// Layer 1 어휘 판정기. 자산이 없으면 `nil`이고, 그때는 이 계층 없이
    /// 오늘과 동일하게 동작합니다.
    private let lexicalTiebreaker: LexicalTiebreaker?
    /// LexicalGuard의 영어 증거 투영. nil이면 순수 자음 게이트는 fail-closed.
    private let guardEvidence: Set<String>?
    /// 단음절 관문 자산. nil이면 단음절 교정이 **전부** 사라집니다(fail-closed).
    private let monosyllableLexicon: MonosyllableLexicon?

    /// 현재 토큰의 키열 사본.
    ///
    /// 엔진은 보존 판정 시 `nil`만 돌려주고 키열을 즉시 폐기하므로(설계상
    /// 의도), 어휘 계층이 볼 후보가 남지 않습니다. 엔진은 동결 대상이라
    /// 노출 표면을 추가할 수 없어 여기서 사본을 둡니다.
    ///
    /// 사본은 발산할 수 있습니다 — 엔진에는 입력 소스 변경·유휴 시간 초과처럼
    /// 밖에서 관측할 수 없는 내부 리셋이 있습니다. 그래서 사본을 **신뢰하지 않고**
    /// 사용 직전에 엔진의 진단과 대조해 검증합니다(`lexicalCandidate`).
    /// 어긋나면 아무것도 하지 않으므로, 발산은 기회를 놓칠 뿐 오교정을 만들지
    /// 못합니다.
    private var lexicalKeystrokeMirror: [PhysicalKeystroke] = []

    /// 현재 수집 중인 토큰 안에서 어퍼스트로피가 나온 위치(그 앞의 자모 키 수).
    /// `nil`이면 어퍼스트로피 없는 보통 토큰입니다. 어퍼스트로피는 **판정이 아니라
    /// 투명한 구분자**로, 이 값이 있으면 경계에서 양쪽 키열을 합쳐 동결 정책에
    /// 맡기고 결과에 `'`를 다시 끼웁니다. 모든 리셋이 지나는
    /// `clearAutomaticCorrectionFocus`에서 비워져 토큰 경계를 넘어 새지 않습니다.
    private var apostropheBreakStrokeCount: Int?

    private var _isActive: Bool = false
    private var _isAutoCorrectionEnabled: Bool = false
    private var automaticCorrectionFieldAllowed: Bool?
    /// 현재 필드가 "AX엔 텍스트 없음 + 사용자 blind opt-in"이라 검증 없이 교정할
    /// 대상인가. `.ineligibleUnsupportedRole`과 `.unavailable` 프로브에서 켜집니다
    /// — 둘 다 보안 필드가 아님이 보장되는 케이스입니다(보안 필드는 프로브 첫
    /// 줄에서 `.ineligible`로 빠지고, 이 둘은 그 뒤에만 옵니다).
    ///
    /// 끄는 곳은 두 군데입니다: `.ineligible`(확정 거부 — 같은 토큰 안에서 뒤늦게
    /// 보호 필드로 판명된 경우)과 `clearAutomaticCorrectionFocus`(토큰 경계).
    /// 이 값이 켜져 있으면 AX 미지원이어도 기록을 이어가고 경계에서 blind 교정합니다.
    private var blindFieldActive = false
    /// applyCorrection 체인이 blind 교정을 실행 중인 동안만 true. finalizeCorrection이
    /// 이 값으로 UndoTransaction.blind를 세웁니다(동기 체인이라 안전).
    private var applyingBlindCorrection = false
    private var automaticCorrectionFocusToken: FocusedInputSafety.FocusToken?
    /// 이 토큰에서 일시적 거부(선택 영역·AX 소진)로 확정을 미룬 키 수.
    /// 상한에 닿으면 확정 거부로 굳힙니다. 기록은 절대 막지 않고 조회/래치만
    /// 제어합니다. 모든 리셋이 지나는 clearAutomaticCorrectionFocus에서 0으로
    /// 되돌리므로 토큰 경계를 넘어 새지 않습니다.
    private var softProbeRefusalKeys = 0
    /// "포커스가 텍스트 역할이 아니다"를 연속으로 본 횟수. 다른 결과가 한 번이라도
    /// 나오면 0으로 되돌아갑니다.
    private var unsupportedRoleObservations = 0
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
    private let monotonicNow: () -> TimeInterval
    private let pause: (useconds_t) -> Void
    private let scheduleBoundaryCorrection: (@escaping () -> Void) -> Void
    private var boundaryCorrectionGeneration: UInt64 = 0
    private var originalChoiceGeneration: UInt64 = 0

    var onOriginalChoiceAvailable: ((OriginalChoiceRequest) -> Void)?
    var originalChoiceHitTest: ((CGPoint, UInt64) -> Bool)?
    var onCorrectionUndone: (() -> Void)?
    var onInputSourceSwitch: ((CorrectionDirection) -> InputSourceSwitchReceipt?)?
    var onInputSourceRestore: ((InputSourceSwitchReceipt) -> Bool)?
    var onInputSourceKindRefresh: (() -> InputSourceKind)?
    /// 현재 앱이 AX에 텍스트를 내놓지 않는다고 판단됐을 때 한 번 불립니다.
    /// 이 계층은 앱 목록·저장을 모르므로 학습은 호출부(UI 계층)가 합니다.
    var onAutoCorrectionUnsupported: (() -> Void)?

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
    /// 경계 keyDown 안에서 교정과 경계 재입력을 끝낼 때는 이벤트 탭을
    /// 오래 붙잡지 않도록 짧은 토큰으로 제한합니다. 삭제당 3ms 대기를
    /// 포함해 고정 대기는 최대 27ms입니다.
    private static let maximumSynchronousCorrectionCharacters = 8
    /// 자음 매시 어휘 구제의 최소 키 수. 3키 전부-다른-자음 구간은 `ace`·`cat`
    /// 같은 실단어와 `ㅁㅊㄷ`(미쳤다)류 실사용 초성체가 조밀하게 겹치므로
    /// 제외하고, 4키 이상에서만 되살립니다(en-guard 4+ 구제 대상 365개 전수
    /// 확인 결과 실사용 초성체 충돌 없음).
    private static let minimumConsonantMashKeystrokes = 4
    /// 어퍼스트로피(kVK_ANSI_Quote). 영어 축약형(it's·don't)을 한글 모드에서
    /// 치면 자모 사이에 이 키가 들어옵니다.
    private static let apostropheKeycode: UInt16 = 0x27
    /// 이벤트 탭 안에서 연속 AX 요청에 쓰는 soft 예산입니다. 이미 시작한 AX
    /// 요청은 끝까지 기다리지만, 만료 뒤 새 요청이나 삭제는 시작하지 않습니다.
    /// 일반 경계는 지연 경로로 돌아가고 제출 경계는 제출 키만 전달합니다.
    private static let synchronousAXTimeBudget: TimeInterval = 0.1
    /// 한 키 안에서 포커스 조회를 다시 시도할 최대 횟수. 실패한 조회가
    /// AX 연결을 데우므로 보통 2회째에 성공합니다.
    private static let maximumFocusProbeAttempts = 3
    /// 일시적 거부(선택 영역·AX 소진)를 확정 거부로 굳히기 전 허용하는 키 수.
    /// 2면 첫 키의 거부는 보존해 다음 키에서 재확인하고, 두 번째 키에서도
    /// 거부되면 그때 굳힙니다. 선택은 이 키가 곧 지우므로 대개 두 번째 키에서
    /// 빈 캐럿으로 바뀌어 교정됩니다.
    private static let maximumSoftProbeRefusalKeys = 2
    /// 같은 앱에서 "포커스가 텍스트 역할이 아니다"를 몇 번 연속으로 봐야 그 앱을
    /// 미지원으로 학습할지. 포커스 판정은 토큰당 한 번 굳으므로 **사실상 단어 수**입니다.
    ///
    /// 한 번으로는 안 됩니다 — 버튼이나 캔버스에 포커스가 가 있어도 같은 신호가
    /// 나옵니다. 그러나 AX에 텍스트를 아예 안 내놓는 앱에서는 치는 단어마다
    /// 빠짐없이 쌓입니다. 그 비대칭이 판별의 근거이고, 중간에 적격이 한 번이라도
    /// 나오면 카운터를 0으로 되돌려 오탐을 막습니다.
    ///
    /// 3인 이유: 사용자가 "켜져 있는데 안 된다"를 겪는 시간이 곧 이 숫자입니다.
    /// 실사용에서 네 단어를 치고도 목록이 그대로라 오해가 생겼습니다. 정상 앱이
    /// 버튼 포커스만으로 세 단어를 연속으로 채울 일은 없고, 혹 그래도 다음 적격
    /// 판정 한 번이면 `.supported`가 이 값을 덮어 즉시 복구됩니다.
    private static let unsupportedRoleObservationsToLearn = 3

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

    private enum ImmediateBoundaryDisposition {
        case passThrough
        /// 교정과 합성 경계를 이미 전달했으므로 물리 keyDown/keyUp을
        /// 모두 억제해야 합니다.
        case suppressPhysicalEvent
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
        /// blind 교정(AX 없는 앱)에서 만들어졌는가. blind는 focusToken이 합성이라
        /// AX 앵커 검증을 할 수 없으므로, ⌘Z 되돌리기에서 그 검증을 건너뜁니다
        /// (교정과 같은 커서-고정 안전 논리 — 다른 실제 키가 오면 트랜잭션이
        /// 먼저 폐기되므로 ⌘Z는 교정 직후에만 발동합니다).
        let blind: Bool
    }

    /// 한글 IME의 marked text는 공백/문장부호 keyDown을 대상 앱이 처리한
    /// 뒤에야 확정됩니다. exact text를 경계 전에 확인할 수 없는 Latin
    /// 교정도 같은 경로를 쓰므로, 이 경우는 대응 keyUp까지 보류합니다.
    private struct PendingBoundaryCorrection {
        let decision: CorrectionDecision
        let boundarySequence: BoundarySequence
        let focusToken: FocusedInputSafety.FocusToken
        /// blind(AX 없는 앱) 한→영 교정인가. blind면 keyUp 적용 시 AX 앵커 검증을
        /// 건너뜁니다 — 한글 IME 조합이 경계키로 확정된 뒤라 커서가 결과 뒤에
        /// 고정돼 있고, AX로 읽을 텍스트가 없기 때문입니다.
        var blind: Bool = false
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
        let validationDeadline: TimeInterval
    }

    private enum OriginalChoiceState {
        case none
        case chipVisible(generation: UInt64)
        case shortcutOnly
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

    /// 현재 앱에서 AX 없는 blind 교정을 사용자가 켰는지. AX가 텍스트를 안
    /// 내놓는 필드(`.ineligibleUnsupportedRole`)에서만, 그리고 자판자동이 켜진
    /// 상태에서만 발동을 허용합니다. 꺼지면 blind 필드 상태를 즉시 폐기합니다.
    var blindAutoCorrectionEnabled: Bool = false {
        didSet {
            if blindAutoCorrectionEnabled != oldValue {
                EventTapManager.diagnostic(
                    "blindAutoCorrectionEnabled=\(blindAutoCorrectionEnabled)"
                )
            }
            if !blindAutoCorrectionEnabled, oldValue {
                blindFieldActive = false
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
        // 사전은 앱 번들에서 읽습니다. 없으면 nil이고, 그때는 어휘 계층 없이
        // 규칙만으로 오늘과 동일하게 동작합니다.
        lexicalTiebreaker = LexicalTiebreaker(bundle: .main)
        // guard 증거가 없으면 순수 자음 게이트가 fail-closed(보존)로 돌아
        // 파괴적 오교정만 막히고 we/see류 교정을 놓칩니다 — 안전한 방향입니다.
        guardEvidence = LexicalGuard.loadEnglishEvidence(bundle: .main)
        // 안전 게이트(영어 사전·CLI·로케일·거부 원장)는 **생성 시점**에 이미
        // 적용돼 자산에 구워져 있습니다. 런타임은 조회 한 번입니다.
        monosyllableLexicon = MonosyllableLexicon(bundle: .main)
        if monosyllableLexicon == nil {
            // 미발동은 사용자 체감으로 "그냥 안 된다"와 구분되지 않으므로
            // 반드시 흔적을 남깁니다.
            EventTapManager.diagnostic("monosyllable lexicon missing — 단음절 교정 비활성")
        }
        keyboardOutput = QuartzKeyboardOutput()
        focusInspector = AccessibilityEventTapFocusInspector()
        now = Date.init
        monotonicNow = { ProcessInfo.processInfo.systemUptime }
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
        monotonicNow: @escaping () -> TimeInterval = {
            ProcessInfo.processInfo.systemUptime
        },
        pause: @escaping (useconds_t) -> Void,
        scheduleBoundaryCorrection: @escaping (@escaping () -> Void) -> Void = { $0() },
        lexicalTiebreaker: LexicalTiebreaker? = LexicalTiebreaker(bundle: .main),
        guardEvidence: Set<String>? = nil,
        monosyllableLexicon: MonosyllableLexicon? = nil
    ) {
        autoCorrectionEngine = WrongLayoutCorrectionEngine()
        self.lexicalTiebreaker = lexicalTiebreaker
        self.guardEvidence = guardEvidence
        self.monosyllableLexicon = monosyllableLexicon
        self.keyboardOutput = keyboardOutput
        self.focusInspector = focusInspector
        self.now = now
        self.monotonicNow = monotonicNow
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
        return CFMachPortIsValid(tap) && CGEvent.tapIsEnabled(tap: tap)
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
        // 앱이 막 뜬 직후의 첫 AX 읽기는 낡은 캐럿 위치를 돌려줄 수 있습니다.
        // 실제 입력이 오기 전에 미리 한 번 버리는 읽기로 캐시를 갱신합니다.
        FocusedInputSafety.warmFocusCache()
        print("[Mackor] Event tap 시작됨.")
        return true
    }

    func stop() {
        // 정리 순서가 중요합니다. 무효화된(권한 회수된) 포트가 런루프에 소스로
        // 남아 있으면 헤드 삽입 세션 탭이 시스템 입력 경로를 계속 막을 수 있습니다.
        // tapEnable(false) → 소스 무효화·제거 → 포트 무효화 → nil 순으로 완전히
        // 떼어냅니다. 죽은 포트에도 CFMachPortInvalidate는 안전하게 동작합니다.
        if let tap = eventTap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopSourceInvalidate(source)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        eventTap = nil
        runLoopSource = nil
        resetTransientState()
        print("[Mackor] Event tap 중지됨.")
    }

    /// 시스템이 탭을 비활성화했을 때(`tapDisabledByTimeout`/`tapDisabledByUserInput`)
    /// 콜백에서 호출합니다.
    ///
    /// 포트가 아직 살아 있으면 일시적 비활성화이므로 재활성화합니다. 포트가
    /// 무효화됐다면(손쉬운 사용 권한 회수 등) 재활성화는 죽은 포트로의 헛된 CGS
    /// 왕복일 뿐이고, 무효화된 탭을 런루프에 남겨 시스템 입력을 막을 수 있으므로
    /// 즉시 정리합니다. 정리 뒤에는 `MackorApp.startTapWatchdog()`의 주기 감시가
    /// 권한을 확인해 새 탭을 만들어 복구합니다.
    ///
    /// 단, 시스템이 이 콜백을 **보내주지 않는** 경우(권한 회수로 포트가 그냥 죽는
    /// 경우)가 있으므로 이 경로만으로는 감지가 보장되지 않습니다. 그래서 주기
    /// 감시가 별도로 필요합니다.
    func handleSystemTapDisabled() {
        resetComposition()
        guard let tap = eventTap else { return }
        if CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
        } else {
            // 이 콜백은 탭 자신의 런루프 소스가 서비스하는 중이므로, 여기서 곧바로
            // 그 소스를 무효화·제거하면 재진입이 된다. 정리는 다음 런루프 턴으로
            // 미뤄 현재 콜백이 완전히 반환된 뒤 안전하게 수행한다.
            print("[Mackor] 탭 포트가 무효화되어 정리합니다(권한 회수 등).")
            DispatchQueue.main.async { [weak self] in
                self?.stop()
            }
        }
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

        // 클릭으로 포커스/캐럿이 옮겨간 뒤, 첫 키가 오기 전에 그 앱의 AX 연결을
        // 미리 데웁니다. Chromium/Electron은 콜드 첫 조회가 최대 57ms라 첫 단어가
        // 콜드 트리에 걸립니다. 예열은 pid 단위 연결을 데우는 것이라 정확한
        // 자식 요소를 안 읽어도 이후 프로브가 빨라집니다. 옵저버가 놓치는
        // 같은-요소 캐럿 이동 클릭까지 마우스 기반 전이를 전부 커버합니다.
        // warmFocusCache는 탭 콜백 밖에서 호출해야 하므로 async입니다
        // (handleSystemTapDisabled·scheduleBoundaryCorrection과 동일 패턴).
        DispatchQueue.main.async { FocusedInputSafety.warmFocusCache() }
    }

    /// 앱 전환이나 이벤트 탭 복구 뒤에는 화면의 마지막 글자를 더 이상
    /// 안전하게 교체할 수 없으므로 진행 중인 조합만 확정 상태로 돌린다.
    func resetComposition() {
        resetTransientState()
    }

    func handleKeyDown(_ event: CGEvent) -> CGEvent? {
        // 우리가 주입한 이벤트면 통과
        if EventTapManager.isInjected(event) {
            return event
        }

        // TIS 알림보다 다음 keyDown이 먼저 올 수 있으므로 캐시만 믿지 않습니다.
        // 소스 전환 직후 첫 글자를 이전 자판으로 조합하는 race를 막습니다.
        if let currentKind = onInputSourceKindRefresh?(),
           currentKind != inputSourceKind {
            inputSourceKind = currentKind
        }

        // 두 기능이 모두 비활성 상태면 통과
        guard isActive || isAutoCorrectionEnabled else { return event }

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
            let disposition = processImmediateBoundary(
                boundary,
                stroke: boundaryStroke
            )
            commitCompositionIfNeeded()
            switch disposition {
            case .passThrough:
                return event
            case .suppressPhysicalEvent:
                return nil
            }
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

            // 어퍼스트로피는 화면에만 찍히고 엔진·미러에는 들어가지 않습니다
            // (아래 어퍼스트로피 분기는 apostropheBreakStrokeCount만 기록하고
            // 이벤트를 통과시킵니다). 그래서 이 백스페이스가 실제로 지우는 문자는
            // `'`인데, 아래 `.collecting` 분기는 엔진의 자모 스트로크를 pop합니다.
            // 그대로 두면 apostropheCorrection이 화면에 없는 `'`를 끼운 original을
            // 만들어 originalCharacterCount가 화면 글자 수와 어긋납니다 — 삭제 수가
            // 어긋나면 텍스트가 깨집니다. 위 trailing-period 처리와 같은 방침으로
            // 교정 기회만 포기하고 엔진은 건드리지 않습니다.
            if isAutoCorrectionEnabled, apostropheBreakStrokeCount != nil {
                invalidateAutomaticCorrectionTokenUntilBoundary()
                return event
            }

            // 기록 게이트(아래 `!= false`)와 짝을 맞춥니다. 미해결(nil) 창에서도
            // 정방향 키는 엔진에 기록되므로, 백스페이스도 nil에서 엔진을 줄여야
            // 엔진 버퍼가 화면을 정확히 미러합니다. == true로 두면 nil 창의
            // 백스페이스가 화면만 지우고 엔진은 안 줄어 decision.original이
            // 부풀고, reanchored가 인접 확정 텍스트까지 되짚어 파괴할 수 있습니다.
            if isAutoCorrectionEnabled,
               automaticCorrectionFieldAllowed != false || blindFieldActive {
                switch tokenCaptureState {
                case .collecting(let letterStrokeCount):
                    autoCorrectionEngine.processBackspace()
                    if !lexicalKeystrokeMirror.isEmpty {
                        lexicalKeystrokeMirror.removeLast()
                    }
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
            // 어퍼스트로피는 토큰을 죽이지 않고 **투명한 구분자**로 남깁니다.
            //
            // 영어 축약형(it's·don't·we're)은 한글 모드에서 자모+`'`+자모로
            // 찍히는데, 지금까지는 `'`가 비자모라 아래 폐기 경로로 빠져 교정
            // 기회조차 없었습니다. 그렇다고 `'`를 "영어" 신호로 쓰면 안 됩니다 —
            // 한국어 닫는 따옴표+조사(`배고프다'라고`·`세상'이라는`)를 전부
            // 파괴합니다(내부 공백으로 쪼개져 `'` 하나짜리라 "하나만" 조건으로도
            // 못 막습니다). 그래서 `'`는 판정하지 않고, 양쪽 키열을 **합쳐 동결
            // 정책에** 넘겨 정책이 확인하게 합니다(경계의 `apostropheCorrection`).
            // `배고프다라고`는 정책이 modernKorean으로 보존하고 `its`는
            // englishStructure로 교정합니다 — 실측 한국어 오탐 0.0016%.
            //
            // 가드: 자동 교정 켜짐 · 한글자판 방향(영자판은 이미 영어라 불필요하고
            // `didn't`→야웃 오교정이 측정됨) · Shift 없음(Shift+`'`는 큰따옴표) ·
            // Caps 없음 · 수집 중이고 앞에 자모 ≥1 · 이 토큰에 `'`가 아직 없음
            // (둘째 `'`는 재구성을 복잡하게 하고 `'아니'라고`를 제외).
            if isAutoCorrectionEnabled,
               keycode == EventTapManager.apostropheKeycode,
               !shiftPressed,
               !capsLockPressed,
               inputSourceKind == .koreanTwoSet,
               apostropheBreakStrokeCount == nil,
               case .collecting(let letterStrokeCount) = tokenCaptureState,
               letterStrokeCount >= 1 {
                // 실제 IME도 비자모 키에서 조합을 확정하므로 표시 조합만 커밋하고,
                // 토큰(엔진 버퍼·수집 상태)은 그대로 살려 오른쪽 자모를 이어 받습니다.
                apostropheBreakStrokeCount = letterStrokeCount
                commitCompositionIfNeeded()
                return event
            }
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
                // 조회가 *실패*한 것과 이 필드가 *교정 대상이 아닌* 것은 다릅니다.
                //
                // 실측: Chrome의 차가운 첫 조회는 약 57ms 걸립니다. 상한이 50ms이던
                // 시절 이 조회는 잘려 *실패*로 돌아왔고(지금은 100ms —
                // `FocusedInputSafety.messagingTimeout`), 그 타임아웃을 "교정 금지"로
                // 확정해 버리면 Chrome에서는 자동 교정이 영영 걸리지 않았습니다.
                // 상한을 올린 뒤에도 더 느린 앱은 여전히 실패할 수 있으므로 이
                // 구분(실패 ≠ 거부)은 그대로 유지합니다.
                //
                // 실패한 조회 자체가 AX 연결을 데우므로 예산 안에서는 곧바로
                // 재시도합니다. 예산을 넘기면 키열만 보존하고 다음 글자에서
                // 새 횟수로 다시 확인합니다. 이렇게 해야 첫 글자를 잃지 않으면서도
                // 멈춘 앱의 AX IPC가 한 keyDown을 오래 붙잡지 않습니다.
                //
                // 시도 횟수는 **이 키 안에서만** 셉니다. 토큰 단위로 누적하면
                // 차가운 앱에서 첫 두세 키가 횟수를 다 써 버리고, 그 시점부터
                // 아래 `!= false` 게이트가 그 단어의 나머지 키를 통째로 버립니다
                // — 단어 하나가 통째로 교정 후보에서 사라집니다. 실제로 그랬고
                // (`4bb0dbb`가 지역 변수를 인스턴스 변수로 바꾸며 생긴 회귀),
                // 아래 두 회귀 테스트가 이걸 고정합니다.
                let focusProbeDeadline = monotonicNow()
                    + EventTapManager.synchronousAXTimeBudget
                var probe = focusInspector.probeAutomaticCorrectionFocus()
                var probeAttempts = 1
                while case .unavailable = probe,
                      probeAttempts
                        < EventTapManager.maximumFocusProbeAttempts,
                      monotonicNow() < focusProbeDeadline {
                    // 실패한 조회 자체가 AX 연결을 데우므로 다음 시도는
                    // 데워진 경로(실측 중앙값 0.4ms)로 곧장 돌아옵니다.
                    probe = focusInspector.probeAutomaticCorrectionFocus()
                    probeAttempts += 1
                }
                switch probe {
                case .eligible(let token):
                    // flag=true와 token 캡처는 오직 여기서만 함께 일어납니다.
                    // 어떤 토큰도 진짜 .eligible 프로브 없이는 파괴 경로(경계
                    // 게이트 flag==true && token!=nil)에 닿을 수 없습니다.
                    automaticCorrectionFocusToken = token
                    automaticCorrectionFieldAllowed = true
                    // 텍스트 역할을 실제로 봤으므로 미지원 근거가 끊깁니다.
                    unsupportedRoleObservations = 0
                case .ineligible:
                    // 보안 입력·보호 subrole·보호 메타데이터 — 확정 거부.
                    // 즉시 래치, 재확인 없음(기존과 동일).
                    //
                    // 이건 **필드 단위** 거부이므로 앱 학습에 쓰지 않습니다.
                    // 쓰면 Safari가 비밀번호 칸 하나 때문에 미지원이 됩니다.
                    automaticCorrectionFocusToken = nil
                    automaticCorrectionFieldAllowed = false
                    unsupportedRoleObservations = 0
                    // 같은 토큰의 앞선 키가 .unavailable/.ineligibleUnsupportedRole로
                    // blind를 켰을 수 있습니다. 확정 거부가 나온 이상 그 상태를 반드시
                    // 취소합니다 — 안 그러면 아래 기록 게이트(`|| blindFieldActive`)와
                    // 경계 blind 분기가 살아남아, 프로브가 방금 "보호 필드"라고 거부한
                    // 입력란에서 AX 검증 없는 삭제+재입력이 일어납니다.
                    blindFieldActive = false

                case .ineligibleUnsupportedRole:
                    // 판정은 위와 같습니다(확정 거부). 다른 것은 이 신호가 앱이
                    // AX에 텍스트를 안 내놓는다는 뜻일 수 있다는 점뿐입니다.
                    // 같은 앱에서 연속으로 쌓일 때만 미지원으로 학습합니다.
                    automaticCorrectionFocusToken = nil
                    automaticCorrectionFieldAllowed = false
                    noteUnsupportedRoleObservation()
                    // 사용자가 이 앱에 blind 교정을 켰다면, AX 미지원이 곧
                    // "검증 없이 교정할 대상"이라는 신호입니다. 기록을 이어가고
                    // (아래 게이트의 `|| blindFieldActive`) 경계에서 blind
                    // 교정합니다. 이 케이스는 보안 필드가 아님이 보장됩니다.
                    if blindAutoCorrectionEnabled {
                        blindFieldActive = true
                    }
                case .ineligibleTransientSelection:
                    // 선택 영역은 이 키가 곧 지울 직전 상태의 증거일 뿐입니다.
                    // 즉시 굳히지 않고 플래그를 nil로 두어 키열은 계속 기록하고
                    // (게이트 아래 `!= false`가 nil에도 기록) 다음 키에서 다시
                    // 확인합니다. 선택은 이 키 안에서 확정적이므로 in-key 재시도는
                    // 하지 않습니다(위 루프는 .unavailable에만 회전). 상한 키 수까지
                    // 계속 선택돼 있으면 그때 확정 거부로 굳힙니다.
                    automaticCorrectionFocusToken = nil
                    softProbeRefusalKeys += 1
                    if softProbeRefusalKeys
                        >= EventTapManager.maximumSoftProbeRefusalKeys {
                        automaticCorrectionFieldAllowed = false
                    }
                case .unavailable:
                    automaticCorrectionFocusToken = nil
                    // blind opt-in 앱은 AX 실패 **이유**를 가리지 않습니다. 한컴처럼
                    // AX가 무거운 앱은 100ms 예산 안에서 프로브가 토큰마다
                    // .unavailable(느림)과 .ineligibleUnsupportedRole(역할없음)을
                    // 오갑니다. .unsupportedRole에서만 blind를 켜면 교정이 간헐적으로
                    // 빠집니다. .unavailable도 즉시 blind로 처리합니다 — 이 케이스는
                    // 보안 필드가 아님이 보장됩니다(secure는 프로브 첫 줄에서
                    // .ineligible로 빠지고, 여기는 그 뒤에만 옵니다).
                    if blindAutoCorrectionEnabled {
                        blindFieldActive = true
                    }
                    // 이 키 안에서 상한까지 다 물어봤는데도 안 되면 키열은 계속
                    // 보존하고 다음 키에서 다시 확인합니다. 실패한 조회가 AX를
                    // 데우므로 다음 키는 성공할 수 있습니다. 소진이 상한 키 수만큼
                    // 이어질 때만 확정 거부로 굳힙니다. 예산 때문에 횟수를 남긴 채
                    // 빠져나왔다면(else 없음) 소프트 카운터도 건드리지 않아 다음
                    // 키가 온전한 재시도 예산을 갖습니다. exact-text 검증 전에는
                    // 화면을 바꾸지 않습니다.
                    if probeAttempts
                        >= EventTapManager.maximumFocusProbeAttempts {
                        softProbeRefusalKeys += 1
                        if softProbeRefusalKeys
                            >= EventTapManager.maximumSoftProbeRefusalKeys {
                            automaticCorrectionFieldAllowed = false
                        }
                    }
                }
                if blindAutoCorrectionEnabled {
                    EventTapManager.diagnostic(
                        "blind probe fieldAllowed="
                            + "\(automaticCorrectionFieldAllowed.map(String.init) ?? "nil") "
                            + "blindFieldActive=\(blindFieldActive)"
                    )
                }
            }

            if !isAlreadyDiscarding,
               automaticCorrectionFieldAllowed != false || blindFieldActive {
                // false는 overflow/지원하지 않는 토큰으로 이번 후보가 폐기됐다는
                // 뜻입니다. AX 필드 안전성은 그대로이므로 직접 조합은 경계까지
                // 유지해 입력 방식이 단어 중간에 바뀌지 않게 합니다.
                // blindFieldActive면 AX가 false여도(미지원 role) 기록을 이어가
                // 경계에서 blind 교정 후보를 만듭니다.
                // 한 bool로는 Latin 대소문자(Caps XOR Shift)와 두벌식의 물리
                // Shift(ㅂ/ㅃ)를 동시에 표현할 수 없습니다. Caps가 섞인 토큰은
                // 잘못된 후보를 만들지 않도록 보수적으로 건너뜁니다.
                let capsLockIsAmbiguous = capsLockPressed
                if capsLockIsAmbiguous {
                    invalidateAutomaticCorrectionTokenUntilBoundary()
                } else {
                    let keystroke = PhysicalKeystroke(
                        keycode: keycode,
                        shift: shiftPressed
                    )
                    let wasRecorded = autoCorrectionEngine.record(
                        keystroke,
                        inputSource: inputSourceKind
                    )
                    // 엔진이 버퍼에 넣었을 때만 사본에도 넣습니다. 넣지 않았다면
                    // 엔진이 토큰을 리셋했거나 폐기한 것이므로 사본도 비웁니다.
                    // 보수적으로 비우는 쪽이 안전합니다 — 사본이 비면 아래 검증에서
                    // 길이가 어긋나 어휘 계층이 그냥 동작하지 않을 뿐입니다.
                    if wasRecorded {
                        lexicalKeystrokeMirror.append(keystroke)
                    } else {
                        lexicalKeystrokeMirror.removeAll(keepingCapacity: true)
                    }
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

    private func clearSuppressedKeyUps() {
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
        case (0x31, _):           // Space (Shift가 겹쳐도 같은 경계)
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

    /// Return/Enter/Tab인지 판별합니다. Shift+Return/Enter는 줄바꿈 경계로
    /// 처리하되 Shift+Tab은 역방향 포커스 이동이라 제외합니다.
    private func submitBoundaryStroke(
        for keycode: UInt16,
        shift: Bool
    ) -> BoundaryStroke? {
        switch keycode {
        case 0x24, 0x4C:  // Return, 숫자패드 Enter
            return BoundaryStroke(
                keycode: keycode,
                shift: shift,
                producedCharacterCount: 1,
                producedUTF16Count: 1
            )
        case 0x30 where !shift:  // Tab
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
        let validationDeadline = monotonicNow()
            + EventTapManager.synchronousAXTimeBudget
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
        // 주소·URL 입력란은 **이 경계에서만** 교정하지 않습니다.
        //
        // `performSubmitCorrection`은 `defer`로 제출키를 무조건 주입하므로 교정
        // 직후 페이지가 넘어갑니다. 그러면 ⌘Z(6초)도 원문 칩도 되돌릴 대상이
        // 사라져 구조적으로 실패하고 오교정이 그대로 확정됩니다. 실측상 파괴는
        // 전부 2글자 medium 교정(`sk`→나, `go`→해, `gh`→호 …)이고,
        // Space·`,`·`?`·`!` 경계에서는 같은 교정이 나도 복구가 온전히 작동합니다.
        // 그래서 필드 전체가 아니라 되돌릴 수 없는 이 지점 하나만 닫습니다.
        //
        // `.trailingPeriods` 상태(`sk.`+Enter)도 이 게이트를 지납니다.
        if isAutoCorrectionEnabled,
           hasEligibleToken,
           automaticCorrectionFieldAllowed == true,
           focusToken?.allowsIrreversibleBoundary == true {
            // 제출 키 자체는 아직 앱에 도착하지 않았지만, 앞서 통과시킨
            // 후행 마침표는 화면에 있으므로 그 길이만큼 건너뛰어 토큰의
            // 마지막 글자를 방향 증거로 읽습니다.
            let precedingBoundaryUTF16Count = precedingBoundaryStrokes.reduce(0) {
                $0 + $1.producedUTF16Count
            }
            let readUptime = monotonicNow
            decision = resolveBoundary(
                .submit,
                boundaryUTF16Count: precedingBoundaryUTF16Count,
                shouldContinue: {
                    readUptime() <= validationDeadline
                }
            )
        } else {
            autoCorrectionEngine.reset()
            lexicalKeystrokeMirror.removeAll(keepingCapacity: true)
            decision = nil
        }
        tokenCaptureState = .idle
        clearAutomaticCorrectionFocus()

        guard let decision,
              let focusToken,
              decision.originalCharacterCount
                <= EventTapManager.maximumSynchronousCorrectionCharacters else {
            return nil
        }
        EventTapManager.diagnostic(
            "submit boundary direction=\(decision.direction) "
                + "originalUTF16=\(decision.original.utf16.count) "
                + "key=\(stroke.keycode)"
        )
        return PendingSubmitCorrection(
            decision: decision,
            precedingBoundaryStrokes: precedingBoundaryStrokes,
            submitStroke: stroke,
            focusToken: focusToken,
            validationDeadline: validationDeadline
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
        let readUptime = monotonicNow
        let shouldContinue = { readUptime() <= pending.validationDeadline }
        let correctionFocusToken: FocusedInputSafety.FocusToken
        guard shouldContinue() else {
            EventTapManager.diagnostic("submit direction check exceeded time budget")
            return
        }
        let anchoredToken = focusInspector.anchoredOriginalFocusToken(
            pending.focusToken,
            original: pending.decision.original,
            boundaryUTF16Count: precedingBoundaryUTF16Count,
            shouldContinue: shouldContinue
        )
        guard shouldContinue() else {
            EventTapManager.diagnostic("submit validation exceeded time budget")
            return
        }
        if let anchoredToken {
            correctionFocusToken = anchoredToken
        } else if let reanchoredToken = focusInspector.reanchoredFocusToken(
            pending.focusToken,
            original: pending.decision.original,
            boundaryUTF16Count: precedingBoundaryUTF16Count,
            shouldContinue: shouldContinue
        ) {
            // 토큰 시작 때 읽은 캐럿 앵커가 낡았더라도, 같은 입력란의
            // 현재 캐럿 앞 exact text가 원문과 같으면 안전하게 계속합니다.
            correctionFocusToken = reanchoredToken
        } else {
            EventTapManager.diagnostic(
                "submit focus mismatch expectedOffset=\(expectedOffset)"
            )
            return
        }
        guard shouldContinue() else {
            EventTapManager.diagnostic("submit reanchor exceeded time budget")
            return
        }

        applySubmitCorrection(pending, focusToken: correctionFocusToken)
    }

    private func applySubmitCorrection(
        _ pending: PendingSubmitCorrection,
        focusToken: FocusedInputSafety.FocusToken
    ) {
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

        // 제출 키는 호출자가 주입하므로 경계 배열에 포함해 Undo 산술을 맞춥니다.
        let boundarySequence = BoundarySequence(
            strokes: pending.precedingBoundaryStrokes + [pending.submitStroke]
        )
        finalizeCorrection(
            decision,
            boundarySequence: boundarySequence,
            focusToken: focusToken
        )
    }

    private func processImmediateBoundary(
        _ boundary: CorrectionBoundary,
        stroke: BoundaryStroke
    ) -> ImmediateBoundaryDisposition {
        let fastPathDeadline = monotonicNow()
            + EventTapManager.synchronousAXTimeBudget
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

        // blind 교정 — AX가 텍스트를 안 내놓는 앱에서 사용자가 opt-in한 경우.
        // 화면을 읽지 않고, 경계키 keyDown 순간(커서가 방금 친 단어 뒤에 고정)에
        // 검증 없이 지우고 다시 씁니다. 정상 AX가 잡히면(`== true`) 그 경로를
        // 우선하므로 여기 오지 않습니다.
        if isAutoCorrectionEnabled,
           hasEligibleToken,
           blindFieldActive,
           automaticCorrectionFieldAllowed != true {
            let precedingBoundaryUTF16Count = sequence.producedUTF16Count
                - stroke.producedUTF16Count
            let readUptime = monotonicNow
            let blindDecision = resolveBoundary(
                boundary,
                boundaryUTF16Count: precedingBoundaryUTF16Count,
                shouldContinue: { readUptime() <= fastPathDeadline }
            )
            tokenCaptureState = .idle
            clearAutomaticCorrectionFocus()
            guard let blindDecision else {
                EventTapManager.diagnostic("blind skip: 판정 없음")
                return .passThrough
            }
            let synthetic = FocusedInputSafety.FocusToken(syntheticSelectionLocation: 0)
            // 즉시 경로는 **영→한 + 단일 경계 + 8자 이하**만입니다. 화면이 라틴
            // 직접 글자라 조합이 없고, 경계키(스페이스 하나)는 아직 앱에 안 갔으니
            // 삼키고 즉시 지우고 다시 쓰면 됩니다. 8자 제한은 탭 콜백 안의 동기
            // 삭제가 시스템 타임아웃을 넘지 않게 하기 위함입니다. 그 외는 전부
            // 지연 경로로 보냅니다:
            //   · 한→영은 화면이 한글 IME 조합이라 경계키로 확정한 뒤 지워야 하고,
            //   · 다중 경계(후행 마침표)는 이미 화면에 있는 마침표까지 지워야 하며,
            //   · 긴 영→한(되는건가=11자)은 지연 경로가 탭 밖(비동기)에서 지워 길이
            //     제한 없이 처리합니다.
            if blindDecision.direction == .latinToKorean,
               sequence.strokes.count == 1,
               blindDecision.originalCharacterCount
                <= EventTapManager.maximumSynchronousCorrectionCharacters {
                EventTapManager.diagnostic(
                    "blind correction dir=latinToKorean "
                        + "len=\(blindDecision.originalCharacterCount) "
                        + FocusedInputSafety.diagnosticContext()
                )
                applyingBlindCorrection = true
                applyCorrection(
                    blindDecision,
                    boundarySequence: sequence,
                    focusToken: synthetic
                )
                applyingBlindCorrection = false
                return .suppressPhysicalEvent
            } else {
                EventTapManager.diagnostic(
                    "blind deferred dir=\(blindDecision.direction) "
                        + "strokes=\(sequence.strokes.count) "
                        + "len=\(blindDecision.originalCharacterCount)"
                )
                pendingCorrectionState = .awaitingTriggerKeyUp(
                    PendingBoundaryCorrection(
                        decision: blindDecision,
                        boundarySequence: sequence,
                        focusToken: synthetic,
                        blind: true
                    )
                )
                return .passThrough
            }
        }

        let focusToken = automaticCorrectionFocusToken
        let decision: CorrectionDecision?
        if isAutoCorrectionEnabled,
           hasEligibleToken,
           automaticCorrectionFieldAllowed == true,
           focusToken != nil {
            // 현재 keyDown은 아직 앱에 도착하지 않았습니다. 화면 문자를
            // 읽을 때는 이미 통과한 후행 마침표만 넘겨야 토큰 끝에 닿습니다.
            let precedingBoundaryUTF16Count = sequence.producedUTF16Count
                - stroke.producedUTF16Count
            let readUptime = monotonicNow
            decision = resolveBoundary(
                boundary,
                boundaryUTF16Count: precedingBoundaryUTF16Count,
                shouldContinue: {
                    readUptime() <= fastPathDeadline
                }
            )
        } else {
            // 실제 경계는 discard 상태도 끝냅니다.
            autoCorrectionEngine.reset()
            lexicalKeystrokeMirror.removeAll(keepingCapacity: true)
            decision = nil
        }
        tokenCaptureState = .idle
        clearAutomaticCorrectionFocus()

        guard let decision, let focusToken else { return .passThrough }
        if let correctionFocusToken = preBoundaryCorrectionFocusToken(
            decision,
            sequence: sequence,
            focusToken: focusToken,
            deadline: fastPathDeadline
        ) {
            EventTapManager.diagnostic(
                "pre-boundary direction=\(decision.direction) "
                    + "originalUTF16=\(decision.original.utf16.count) "
                    + "trigger=\(sequence.triggerKeycode)"
            )
            // 진단 출력까지 포함해 검증 예산을 다시 확인합니다. 이 guard를
            // 지난 뒤에만 첫 Backspace를 보내므로 테스트 대역이나 느린 로그
            // 출력이 있어도 만료 뒤 부분 교정은 시작하지 않습니다.
            if monotonicNow() <= fastPathDeadline {
                applyCorrection(
                    decision,
                    boundarySequence: sequence,
                    focusToken: correctionFocusToken
                )
                return .suppressPhysicalEvent
            }
        }

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
        return .passThrough
    }

    /// 짧은 Latin 원문은 경계 keyDown이 앱에 도착하기 전에 고칠 수 있습니다.
    ///
    /// Latin 문자는 marked-text 확정을 기다릴 필요가 없고 현재 물리 경계가 아직
    /// 앱에 전달되지 않았으므로, 여기서 고치면 `Space down → 다음 글자 down →
    /// Space up` 키 롤오버와 keyUp 뒤 20ms 예약 경합이 모두 사라집니다. 반대로
    /// 한글 IME 출력, 이미 통과한 후행 마침표, 긴 토큰은 기존 keyUp 이후 경로를
    /// 유지합니다.
    ///
    /// 현재 포커스된 입력란이 캡처 시점과 같고, 캐럿 앞 exact text가
    /// 원문과 같을 때만 실행합니다. 초반의 낡은 캡처 캐럿 위치는 쓰지
    /// 않습니다. exact 확인을 할 수 없으면 지연 경로가 다시 검증합니다.
    private func preBoundaryCorrectionFocusToken(
        _ decision: CorrectionDecision,
        sequence: BoundarySequence,
        focusToken: FocusedInputSafety.FocusToken,
        deadline: TimeInterval
    ) -> FocusedInputSafety.FocusToken? {
        let isWithinLatencyLimit = decision.originalCharacterCount
            <= EventTapManager.maximumSynchronousCorrectionCharacters
        guard decision.direction == .latinToKorean,
              !shouldDirectlyComposeCurrentInput,
              sequence.strokes.count == 1,
              isWithinLatencyLimit else {
            return nil
        }
        let readUptime = monotonicNow
        let shouldContinue = { readUptime() <= deadline }
        guard shouldContinue() else { return nil }
        return focusInspector.reanchoredFocusToken(
            focusToken,
            original: decision.original,
            boundaryUTF16Count: 0,
            shouldContinue: shouldContinue
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

    /// 직접 조합은 자동 교정 범위와 무관하게 사용자가 명시적으로 등록한 문제
    /// 앱에서만 사용합니다. 그 밖의 앱은 macOS 네이티브 IME를 그대로 둡니다.
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
        // blind 한→영: AX가 없으니 앵커 검증을 건너뛰고 합성 토큰으로 바로
        // 진행합니다. 경계키가 이미 통과해 조합이 확정됐고 커서는 결과 뒤에
        // 고정돼 있습니다(교정과 같은 안전 논리). blind로 표시해 ⌘Z도 검증을
        // 건너뛰게 합니다.
        if pending.blind {
            pendingCorrectionState = .applying
            applyingBlindCorrection = true
            deleteBoundarySequence(pending.boundarySequence)
            applyCorrection(
                pending.decision,
                boundarySequence: pending.boundarySequence,
                focusToken: pending.focusToken
            )
            applyingBlindCorrection = false
            return true
        }

        let expectedOffset = pending.decision.original.utf16.count
            + pending.boundarySequence.producedUTF16Count
        let anchoredToken = focusInspector.anchoredOriginalFocusToken(
            pending.focusToken,
            original: pending.decision.original,
            boundaryUTF16Count: pending.boundarySequence.producedUTF16Count,
            shouldContinue: { true }
        )
        // 캡처 시점 앵커가 낡으면 위 산술은 어긋납니다(실측: 실제 캐럿 0인데
        // initial=32). 재시도해도 다시 읽는 건 현재 캐럿뿐이고 틀린 쪽은 앵커라
        // 영영 맞지 않습니다 — 사용자가 겪는 "되다가 안 되다가"의 원인입니다.
        //
        // 그래서 앵커를 쓰지 않는 직접 증거로 한 번 더 확인합니다. 지금 캐럿
        // 바로 앞의 실제 글자가 원문과 같으면 지울 대상이 정확히 그 자리에
        // 있다는 뜻이므로 안전합니다. 산술보다 강한 보장입니다.
        var reanchored = false
        let correctionFocusToken: FocusedInputSafety.FocusToken?
        if let anchoredToken {
            correctionFocusToken = anchoredToken
        } else if let reanchoredToken = focusInspector.reanchoredFocusToken(
                pending.focusToken,
                original: pending.decision.original,
                boundaryUTF16Count: pending.boundarySequence.producedUTF16Count,
                shouldContinue: { true }
        ) {
            correctionFocusToken = reanchoredToken
            reanchored = true
        } else {
            correctionFocusToken = nil
        }
        EventTapManager.diagnostic(
            "deferred focus match=\(correctionFocusToken != nil) "
                + "expectedOffset=\(expectedOffset) attempt=\(attempt)"
                + "\(reanchored ? " reanchored=true" : "") "
                + FocusedInputSafety.diagnosticContext()
        )
        guard let correctionFocusToken else {
            return false
        }

        pendingCorrectionState = .applying
        // 대상 앱이 이미 원문과 모든 경계 문자를 처리했으므로 경계를 역순으로
        // 지운 뒤 원문을 지우고 교정문을 넣습니다.
        deleteBoundarySequence(pending.boundarySequence)
        applyCorrection(
            pending.decision,
            boundarySequence: pending.boundarySequence,
            focusToken: correctionFocusToken
        )
        return true
    }

    /// 원문을 지우고 교정문을 넣습니다.
    ///
    /// 삭제 착지를 AX로 확인하는 게이트는 두지 않습니다. Mackor이 게시한
    /// 백스페이스와 교정문은 같은 큐로 순서대로 앱에 전달되므로, 정상적으로
    /// 삭제가 되는 앱에서는 지우고→타이핑 순서가 보장됩니다. 게이트는 백스페이스가
    /// 흡수되는 드문 경우(IME 마크드 텍스트)를 잡으려 했으나, 그 확인을 AX에
    /// 의존하는 바람에 AX가 느린/불완전한 앱(VS Code 등 Electron)에서 오히려
    /// 멀쩡한 교정을 죽여(단어 소실·연쇄) 순해악이었습니다. 제거합니다.
    private func applyCorrection(
        _ decision: CorrectionDecision,
        boundarySequence: BoundarySequence,
        focusToken: FocusedInputSafety.FocusToken
    ) {
        for _ in 0..<decision.originalCharacterCount {
            sendKeyEvent(keycode: EventTapManager.backspaceKeycode, shift: false)
            pause(3000)
        }
        emitReplacement(
            decision,
            boundarySequence: boundarySequence,
            focusToken: focusToken
        )
    }

    /// 삭제가 반영된 뒤의 방출 꼬리. 교정문 → 정착 대기 → 경계 재주입 → finalize.
    /// fast 경로는 백스페이스 직후 바로, 지연 경로는 게이트 통과 후 호출합니다.
    private func emitReplacement(
        _ decision: CorrectionDecision,
        boundarySequence: BoundarySequence,
        focusToken: FocusedInputSafety.FocusToken
    ) {
        sendUnicodeText(decision.replacement)
        pause(3000)
        reinjectBoundarySequence(boundarySequence)

        finalizeCorrection(
            decision,
            boundarySequence: boundarySequence,
            focusToken: focusToken
        )
    }

    /// 모든 교정 경로의 후처리를 한 곳에 모읍니다. 입력 소스 콜백이
    /// 동기로 상태를 리셋해도, 완료된 교정의 Undo 트랜잭션은 그 뒤에
    /// 등록하므로 유실되지 않습니다.
    private func finalizeCorrection(
        _ decision: CorrectionDecision,
        boundarySequence: BoundarySequence,
        focusToken: FocusedInputSafety.FocusToken
    ) {
        // 교정 뒤 입력 소스를 결과 언어로 전환합니다. blind(AX 없는 앱)도
        // 전환하는 이유: 한컴은 시스템 입력 소스를 따르므로(영→한·한→영 양방향
        // 실동작으로 확인) 전환하면 이후 입력이 결과 언어로 이어집니다 —
        // dkwn→아주 뒤 한글, ㅎㄱㄷㅁㅅ→great 뒤 영문. 전환을 안 하면 인디케이터가
        // 안 따라와 사용자가 한/영을 수동 관리해야 합니다.
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
            inputSourceSwitchReceipt: inputSourceSwitchReceipt,
            blind: applyingBlindCorrection
        )
        undoTransaction = transaction
        originalChoiceState = .shortcutOnly
        scheduleUndoExpiration(for: generation)
        // 제출 뒤에는 원문 칩의 화면 앵커를 잡을 수 없는 경우가 많습니다.
        // UI 계층이 정확한 범위를 다시 확인하고 실패하면 조용히 칩을 띄우지
        // 않으므로 일반 경계와 제출 경계를 같은 루틴으로 처리해도 안전합니다.
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

        guard let transaction = undoTransaction else { return false }

        // 물리 Cmd-Z는 event-tap keyDown 안에서 실행됩니다. 긴 결과를 여기서
        // 여러 번 지우면 시스템 timeout으로 전체 입력이 멎을 수 있으므로 앱의
        // 원래 Undo로 넘깁니다. generation이 있는 호출은 이미 UI 버튼에서 온
        // 것으로 event-tap callback 밖이므로 원문 칩 복원은 계속 지원합니다.
        guard expectedGeneration != nil
                || transaction.decision.replacementCharacterCount
                    <= EventTapManager.maximumSynchronousCorrectionCharacters else {
            clearUndoTransaction(notify: true)
            return false
        }

        guard now().timeIntervalSince(transaction.createdAt) <= EventTapManager.undoLifetime else {
            clearUndoTransaction(notify: true)
            return false
        }

        // blind 교정은 AX가 없어 앵커 검증을 할 수 없습니다. 교정과 같은 안전
        // 논리로 검증을 건너뜁니다 — 다른 실제 키가 오면 이 트랜잭션이 먼저
        // 폐기되므로(handleKeyDown의 clearUndoTransaction), ⌘Z는 교정 직후
        // 커서가 결과 바로 뒤에 있을 때에만 발동합니다.
        if !transaction.blind,
           focusInspector.anchoredOriginalFocusToken(
               transaction.focusToken,
               original: transaction.decision.replacement,
               boundaryUTF16Count: transaction.boundarySequence.producedUTF16Count,
               shouldContinue: { true }
           ) == nil {
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
              let transaction = undoTransaction,
              transaction.generation == generation else {
            return
        }
        if transaction.decision.replacementCharacterCount
            <= EventTapManager.maximumSynchronousCorrectionCharacters {
            originalChoiceState = .shortcutOnly
        } else {
            // 긴 결과는 물리 Cmd-Z를 앱에 넘기므로 칩이 사라진 뒤에는
            // 복구 수단이 없습니다. 쓸 수 없는 트랜잭션을 남기지 않습니다.
            clearUndoTransaction(notify: false)
        }
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
        lexicalKeystrokeMirror.removeAll(keepingCapacity: true)
        tokenCaptureState = .idle
        clearAutomaticCorrectionFocus()
    }

    /// 경계에서 규칙 엔진에 판정을 맡기고, 규칙이 가르지 못했을 때만
    /// 어휘 계층(Layer 1)에 한 번 더 묻습니다.
    ///
    /// 규칙이 이미 교정하거나 다른 이유로 보존한 토큰은 건드리지 않습니다.
    /// 오직 `ambiguousBothValid` — 한국어·영어 두 문법을 모두 만족해 키열만으로는
    /// 구분할 수 없던 경우 — 만 대상입니다.
    private func resolveBoundary(
        _ boundary: CorrectionBoundary,
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> CorrectionDecision? {
        let keystrokes = lexicalKeystrokeMirror
        // `processBoundary`는 내부에서 `defer { reset() }`으로 토큰을 비웁니다.
        // 사본도 같이 비우지 않으면 경계를 넘길 때마다 계속 쌓여, 길이 대조가
        // 항상 어긋나고 이 아래의 방향 수정·어휘 판정이 영영 발동하지 못합니다.
        // 실제로 그 상태였습니다 — 진단의 token length가 문장 전체로 자랐습니다.
        lexicalKeystrokeMirror.removeAll(keepingCapacity: true)
        // 호출자가 곧 `clearAutomaticCorrectionFocus`로 비우므로 여기서 잡아 둡니다.
        let apostropheBreak = apostropheBreakStrokeCount

        // 어느 경로에서 나온 결정이든 마지막에 어휘 거부권·강화(LexicalGuard)를
        // 한 번 거칩니다. 세 경로(엔진·어휘·방향 재판정)가 전부 이 출구를
        // 지나므로, 일반 경로와 방향 재판정 경로가 같은 최종 resolver를 씁니다.
        // 거부되면 보존과 동일하게 nil — 파괴적 오교정(`ㅁㅊ`→ac, `dns`→운)이
        // 여기서 멈춥니다.
        func guarded(_ decision: CorrectionDecision) -> CorrectionDecision? {
            guard let resolved = LexicalGuard.apply(
                decision,
                englishEvidence: guardEvidence,
                monosyllables: monosyllableLexicon
            ) else {
                EventTapManager.diagnostic(
                    "lexical veto direction=\(decision.direction) "
                        + "rule=\(decision.rule) len=\(decision.originalCharacterCount) "
                        + FocusedInputSafety.diagnosticContext()
                )
                return nil
            }
            if resolved != decision {
                EventTapManager.diagnostic(
                    "lexical guard retier direction=\(decision.direction) "
                        + "rule=\(decision.rule) \(decision.tier)->\(resolved.tier) "
                        + "len=\(decision.originalCharacterCount)"
                )
            }
            return resolved
        }

        // 어퍼스트로피 토큰: `'`를 판정으로 쓰지 않고, 합친 키열을 동결 정책에
        // 맡겨 "영어로 읽어보고 확인"합니다. 정책이 교정이면 `'`를 다시 끼워
        // emit하고, 아니면 보존합니다(조사·따옴표가 여기서 안전하게 걸러집니다).
        // 엔진 버퍼는 `processBoundary`를 우회하므로 여기서 직접 비웁니다.
        if let apostropheBreak {
            autoCorrectionEngine.reset()
            if let decision = apostropheCorrection(
                keystrokes: keystrokes,
                breakIndex: apostropheBreak,
                boundary: boundary
            ) {
                return guarded(decision)
            }
            return nil
        }

        if let decision = autoCorrectionEngine.processBoundary(boundary) {
            return guarded(decision)
        }
        // 현재 TIS 방향에서 사전만으로 확정할 수 있으면 AX 조회 없이 끝냅니다.
        // 특히 짧은 첫 단어가 cold AX 비용 때문에 지연 경로로 밀리는 일을 줄입니다.
        if let decision = lexicalDecision(boundary: boundary, keystrokes: keystrokes) {
            return guarded(decision)
        }

        // 2키 단음절은 엔진이 `weakKoreanStructure`로 보존합니다(R-K4: 단음절은
        // 3키 이상 요구). 그 하한은 무작위 충돌률 7.69%라는 구조적 근거로 세워진
        // 것이라 옳습니다 — 구조만으로는 `dk`(아)와 `sk`(SK)를 가를 수 없습니다.
        // 그래서 여기서 완화하는 것은 구조가 아니라 **증거**입니다: 해시로 동결된
        // 자산에 그 키열이 명시적으로 들어 있을 때만 교정합니다.
        //
        // AX 조회보다 앞에 두는 이유는 위 1789-1790행과 같습니다. 단음절은 정확히
        // 그 "짧은 첫 단어"의 극단이고, 아래 `directionCorrectedDecision`은 캐럿
        // 앞 글자를 읽으려 AX 왕복을 하므로 cold AX 비용을 치르면 지연 경로로 밀립니다.
        //
        // `guarded()`를 우회하지 않습니다. 여기서 만든 결정도 자산에서 왔으므로
        // 단음절 관문을 그대로 통과합니다 — 하나의 증거가 두 갈래를 동시에 살리고,
        // "모든 결정은 단일 출구를 지난다"는 보장(위 1766-1770행)이 깨지지 않습니다.
        if let decision = monosyllableDecision(boundary: boundary, keystrokes: keystrokes) {
            return guarded(decision)
        }

        // 한→영 자음 매시 구제. 구조 규칙은 서로 다른 자음 자모 나열(ㅁㄴㅇ류)을
        // 키보드 매시로 보고 보존하는데, 그중 `card`·`water`처럼 자음 자판
        // 글자만으로 적힌 실제 영어 단어가 함께 죽습니다. 단음절 구제와 같은
        // 원리로 완화하는 것은 구조가 아니라 **증거**입니다 — 결과가 동결
        // 사전에 실단어로 있을 때만, 그리고 `guarded()` 단일 출구를 그대로
        // 지나며 되살립니다.
        if let decision = consonantMashDecision(boundary: boundary, keystrokes: keystrokes) {
            return guarded(decision)
        }

        // 방향을 **믿음이 아니라 증거로** 다시 확인합니다.
        //
        // 엔진은 "지금 입력 소스가 무엇인가"로 방향을 정하는데, 그 믿음은
        // 어긋날 수 있습니다 — 시스템(TIS)은 한글이라는데 앱은 계속 라틴을
        // 찍는 경우가 실제로 있습니다. 그러면 영자판으로 친 `dkwn`을
        // 한글자판으로 친 것으로 오판해 `아주` 교정을 통째로 놓칩니다.
        //
        // 화면에 찍힌 글자는 증거입니다. 캐럿 앞 글자가 라틴인데 엔진이
        // 한글자판이라 믿었다면, 올바른 방향으로 동결 정책을 다시 돌립니다.
        if let decision = directionCorrectedDecision(
            boundary: boundary,
            keystrokes: keystrokes,
            boundaryUTF16Count: boundaryUTF16Count,
            shouldContinue: shouldContinue
        ) {
            return guarded(decision)
        }

        // 보존된 토큰도 반드시 흔적을 남깁니다.
        //
        // 지금까지 보존은 로그를 전혀 남기지 않았습니다. 그런데 사용자가
        // "안 된다"고 겪는 상황의 대부분이 바로 이 보존입니다. 그래서 교정
        // 시도만 세면 성공률이 좋아 보이는데 실제 체감은 정반대인, 지표와
        // 현실이 어긋나는 상태였습니다. 무엇이 왜 안 바뀌었는지가 보여야
        // 다음을 고칠 수 있습니다.
        EventTapManager.diagnostic(
            "preserved "
                + "rule=\(autoCorrectionEngine.lastDiagnostic.map { "\($0.rule)" } ?? "노판정") "
                + "len=\(autoCorrectionEngine.lastDiagnostic?.tokenLength ?? keystrokes.count) "
                + FocusedInputSafety.diagnosticContext()
        )
        return nil
    }

    /// 화면에 실제로 찍힌 글자로 방향을 확정하고, 엔진이 반대로 판정했다면
    /// 올바른 방향으로 동결 정책을 다시 돌립니다.
    ///
    /// 사본이 발산했을 수 있으므로 여기서도 길이를 대조합니다. 증거를 못 읽거나
    /// 엔진 판정과 방향이 같으면 아무것도 하지 않습니다.
    private func directionCorrectedDecision(
        boundary: CorrectionBoundary,
        keystrokes: [PhysicalKeystroke],
        boundaryUTF16Count: Int,
        shouldContinue: () -> Bool
    ) -> CorrectionDecision? {
        guard let diagnostic = autoCorrectionEngine.lastDiagnostic,
              diagnostic.boundary == boundary,
              diagnostic.tokenLength == keystrokes.count,
              !keystrokes.isEmpty,
              let focusToken = automaticCorrectionFocusToken,
              shouldContinue(),
              // 현재 경계 keyDown은 아직 앱에 도착하지 않았습니다. 다만
              // `token...period...Space` 흐름의 period처럼 이미 통과한 경계는
              // 그 길이만큼 넘겨야 토큰의 마지막 글자에 닿습니다.
              let observed = focusInspector.scriptBeforeCaret(
                focusToken,
                boundaryUTF16Count: boundaryUTF16Count,
                shouldContinue: shouldContinue
              ),
              observed != diagnostic.direction else {
            return nil
        }

        let source: InputSourceKind = observed == .latinToKorean
            ? .supportedLatin
            : .koreanTwoSet
        switch LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: source
        ) {
        case .correct(let tier, let original, let replacement, let rule):
            guard original != replacement else { return nil }
            EventTapManager.diagnostic(
                "direction corrected believed=\(diagnostic.direction) observed=\(observed) "
                    + "rule=\(rule) len=\(keystrokes.count) "
                    + FocusedInputSafety.diagnosticContext()
            )
            return CorrectionDecision(
                original: original,
                replacement: replacement,
                direction: observed,
                tier: tier,
                rule: rule,
                diagnostic: CorrectionDiagnostic(
                    direction: observed,
                    tier: tier,
                    rule: rule,
                    tokenLength: keystrokes.count,
                    boundary: boundary
                )
            )

        case .preserve(.ambiguousBothValid):
            // TIS와 화면 방향이 어긋난 경우에도 일반 경로와 같은 고정 어휘
            // tiebreaker를 거쳐야 합니다. 그렇지 않으면 `sork`처럼 규칙만으로
            // 양쪽이 가능한 첫 단어만 조용히 빠집니다.
            guard observed == .latinToKorean else { return nil }
            return lexicalCorrection(boundary: boundary, keystrokes: keystrokes)

        case .preserve(.weakKoreanStructure):
            // 단음절 구제도 같은 이유로 여기 대칭이 필요합니다. 없으면 TIS와
            // 화면이 어긋난 **첫 단어에서만** 단음절이 조용히 빠집니다.
            guard observed == .latinToKorean else { return nil }
            return monosyllableCorrection(boundary: boundary, keystrokes: keystrokes)

        case .preserve(.consonantJamoMash):
            // 자음 매시 구제도 대칭이 필요합니다. 이쪽은 화면에 한글(자모)이
            // 찍힌 한→영 방향이므로 관측 방향이 반대입니다.
            guard observed == .koreanToLatin else { return nil }
            return consonantMashCorrection(boundary: boundary, keystrokes: keystrokes)

        case .preserve:
            return nil
        }
    }

    /// 규칙이 보존한 토큰을 어휘로 다시 판정합니다.
    ///
    /// 키열 사본은 발산할 수 있으므로 **신뢰하지 않고 검증**합니다. 사본으로
    /// 동결된 정책을 다시 돌려, 엔진이 방금 낸 진단과 규칙·길이가 모두 일치할
    /// 때만 어휘를 조회합니다. 하나라도 어긋나면 사본이 실제 토큰이 아니라는
    /// 뜻이므로 아무것도 하지 않습니다 — 발산은 기회를 놓칠 뿐 오교정을
    /// 만들지 못합니다.
    private func lexicalDecision(
        boundary: CorrectionBoundary,
        keystrokes: [PhysicalKeystroke]
    ) -> CorrectionDecision? {
        guard let diagnostic = autoCorrectionEngine.lastDiagnostic,
              diagnostic.rule == .ambiguousBothValid,
              diagnostic.boundary == boundary,
              // 어휘 계층은 영자판으로 친 한국어에만 적용합니다. 한글자판 쪽은
              // 실측 결과 이 분기에 도달하는 토큰이 하나도 없습니다.
              diagnostic.direction == .latinToKorean,
              diagnostic.tokenLength == keystrokes.count,
              !keystrokes.isEmpty else {
            return nil
        }

        // 사본으로 동결 정책을 재실행해 같은 판정이 나오는지 확인합니다.
        guard case .preserve(.ambiguousBothValid) = LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: .supportedLatin
        ) else {
            return nil
        }

        return lexicalCorrection(boundary: boundary, keystrokes: keystrokes)
    }

    /// 이미 `ambiguousBothValid`임을 검증한 물리 키열에만 고정 어휘를 적용합니다.
    private func lexicalCorrection(
        boundary: CorrectionBoundary,
        keystrokes: [PhysicalKeystroke]
    ) -> CorrectionDecision? {
        guard let tiebreaker = lexicalTiebreaker,
              let latin = LayoutCorrectionPolicy.latinCandidate(for: keystrokes),
              let korean = tiebreaker.resolve(latin: latin),
              latin != korean else {
            return nil
        }

        EventTapManager.diagnostic(
            "lexical tiebreak direction=latinToKorean len=\(keystrokes.count)"
        )

        // tier는 medium입니다. 반대 읽기가 구조적으로 가능했다는 뜻이고,
        // 원문 칩을 강조 표시해 되돌리기 쉽게 만듭니다.
        return CorrectionDecision(
            original: latin,
            replacement: korean,
            direction: .latinToKorean,
            tier: .medium,
            rule: .ambiguousBothValid,
            diagnostic: CorrectionDiagnostic(
                direction: .latinToKorean,
                tier: .medium,
                rule: .ambiguousBothValid,
                tokenLength: keystrokes.count,
                boundary: boundary
            )
        )
    }

    /// 규칙이 R-K4로 판정을 포기한 단음절을 동결 자산으로 되살립니다.
    ///
    /// 키열 사본은 발산할 수 있으므로 **신뢰하지 않고 검증**합니다. 사본으로
    /// 동결 정책을 다시 돌려, 엔진이 방금 낸 진단과 규칙·경계·방향·길이가 모두
    /// 일치할 때만 자산을 조회합니다. 하나라도 어긋나면 사본이 실제 토큰이
    /// 아니라는 뜻이므로 아무것도 하지 않습니다 — 발산은 기회를 놓칠 뿐
    /// 오교정을 만들지 못합니다.
    ///
    /// 진단을 반드시 대조해야 하는 이유는 `WrongLayoutCorrectionEngine`이
    /// 폐기된 토큰에서는 `lastDiagnostic`을 갱신하지 않고 `nil`만 돌려주기
    /// 때문입니다 — 그때 `lastDiagnostic`은 **직전 토큰의 것**일 수 있습니다.
    private func monosyllableDecision(
        boundary: CorrectionBoundary,
        keystrokes: [PhysicalKeystroke]
    ) -> CorrectionDecision? {
        guard let diagnostic = autoCorrectionEngine.lastDiagnostic,
              diagnostic.rule == .weakKoreanStructure,
              diagnostic.boundary == boundary,
              diagnostic.direction == .latinToKorean,
              diagnostic.tokenLength == keystrokes.count,
              !keystrokes.isEmpty else {
            return nil
        }

        // 사본으로 동결 정책을 재실행해 같은 판정이 나오는지 확인합니다.
        // `inputSource`를 하드코딩하는 이유는 위에서 진단의 방향을 이미 확인했고,
        // 런타임 입력 소스는 그 사이 바뀌었을 수 있기 때문입니다.
        guard case .preserve(.weakKoreanStructure) = LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: .supportedLatin
        ) else {
            return nil
        }

        return monosyllableCorrection(boundary: boundary, keystrokes: keystrokes)
    }

    /// 이미 `weakKoreanStructure`임을 검증한 물리 키열에만 동결 자산을 적용합니다.
    private func monosyllableCorrection(
        boundary: CorrectionBoundary,
        keystrokes: [PhysicalKeystroke]
    ) -> CorrectionDecision? {
        guard let lexicon = monosyllableLexicon,
              // 원문은 반드시 정책의 함수로 얻습니다. 손으로 조립하면 shift 처리가
              // 어긋납니다.
              let latin = LayoutCorrectionPolicy.latinCandidate(for: keystrokes),
              let korean = lexicon.resolve(latin: latin),
              latin != korean,
              // 동결 조합기와 자산이 **같은 음절**을 가리킬 때만 진행합니다.
              // 출력은 여전히 자산에서만 오고 조합기는 대조용입니다. 둘이 어긋나면
              // (자산 오타·NFD 혼입·오토마톤 발산) 결과는 nil = 보존입니다.
              // 파괴가 일어나려면 해시로 동결된 자산과 pre-imk로 동결된 조합기가
              // **동시에** 틀려야 합니다.
              let composed = HangulStructure.evaluate(keystrokes),
              composed.jamoCount == 0,
              composed.syllableCount == 1,
              composed.text.precomposedStringWithCanonicalMapping == korean else {
            return nil
        }

        EventTapManager.diagnostic(
            "monosyllable rescue rule=weakKoreanStructure len=\(keystrokes.count) "
                + FocusedInputSafety.diagnosticContext()
        )

        // tier는 medium입니다. 2키는 규칙이 판정을 포기할 만큼 증거가 약한 칸이고
        // (R-K4 실측 무작위 충돌률 7.69%) 교정 근거가 전적으로 자산이라, 원문 칩을
        // Undo 창(6초) 내내 강조해 되돌리기를 쉽게 만듭니다.
        return CorrectionDecision(
            original: latin,
            replacement: korean,
            direction: .latinToKorean,
            tier: .medium,
            rule: .weakKoreanStructure,
            diagnostic: CorrectionDiagnostic(
                direction: .latinToKorean,
                tier: .medium,
                rule: .weakKoreanStructure,
                tokenLength: keystrokes.count,
                boundary: boundary
            )
        )
    }

    private func consonantMashDecision(
        boundary: CorrectionBoundary,
        keystrokes: [PhysicalKeystroke]
    ) -> CorrectionDecision? {
        guard let diagnostic = autoCorrectionEngine.lastDiagnostic,
              diagnostic.rule == .consonantJamoMash,
              diagnostic.boundary == boundary,
              diagnostic.direction == .koreanToLatin,
              diagnostic.tokenLength == keystrokes.count,
              !keystrokes.isEmpty else {
            return nil
        }

        // 사본으로 동결 정책을 재실행해 같은 판정이 나오는지 확인합니다.
        // 방향은 위에서 진단으로 이미 확인했으므로 한글자판으로 하드코딩합니다.
        guard case .preserve(.consonantJamoMash) = LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: .koreanTwoSet
        ) else {
            return nil
        }

        return consonantMashCorrection(boundary: boundary, keystrokes: keystrokes)
    }

    /// 이미 `consonantJamoMash`임을 검증한 물리 키열에만 동결 영어 사전을 적용합니다.
    ///
    /// 구조 규칙은 서로 다른 자음 자모 나열을 키보드 매시로 보고 보존하는데,
    /// 그중 `card`·`water`처럼 자음 자판 글자만으로 적힌 **실제 영어 단어**가
    /// 함께 죽습니다. 결과가 동결 사전(`en-guard.v1.txt`)에 실단어로 있을 때만
    /// 되살립니다 — LexicalGuard 의 한→영 순수 자음 게이트와 같은 증거원(`guardEvidence`)
    /// 을 씁니다. 자산이 없으면 `guard`가 fail-closed(보존)로 떨어집니다.
    ///
    /// 조회 키는 `LexicalTiebreaker.englishLookupKey`로 정규화합니다 — 소문자 fold에
    /// 더해 어중 대문자를 veto하므로, 정상 영어가 아닌 표기(`cArd`)는 걸러집니다.
    private func consonantMashCorrection(
        boundary: CorrectionBoundary,
        keystrokes: [PhysicalKeystroke]
    ) -> CorrectionDecision? {
        guard keystrokes.count >= EventTapManager.minimumConsonantMashKeystrokes,
              let evidence = guardEvidence,
              // 원문은 반드시 정책의 함수로 얻습니다. 손으로 조립하면 shift 처리가
              // 어긋납니다.
              let latin = LayoutCorrectionPolicy.latinCandidate(for: keystrokes),
              let key = LexicalTiebreaker.englishLookupKey(latin),
              evidence.contains(key),
              // 동결 조합기로 화면의 자모를 재구성해, 실제로 음절을 이루지 못한
              // **순수 낱자모 매시**일 때만 진행합니다. 하나라도 음절이 서면
              // 매시가 아니므로 nil = 보존입니다.
              let composed = HangulStructure.evaluate(keystrokes),
              composed.syllableCount == 0,
              composed.jamoCount == keystrokes.count,
              composed.text != latin else {
            return nil
        }

        EventTapManager.diagnostic(
            "consonant mash rescue rule=consonantJamoMash len=\(keystrokes.count) "
                + FocusedInputSafety.diagnosticContext()
        )

        // tier는 medium입니다. 구조가 '보존(매시)'으로 판정한 것을 사전 증거만으로
        // 뒤집는 경우라 확신이 낮고, 원문 칩을 Undo 창(6초) 내내 강조해 되돌리기를
        // 쉽게 만듭니다.
        return CorrectionDecision(
            original: composed.text,
            replacement: latin,
            direction: .koreanToLatin,
            tier: .medium,
            rule: .consonantJamoMash,
            diagnostic: CorrectionDiagnostic(
                direction: .koreanToLatin,
                tier: .medium,
                rule: .consonantJamoMash,
                tokenLength: keystrokes.count,
                boundary: boundary
            )
        )
    }

    /// 어퍼스트로피 토큰을 `'`를 사이에 낀 두 세그먼트로 복원해 교정합니다.
    ///
    /// 판정은 **합친 키열을 동결 정책에 그대로** 맡깁니다 — `'`는 판정에 관여하지
    /// 않습니다. 정책이 한→영 교정을 내면(`its`→englishStructure) 그 결정을 받되,
    /// 원문·교정문은 `'`를 다시 끼운 **세그먼트별** 값으로 덮어씁니다. 세그먼트별로
    /// 조합해야 하는 이유: 화면은 `'`가 왼쪽 조합을 확정시켜 `ㅑㅅ'ㄴ`(4자)인데,
    /// 합쳐 조합하면 `HangulStructure.evaluate([i,t,s])`가 다른 글자·다른 길이를
    /// 줍니다. 삭제 수(`originalCharacterCount`)가 화면과 어긋나면 텍스트가 깨지므로
    /// 반드시 세그먼트별로 만듭니다.
    ///
    /// 정책이 보존이면(`배고프다라고`→modernKorean) nil = 보존이라, 한국어 닫는
    /// 따옴표+조사가 여기서 안전하게 걸러집니다.
    private func apostropheCorrection(
        keystrokes: [PhysicalKeystroke],
        breakIndex: Int,
        boundary: CorrectionBoundary
    ) -> CorrectionDecision? {
        // 양쪽에 자모가 최소 1개씩 있어야 합니다("양옆에 글자"). 선행/후행
        // 어퍼스트로피(`'25년`·`don'`)는 여기서 걸러 nil = 보존입니다.
        guard breakIndex >= 1, breakIndex < keystrokes.count else { return nil }
        let left = Array(keystrokes[..<breakIndex])
        let right = Array(keystrokes[breakIndex...])

        // 합친 키열이 한글로 **완전히 조합**되면 보존합니다. 정책의 modernKorean
        // 게이트는 KS X 1001 밖 접합 음절(`현재'ㄷ` → 합치면 현잳)을 놓쳐
        // 라틴으로 오교정하는데, 완전 조합 자체가 "한국어를 치고 있었다"는
        // 충분한 증거입니다. 영어 축약형은 두벌식으로 낱자모가 반드시 남아
        // (its=ㅑㅅㄴ, dont=애ㅜㅅ) 여기 걸리지 않습니다. 조합을 확인할 수
        // 없으면 fail-closed = 보존입니다.
        guard let joined = HangulStructure.evaluate(keystrokes),
              !joined.isFullyComposed else {
            return nil
        }

        // 판정은 `'`를 뺀 합친 키열로 — 동결 정책이 확인합니다. 한글자판 방향의
        // `.correct`는 언제나 koreanToLatin(englishStructure·markedEnglishForm)입니다.
        guard case .correct(let tier, _, _, let rule) = LayoutCorrectionPolicy.evaluate(
            keystrokes: keystrokes,
            inputSource: .koreanTwoSet
        ) else {
            return nil
        }

        // 원문·교정문은 세그먼트별로 조합하고 `'`를 다시 끼웁니다(화면과 일치).
        guard let leftKorean = HangulStructure.evaluate(left)?.text,
              let rightKorean = HangulStructure.evaluate(right)?.text,
              let leftLatin = LayoutCorrectionPolicy.latinCandidate(for: left),
              let rightLatin = LayoutCorrectionPolicy.latinCandidate(for: right) else {
            return nil
        }
        let original = leftKorean + "'" + rightKorean
        let replacement = leftLatin + "'" + rightLatin
        guard original != replacement else { return nil }

        EventTapManager.diagnostic(
            "apostrophe rescue rule=\(rule) len=\(keystrokes.count) "
                + FocusedInputSafety.diagnosticContext()
        )

        return CorrectionDecision(
            original: original,
            replacement: replacement,
            direction: .koreanToLatin,
            tier: tier,
            rule: rule,
            diagnostic: CorrectionDiagnostic(
                direction: .koreanToLatin,
                tier: tier,
                rule: rule,
                tokenLength: keystrokes.count,
                boundary: boundary
            )
        )
    }

    /// "텍스트 역할이 아니다"를 한 번 더 관찰합니다. 상한에 닿으면 딱 한 번
    /// 호출부에 알리고 카운터를 비웁니다.
    ///
    /// 여기서 앱을 직접 판정하지 않는 이유: 버튼·캔버스에 포커스가 가 있어도 같은
    /// 신호가 나옵니다. 한 번으로 단정하면 정상 앱이 미지원으로 굳습니다. 반면
    /// AX에 텍스트를 아예 안 내놓는 앱에서는 몇 글자만 쳐도 연속으로 쌓입니다 —
    /// 그 비대칭이 판별의 근거이고, 중간에 적격이 한 번이라도 나오면 0으로
    /// 되돌아가 오탐이 남지 않습니다.
    private func noteUnsupportedRoleObservation() {
        unsupportedRoleObservations += 1
        // 상한에 **정확히 닿는 순간에만** 알립니다. 계속 세되 0으로 되돌리지 않으므로
        // 같은 앱에서 계속 쳐도 통지는 한 번뿐이고, 앱이 바뀔 때
        // (`resetAutomaticCorrectionState`) 비워져 다음 앱이 새로 세기 시작합니다.
        guard unsupportedRoleObservations
            == EventTapManager.unsupportedRoleObservationsToLearn else { return }
        EventTapManager.diagnostic(
            "auto correction unsupported app — 텍스트 역할 미노출 "
                + FocusedInputSafety.diagnosticContext()
        )
        onAutoCorrectionUnsupported?()
    }

    private func invalidateAutomaticCorrectionTokenUntilBoundary() {
        autoCorrectionEngine.invalidateCurrentTokenUntilBoundary()
        lexicalKeystrokeMirror.removeAll(keepingCapacity: true)
        tokenCaptureState = .discardUntilBoundary
        clearAutomaticCorrectionFocus()
    }

    private func clearAutomaticCorrectionFocus() {
        automaticCorrectionFieldAllowed = nil
        automaticCorrectionFocusToken = nil
        softProbeRefusalKeys = 0
        apostropheBreakStrokeCount = nil
        blindFieldActive = false
        // 미지원 관찰은 **앱 단위** 근거이므로 여기서 비우지 않습니다. 토큰·포커스가
        // 바뀔 때마다 0이 되면 상한에 영영 닿지 못해 학습이 죽습니다. 앱이 바뀌는
        // 시점(`resetAutomaticCorrectionState`)에서만 비웁니다.
    }

    private func resetAutomaticCorrectionState() {
        invalidatePendingBoundaryCorrection()
        resetAutomaticCorrectionToken()
        clearUndoTransaction(notify: true)
        // 미지원 관찰은 앱 단위 근거입니다. 앱이 바뀌면 근거도 끊어야
        // A 앱에서 쌓인 관찰이 B 앱을 미지원으로 만들지 않습니다.
        unsupportedRoleObservations = 0
    }

    private func invalidatePendingBoundaryCorrection() {
        pendingCorrectionState = .none
        boundaryCorrectionGeneration &+= 1
    }

    private func resetTransientState() {
        tracker.reset()
        resetAutomaticCorrectionState()
        // 앱 전환 뒤 이전 keyDown의 keyUp이나 자동반복을 잘못 삼키지 않습니다.
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
        // NSLog는 통합 로그(os_log)로 흘러 `log stream`에서 보입니다. print는
        // LaunchServices로 뜬 GUI 앱에서 어디에도 안 잡혀 디버깅이 불가능했습니다.
        NSLog("[Mackor][diagnostic] %@", message())
    }

    // MARK: - 권한 확인

    /// 손쉬운 사용 권한 상태를 확인합니다.
    ///
    /// `prompt`를 켜면 macOS가 자체 권한 창을 띄웁니다. Mackor는 이유와 개인정보
    /// 처리를 설명하는 자체 안내 창을 쓰고 시스템 설정도 직접 열어 주므로,
    /// **기본값은 확인만 하는 `false`**입니다. 켜면 창이 두 번 뜹니다.
    static func checkAccessibilityPermission(prompt: Bool = false) -> Bool {
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

    // 시스템이 tap을 비활성화한 경우: 포트가 살았으면 재활성화, 무효화됐으면 정리.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()
            manager.handleSystemTapDisabled()
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
