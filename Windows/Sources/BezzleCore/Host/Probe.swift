import Foundation

/// Where the main thread's time goes while Animate is measured: named stretches of its work, each
/// timed and added up while a measure runs (a scrub or a watch of the Animate hooks, `BEZZLE_FILM`
/// in `Sources/Bezzle/AnimateHooks.swift`, or `bezzle-render`'s stage check), and one test of a
/// flag at any other time. What a scrub writes ends with these, the dearest first: the VM has no
/// profiler to ask instead, as `sample` is asked on the Mac.
///
/// Read and written on the main thread alone.
public enum Probe {
    nonisolated(unsafe) public static var on = false
    nonisolated(unsafe) public static var totals: [String: (seconds: Double, count: Int)] = [:]

    /// Begins a measure: nothing counted yet.
    public static func begin() {
        totals = [:]
        on = true
    }

    /// Does `f`, and while a measure runs adds the time it took to what is counted under `name`.
    @inline(__always)
    public static func time<T>(_ name: String, _ f: () throws -> T) rethrows -> T {
        guard on else { return try f() }
        let a = WindowsCore.now
        defer {
            let d = WindowsCore.now - a
            var had = totals[name] ?? (0, 0)
            had.seconds += d
            had.count += 1
            totals[name] = had
        }
        return try f()
    }

    /// Ends the measure and says what was counted, a line each, as parts of `seconds` that passed.
    /// Stretches lie inside one another (a frame's holds its pictures'), so they add up to more.
    public static func end(over seconds: Double) -> String {
        on = false
        return totals.sorted { $0.value.seconds > $1.value.seconds }.map {
            String(format: "  %@: %.0f ms in %d (%.2f ms each, %.0f %% of the time)", $0.key, $0.value.seconds * 1000, $0.value.count,
                   $0.value.seconds * 1000 / Double(max($0.value.count, 1)), $0.value.seconds / max(seconds, 1e-6) * 100)
        }.joined(separator: "\n") + "\n"
    }
}
