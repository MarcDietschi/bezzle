import Foundation
import CoreGraphics

/// Draws the canvas's tiles away from the main thread, on as many threads as there are cores to
/// spare, so that moving about a design never waits for one to be drawn: what is in sight first,
/// the newest wanted first, and what is no longer wanted by the time a thread is free not at all.
/// Each thread keeps to itself what it lays out, as Text Kit asks.
nonisolated final class TileMaker: @unchecked Sendable {
    static let shared = TileMaker(threads: max(2, ProcessInfo.processInfo.activeProcessorCount - 2))

    /// A tile, by whose it is and where: one canvas's tiles are not another's.
    struct Key: Hashable, Sendable {
        let owner: ObjectIdentifier
        let board: UUID
        let step: CGFloat
        let i: Int
        let j: Int
    }

    /// How much a tile is wanted: one in sight before the picture of a whole artboard, which
    /// stands in for tiles to come, and that before one just out of sight.
    enum Urgency: Int, Sendable {
        case around, whole, sight
    }

    private struct Job {
        let draw: @Sendable () -> CGImage?
        let done: @MainActor @Sendable (CGImage?) -> Void
        let frame: UInt64
        let urgency: Urgency
        let order: Int
    }

    private struct Made: @unchecked Sendable { let image: CGImage? }

    private let lock = NSCondition()
    private var waiting: [Key: Job] = [:]
    /// Being drawn, or drawn and on its way to the main thread: not wanted again meanwhile.
    private var drawing: Set<Key> = []
    /// Each canvas's frame, counted.
    private var frames: [ObjectIdentifier: UInt64] = [:]
    private var order = 0

    init(threads: Int) {
        for n in 0..<threads {
            let thread = Thread { [unowned self] in self.work() }
            thread.name = "Bezzle tiles \(n + 1)"
            thread.qualityOfService = .userInitiated
            // As deep as a design's groups go, as the main thread's.
            thread.stackSize = 8 << 20
            thread.start()
        }
    }

    /// Starts a frame for a canvas, on the main thread: what it wanted in the frame before and
    /// did not want again in the one just ended is let go.
    func begin(_ owner: ObjectIdentifier) {
        lock.lock()
        defer { lock.unlock() }
        let frame = (frames[owner] ?? 0) + 1
        frames[owner] = frame
        waiting = waiting.filter { $0.key.owner != owner || $0.value.frame + 1 >= frame }
    }

    /// Wants a tile drawn, on the main thread, again on every frame it is still wanted: the
    /// newest asking stands. `done` is told on the main thread, with the picture.
    func want(_ key: Key, _ urgency: Urgency, draw: @escaping @Sendable () -> CGImage?, done: @escaping @MainActor @Sendable (CGImage?) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !drawing.contains(key) else { return }
        let first = waiting[key] == nil
        order += 1
        waiting[key] = Job(draw: draw, done: done, frame: frames[key.owner] ?? 0, urgency: urgency, order: waiting[key]?.order ?? order)
        if first { lock.signal() }
    }

    private func work() {
        while true {
            lock.lock()
            while waiting.isEmpty { lock.wait() }
            // The most urgent of what was wanted last, in the order it was first asked for.
            let (key, job) = waiting.max { a, b in
                (a.value.frame, a.value.urgency.rawValue, -a.value.order) < (b.value.frame, b.value.urgency.rawValue, -b.value.order)
            }!
            waiting[key] = nil
            drawing.insert(key)
            lock.unlock()
            let made = Made(image: autoreleasepool { job.draw() })
            Self.onMain {
                self.lock.withLock { _ = self.drawing.remove(key) }
                job.done(made.image)
            }
        }
    }

    /// Runs `body` on the main thread at its run loop's next turn, in any mode: also while the
    /// main thread turns its run loop itself from inside other work, as a test or a stress run
    /// does, where what is sent to the main queue waits until that work is done.
    static func onMain(_ body: @escaping @MainActor @Sendable () -> Void) {
        let main = CFRunLoopGetMain()
        CFRunLoopPerformBlock(main, CFRunLoopMode.commonModes.rawValue) { MainActor.assumeIsolated(body) }
        CFRunLoopWakeUp(main)
    }
}

/// A value kept behind a lock, for what the canvas's tiles share as they are drawn side by side
/// on several threads: whoever holds it has it to themselves until they let go.
nonisolated final class Shared<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()

    init(_ value: Value) { self.value = value }

    func with<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }
}
