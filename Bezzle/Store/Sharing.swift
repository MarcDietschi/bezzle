import AppKit
import CryptoKit
import Observation
import os

/// Shares designs by link, through Bezzle's relay on Cloudflare: anyone with the link can work on
/// the design with the others, from Bezzle on a Mac or in a browser, with no account of any kind.
/// The design stays wherever it is kept; sharing gives it a room on the relay, where every copy
/// keeps records of its own changes, sealed before they leave it with a key only the link holds,
/// so that the relay keeps what it cannot read (see Relay/SHARING.md and `CloudShare`).
///
/// The Mac that shared a design is its owner: only it can stop sharing it. The others then keep
/// the design as it last was, to look at and to save a copy of.
@Observable
final class Sharing {
    static let shared = Sharing()

    /// What sharing does, in the system log: `log show --predicate 'subsystem == "com.erik.Bezzle"'`.
    nonisolated static let log = Logger(subsystem: "com.erik.Bezzle", category: "Sharing")

    /// Whether this copy of Bezzle has a relay to share through.
    static var isAvailable: Bool { LiveRelay.address != nil }

    /// A shared design being fetched for the first time, from a link just opened, as the home
    /// screen shows it.
    struct Arrival: Equatable {
        var title: String
        var owner: String?
    }

    /// Those on their way, by room.
    private(set) var arriving: [String: Arrival] = [:]
    /// Why the last link could not be opened, until the next one.
    var invitationProblem: String?

    /// How far a design is in getting everything to the relay before its link is handed out.
    struct Upload: Equatable {
        var done = 0
        var total = 0
    }

    private(set) var preparing: [URL: Upload] = [:]

    /// The relay: the one in Info.plist, or in tests one of their own, never the real one.
    @ObservationIgnored var server: ShareServer? = BezzleApp.isTesting ? nil : LiveRelay.address.map { RelayServer(base: $0) }

    // MARK: Who this Mac is

    /// This Mac's name among those sharing a design. It is made once, and again on another Mac
    /// even when the settings come across with Migration Assistant, so two Macs never share one.
    static let replica: String = {
        #if DEBUG
        // Two test copies on one Mac share their settings; each says who it is.
        if let id = ProcessInfo.processInfo.environment["BEZZLE_REPLICA"] { return id }
        #endif
        let defaults = Library.settings
        let host = hostID()
        if let id = defaults.string(forKey: "sharingReplica"), defaults.string(forKey: "sharingHost") == host { return id }
        let letters = Array("0123456789abcdefghijklmnopqrstuvwxyz")
        let id = String((0..<16).map { _ in letters.randomElement()! })
        defaults.set(id, forKey: "sharingReplica")
        defaults.set(host, forKey: "sharingHost")
        return id
    }()

    private static func hostID() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        var wait = timespec(tv_sec: 0, tv_nsec: 0)
        guard gethostuuid(&bytes, &wait) == 0 else { return "" }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Which design is which

    /// Each shared design's room, with where the design is on this Mac.
    private var index: [String: String] {
        get { Library.settings.dictionary(forKey: "sharedRooms") as? [String: String] ?? [:] }
        set { Library.settings.set(newValue, forKey: "sharedRooms") }
    }

    func url(of room: String) -> URL? {
        index[room].map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Whether the design at `url` is this Mac's copy of `room`. A copy of it made in the Finder
    /// is not, while the copy this Mac has is still there.
    func claim(_ room: String, at url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if let known = index[room], known != path, FileManager.default.fileExists(atPath: known),
           SharingFiles.link(of: URL(fileURLWithPath: known))?.keys?.room == room { return false }
        index[room] = path
        return true
    }

    /// What this Mac keeps of each room it has a part in, never in the design: the token its
    /// records are written with, and for those it shared, the owner's.
    private var tokens: [String: [String: String]] {
        get { Library.settings.dictionary(forKey: "shareTokens") as? [String: [String: String]] ?? [:] }
        set { Library.settings.set(newValue, forKey: "shareTokens") }
    }

    /// The token this Mac writes its records in `room` with, made the first time.
    func writer(for room: String) -> String {
        if let token = tokens[room]?["writer"] { return token }
        let token = ShareKeys.newSecret().base64URL
        tokens[room, default: [:]]["writer"] = token
        return token
    }

    func ownerToken(for room: String) -> String? { tokens[room]?["owner"] }

    /// This Mac shared the design whose room this is, and can stop sharing it with `token`.
    func own(_ room: String, with token: String) {
        tokens[room, default: [:]]["owner"] = token
    }

    /// Whether this Mac shared the design whose room this is.
    func owns(_ room: String) -> Bool { ownerToken(for: room) != nil }

    nonisolated static func hash(_ token: String) -> String { Data(SHA256.hash(data: Data(token.utf8))).hex }

    // MARK: Sharing a design

    /// Puts the design's link on the pasteboard, sharing it first if it is not yet, once
    /// everything in it is on the relay; returns whether it did. Anyone with the link can work
    /// on the design.
    func copyLink(for store: DocumentStore) async -> Bool {
        let key = store.url
        guard preparing[key] == nil else { return false }
        preparing[key] = Upload()
        defer { preparing[key] = nil }
        do {
            let link = try await share(store)
            guard let page = link.page else { throw SharingError(message: String(localized: "The design could not be shared.")) }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(page.absoluteString, forType: .string)
            Self.log.notice("Copied the link to \(store.name, privacy: .public)")
            return true
        } catch {
            Self.log.error("Could not share \(store.name, privacy: .public): \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(store.name)” could not be shared")
            alert.informativeText = (error as? SharingError)?.message ?? String(localized: "Bezzle could not connect. Check the connection and try again.")
            if let window = store.canvas?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            return false
        }
    }

    /// Gives the design a room on the relay, if it has none, and sends everything in it there.
    private func share(_ store: DocumentStore) async throws -> ShareLink {
        guard let server else { throw SharingError(message: String(localized: "This copy of Bezzle cannot share designs.")) }
        guard !store.isReadOnly else { throw SharingError(message: String(localized: "This design is no longer shared with you. Save a copy of it to share that.")) }
        store.save()
        DocumentStore.finishSaving()
        if !DesignFile.isPackage(store.url) {
            try DesignFile.makePackage(store.url)
            store.becamePackage()
        }
        if let session = store.sharing, let link = session.link, let cloud = session.cloud {
            try await cloud.sendEverything { done, total in self.preparing[store.url] = Upload(done: done, total: total) }
            return link
        }
        let secret = ShareKeys.newSecret()
        guard let keys = ShareKeys(secret: secret) else { throw SharingError(message: String(localized: "The design could not be shared.")) }
        let owner = ShareKeys.newSecret().base64URL
        try await server.create(keys.room, hashes: ["read": Self.hash(keys.readToken), "write": Self.hash(keys.writeToken), "owner": Self.hash(owner)])
        own(keys.room, with: owner)
        let link = ShareLink(secret: secret.base64URL, title: store.name, ownerName: LiveRoom.myName)
        try SharingFiles.write(link, to: store.url)
        _ = claim(keys.room, at: store.url)
        let session: Collaboration
        if let open = store.sharing {
            session = open
            session.shared(link)
        } else {
            guard let made = Collaboration.open(store.url) else { throw SharingError(message: String(localized: "The design could not be shared.")) }
            _ = made.document()
            store.sharing = made
            made.attach(to: store)
            session = made
        }
        guard let cloud = session.cloud else { throw SharingError(message: String(localized: "The design could not be shared.")) }
        try await cloud.sendMeta(ShareMeta(title: store.name, owner: LiveRoom.myName, made: Collaboration.now))
        try await cloud.sendEverything { done, total in self.preparing[store.url] = Upload(done: done, total: total) }
        Library.shared.refresh()
        Self.log.notice("Shared \(store.name, privacy: .public) in room \(keys.room.prefix(8), privacy: .public)")
        return link
    }

    /// Stops sharing a design this Mac shared: its room on the relay goes, with everything in it,
    /// and the others keep the design as it last was. Here it goes on as a design of its own.
    func stopSharing(_ store: DocumentStore) async -> Bool {
        guard let session = store.sharing, let cloud = session.cloud, let owner = ownerToken(for: cloud.keys.room), let server else { return false }
        do {
            try await server.unshare(cloud.keys.room, write: cloud.keys.writeToken, owner: owner)
        } catch ShareError.gone {
            // Gone already.
        } catch {
            Self.log.error("Could not stop sharing \(store.name, privacy: .public): \(String(describing: error), privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "Bezzle could not stop sharing “\(store.name)”")
            alert.informativeText = String(localized: "Bezzle could not connect. Check the connection and try again.")
            if let window = store.canvas?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            return false
        }
        forget(cloud.keys.room)
        session.unshared(own: true)
        Self.log.notice("Stopped sharing \(store.name, privacy: .public)")
        return true
    }

    /// Stops sharing a design this Mac shared that is not open, as when it goes to the Trash: the
    /// others keep it as it last was. Should the relay not be reached, it is tried again whenever
    /// Bezzle comes to the front, until it is.
    func stopSharing(designAt url: URL) {
        guard let keys = SharingFiles.link(of: url)?.keys, let owner = ownerToken(for: keys.room) else { return }
        stopping[keys.room] = ["write": keys.writeToken, "owner": owner]
        stopWhatIsLeft()
    }

    /// Rooms to stop sharing, with what that takes, until the relay has heard.
    private var stopping: [String: [String: String]] {
        get { Library.settings.dictionary(forKey: "sharesToStop") as? [String: [String: String]] ?? [:] }
        set { Library.settings.set(newValue, forKey: "sharesToStop") }
    }

    private func stopWhatIsLeft() {
        guard let server else { return }
        for (room, tokens) in stopping {
            guard let write = tokens["write"], let owner = tokens["owner"] else { continue }
            Task {
                do {
                    try await server.unshare(room, write: write, owner: owner)
                } catch ShareError.gone, ShareError.missing {
                } catch {
                    Self.log.error("Could not stop sharing a design in the Trash yet: \(String(describing: error), privacy: .public)")
                    return
                }
                stopping[room] = nil
                forget(room)
            }
        }
    }

    private func forget(_ room: String) {
        tokens[room] = nil
        index[room] = nil
    }

    // MARK: Opening a link

    /// Where Bezzle's website is, and was until 7 November 2026: links made before then lead to
    /// mfrports.github.io/bezzle-web, which sends them on to bezzle.ch.
    nonisolated static let websites: Set<String> = ["bezzle.ch", "www.bezzle.ch", "mfrports.github.io"]

    /// The secret in a design's link: `bezzle://share/2.<secret>`, or Bezzle's page on the web with
    /// it after the #. Anything else is not a design's link.
    nonisolated static func secret(from url: URL) -> String? {
        let token: String
        switch url.scheme?.lowercased() {
        case "bezzle":
            guard url.host()?.lowercased() == "share" else { return nil }
            token = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case "https":
            guard let host = url.host()?.lowercased(), websites.contains(host), let fragment = url.fragment(percentEncoded: false) else { return nil }
            token = fragment
        default:
            return nil
        }
        guard token.hasPrefix("2.") else { return nil }
        let secret = String(token.dropFirst(2))
        return ShareKeys(link: secret) != nil ? secret : nil
    }

    /// A design's link was opened: the design comes from the relay into the designs folder and
    /// opens, its pictures following. One here already just opens. What went wrong shows on the
    /// home screen, as nobody would see it anywhere else.
    func accept(link url: URL) {
        guard let secret = Self.secret(from: url), let keys = ShareKeys(link: secret) else {
            notAccepted(String(localized: "This link does not lead to a design."))
            return
        }
        let room = keys.room
        if let known = self.url(of: room), SharingFiles.link(of: known)?.keys?.room == room {
            WindowRouter.shared.open(known)
            return
        }
        guard let server, arriving[room] == nil else { return }
        Self.log.notice("Opening a link to room \(room.prefix(8), privacy: .public)")
        arriving[room] = Arrival(title: String(localized: "Shared Design"), owner: nil)
        invitationProblem = nil
        WindowRouter.shared.showHome()
        Task {
            do {
                let arrived = try await CloudShare.download(keys, from: server) { meta in
                    self.arriving[room] = Arrival(title: meta.title, owner: meta.owner)
                }
                let url = try make(arrived, secret: secret, keys: keys)
                arriving[room] = nil
                Library.shared.touched(url)
                WindowRouter.shared.open(url)
            } catch {
                arriving[room] = nil
                Self.log.error("Could not open the link: \(String(describing: error), privacy: .public)")
                switch error {
                case ShareError.gone: notAccepted(String(localized: "This design is no longer shared."))
                case ShareError.missing: notAccepted(String(localized: "This link does not lead to a design."))
                default: notAccepted(String(localized: "Bezzle could not reach the design. Check the connection and open the link again."))
                }
            }
        }
    }

    /// Makes the design that came from a link in the designs folder.
    private func make(_ arrived: CloudShare.Arrived, secret: String, keys: ShareKeys) throws -> URL {
        let title = arrived.meta?.title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-") ?? ""
        let url = Library.shared.freeURL(named: title.isEmpty ? String(localized: "Shared Design") : title, in: Library.shared.folder)
        try DesignFile.write(arrived.state.flatDesign().document(), to: url)
        try SharingFiles.write(ShareLink(secret: secret, title: arrived.meta?.title, ownerName: arrived.meta?.owner), to: url)
        _ = claim(keys.room, at: url)
        guard FolderSync.open(url, replica: Self.replica, seed: arrived.state) != nil else { throw SharingError(message: String(localized: "The design could not be kept.")) }
        CloudShare.keep(arrived.progress, of: url, replica: Self.replica)
        return url
    }

    private func notAccepted(_ problem: String) {
        Self.log.error("Could not open a link: \(problem, privacy: .public)")
        invitationProblem = problem
        WindowRouter.shared.showHome()
    }

    /// Every open shared design looks for what is new, as when Bezzle comes to the front.
    func lookNow() {
        for store in Tabs.shared.designs.compactMap(\.store) { store.sharing?.cloud?.syncSoon() }
        stopWhatIsLeft()
    }

    #if DEBUG
    /// Forgets that this Mac shared the room, for tests in which one process stands for two Macs.
    func disownForTesting(_ room: String) { tokens[room]?["owner"] = nil }

    func pretendArriving(_ title: String, from owner: String?) {
        arriving["debug-\(title)"] = Arrival(title: title, owner: owner)
    }
    #endif
}

/// Something that stops a design being shared, in words for the person sharing it.
struct SharingError: Error {
    let message: String
}

// MARK: - The relay

/// What went wrong with the relay.
nonisolated enum ShareError: Error, Equatable {
    /// The room was unshared.
    case gone
    /// There is no such room, or no such record.
    case missing
    /// The relay would not take what was sent, with its status.
    case refused(Int)
    /// The relay could not be reached.
    case unreachable
}

/// A room's records, as the relay lists them.
nonisolated struct ShareListing: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        var key: String
        var seq: Int64
        var size: Int
    }

    var seq: Int64
    var records: [Entry]
}

/// The relay's rooms, as Relay/SHARING.md has them; in tests, one kept in memory.
nonisolated protocol ShareServer: AnyObject, Sendable {
    func create(_ room: String, hashes: [String: String]) async throws
    func list(_ room: String, since: Int64, read: String) async throws -> ShareListing
    /// A record, or nil when there is none.
    func get(_ room: String, _ key: String, read: String) async throws -> Data?
    func put(_ room: String, _ key: String, _ body: Data, write: String, writer: String?, owner: String?) async throws
    func delete(_ room: String, _ key: String, write: String, writer: String) async throws
    func unshare(_ room: String, write: String, owner: String) async throws
}

/// Bezzle's relay on Cloudflare, over HTTPS.
nonisolated final class RelayServer: ShareServer {
    let base: URL
    private let session: URLSession

    init(base relay: URL) {
        var parts = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        if parts.scheme == "wss" { parts.scheme = "https" } else if parts.scheme == "ws" { parts.scheme = "http" }
        base = parts.url!
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
    }

    private func url(_ room: String, _ key: String? = nil, since: Int64? = nil) -> URL {
        var url = base.appendingPathComponent("v2").appendingPathComponent(room)
        if let key { url = url.appendingPathComponent(key) }
        guard let since, var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        parts.queryItems = [URLQueryItem(name: "since", value: String(since))]
        return parts.url!
    }

    private func send(_ request: URLRequest, body: Data? = nil) async throws -> (Data, Int) {
        do {
            let (data, response): (Data, URLResponse)
            if let body { (data, response) = try await session.upload(for: request, from: body) } else { (data, response) = try await session.data(for: request) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 410 { throw ShareError.gone }
            return (data, status)
        } catch let error as ShareError {
            throw error
        } catch {
            throw ShareError.unreachable
        }
    }

    private func request(_ url: URL, _ method: String, token: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    func create(_ room: String, hashes: [String: String]) async throws {
        var request = request(url(room), "POST")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, status) = try await send(request, body: try JSONEncoder().encode(hashes))
        guard status == 201 else { throw ShareError.refused(status) }
    }

    func list(_ room: String, since: Int64, read: String) async throws -> ShareListing {
        let (data, status) = try await send(request(url(room, since: since), "GET", token: read))
        if status == 404 { throw ShareError.missing }
        guard status == 200, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ShareError.refused(status) }
        let records = (json["records"] as? [[String: Any]] ?? []).compactMap { r -> ShareListing.Entry? in
            guard let key = r["key"] as? String, let seq = (r["seq"] as? NSNumber)?.int64Value else { return nil }
            return ShareListing.Entry(key: key, seq: seq, size: (r["size"] as? NSNumber)?.intValue ?? 0)
        }
        return ShareListing(seq: (json["seq"] as? NSNumber)?.int64Value ?? since, records: records)
    }

    func get(_ room: String, _ key: String, read: String) async throws -> Data? {
        let (data, status) = try await send(request(url(room, key), "GET", token: read))
        if status == 404 { return nil }
        guard status == 200 else { throw ShareError.refused(status) }
        return data
    }

    func put(_ room: String, _ key: String, _ body: Data, write: String, writer: String?, owner: String?) async throws {
        var request = request(url(room, key), "PUT", token: write)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        if let writer { request.setValue(writer, forHTTPHeaderField: "X-Bezzle-Writer") }
        if let owner { request.setValue(owner, forHTTPHeaderField: "X-Bezzle-Owner") }
        let (_, status) = try await send(request, body: body)
        // Taken already: a record written once is the same wherever it came from.
        guard [200, 201, 409].contains(status) else { throw ShareError.refused(status) }
    }

    func delete(_ room: String, _ key: String, write: String, writer: String) async throws {
        var request = request(url(room, key), "DELETE", token: write)
        request.setValue(writer, forHTTPHeaderField: "X-Bezzle-Writer")
        let (_, status) = try await send(request)
        guard [200, 204, 404].contains(status) else { throw ShareError.refused(status) }
    }

    func unshare(_ room: String, write: String, owner: String) async throws {
        var request = request(url(room), "DELETE", token: write)
        request.setValue(owner, forHTTPHeaderField: "X-Bezzle-Owner")
        let (_, status) = try await send(request)
        if status == 404 { throw ShareError.missing }
        guard [200, 204].contains(status) else { throw ShareError.refused(status) }
    }
}
