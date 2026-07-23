// 공통 계층 지원 가능성 탐침.
//
// axgate가 "포커스된 요소"의 role만 보는 것과 달리, 이 도구는:
//   1. 포커스 요소의 전체 속성·자식 트리를 덤프
//   2. 앱 요소에 일반 활성화 속성(AXManualAccessibility·AXEnhancedUserInterface)을
//      켠 뒤 다시 측정 — 특정 앱 이름에 의존하지 않는 기법이라 되면 같은 부류
//      전체가 열린다
//   3. 스크롤/그룹 안에 숨은 텍스트 요소(AXTextArea/AXTextField)가 있는지 하강 탐색
//   4. 찾은 요소에서 실제 텍스트(AXValue/AXSelectedText/kAXStringForRange)를 읽어본다
//
// 사용법: 대상 앱 본문에 커서를 둔 뒤  ./axexplore [지연초=8]

import AppKit
import ApplicationServices
import Foundation

let delay = CommandLine.arguments.count > 1 ? (Double(CommandLine.arguments[1]) ?? 8) : 8
func log(_ s: String) { print(s) }

if delay > 0 {
    FileHandle.standardError.write(Data("\(Int(delay))초 뒤 탐침합니다. 대상 앱 본문에 커서를 두세요...\n".utf8))
    Thread.sleep(forTimeInterval: delay)
}

log("AXIsProcessTrusted: \(AXIsProcessTrusted())")

func copyAttr(_ el: AXUIElement, _ attr: String) -> CFTypeRef? {
    var v: CFTypeRef?
    return AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success ? v : nil
}
func attrNames(_ el: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyAttributeNames(el, &names) == .success,
          let arr = names as? [String] else { return [] }
    return arr
}
func role(_ el: AXUIElement) -> String { (copyAttr(el, "AXRole") as? String) ?? "?" }
func subrole(_ el: AXUIElement) -> String { (copyAttr(el, "AXSubrole") as? String) ?? "-" }
func children(_ el: AXUIElement) -> [AXUIElement] {
    (copyAttr(el, "AXChildren") as? [AXUIElement]) ?? []
}

// 포커스 요소 — systemWide는 셸 컨텍스트에서 -25204를 반환하므로(axgate 주석),
// 대상 앱 요소에서 넉넉한 타임아웃으로 직접 읽는다.
// 인자 2로 pid를 주면 최전면 여부와 무관하게 그 앱을 겨냥한다(코디네이션 제거).
let pid: pid_t = {
    if CommandLine.arguments.count > 2, let p = pid_t(CommandLine.arguments[2]) { return p }
    return NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
}()
let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
let sys = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(sys, 2.0)
guard let focusedRef = copyAttr(sys, "AXFocusedUIElement") else {
    log("대상: \(appName) [\(bundleID)] pid=\(pid)")
    log("포커스 요소 없음 (앱 요소에서도). 본문에 커서가 있는지 확인하세요.")
    exit(1)
}
let focused = focusedRef as! AXUIElement
log("대상: \(appName) [\(bundleID)] pid=\(pid)")
log("포커스 role=\(role(focused)) subrole=\(subrole(focused))")
log("포커스 속성: \(attrNames(focused).joined(separator: ", "))")

// 텍스트 신호를 담은 속성이 있나
for a in ["AXValue", "AXSelectedText", "AXNumberOfCharacters", "AXSelectedTextRange"] {
    if let v = copyAttr(focused, a) { log("  \(a) = \(v)") }
}

let appEl = AXUIElementCreateApplication(pid)

func setActivation(_ attr: String) {
    let r = AXUIElementSetAttributeValue(appEl, attr as CFString, kCFBooleanTrue)
    log("set \(attr) on app -> \(r == .success ? "성공" : "실패(\(r.rawValue))")")
}

// 텍스트 요소 하강 탐색 (BFS, 깊이 제한)
func findText(_ root: AXUIElement, maxNodes: Int = 4000) -> [(depth: Int, el: AXUIElement)] {
    var found: [(Int, AXUIElement)] = []
    var queue: [(Int, AXUIElement)] = [(0, root)]
    var seen = 0
    let textRoles: Set<String> = ["AXTextArea", "AXTextField", "AXComboBox", "AXStaticText"]
    while !queue.isEmpty, seen < maxNodes {
        let (d, el) = queue.removeFirst()
        seen += 1
        if textRoles.contains(role(el)) { found.append((d, el)) }
        if d < 12 { for c in children(el) { queue.append((d + 1, c)) } }
    }
    log("  탐색 노드 \(seen)개, 텍스트류 요소 \(found.count)개")
    return found
}

func dumpText(_ el: AXUIElement, label: String) {
    let val = (copyAttr(el, "AXValue") as? String) ?? ""
    let sel = (copyAttr(el, "AXSelectedText") as? String) ?? ""
    let n = (copyAttr(el, "AXNumberOfCharacters") as? Int)
    log("    [\(label)] role=\(role(el)) AXValue='\(val.prefix(40))' 선택='\(sel.prefix(20))' 글자수=\(n.map(String.init) ?? "nil")")
}

log("\n=== 1) 활성화 전 하강 탐색 ===")
for (d, el) in findText(focused) { dumpText(el, label: "focused하위 d\(d)") }
log("앱 루트에서도 탐색:")
for (d, el) in findText(appEl).prefix(8) { dumpText(el, label: "app하위 d\(d)") }

log("\n=== 2) 일반 활성화 속성 켜고 재측정 ===")
setActivation("AXManualAccessibility")
setActivation("AXEnhancedUserInterface")
Thread.sleep(forTimeInterval: 0.6)

// 포커스 다시
if let f2ref = copyAttr(sys, "AXFocusedUIElement") {
    let f2 = f2ref as! AXUIElement
    log("재측정 포커스 role=\(role(f2)) subrole=\(subrole(f2))")
    for (d, el) in findText(f2) { dumpText(el, label: "재측정 d\(d)") }
} else {
    log("재측정 포커스 없음")
}

log("\n=== 판정 ===")
log("텍스트류 요소가 하나라도 실제 AXValue를 주면 → 공통 하강/활성화로 지원 가능")
log("전부 빈 값·요소 없음 → 캔버스형(Illustrator 부류) 원리적 불가")
