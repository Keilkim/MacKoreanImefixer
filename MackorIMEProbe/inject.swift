// A-1 측정: 주입 마커가 CGEvent → WindowServer → TSM → NSEvent 왕복에서
// 살아남는가.
//
// 왜 별도 도구인가: Mackor로 주입을 발생시키려 하면 막힌다. 프로브가 활성 입력
// 소스이면 Mackor의 inputSourceKind가 .unsupported가 되어(AppMonitor.swift:44가
// Apple 두벌식을 하드코딩) 탭이 아무것도 주입하지 않는다. 설계 §5-6이 지적한
// 문제가 측정 자체를 막는 형태로 나타난다.
//
// 그래서 EventTapManager.QuartzKeyboardOutput(:54-110)의 주입 방식을 그대로
// 복제해 직접 쏜다. 측정하려는 질문은 동일하다.
//
// 사용법:
//   inject key <keycode>   — sendKeyEvent와 동일 방식 (태깅된 keyDown/keyUp)
//   inject text <문자열>    — sendUnicodeText와 동일 방식 (더미 키코드 0x09)
//   inject plain <keycode> — 태그 없는 대조군

import CoreGraphics
import Foundation

let injectionMarker: Int64 = 0x4847_4C46          // "HGLF" = 1212632134
let userDataField = CGEventField(rawValue: 42)!   // kCGEventSourceUserData

func tagAsInjected(_ event: CGEvent) {
    event.setIntegerValueField(userDataField, value: injectionMarker)
}

func taggedSource() -> CGEventSource? {
    let source = CGEventSource(stateID: .privateState)
    source?.userData = injectionMarker
    return source
}

let args = CommandLine.arguments
guard args.count >= 3 else {
    print("usage: inject key <keycode> | text <문자열> | plain <keycode>")
    exit(1)
}

switch args[1] {
case "key":
    guard let code = UInt16(args[2]) else { exit(1) }
    let source = taggedSource()
    if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
        tagAsInjected(down)
        print("post keyDown keycode=\(code) field42=\(down.getIntegerValueField(userDataField))")
        down.post(tap: .cgAnnotatedSessionEventTap)
    }
    usleep(30_000)
    if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
        tagAsInjected(up)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

case "text":
    let text = args[2]
    let source = taggedSource()
    var units = Array(text.utf16)
    if let down = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) {
        down.keyboardSetUnicodeString(stringLength: units.count, unicodeString: &units)
        down.flags = []
        tagAsInjected(down)
        print("post unicode text=[\(text)] field42=\(down.getIntegerValueField(userDataField))")
        down.post(tap: .cgAnnotatedSessionEventTap)
    }
    usleep(30_000)
    if let up = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false) {
        tagAsInjected(up)
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

case "plain":
    // 대조군: 태그도 source userData도 없는 순수 합성 이벤트
    guard let code = UInt16(args[2]) else { exit(1) }
    let source = CGEventSource(stateID: .hidSystemState)
    if let down = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) {
        print("post plain keyDown keycode=\(code) field42=\(down.getIntegerValueField(userDataField))")
        down.post(tap: .cgAnnotatedSessionEventTap)
    }
    usleep(30_000)
    if let up = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: false) {
        up.post(tap: .cgAnnotatedSessionEventTap)
    }

default:
    print("unknown mode")
    exit(1)
}
