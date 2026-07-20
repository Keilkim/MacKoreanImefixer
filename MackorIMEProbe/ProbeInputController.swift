import AppKit
import Carbon.HIToolbox
import InputMethodKit

/// P0 측정 전용 IMKInputController.
///
/// 2차 개정: 1차 측정에서 `ProbeModeState.current`가 갱신되지 않아 P0-1이 "호출 의도"만
/// 기록됐다. 이제 모드는 **TIS에서 직접 읽고**, 재변환은 mozc 정공법 순서
/// (대상 범위에 setMarkedText → 같은 범위로 커밋)로 테스트한다.
///
/// 트리거 (F1~F7 / ⌃⌥1~7):
///   F1 — [P0-1] TIS 상태 기록 → selectMode(다른 모드) → 0/50/250/1000ms 후 TIS 재기록
///   F2 — [P0-3] 캐럿에 setMarkedText("ㅁ"), 재입력 시 커밋
///   F3 — [P0-4] index=0 캐럿 rect + 빨간 점
///   F4 — [대조군A] 조합 없이 직접 ranged insertText (1차와 동일 — 비교용)
///   F5 — [진단] snapshot: supportsProperty / stringFromRange / range 전체
///   F6 — [정공법] mozc 순서: setMarkedText(대상범위) → 같은 범위로 insertText 커밋
///   F7 — [대조군B] ranged 삭제: insertText("", replacementRange: 대상)
@objc(ProbeInputController)
class ProbeInputController: IMKInputController {

    private var markedProbeActive = false

    private func textClient(_ sender: Any!) -> (IMKTextInput & NSObjectProtocol)? {
        sender as? (IMKTextInput & NSObjectProtocol)
    }

    private func clientID(_ sender: Any!) -> String {
        textClient(sender)?.bundleIdentifier() ?? "unknown-client"
    }

    // MARK: - 수신 이벤트 마스크 (IMK에 keyUp은 존재하지 않음)

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown,
        ]
        return Int(mask.rawValue)
    }

    // MARK: - 수명 콜백

    override func activateServer(_ sender: Any!) {
        ProbeLog.line("activateServer client=\(clientID(sender)) \(TISProbe.snapshot())")
        super.activateServer(sender)
    }

    override func deactivateServer(_ sender: Any!) {
        ProbeLog.line("deactivateServer client=\(clientID(sender))")
        super.deactivateServer(sender)
    }

    override func commitComposition(_ sender: Any!) {
        ProbeLog.line("commitComposition client=\(clientID(sender))")
        super.commitComposition(sender)
    }

    /// [P0-2] 모드 통지. **여기서 실제 상태를 갱신한다** (1차 측정의 결함 수정).
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        if tag == Int(kTextServiceInputModePropertyTag), let mode = value as? String {
            ProbeModeState.current = mode
            ProbeLog.line("setValue MODE-CHANGED -> \(mode) client=\(clientID(sender))")
        } else {
            ProbeLog.line("setValue tag=\(tag) value=\(String(describing: value)) client=\(clientID(sender))")
        }
        super.setValue(value, forTag: tag, client: sender)
    }

    // MARK: - 이벤트 처리

    override func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        guard let event else { return false }

        switch event.type {
        case .flagsChanged:
            ProbeLog.line("flagsChanged flags=\(flagString(event.modifierFlags)) keycode=\(event.keyCode)")
            return false
        case .leftMouseDown, .rightMouseDown:
            ProbeLog.line("mouseDown type=\(event.type.rawValue) client=\(clientID(sender))")
            return false
        case .keyDown:
            break
        default:
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keycode = event.keyCode

        if flags.contains(.command) {
            ProbeLog.line("CMD-combo REACHED handle: keycode=\(keycode) flags=\(flagString(flags)) client=\(clientID(sender))")
            return false
        }

        if let measurement = measurementTrigger(keycode: keycode, flags: flags) {
            run(measurement, client: sender)
            return true
        }

        // 물리/합성 구분 기록.
        // 이전 판은 `getIntegerValueField(...) != nil`로 썼는데 이는 옵셔널 체인의
        // nil 검사라 cgEvent가 있으면 항상 true였다 — 판별자로 무의미했다.
        // 이제 EventTapManager와 같은 필드(42)·마커(0x48474C46 "HGLF")를 읽고
        // 원시값을 그대로 남긴다. 이 값 하나가 두 가지를 동시에 판정한다:
        // (a) 합성 이벤트가 handle()에 도달하는가
        // (b) 필드 42가 CGEvent → WindowServer → TSM → NSEvent 왕복에서 살아남는가
        let raw = event.cgEvent?.getIntegerValueField(CGEventField(rawValue: 42)!)
        let synthetic = (raw == 0x4847_4C46)
        ProbeLog.line("keyDown keycode=\(keycode) flags=\(flagString(flags)) chars=\(event.characters ?? "") autorepeat=\(event.isARepeat) mode=\(ProbeModeState.current) rawUserData=\(raw.map(String.init) ?? "nil") synth?=\(synthetic) client=\(clientID(sender))")
        return false
    }

    // MARK: - 측정

    private enum Measurement: String {
        case selectMode, markedProbe, caretRect, rangedInsert, snapshot, mozcReconvert, rangedDelete
    }

    private func measurementTrigger(keycode: UInt16, flags: NSEvent.ModifierFlags) -> Measurement? {
        switch keycode {
        case UInt16(kVK_F1): return .selectMode
        case UInt16(kVK_F2): return .markedProbe
        case UInt16(kVK_F3): return .caretRect
        case UInt16(kVK_F4): return .rangedInsert
        case UInt16(kVK_F5): return .snapshot
        case UInt16(kVK_F6): return .mozcReconvert
        case UInt16(kVK_F7): return .rangedDelete
        default: break
        }
        guard flags.contains(.control), flags.contains(.option) else { return nil }
        switch keycode {
        case UInt16(kVK_ANSI_1): return .selectMode
        case UInt16(kVK_ANSI_2): return .markedProbe
        case UInt16(kVK_ANSI_3): return .caretRect
        case UInt16(kVK_ANSI_4): return .rangedInsert
        case UInt16(kVK_ANSI_5): return .snapshot
        case UInt16(kVK_ANSI_6): return .mozcReconvert
        case UInt16(kVK_ANSI_7): return .rangedDelete
        default: return nil
        }
    }

    /// 대상 범위: 캐럿 직전 n글자
    private func targetRange(_ client: IMKTextInput, length: Int) -> NSRange? {
        let sel = client.selectedRange()
        guard sel.location != NSNotFound, sel.location >= length else { return nil }
        return NSRange(location: sel.location - length, length: length)
    }

    private func docText(_ client: IMKTextInput, _ label: String) {
        let len = client.length()
        guard len > 0, len != NSNotFound else {
            ProbeLog.line("  \(label): length=\(len) (문서 문자열 읽기 불가)")
            return
        }
        let whole = NSRange(location: 0, length: len)
        var actual = NSRange(location: NSNotFound, length: 0)
        let s = client.string(from: whole, actualRange: &actual)
        ProbeLog.line("  \(label): length=\(len) text=[\(s ?? "nil")] actualRange=\(ProbeLog.range(actual)) sel=\(ProbeLog.range(client.selectedRange())) marked=\(ProbeLog.range(client.markedRange()))")
    }

    private func run(_ measurement: Measurement, client sender: Any!) {
        guard let client = textClient(sender) else {
            ProbeLog.line("MEASURE \(measurement.rawValue): client cast FAILED")
            return
        }
        let cid = clientID(sender)

        switch measurement {
        case .selectMode:
            // [P0-1 재측정] TIS 실제 상태를 전후로 기록한다
            let before = TISProbe.snapshot()
            let next = ProbeModeState.current == ProbeModeState.han2
                ? ProbeModeState.roman : ProbeModeState.han2
            ProbeLog.line("MEASURE selectMode: 내부기록모드=\(ProbeModeState.current) 목표=\(next) client=\(cid)")
            ProbeLog.line("  BEFORE \(before)")
            client.selectMode(next)
            ProbeLog.line("  AFTER-0ms \(TISProbe.snapshot())")
            for (delay, label) in [(0.05, "50ms"), (0.25, "250ms"), (1.0, "1000ms")] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    ProbeLog.line("  AFTER-\(label) \(TISProbe.snapshot()) 내부기록모드=\(ProbeModeState.current)")
                }
            }

        case .markedProbe:
            if markedProbeActive {
                client.insertText("ㅁ", replacementRange: NSRange(location: NSNotFound, length: 0))
                markedProbeActive = false
                ProbeLog.line("MEASURE markedProbe: committed client=\(cid)")
                docText(client, "AFTER-commit")
            } else {
                client.setMarkedText("ㅁ", selectionRange: NSRange(location: 1, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
                markedProbeActive = true
                ProbeLog.line("MEASURE markedProbe: setMarkedText marked=\(ProbeLog.range(client.markedRange())) sel=\(ProbeLog.range(client.selectedRange())) client=\(cid)")
            }

        case .caretRect:
            var rect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            ProbeLog.line("MEASURE caretRect: index=0 rect=\(rect) client=\(cid)")
            ProbeDot.flash(at: rect)

        case .rangedInsert:
            // [대조군A] 조합 없이 직접 ranged insert (1차와 동일 조건)
            guard let target = targetRange(client, length: 1) else {
                ProbeLog.line("MEASURE rangedInsert: 대상 범위 확보 실패 sel=\(ProbeLog.range(client.selectedRange())) client=\(cid)")
                return
            }
            ProbeLog.line("MEASURE rangedInsert (대조군A) target=\(ProbeLog.range(target)) client=\(cid)")
            docText(client, "BEFORE")
            client.insertText("한", replacementRange: target)
            docText(client, "AFTER")

        case .mozcReconvert:
            // [정공법] mozc 순서: 대상 범위에 setMarkedText → 같은 범위로 커밋
            guard let target = targetRange(client, length: 2) else {
                ProbeLog.line("MEASURE mozcReconvert: 대상 범위 확보 실패 sel=\(ProbeLog.range(client.selectedRange())) client=\(cid)")
                return
            }
            ProbeLog.line("MEASURE mozcReconvert (정공법) target=\(ProbeLog.range(target)) client=\(cid)")
            docText(client, "BEFORE")
            // 1단계: 대상 범위를 marked text로 덮는다
            client.setMarkedText("한글", selectionRange: NSRange(location: 2, length: 0),
                                 replacementRange: target)
            ProbeLog.line("  STEP1 setMarkedText(range=\(ProbeLog.range(target))) -> marked=\(ProbeLog.range(client.markedRange())) sel=\(ProbeLog.range(client.selectedRange()))")
            docText(client, "AFTER-STEP1")
            // 2단계: 같은 범위로 커밋
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                client.insertText("한글", replacementRange: target)
                ProbeLog.line("  STEP2 insertText(range=\(ProbeLog.range(target))) 완료")
                self.docText(client, "AFTER-STEP2")
            }

        case .rangedDelete:
            // [대조군B] ranged 삭제 — IMK만으로 앞 글자를 지울 수 있는가
            guard let target = targetRange(client, length: 1) else {
                ProbeLog.line("MEASURE rangedDelete: 대상 범위 확보 실패 client=\(cid)")
                return
            }
            ProbeLog.line("MEASURE rangedDelete target=\(ProbeLog.range(target)) client=\(cid)")
            docText(client, "BEFORE")
            client.insertText("", replacementRange: target)
            docText(client, "AFTER")

        case .snapshot:
            let supportsDocAccess = client.supportsProperty(TSMDocumentPropertyTag(kTSMDocumentSupportDocumentAccessPropertyTag))
            let attrs = client.validAttributesForMarkedText() ?? []
            ProbeLog.line("MEASURE snapshot: client=\(cid) supportsDocumentAccess=\(supportsDocAccess) validAttrs=\(attrs) \(TISProbe.snapshot())")
            docText(client, "DOC")
        }
    }

    private func flagString(_ flags: NSEvent.ModifierFlags) -> String {
        var parts: [String] = []
        if flags.contains(.shift) { parts.append("shift") }
        if flags.contains(.command) { parts.append("cmd") }
        if flags.contains(.control) { parts.append("ctrl") }
        if flags.contains(.option) { parts.append("opt") }
        if flags.contains(.capsLock) { parts.append("caps") }
        return parts.isEmpty ? "-" : parts.joined(separator: "+")
    }
}

/// TIS 실제 상태 판독 — 1차 측정의 핵심 결함(내부 변수만 신뢰)을 메운다.
enum TISProbe {
    static func snapshot() -> String {
        guard let src = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return "TIS[읽기실패]"
        }
        func prop(_ key: CFString) -> String {
            guard let p = TISGetInputSourceProperty(src, key) else { return "-" }
            return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        var modeID = "-"
        if let p = TISGetInputSourceProperty(src, kTISPropertyInputModeID) {
            modeID = Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
        }
        return "TIS[sourceID=\(prop(kTISPropertyInputSourceID)) modeID=\(modeID)]"
    }
}

enum ProbeModeState {
    static let han2 = "com.mackor.inputmethod.MackorProbe.han2"
    static let roman = "com.mackor.inputmethod.MackorProbe.roman"
    static var current = han2
}

/// [P0-4] 시각 확인용: 반환된 rect 위치에 빨간 점을 1.5초 표시
enum ProbeDot {
    private static var panel: NSPanel?

    static func flash(at rect: NSRect) {
        DispatchQueue.main.async {
            panel?.orderOut(nil)
            let size: CGFloat = 10
            let frame = NSRect(x: rect.midX - size / 2, y: rect.midY - size / 2,
                               width: size, height: size)
            let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let dot = NSView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = NSColor.systemRed.cgColor
            dot.layer?.cornerRadius = size / 2
            p.contentView = dot
            p.orderFrontRegardless()
            panel = p
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                p.orderOut(nil)
                if panel === p { panel = nil }
            }
        }
    }
}
