import Foundation
import CoreGraphics
import Carbon.HIToolbox

/// 키보드 이벤트를 가로채서 한글 조합을 직접 수행하고,
/// 완성된 유니코드 문자를 CorelDRAW에 전달하는 핵심 매니저.
///
/// 동작 원리:
/// 1. 한글 자모 키 입력을 가로챔 (원래 이벤트는 차단)
/// 2. HangulCompositionTracker로 자모 조합
/// 3. CGEventKeyboardSetUnicodeString으로 완성된 문자를 직접 전송
class EventTapManager {

    var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let tracker = HangulCompositionTracker()
    private var _isActive: Bool = false

    /// 우리가 주입한 이벤트를 식별하기 위한 마커값
    private static let injectionMarker: Int64 = 0x48474C46  // "HGLF"
    private static let userDataField = CGEventField(rawValue: 42)!  // kCGEventSourceUserData

    /// 백스페이스 키코드
    private static let backspaceKeycode: UInt16 = 0x33

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

    init() {}
    deinit { stop() }

    // MARK: - 시작/중지

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let eventMask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: eventTapCallback,
            userInfo: userInfo
        ) else {
            print("[MacKR] Event tap 생성 실패. 손쉬운 사용 권한을 확인하세요.")
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        if let source = runLoopSource {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[MacKR] Event tap 시작됨.")
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
        tracker.reset()
        print("[MacKR] Event tap 중지됨.")
    }

    // MARK: - 이벤트 처리

    func handleKeyDown(_ event: CGEvent) -> CGEvent? {
        // 비활성 상태면 통과
        guard isActive else { return event }

        // 우리가 주입한 이벤트면 통과
        if event.getIntegerValueField(EventTapManager.userDataField) == EventTapManager.injectionMarker {
            return event
        }

        let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // Cmd, Ctrl, Option 키가 눌려있으면 조합 확정 후 통과 (단축키)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) || flags.contains(.maskAlternate) {
            let result = tracker.processNonJamo()
            executeResult(result)
            return event
        }

        let shiftPressed = flags.contains(.maskShift)

        // 스페이스 → 조합 확정 후 통과
        if keycode == 0x31 {
            let result = tracker.processNonJamo()
            executeResult(result)
            return event
        }

        // 방향키, 엔터 등 → 조합 확정 후 통과
        if EventTapManager.commitKeycodes.contains(keycode) {
            let result = tracker.processNonJamo()
            executeResult(result)
            return event
        }

        // 백스페이스
        if keycode == EventTapManager.backspaceKeycode {
            let result = tracker.processBackspace()
            if result.passthrough { return event }
            executeResult(result)
            return nil  // 원래 백스페이스는 차단
        }

        // 자모 키 확인
        guard let jamo = KeycodeToJamoMap.jamo(for: keycode, shift: shiftPressed) else {
            // 자모가 아닌 키 → 조합 확정 후 통과
            let result = tracker.processNonJamo()
            executeResult(result)
            return event
        }

        // 자모 처리
        let result = tracker.processJamo(jamo)
        if result.passthrough { return event }
        print("[CHF] 자모=\(jamo.character) → delete=\(result.deleteCount) insert=\"\(result.insertText)\"")
        executeResult(result)
        return nil  // 원래 키 이벤트는 차단
    }

    // MARK: - 결과 실행 (백스페이스 + 문자 전송)

    private func executeResult(_ result: CompositionResult) {
        if result.deleteCount == 0 && result.insertText.isEmpty { return }

        // 백스페이스 전송
        for _ in 0..<result.deleteCount {
            sendKeyEvent(keycode: EventTapManager.backspaceKeycode, shift: false)
            usleep(3000)  // 3ms — CorelDRAW가 처리할 시간
        }

        // 유니코드 문자 전송
        if !result.insertText.isEmpty {
            for char in result.insertText {
                sendUnicodeCharacter(char)
                usleep(3000)
            }
        }
    }

    // MARK: - 키 이벤트 전송

    /// 일반 키 이벤트 전송 (백스페이스 등)
    private func sendKeyEvent(keycode: UInt16, shift: Bool) {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = EventTapManager.injectionMarker

        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: true) {
            if shift { keyDown.flags.insert(.maskShift) }
            keyDown.setIntegerValueField(EventTapManager.userDataField, value: EventTapManager.injectionMarker)
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keycode, keyDown: false) {
            if shift { keyUp.flags.insert(.maskShift) }
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    /// 유니코드 문자를 직접 전송 (IME를 거치지 않음)
    private func sendUnicodeCharacter(_ char: Character) {
        let source = CGEventSource(stateID: .privateState)
        source?.userData = EventTapManager.injectionMarker

        var utf16Units = Array(String(char).utf16)
        let length = utf16Units.count

        // 더미 키코드로 keyDown 이벤트 생성 후 유니코드 문자열 설정
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
            keyDown.keyboardSetUnicodeString(stringLength: length, unicodeString: &utf16Units)
            keyDown.flags = []  // 수정키 초기화 (Shift 등이 간섭하지 않도록)
            keyDown.setIntegerValueField(EventTapManager.userDataField, value: EventTapManager.injectionMarker)
            keyDown.post(tap: .cgAnnotatedSessionEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
            keyUp.setIntegerValueField(EventTapManager.userDataField, value: EventTapManager.injectionMarker)
            keyUp.post(tap: .cgAnnotatedSessionEventTap)
        }
    }

    // MARK: - 권한 확인

    static func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
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
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    guard type == .keyDown, let userInfo = userInfo else {
        return Unmanaged.passUnretained(event)
    }

    let manager = Unmanaged<EventTapManager>.fromOpaque(userInfo).takeUnretainedValue()

    if let resultEvent = manager.handleKeyDown(event) {
        return Unmanaged.passUnretained(resultEvent)
    } else {
        return nil  // 이벤트 차단
    }
}
