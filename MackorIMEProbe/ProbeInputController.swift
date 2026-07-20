import AppKit
import Carbon.HIToolbox
import InputMethodKit

/// P0 측정 전용 IMKInputController.
///
/// 계획(Phase 0)의 측정 항목을 트리거 키로 실행한다. 트리거 외의 모든 키는
/// 로그만 남기고 `false`(패스스루)를 반환하므로 일반 타이핑을 방해하지 않는다.
///
/// 트리거 (F키가 미디어 키로 잡히는 랩톱은 fn+F, 또는 ⌃⌥숫자 대체):
///   F1 / ⌃⌥1  — [P0-1] selectMode로 자기 다른 모드 전환 → 이후 handle() 지속 관찰
///   F2 / ⌃⌥2  — [P0-3] setMarkedText("ㅁ") 후 markedRange/selectedRange 읽기
///                (다시 누르면 marked를 insertText로 커밋)
///   F3 / ⌃⌥3  — [P0-4] index=0 캐럿 rect 조회 + 화면에 빨간 점 1.5초 표시
///   F4 / ⌃⌥4  — [P0-5] 직전 1글자를 "한"으로 replacementRange 치환 시도
///                (치환되면 ranged 편집 지원, 뒤에 덧붙으면 무시 = 미지원)
///   F5 / ⌃⌥5  — 클라이언트 스냅샷(번들ID·selectedRange·markedRange·validAttributes)
///
/// 자동 기록: activate/deactivate, setValue(모드 통지), commitComposition,
/// ⌘/⌃/⌥ 조합 도달 여부, flagsChanged(shift 손실 관찰), 마우스 다운.
@objc(ProbeInputController)
class ProbeInputController: IMKInputController {

    private var markedProbeActive = false

    private func textClient(_ sender: Any!) -> (IMKTextInput & NSObjectProtocol)? {
        sender as? (IMKTextInput & NSObjectProtocol)
    }

    private func clientID(_ sender: Any!) -> String {
        textClient(sender)?.bundleIdentifier() ?? "unknown-client"
    }

    // MARK: - 수신 이벤트 마스크 (Gureum 준용: keyUp은 IMK에 존재하지 않음)

    override func recognizedEvents(_ sender: Any!) -> Int {
        let mask: NSEvent.EventTypeMask = [
            .keyDown, .flagsChanged,
            .leftMouseDown, .rightMouseDown,
        ]
        return Int(mask.rawValue)
    }

    // MARK: - 수명 콜백

    override func activateServer(_ sender: Any!) {
        ProbeLog.line("activateServer client=\(clientID(sender))")
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

    // [P0-2] 시스템발 모드 변경 통지
    override func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        ProbeLog.line("setValue tag=\(tag) value=\(String(describing: value)) client=\(clientID(sender))")
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
            ProbeLog.line("event type=\(event.type.rawValue)")
            return false
        }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let keycode = event.keyCode

        // [P0-7] ⌘ 조합이 handle()까지 도달하는지 — 도달 자체가 데이터
        if flags.contains(.command) {
            ProbeLog.line("CMD-combo REACHED handle: keycode=\(keycode) flags=\(flagString(flags)) client=\(clientID(sender))")
            return false
        }

        if let measurement = measurementTrigger(keycode: keycode, flags: flags) {
            run(measurement, client: sender)
            return true // 트리거 키만 소비
        }

        ProbeLog.line("keyDown keycode=\(keycode) flags=\(flagString(flags)) chars=\(event.characters ?? "") autorepeat=\(event.isARepeat) client=\(clientID(sender))")
        return false
    }

    // MARK: - 측정

    private enum Measurement: String {
        case selectMode, markedProbe, caretRect, replacementRange, snapshot
    }

    private func measurementTrigger(keycode: UInt16, flags: NSEvent.ModifierFlags) -> Measurement? {
        // F1~F5
        switch keycode {
        case UInt16(kVK_F1): return .selectMode
        case UInt16(kVK_F2): return .markedProbe
        case UInt16(kVK_F3): return .caretRect
        case UInt16(kVK_F4): return .replacementRange
        case UInt16(kVK_F5): return .snapshot
        default: break
        }
        // ⌃⌥숫자 대체 (F키가 미디어 키인 랩톱용)
        guard flags.contains(.control), flags.contains(.option) else { return nil }
        switch keycode {
        case UInt16(kVK_ANSI_1): return .selectMode
        case UInt16(kVK_ANSI_2): return .markedProbe
        case UInt16(kVK_ANSI_3): return .caretRect
        case UInt16(kVK_ANSI_4): return .replacementRange
        case UInt16(kVK_ANSI_5): return .snapshot
        default: return nil
        }
    }

    private func run(_ measurement: Measurement, client sender: Any!) {
        guard let client = textClient(sender) else {
            ProbeLog.line("MEASURE \(measurement.rawValue): client cast FAILED")
            return
        }
        let cid = clientID(sender)

        switch measurement {
        case .selectMode:
            // [P0-1] 자기 다른 모드로 전환 — 이후에도 keyDown 로그가 이어지는지가 판정
            let current = ProbeModeState.current
            let next = current == ProbeModeState.han2 ? ProbeModeState.roman : ProbeModeState.han2
            ProbeLog.line("MEASURE selectMode: \(current) -> \(next) client=\(cid) (이후 keyDown 로그 지속 여부 = P0-1 판정)")
            client.selectMode(next)

        case .markedProbe:
            // [P0-3] 능력 탐지의 원자 동작
            if markedProbeActive {
                client.insertText("ㅁ", replacementRange: NSRange(location: NSNotFound, length: 0))
                markedProbeActive = false
                ProbeLog.line("MEASURE markedProbe: committed via insertText client=\(cid)")
            } else {
                client.setMarkedText(
                    "ㅁ",
                    selectionRange: NSRange(location: 1, length: 0),
                    replacementRange: NSRange(location: NSNotFound, length: 0)
                )
                let marked = client.markedRange()
                let selected = client.selectedRange()
                markedProbeActive = true
                ProbeLog.line("MEASURE markedProbe: setMarkedText(\"ㅁ\") -> markedRange=\(ProbeLog.range(marked)) selectedRange=\(ProbeLog.range(selected)) client=\(cid) (화면에 ㅁ가 보이고 유지되는지 눈으로도 확인)")
            }

        case .caretRect:
            // [P0-4] marked text 없는 시점의 index=0 캐럿 rect (IMKInputSession.h:163 규격)
            var rect = NSRect.zero
            _ = client.attributes(forCharacterIndex: 0, lineHeightRectangle: &rect)
            ProbeLog.line("MEASURE caretRect: index=0 rect=\(rect) client=\(cid)")
            ProbeDot.flash(at: rect)

        case .replacementRange:
            // [P0-5] ranged 편집 지원 판정: 직전 1글자를 "한"으로 치환 시도
            let selected = client.selectedRange()
            guard selected.location != NSNotFound, selected.location >= 1 else {
                ProbeLog.line("MEASURE replacementRange: selectedRange=\(ProbeLog.range(selected)) — 위치 확보 실패(이 자체가 TSMDocumentAccess 미지원 신호) client=\(cid)")
                return
            }
            let target = NSRange(location: selected.location - 1, length: 1)
            client.insertText("한", replacementRange: target)
            ProbeLog.line("MEASURE replacementRange: insertText(\"한\", range=\(ProbeLog.range(target))) client=\(cid) (직전 글자가 한으로 바뀌면 지원, 뒤에 덧붙으면 무시=미지원)")

        case .snapshot:
            let marked = client.markedRange()
            let selected = client.selectedRange()
            let attrs = client.validAttributesForMarkedText() ?? []
            ProbeLog.line("MEASURE snapshot: client=\(cid) selectedRange=\(ProbeLog.range(selected)) markedRange=\(ProbeLog.range(marked)) validAttrs=\(attrs)")
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

/// 프로브의 현재 모드 추적 (setValue 통지와 selectMode 호출 양쪽에서 갱신)
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
            let frame = NSRect(
                x: rect.midX - size / 2, y: rect.midY - size / 2,
                width: size, height: size
            )
            let p = NSPanel(
                contentRect: frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
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
