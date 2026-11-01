import Foundation
import AppKit

/// Where the live relay is: the Cloudflare Worker in Relay/, deployed with `wrangler deploy`. Its
/// address goes into Info.plist as BezzleLiveRelay; without one, shared designs sync through
/// iCloud alone, as before.
enum LiveRelay {
    static var address: URL? {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["BEZZLE_LIVE_RELAY"] { return URL(string: override) }
        #endif
        guard let text = Bundle.main.object(forInfoDictionaryKey: "BezzleLiveRelay") as? String, !text.isEmpty else { return nil }
        return URL(string: text)
    }
}

/// How a room's connection to the relay is.
enum LiveLink: Equatable {
    case connecting
    case live
    /// Lost; trying again in a moment.
    case away
}

/// What carries frames to the relay and back: a WebSocket, or in tests, a relay of their own.
protocol LiveTransport: AnyObject {
    var onFrame: ((LiveFrame) -> Void)? { get set }
    var onLink: ((LiveLink) -> Void)? { get set }
    func start()
    /// Sends a frame. One that can be dropped, such as where the pointer is, is left out when
    /// the network is behind, as the next one will say the same more recently.
    func send(_ frame: Data, droppable: Bool)
    func stop()
}

/// A room's WebSocket to the relay. It keeps itself open: it pings, notices when nothing comes
/// back, tries again a little later each time, and at once when the Mac wakes.
final class LiveSocket: LiveTransport {
    var onFrame: ((LiveFrame) -> Void)?
    var onLink: ((LiveLink) -> Void)?

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    /// Counts connections, so what an old one says late is not taken for the new one's.
    private var generation = 0
    private var attempt = 0
    private var stopped = true
    /// Once stopped, it never starts again: its session is gone.
    private var finished = false
    private var lastHeard = Date()
    private var inFlight = 0
    private var pinger: Timer?
    private var retry: Timer?
    private var wake: NSObjectProtocol?

    init(room: String, relay: URL) {
        url = relay.appendingPathComponent("v1").appendingPathComponent(room)
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
    }

    func start() {
        guard stopped, !finished else { return }
        stopped = false
        wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconnect(now: true) }
        }
        connect()
    }

    func stop() {
        stopped = true
        finished = true
        pinger?.invalidate()
        retry?.invalidate()
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }
        wake = nil
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session.invalidateAndCancel()
    }

    private func connect() {
        guard !stopped else { return }
        generation += 1
        let generation = generation
        onLink?(.connecting)
        var request = URLRequest(url: url)
        request.setValue("1", forHTTPHeaderField: "X-Bezzle-Live")
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 1 << 20
        self.task = task
        inFlight = 0
        lastHeard = Date()
        task.resume()
        listen(task, generation)
        pinger?.invalidate()
        pinger = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ping(generation) }
        }
    }

    private func listen(_ task: URLSessionWebSocketTask, _ generation: Int) {
        Task { [weak self] in
            while true {
                let message: URLSessionWebSocketTask.Message
                do {
                    message = try await task.receive()
                } catch {
                    guard let self, self.generation == generation else { return }
                    CloudSync.log.info("Live relay connection ended: \(error.localizedDescription, privacy: .public)")
                    self.reconnect(now: false)
                    return
                }
                guard let self, self.generation == generation else { return }
                self.lastHeard = Date()
                switch message {
                case .data(let data):
                    guard let frame = LiveFrame.read(data) else { continue }
                    if case .welcome = frame {
                        self.attempt = 0
                        self.onLink?(.live)
                    }
                    self.onFrame?(frame)
                case .string:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    private func ping(_ generation: Int) {
        guard generation == self.generation, let task else { return }
        // The relay answers every ping: nothing for a while means the connection is gone, even
        // when the network has not said so, as after a change of Wi-Fi.
        if Date().timeIntervalSince(lastHeard) > 25 {
            reconnect(now: true)
            return
        }
        task.send(.string("ping")) { _ in }
    }

    func send(_ frame: Data, droppable: Bool) {
        guard let task, !stopped else { return }
        if droppable && inFlight > 6 { return }
        inFlight += 1
        let generation = generation
        task.send(.data(frame)) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.generation == generation else { return }
                self.inFlight = max(0, self.inFlight - 1)
            }
        }
    }

    private func reconnect(now: Bool) {
        guard !stopped else { return }
        generation += 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        pinger?.invalidate()
        onLink?(.away)
        retry?.invalidate()
        let delay = now ? 0.1 : min(15, 0.5 * pow(2, Double(attempt))) * Double.random(in: 0.8...1.2)
        attempt += 1
        retry = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.connect() }
        }
    }
}
