import Foundation
import CryptoKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// A design shared by link, as every copy of Bezzle speaks to its room on the relay
// (Relay/SHARING.md): the relay's requests and answers, the link, and reading what is new in a
// room. The Mac's Sharing and CloudShare call these, and so does Bezzle for Windows. Not in the
// browser's core, which speaks to the relay from its page.
#if !os(WASI)

/// What ties a design to its room on the relay, the same for everyone who has it, kept in its
/// package as `sharing/share.json`. Its secret is the design's link: whoever has the package
/// has the link too, as they have the design.
nonisolated struct ShareLink: Codable, Equatable, Sendable {
    /// The link's secret, as base64url. Empty in a design someone shared through iCloud, which
    /// is no longer shared now that Bezzle shares through its relay.
    var secret: String
    /// The design's name as its owner gave it.
    var title: String?
    /// The name of whoever shared it, as they gave it.
    var ownerName: String?
    /// Its owner stopped sharing it, so it is kept as it last was, to look at and to save a copy of.
    var ended = false

    init(secret: String, title: String? = nil, ownerName: String? = nil, ended: Bool = false) {
        self.secret = secret
        self.title = title
        self.ownerName = ownerName
        self.ended = ended
    }

    /// The room's keys, while it is shared.
    var keys: ShareKeys? { ended ? nil : ShareKeys(link: secret) }

    /// The page on Bezzle's website that hands the link to Bezzle, in any browser.
    var page: URL? {
        guard keys != nil else { return nil }
        return URL(string: "https://bezzle.ch/open.html#2.\(secret)")
    }
}

/// A room on the relay, as every copy reads it.
nonisolated enum CloudRoom {
    /// Where Bezzle's website is, and was until 7 November 2026: links made before then lead to
    /// mfrports.github.io/bezzle-web, which sends them on to bezzle.ch.
    static let websites: Set<String> = ["bezzle.ch", "www.bezzle.ch", "mfrports.github.io"]

    /// The secret in a design's link: `bezzle://share/2.<secret>`, or Bezzle's page on the web with
    /// it after the #. Anything else is not a design's link.
    static func secret(from url: URL) -> String? {
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

    static func hash(_ token: String) -> String { Data(SHA256.hash(data: Data(token.utf8))).hex }

    /// What a copy has done with the room so far.
    struct Progress: Codable, Equatable, Sendable {
        /// The room's latest record seen.
        var seq: Int64 = 0
        /// Every record in the room, as far as known, with the seq it last had.
        var known: [String: Int64] = [:]
        /// Records taken in, and those that would not open.
        var read: Set<String> = []
        var failed: Set<String> = []
        /// Copies whose records went before they were read: their next whole is read.
        var behind: Set<String> = []
        /// The latest of this Mac's changes in the room.
        var sentUpTo: Int64 = 0
        /// This Mac's own parts in the room, by key.
        var parts: [String] = []
        /// Pictures in the room, by their names in the design.
        var pictures: Set<String> = []
        /// Who this Mac last said it was there.
        var introduced: FolderShare.Person?
    }

    /// What a look at the room found.
    struct Fetched: Sendable {
        var progress: Progress
        var changes: [SharedDesign] = []
        var meta: ShareMeta?
        var people: [String: FolderShare.Person] = [:]
        var versions: [DesignVersion] = []
        /// Something went before it was read: another look is needed.
        var again = false
    }

    /// Reads what is new in the room since `progress`, or everything, `fully`: everyone else's
    /// newest whole and their changes after it, the design's name and owner, who everyone is, and
    /// named versions. Away from the main thread.
    @concurrent static func fetch(_ keys: ShareKeys, from server: ShareServer, progress: Progress, fully: Bool,
                                  replica: String) async throws -> Fetched {
        var p = progress
        var found = Fetched(progress: progress)
        let listing = try await server.list(keys.room, since: fully ? 0 : p.seq, read: keys.readToken)
        if fully { p.known = [:] }
        var changed: Set<String> = []
        for record in listing.records where p.known[record.key] != record.seq {
            p.known[record.key] = record.seq
            changed.insert(record.key)
        }
        p.seq = max(p.seq, listing.seq)
        var parts: [String: [FolderShare.Part]] = [:]
        for key in p.known.keys {
            if case .part(let who, let part)? = ShareRecord(key: key) { parts[who, default: []].append(part) }
        }
        if fully { p.parts = (parts[replica] ?? []).sorted().map { $0.record(of: replica) } }
        for (who, all) in parts where who != replica {
            var read = Set(all.filter { p.read.contains($0.record(of: who)) })
            // Behind: everything after its newest whole is read again, with the whole.
            if p.behind.remove(who) != nil { read = read.filter { $0.kind == .whole } }
            let failed = Set(all.filter { p.failed.contains($0.record(of: who)) })
            for part in FolderShare.toRead(all, read: read, failed: failed) {
                let key = part.record(of: who)
                guard let sealed = try await server.get(keys.room, key, read: keys.readToken) else {
                    // Folded into a whole meanwhile: that whole is read next time.
                    p.known[key] = nil
                    if part.kind == .changes {
                        p.behind.insert(who)
                        found.again = true
                    }
                    continue
                }
                if let design = keys.open(sealed, about: key).flatMap(FolderShare.unpack) {
                    found.changes.append(design)
                    p.read.insert(key)
                    p.failed.remove(key)
                } else {
                    p.failed.insert(key)
                }
            }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        for key in changed.sorted() {
            switch ShareRecord(key: key) {
            case .meta?:
                if let data = try await server.get(keys.room, key, read: keys.readToken).flatMap({ keys.open($0, about: key) }) {
                    found.meta = FolderShare.decode(ShareMeta.self, from: data)
                }
            case .person(let who)?:
                if let data = try await server.get(keys.room, key, read: keys.readToken).flatMap({ keys.open($0, about: key) }),
                   let person = FolderShare.decode(FolderShare.Person.self, from: data), person.replica == who {
                    found.people[who] = person
                }
            case .version?:
                if let data = try await server.get(keys.room, key, read: keys.readToken).flatMap({ keys.open($0, about: key) }),
                   var version = try? decoder.decode(DesignVersion.self, from: data), version.isNamed {
                    version.shared = true
                    found.versions.append(version)
                }
            default:
                break
            }
        }
        p.read = p.read.filter { p.known[$0] != nil }
        p.failed = p.failed.filter { p.known[$0] != nil }
        found.progress = p
        return found
    }

    /// A design that came from a link: everything in its room, as one design.
    struct Arrived: Sendable {
        var state: SharedDesign
        var meta: ShareMeta?
        var progress: Progress
    }

    /// What a look at the whole room found, as one design.
    static func arrived(_ fetched: Fetched) throws -> Arrived {
        var state = SharedDesign()
        for design in fetched.changes { state.merge(design) }
        // Its owner is still sending it, or it is gone.
        guard !state.isEmpty else { throw ShareError.missing }
        return Arrived(state: state, meta: fetched.meta, progress: fetched.progress)
    }
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

#endif
