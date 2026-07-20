import Foundation

/// P0 측정 전용 로거. `~/mackor-probe.log`에 즉시 append한다.
/// 프로브는 측정 도구이므로 버퍼링 없이 한 줄씩 기록한다.
enum ProbeLog {
    static let path = NSString(string: "~/mackor-probe.log").expandingTildeInPath

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    static func line(_ message: String) {
        let text = "[\(formatter.string(from: Date()))] \(message)\n"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(text.utf8))
        }
    }

    static func range(_ r: NSRange) -> String {
        if r.location == NSNotFound { return "NSNotFound" }
        return "(\(r.location),\(r.length))"
    }
}
