import Foundation
import WinSDK

/// What the app does, written to %TEMP%\bezzle-trace.log when BEZZLE_TRACE is set: for trying
/// it in the test VM, where nothing else shows it.
enum Trace {
    static let on = ProcessInfo.processInfo.environment["BEZZLE_TRACE"] != nil
    private static let url = FileManager.default.temporaryDirectory.appendingPathComponent("bezzle-trace.log")

    /// When Windows made the process, for `time`.
    static let began: Date = {
        var made = FILETIME(), ended = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard GetProcessTimes(GetCurrentProcess(), &made, &ended, &kernel, &user) else { return Date() }
        // 100 ns ticks since 1601.
        let ticks = UInt64(made.dwHighDateTime) << 32 | UInt64(made.dwLowDateTime)
        return Date(timeIntervalSince1970: Double(ticks) / 10_000_000 - 11_644_473_600)
    }()

    /// A line with the milliseconds since the app began.
    static func time(_ what: @autoclosure () -> String) {
        guard on else { return }
        say("\(Int(Date().timeIntervalSince(began) * 1000)) ms: \(what())")
    }

    static func say(_ line: @autoclosure () -> String) {
        guard on else { return }
        let text = line() + "\n"
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(Data(text.utf8))
            try? handle.close()
        } else {
            try? Data(text.utf8).write(to: url)
        }
    }
}
