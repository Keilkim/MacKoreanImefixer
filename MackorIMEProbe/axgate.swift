// G0-3: FocusedInputSafety의 AX 게이트를 그대로 재현하는 독립 측정 도구.
//
// 왜 별도 도구인가: 프로브(IMK)는 손쉬운 사용 권한이 없어 AX 질의를 할 수 없다.
// 그리고 4차 로그의 실패는 IMKTextInput 문서 질의였지 AX 질의가 아니었다.
// "CorelDRAW에서 AX 게이트가 실패하므로 R3가 기록되지 않는다"는 서술은 지금까지
// 추론이었고(직접 AX 측정은 Chrome뿐), 이 도구가 그것을 실측으로 바꾼다.
//
// 사용법: 대상 앱의 텍스트 입력란에 커서를 둔 뒤
//   axgate            — 3초 뒤 현재 포커스에 대해 측정 (앱 전환 시간 확보)
//   axgate 0          — 즉시 측정

import AppKit
import ApplicationServices
import Carbon      // IsSecureEventInputEnabled
import Foundation

let delay = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 3) : 3
if delay > 0 {
    FileHandle.standardError.write(Data("\(Int(delay))초 뒤 측정합니다. 대상 앱 입력란에 커서를 두세요...\n".utf8))
    Thread.sleep(forTimeInterval: delay)
}

print("AXIsProcessTrusted: \(AXIsProcessTrusted())")

// 루트 요소 선택.
//
// FocusedInputSafety는 systemWide 요소를 쓰지만(:39-43), 이 측정 도구가 실행되는
// 셸 컨텍스트에서는 systemWide 조회가 대상 앱과 무관하게 항상 -25204를 반환한다
// (TextEdit에서도 0/10 실패했는데 같은 순간 앱 요소 직접 조회는 AXTextArea를
// 정상 반환했다 — 도구 아티팩트이지 앱의 성질이 아니다).
// 따라서 최전면 앱의 pid로 애플리케이션 요소를 만들어 조회한다. 측정하려는 질문
// ("이 앱이 포커스된 텍스트 요소를 규격대로 노출하는가")은 동일하다.
//
// 50ms가 빡빡해서 실패하는 것인지 앱이 노출을 안 하는 것인지 구분하기 위해
// 넉넉한 타임아웃과 둘 다 측정한다. 이 구분이 "같은 입력란 안에서도 간헐적"
// 실패의 설명일 수 있다.
let frontPID: pid_t = {
    if CommandLine.arguments.count > 2, let p = pid_t(CommandLine.arguments[2]) { return p }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
}()
let frontName = NSRunningApplication(processIdentifier: frontPID)?.localizedName ?? "?"
let frontBundle = NSRunningApplication(processIdentifier: frontPID)?.bundleIdentifier ?? "?"
print("대상: \(frontName) [\(frontBundle)] pid=\(frontPID)")

let systemWide = AXUIElementCreateApplication(frontPID)
let loose = AXUIElementCreateApplication(frontPID)
AXUIElementSetMessagingTimeout(loose, 2.0)
AXUIElementSetMessagingTimeout(systemWide, 0.05)

func axName(_ e: AXError) -> String {
    switch e.rawValue {
    case 0: return "success"
    case -25200: return "failure"
    case -25201: return "illegalArgument"
    case -25202: return "invalidUIElement"
    case -25204: return "cannotComplete(타임아웃 후보)"
    case -25205: return "attributeUnsupported"
    case -25211: return "apiDisabled(권한없음)"
    case -25212: return "noValue"
    default: return "기타"
    }
}

print("IsSecureEventInputEnabled: \(IsSecureEventInputEnabled())")

// FocusedInputSafety.focusedElement() 재현 (:317-329) — 50ms와 2s 양쪽으로.
// 50ms만 실패하고 2s는 성공하면 원인은 앱이 아니라 타임아웃이다.
func focusedElement(_ root: AXUIElement, label: String, trials: Int = 10)
    -> (AXUIElement?, AXError, Int) {
    var lastErr = AXError.success
    var successes = 0
    var found: AXUIElement?
    for _ in 0..<trials {
        var v: CFTypeRef?
        let e = AXUIElementCopyAttributeValue(
            root, kAXFocusedUIElementAttribute as CFString, &v)
        lastErr = e
        if e == .success, let v, CFGetTypeID(v) == AXUIElementGetTypeID() {
            successes += 1
            found = (v as! AXUIElement)
        }
        usleep(20_000)
    }
    print("\(label) AXFocusedUIElement -> 성공 \(successes)/\(trials) 마지막에러=\(lastErr.rawValue) \(axName(lastErr))")
    return (found, lastErr, successes)
}

let (tight, tightErr, tightOK) = focusedElement(systemWide, label: "  [50ms]")
let (looseEl, _, looseOK) = focusedElement(loose, label: "  [2s ]")

if tightOK < looseOK {
    print("  ⚠ 50ms 타임아웃이 원인 — 앱은 노출하지만 시간이 부족하다 (간헐적 실패의 유력 설명)")
} else if looseOK == 0 {
    print("  → 타임아웃과 무관하게 앱이 포커스 요소를 노출하지 않는다")
}

guard let element = looseEl ?? tight else {
    print("=> 판정: focusedElement() == nil  (FocusedInputSafety:54-57에서 fail-closed)")
    print("=> 이 앱에서는 자동 교정(R3)이 기록조차 되지 않는다  [\(axName(tightErr))]")
    exit(0)
}

var pid: pid_t = 0
AXUIElementGetPid(element, &pid)
print("focused element pid=\(pid)")

// FocusedInputSafety.swift:60-68 과 동일한 7개 속성 일괄 조회
let attributes: [CFString] = [
    kAXRoleAttribute as CFString,
    kAXSubroleAttribute as CFString,
    kAXTitleAttribute as CFString,
    kAXDescriptionAttribute as CFString,
    kAXRoleDescriptionAttribute as CFString,
    kAXPlaceholderValueAttribute as CFString,
    kAXSelectedTextRangeAttribute as CFString,
]
var copied: CFArray?
let copyErr = AXUIElementCopyMultipleAttributeValues(
    element, attributes as CFArray, [], &copied)
print("CopyMultipleAttributeValues -> \(copyErr.rawValue) \(axName(copyErr))")

guard copyErr == .success, let values = copied as? [Any],
      values.count == attributes.count else {
    print("=> 판정: 속성 일괄 조회 실패 (FocusedInputSafety:76-82에서 fail-closed)")
    exit(0)
}

let role = values[0] as? String
let subrole = values[1] as? String
print("AXRole=\(role ?? "nil")  AXSubrole=\(subrole ?? "nil")")

// 화이트리스트 판정 (:84-91)
let supportedRoles: Set<String> = [kAXTextFieldRole as String, kAXTextAreaRole as String]
let rolePass = role.map { supportedRoles.contains($0) } ?? false
print("role 화이트리스트: \(rolePass ? "통과" : "거부")")

// 보호 subrole (:93-101)
let protectedSubroles: Set<String> = [
    kAXSecureTextFieldSubrole as String, kAXSearchFieldSubrole as String,
]
let subrolePass = subrole.map { !protectedSubroles.contains($0) } ?? true
print("subrole 검사: \(subrolePass ? "통과" : "거부")")

// 메타데이터 필터 (:103-115)
let metadata = values[2...5].compactMap { ($0 as? String)?.lowercased() }
    .joined(separator: " ")
let protectedHints = [
    "address", "url", "location", "web address",
    "search", "주소", "웹 주소", "위치", "검색",
    "password", "passcode", "암호", "비밀번호",
]
let hit = protectedHints.first { metadata.contains($0) }
print("메타데이터=[\(metadata)]")
print("메타데이터 필터: \(hit.map { "거부(\($0))" } ?? "통과")")

print("")
let overall = rolePass && subrolePass && hit == nil
print("=> 종합 판정: AX 게이트 \(overall ? "통과 — R3 기록 가능" : "거부 — R3 기록 안 됨")")
