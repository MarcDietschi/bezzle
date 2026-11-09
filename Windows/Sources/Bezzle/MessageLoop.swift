import Foundation
import WinSDK
import WinUI
import WinAppSDK

/// Bezzle's own message loop, in place of the WinUI package's (`BezzleApp.runLoop`): Windows'
/// messages, then what Foundation has due (its timers, and the work sent to the main queue,
/// Swift's main actor among it), then sleep until any of them has more.
///
/// The package's loop never slept: it asked Windows to wait `DWORD(exactly:)` of a fraction of a
/// second, which is nil for anything but whole seconds, so it waited for nothing and one core ran
/// flat out for as long as Bezzle was open. And it took every message waiting before Foundation's
/// turn, so a stream of them, as through a drag, held up timers for as long as it lasted.
@MainActor
enum MessageLoop {
    private typealias PreTranslate = @convention(c) (UnsafePointer<MSG>?) -> Bool
    /// What WinUI's own loop asks first of every message, for the keyboard's focus and shortcuts.
    private static let preTranslate: PreTranslate? = {
        guard let dll = LoadLibraryA("Microsoft.UI.Windowing.Core.dll"),
              let function = GetProcAddress(dll, "ContentPreTranslateMessage") else { return nil }
        return unsafeBitCast(function, to: PreTranslate.self)
    }()

    private typealias HandleGetter = @convention(c) () -> HANDLE?
    /// The event libdispatch sets when work comes for the main queue from another thread: the one
    /// Foundation's run loop looks at to know it has work to do.
    private static let mainQueueEvent: HANDLE? = {
        guard let dll = LoadLibraryA("dispatch.dll"),
              let function = GetProcAddress(dll, "_dispatch_get_main_queue_handle_4CF") else { return nil }
        return unsafeBitCast(function, to: HandleGetter.self)()
    }()

    /// How long messages are taken at a time before Foundation has its turn.
    private static let messagesAtOnce: Swift.Duration = .milliseconds(8)

    static func run(_ queue: DispatcherQueue) -> Int32 {
        var msg = MSG()
        // Foundation's next timer as a waitable timer of fine resolution (Windows 10 1803 and
        // later): a wait's own timeout is counted in the system's 15.6 ms ticks, which would let
        // the live room's thirty times a second come at 31 and 47 ms.
        let timer = CreateWaitableTimerExW(nil, nil, DWORD(0x2) /* CREATE_WAITABLE_TIMER_HIGH_RESOLUTION */, DWORD(0x1F_0003) /* TIMER_ALL_ACCESS */)
        // The main queue's event first, so that a wait ending on it ends with 0.
        let handles: [HANDLE?] = [mainQueueEvent, timer].filter { $0 != nil }
        while true {
            let began = ContinuousClock.now
            while PeekMessageW(&msg, nil, 0, 0, UINT(PM_REMOVE)) {
                if msg.message == UINT(WM_QUIT) { return Int32(msg.wParam) }
                if !(preTranslate?(&msg) ?? false) {
                    TranslateMessage(&msg)
                    DispatchMessageW(&msg)
                }
                if ContinuousClock.now - began > messagesAtOnce { break }
            }

            // Foundation's turn: the timers due and the main queue's work, and once more should a
            // timer have fallen due meanwhile.
            var next = RunLoop.main.limitDate(forMode: .default)
            if let date = next, date.timeIntervalSinceNow <= 0 { next = RunLoop.main.limitDate(forMode: .default) }

            // Asleep until a message comes (or one is still waiting), the main queue has work, or
            // the next timer is due. Alertable: WinUI's pointer input reaches the thread as work
            // that runs only in an alertable wait (Foundation's own is one), and without it the
            // pointer waited for the next timer, up to a second and more.
            var timeout = DWORD.max
            if let date = next, date.timeIntervalSinceNow < 1_000_000 {
                // A timer Foundation says is due and has not fired yet waits for its own clock,
                // which runs in Windows' 15.6 ms ticks: a millisecond's sleep at a time, as asking
                // it again at once kept the core busy until then, thirty times a second in a
                // shared design.
                let seconds = max(date.timeIntervalSinceNow, 0.001)
                if let timer {
                    var due = LARGE_INTEGER(QuadPart: -max(1, Int64(seconds * 10_000_000)))
                    if !SetWaitableTimer(timer, &due, 0, nil, nil, false) { timeout = DWORD(min(ceil(seconds * 1000), 3_600_000)) }
                } else {
                    timeout = DWORD(min(ceil(seconds * 1000), 3_600_000))
                }
            } else if let timer {
                CancelWaitableTimer(timer)
            }
            let woke = handles.withUnsafeBufferPointer { h in
                MsgWaitForMultipleObjectsEx(DWORD(h.count), h.baseAddress, timeout, DWORD(QS_ALLINPUT), DWORD(MWMO_INPUTAVAILABLE | MWMO_ALERTABLE))
            }
            // The wait took the main queue's signal: it is given back, for Foundation's run loop
            // to see as it always has, and to do the work.
            if let event = mainQueueEvent, woke == 0 { SetEvent(event) }
        }
    }
}
