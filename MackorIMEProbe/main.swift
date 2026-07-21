import AppKit
import Carbon
import InputMethodKit

// MackorIMEProbe — P0 측정 전용 최소 IMK 입력기.
//
// 실행 형태 두 가지:
//   (인자 없음)      imklaunchagent가 입력 소스 선택 시 기동하는 정상 경로.
//   --register       [P0-8] 번들을 TISRegisterInputSource로 등록하고 종료.
//                    재로그인 없이 시스템 설정에 나타나는지가 측정 대상.
//   --enable         등록된 소스를 TISEnableInputSource까지 시도하고 종료.

let arguments = CommandLine.arguments

if arguments.contains("--register") || arguments.contains("--enable") {
    let bundleURL = Bundle.main.bundleURL
    let status = TISRegisterInputSource(bundleURL as CFURL)
    print("TISRegisterInputSource(\(bundleURL.path)) -> \(status) \(status == noErr ? "OK" : "FAIL")")
    ProbeLog.line("REGISTER: TISRegisterInputSource -> \(status)")

    if arguments.contains("--enable") {
        // 등록 직후 소스가 TIS 목록에 보이는지 + enable 가능한지 (P0-8)
        let probeIDs = [
            "com.mackor.inputmethod.MackorProbe",
            ProbeModeState.han2,
            ProbeModeState.roman,
        ]
        let list = TISCreateInputSourceList(nil, true).takeRetainedValue() as! [TISInputSource]
        for source in list {
            guard let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
            guard probeIDs.contains(id) else { continue }
            let enableStatus = TISEnableInputSource(source)
            print("visible: \(id)  TISEnableInputSource -> \(enableStatus)")
            ProbeLog.line("REGISTER: visible id=\(id) enable=\(enableStatus)")
        }
    }
    exit(0)
}

// 정상 기동 경로 — Squirrel식 수동 main (SwiftUI 공존은 P0-9에서 별도 측정)
let connectionName = "MackorProbe_Connection"
guard let identifier = Bundle.main.bundleIdentifier else {
    ProbeLog.line("FATAL: bundleIdentifier 없음")
    exit(1)
}

let app = NSApplication.shared
let server = IMKServer(name: connectionName, bundleIdentifier: identifier)
ProbeLog.line("IMKServer 기동: name=\(connectionName) id=\(identifier) server=\(server == nil ? "nil" : "ok")")
app.setActivationPolicy(.accessory)
app.run()
