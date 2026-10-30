import AppKit
import os

/// One copy of Bezzle at a time. With several copies on a Mac, one in Downloads and one in
/// Applications say, a second may be started while the first is running: by a double click, or
/// by iCloud, which picks a copy to open an invitation with. Two copies would save the same
/// designs over each other, and macOS is slow to show a second copy's windows, or never does. So
/// a copy that finds another running asks it to take over, passes it the designs and invitations
/// it was opened with, and quits.
///
/// Only a copy using the same iCloud takes over: one built for the other iCloud environment, as
/// Xcode's builds are, keeps its own designs apart and runs alongside. Copies started with
/// BEZZLE_LIBRARY, for tests, keep to themselves both ways.
enum HandOver {
    private enum Name {
        static let ask = Notification.Name("com.erik.Bezzle.handOver.ask")
        static let ready = Notification.Name("com.erik.Bezzle.handOver.ready")
        static let items = Notification.Name("com.erik.Bezzle.handOver.items")
    }

    private enum State { case asking, alone, handing(to: pid_t) }

    private static var state = State.alone
    private static var waiting: (paths: [String], links: [String]) = ([], [])
    private static var whenAlone: [() -> Void] = []
    private static var observers: [NSObjectProtocol] = []

    private static var center: DistributedNotificationCenter { .default() }
    private nonisolated static let log = Logger(subsystem: "com.erik.Bezzle", category: "HandOver")
    private nonisolated static var me: pid_t { ProcessInfo.processInfo.processIdentifier }

    private static var keepsToItself: Bool {
        BezzleApp.isTesting || ProcessInfo.processInfo.environment["BEZZLE_LIBRARY"] != nil
    }

    private static var environment: String { CloudSync.isAvailable ? CloudSync.environment : "none" }

    /// At launch, before anything is opened: asks whether another copy is there to take over.
    static func start() {
        guard !keepsToItself else { return }
        listen()
        guard let id = Bundle.main.bundleIdentifier,
              NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: { $0.processIdentifier != me && !$0.isTerminated })
        else { return }
        state = .asking
        log.notice("Another copy is running; asking it to take over")
        observers.append(center.addObserver(forName: Name.ready, object: nil, queue: .main) { note in
            guard let info = note.userInfo, info["to"] as? Int == Int(me), let from = info["from"] as? Int else { return }
            MainActor.assumeIsolated { handOver(to: pid_t(from)) }
        })
        center.postNotificationName(Name.ask, object: nil, userInfo: ["from": Int(me), "environment": environment], deliverImmediately: true)
        // No one answering means no copy that takes over: this one carries on by itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            guard case .asking = state else { return }
            log.notice("No copy took over; carrying on alone")
            state = .alone
            flush()
        }
    }

    /// Does `work` once it is known that this copy carries on by itself, at once if it is.
    static func whenRunningAlone(_ work: @escaping () -> Void) {
        if case .alone = state { work() } else { whenAlone.append(work) }
    }

    /// Designs to open. Returns whether they were passed on, or will be.
    static func pass(designs urls: [URL]) -> Bool {
        pass(paths: urls.map(\.path), links: [])
    }

    /// An invitation, as its link. Returns whether it was passed on, or will be.
    static func pass(invitation link: URL) -> Bool {
        pass(paths: [], links: [link.absoluteString])
    }

    private static func pass(paths: [String], links: [String]) -> Bool {
        switch state {
        case .alone:
            return false
        case .asking:
            waiting.paths += paths
            waiting.links += links
            return true
        case .handing(let target):
            send(paths: paths, links: links, to: target)
            return true
        }
    }

    // MARK: The copy handing over

    private static func handOver(to target: pid_t) {
        guard case .asking = state else { return }
        log.notice("Handing over to \(target)")
        state = .handing(to: target)
        whenAlone = []
        send(paths: waiting.paths, links: waiting.links, to: target)
        waiting = ([], [])
        if let other = NSRunningApplication(processIdentifier: target) {
            NSApp.yieldActivation(to: other)
            other.activate()
        }
        // A moment for what macOS hands this copy just after launch, an invitation above all,
        // to come and be passed on.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { NSApp.terminate(nil) }
    }

    private static func send(paths: [String], links: [String], to target: pid_t) {
        guard !paths.isEmpty || !links.isEmpty else { return }
        center.postNotificationName(Name.items, object: nil, userInfo: ["to": Int(target), "paths": paths, "links": links], deliverImmediately: true)
    }

    private static func flush() {
        let work = whenAlone
        whenAlone = []
        work.forEach { $0() }
        let (paths, links) = waiting
        waiting = ([], [])
        paths.forEach { WindowRouter.shared.open(URL(fileURLWithPath: $0)) }
        links.compactMap(URL.init(string:)).forEach { CloudSync.shared.accept(link: $0) }
    }

    // MARK: The copy taking over

    private static func listen() {
        observers.append(center.addObserver(forName: Name.ask, object: nil, queue: .main) { note in
            guard let info = note.userInfo, let from = info["from"] as? Int, from != Int(me) else { return }
            let theirs = info["environment"] as? String
            MainActor.assumeIsolated {
                log.notice("Copy \(from) asks to hand over; environment \(theirs ?? "?", privacy: .public)")
                guard case .alone = state, theirs == environment else { return }
                center.postNotificationName(Name.ready, object: nil, userInfo: ["to": from, "from": Int(me)], deliverImmediately: true)
            }
        })
        observers.append(center.addObserver(forName: Name.items, object: nil, queue: .main) { note in
            guard let info = note.userInfo, info["to"] as? Int == Int(me) else { return }
            let paths = info["paths"] as? [String] ?? [], links = info["links"] as? [String] ?? []
            MainActor.assumeIsolated {
                NSApp.activate()
                paths.forEach { WindowRouter.shared.open(URL(fileURLWithPath: $0)) }
                links.compactMap(URL.init(string:)).forEach { CloudSync.shared.accept(link: $0) }
            }
        })
    }
}
