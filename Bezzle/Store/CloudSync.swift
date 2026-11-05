import AppKit
import CloudKit
import Observation
import os

/// Shares designs through iCloud, so people can work on one together without signing up for
/// anything: each uses the iCloud account their Mac already has.
///
/// A shared design is a record zone in its owner's iCloud, shared whole with the others. Every
/// Mac only ever adds records of its own changes there and never saves over anyone's, so no save
/// can undo someone else's work; each Mac merges every record it finds into its copy, and all
/// copies come out the same (see `SharedDesign`). Now and then the owner folds the records into
/// one snapshot, which is also what someone invited finds first. Pictures go up once each, as
/// they never change.
///
/// CKSyncEngine does the fetching and the sending: it hears iCloud's pushes, waits out the
/// network and keeps its place between launches.
@Observable
final class CloudSync {
    static let shared = CloudSync()
    static let containerID = "iCloud.com.erik.Bezzle"

    private enum Kind {
        static let change = "Change"
        static let snapshot = "Snapshot"
        static let picture = "Picture"
        static let version = "Version"
    }

    /// Whether iCloud can be used now: signed in, and not turned off for Bezzle.
    private(set) var accountProblem: String?
    /// Whether something is being fetched or sent right now.
    private(set) var busy = false
    /// The last thing that went wrong, until something goes right.
    private(set) var problem: String?
    /// A shared design being fetched for the first time, just accepted, as the home screen shows it.
    struct Arrival: Equatable {
        var title: String
        var owner: String?
    }

    /// Those on their way, by zone.
    private(set) var arriving: [String: Arrival] = [:]
    /// Why the last invitation could not be accepted, until the next one.
    var invitationProblem: String?

    /// What sharing does, in the system log: `log show --predicate 'subsystem == "com.erik.Bezzle"'`.
    nonisolated static let log = Logger(subsystem: "com.erik.Bezzle", category: "Sharing")

    @ObservationIgnored private lazy var container = CKContainer(identifier: Self.containerID)
    @ObservationIgnored private var engines: [CKDatabase.Scope: CKSyncEngine] = [:]
    @ObservationIgnored private var sessions: [String: WeakSession] = [:]
    /// The change record on its way, for each zone, so there is never more than one.
    @ObservationIgnored private var sending: [String: CKRecord.ID] = [:]
    @ObservationIgnored private var queuedPictures: [String: Set<String>] = [:]
    /// Names of shared designs not here yet, and of their owners, from their invitations.
    @ObservationIgnored private var titles: [String: String] = [:]
    @ObservationIgnored private var owners: [String: String] = [:]
    /// Shared designs to open as soon as they are here, having just been accepted.
    @ObservationIgnored private var toOpen: Set<String> = []
    @ObservationIgnored private var sendTasks: [CKDatabase.Scope: Task<Void, Never>] = [:]
    @ObservationIgnored private var poll: Timer?

    private struct WeakSession { weak var value: Collaboration? }

    /// Whether this copy of Bezzle can reach iCloud at all: it must be signed with the iCloud
    /// entitlement, which builds made without a provisioning profile are not.
    static let isAvailable: Bool = {
        guard !BezzleApp.isTesting, let task = SecTaskCreateFromSelf(nil) else { return false }
        let services = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil)
        return (services as? [String])?.contains("CloudKit") == true
    }()

    /// Which of the container's environments this build uses: development for the builds Xcode
    /// runs, production for those given to people. Each is an iCloud of its own, so each keeps its
    /// own list of shared designs and its own place, and a design shared in one is never sent to
    /// the other.
    static let environment: String = {
        guard let task = SecTaskCreateFromSelf(nil) else { return "Development" }
        let value = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil)
        return (value as? String) ?? (value as? [String])?.first ?? "Development"
    }()

    /// A setting's name for this environment; production's keep the plain one.
    private static func setting(_ name: String) -> String { environment == "Production" ? name : "\(name)-\(environment)" }

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

    /// Each shared design's zone, with where its design is on this Mac.
    private var index: [String: String] {
        get { Library.settings.dictionary(forKey: Self.setting("sharedDesigns")) as? [String: String] ?? [:] }
        set { Library.settings.set(newValue, forKey: Self.setting("sharedDesigns")) }
    }

    private func url(of zone: String) -> URL? {
        index[zone].map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
    }

    /// Whether the design at `url` is this Mac's copy of `zone`. A copy of it made in the Finder
    /// is not, while the copy this Mac has is still there.
    func claim(_ zone: String, at url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        if let known = index[zone], known != path, FileManager.default.fileExists(atPath: known) { return false }
        index[zone] = path
        return true
    }

    func opened(_ session: Collaboration) {
        sessions[session.zone] = WeakSession(value: session)
        pollWhileOpen()
    }

    func closed(_ session: Collaboration) {
        if sessions[session.zone]?.value === session { sessions[session.zone] = nil }
        pollWhileOpen()
    }

    private func session(_ zone: String) -> Collaboration? { sessions[zone]?.value }

    private func link(_ zone: String) -> SharingLink? {
        session(zone)?.link ?? url(of: zone).flatMap(SharingFiles.link)
    }

    private func updateLink(_ zone: String, _ change: (inout SharingLink) -> Void) {
        if let session = session(zone) {
            change(&session.link)
            session.persist()
            return
        }
        guard let url = url(of: zone), var link = SharingFiles.link(of: url) else { return }
        change(&link)
        let changed = link
        DocumentStore.saving.async { try? SharingFiles.write(changed, to: url) }
    }

    private func zoneID(_ link: SharingLink) -> CKRecordZone.ID {
        CKRecordZone.ID(zoneName: link.zone, ownerName: link.owner ?? CKCurrentUserDefaultName)
    }

    private func engine(for link: SharingLink) -> CKSyncEngine? { engines[link.isOwner ? .private : .shared] }

    // MARK: Starting

    /// Copies started with a library of their own (BEZZLE_LIBRARY), for tests and screenshots, do
    /// not sync: they run under the same identity and iCloud as the copy someone is working in,
    /// and would share its sync engine's saved state and its pushes, and stir up what it has open.
    static let keepsOut = ProcessInfo.processInfo.environment["BEZZLE_LIBRARY"] != nil

    /// Starts syncing, at launch.
    func start() {
        guard Self.isAvailable, !Self.keepsOut, engines.isEmpty else { return }
        Self.log.notice("Starting, in iCloud's \(Self.environment, privacy: .public) environment")
        makeEngines()
        NSApplication.shared.registerForRemoteNotifications()
        Task { await checkAccount() }
        // Changes made here but not sent, because Bezzle quit first or the network was away.
        for (zone, path) in index {
            guard let link = SharingFiles.link(of: URL(fileURLWithPath: path)), link.hasUnsent else { continue }
            queueChange(zone, link)
        }
    }

    private func makeEngines() {
        for scope in [CKDatabase.Scope.private, .shared] {
            let database = scope == .private ? container.privateCloudDatabase : container.sharedCloudDatabase
            let config = CKSyncEngine.Configuration(database: database, stateSerialization: savedState(scope), delegate: self)
            let engine = CKSyncEngine(config)
            engines[scope] = engine
            for change in engine.state.pendingRecordZoneChanges {
                if case .saveRecord(let id) = change, id.recordName.hasPrefix("change-") { sending[id.zoneID.zoneName] = id }
            }
        }
    }

    private func checkAccount() async {
        do {
            switch try await container.accountStatus() {
            case .available: accountProblem = nil
            case .noAccount: accountProblem = String(localized: "Sign in to iCloud in System Settings to share designs.")
            case .restricted: accountProblem = String(localized: "iCloud is restricted on this Mac.")
            case .temporarilyUnavailable: accountProblem = String(localized: "iCloud is not available right now.")
            default: accountProblem = String(localized: "iCloud could not be reached.")
            }
        } catch {
            accountProblem = String(localized: "iCloud could not be reached: \(error.localizedDescription)")
        }
    }

    /// Looks for others' changes when Bezzle comes to the front, and every little while as long
    /// as a shared design is open, should a push from iCloud be late or not come.
    func fetchNow() {
        guard !engines.isEmpty, !index.isEmpty else { return }
        for engine in engines.values { Task.detached { try? await engine.fetchChanges() } }
    }

    private func pollWhileOpen() {
        let open = sessions.values.contains { $0.value != nil }
        if open, poll == nil, !engines.isEmpty {
            poll = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { _ in
                Task { @MainActor in CloudSync.shared.pollNow() }
            }
        } else if !open {
            poll?.invalidate()
            poll = nil
        }
    }

    @ObservationIgnored private var polls = 0

    /// While everyone who has an open design is in its live room too, their changes come that
    /// way at once, and iCloud is asked a quarter as often: what it brings then is already here.
    private func pollNow() {
        polls += 1
        guard NSApp.isActive else { return }
        if allLive, polls % 4 != 0 { return }
        fetchNow()
    }

    /// Whether each shared design open here has others in its live room.
    private var allLive: Bool {
        let open = sessions.values.compactMap(\.value)
        return !open.isEmpty && open.allSatisfy { $0.live?.hasOthers == true }
    }

    // MARK: Engine state

    private func stateFile(_ scope: CKDatabase.Scope) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Bezzle/Sharing", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("\(scope == .private ? "private" : "shared")-\(Self.environment).json")
    }

    private func savedState(_ scope: CKDatabase.Scope) -> CKSyncEngine.State.Serialization? {
        (try? Data(contentsOf: stateFile(scope))).flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
    }

    private func scope(of engine: CKSyncEngine) -> CKDatabase.Scope {
        engines.first { $0.value === engine }?.key ?? engine.database.databaseScope
    }

    // MARK: Sending

    /// Something was changed here in a shared design: a record of it goes up soon.
    func haveChanges(in session: Collaboration) {
        queueChange(session.zone, session.link)
    }

    private func queueChange(_ zone: String, _ link: SharingLink) {
        guard link.environment == Self.environment, !link.ended, sending[zone] == nil, let engine = engine(for: link) else { return }
        let id = CKRecord.ID(recordName: "change-\(UUID().uuidString)", zoneID: zoneID(link))
        sending[zone] = id
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(id)])
        sendSoon(link.isOwner ? .private : .shared)
    }

    /// Sends a moment from now, so that a run of changes goes up together.
    ///
    /// Detached, as everything that asks an engine to fetch or send must be: a task made while
    /// the engine is calling in, as it is when changes arrive or have gone, carries that call
    /// along, and an engine asked to sync from inside its own call stops the app.
    private func sendSoon(_ scope: CKDatabase.Scope) {
        guard sendTasks[scope] == nil, let engine = engines[scope] else { return }
        // The others in the room have it already: a longer run of changes goes up as one record.
        let wait = allLive ? 3.0 : 1.5
        sendTasks[scope] = Task.detached {
            try? await Task.sleep(for: .seconds(wait))
            await MainActor.run { CloudSync.shared.sendTasks[scope] = nil }
            try? await engine.sendChanges()
        }
    }

    /// A version was named in a shared design: it goes up, for everyone it is shared with.
    func sendVersion(_ id: UUID, of session: Collaboration) {
        guard session.link.environment == Self.environment, !session.link.ended, let engine = engine(for: session.link) else { return }
        engine.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: "version-\(id.uuidString)", zoneID: zoneID(session.link)))])
        sendSoon(session.link.isOwner ? .private : .shared)
    }

    /// The design shows these pictures: any not in iCloud yet go up.
    func sendPictures(_ names: Set<String>, of session: Collaboration) {
        let zone = session.zone
        let images = session.url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        let new = names.subtracting(session.link.sentPictures).subtracting(queuedPictures[zone] ?? [])
            .filter { FileManager.default.fileExists(atPath: images.appendingPathComponent($0).path) }
        guard !new.isEmpty, session.link.environment == Self.environment, !session.link.ended, let engine = engine(for: session.link) else { return }
        queuedPictures[zone, default: []].formUnion(new)
        let zoneID = zoneID(session.link)
        engine.state.add(pendingRecordZoneChanges: new.map { .saveRecord(CKRecord.ID(recordName: "picture-\($0)", zoneID: zoneID)) })
        sendSoon(session.link.isOwner ? .private : .shared)
    }

    /// The record to send for a pending change, made as it goes, from the design as it is then.
    private func record(for id: CKRecord.ID) -> CKRecord? {
        let zone = id.zoneID.zoneName
        guard let url = url(of: zone), let link = link(zone), link.environment == Self.environment, !link.ended else { return nil }
        let name = id.recordName
        if name.hasPrefix("change-") {
            DocumentStore.finishSaving()
            guard let state = session(zone)?.state ?? SharingFiles.state(of: url) else { return nil }
            let changes = state.changes(by: Self.replica, after: link.sentUpTo)
            guard !changes.isEmpty else {
                if sending[zone] == id { sending[zone] = nil }
                return nil
            }
            let record = CKRecord(recordType: Kind.change, recordID: id)
            record["by"] = Self.replica
            record["upTo"] = state.clock.time
            return attach(changes, to: record) ? record : nil
        }
        if name.hasPrefix("picture-") {
            return pictureRecord(String(name.dropFirst("picture-".count)), of: url, in: id.zoneID)
        }
        if name.hasPrefix("version-") {
            guard let vid = UUID(uuidString: String(name.dropFirst("version-".count))),
                  let version = VersionFiles.index(of: url).first(where: { $0.id == vid }) else { return nil }
            let file = VersionFiles.file(vid, of: url)
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            let record = CKRecord(recordType: Kind.version, recordID: id)
            record["name"] = version.name
            record["at"] = Int64(version.date.timeIntervalSince1970 * 1000)
            record["by"] = version.by
            record["replica"] = version.replica
            record["layers"] = Int64(version.layers)
            record["file"] = CKAsset(fileURL: file)
            return record
        }
        if name == "snapshot" {
            DocumentStore.finishSaving()
            guard let state = session(zone)?.state ?? SharingFiles.state(of: url) else { return nil }
            let record = link.snapshotFields.flatMap(Self.record(fromSystemFields:)) ?? CKRecord(recordType: Kind.snapshot, recordID: id)
            record["upTo"] = state.clock.time
            return attach(state, to: record) ? record : nil
        }
        return nil
    }

    @ObservationIgnored private lazy var outgoing: URL = {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("BezzleSharing", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    /// Puts a design's changes in a record, packed small; when still large, as a file of its own.
    private func attach(_ design: SharedDesign, to record: CKRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(design),
              let packed = try? (data as NSData).compressed(using: .lzfse) as Data else { return false }
        if packed.count < 500_000 {
            record["data"] = packed
            record["file"] = nil
            return true
        }
        let file = outgoing.appendingPathComponent("\(record.recordID.zoneID.zoneName)-\(record.recordID.recordName).lzfse")
        do {
            try packed.write(to: file, options: .atomic)
        } catch {
            return false
        }
        record["data"] = nil
        record["file"] = CKAsset(fileURL: file)
        return true
    }

    private static func design(in record: CKRecord) -> SharedDesign? {
        let packed = (record["data"] as? Data) ?? (record["file"] as? CKAsset)?.fileURL.flatMap { try? Data(contentsOf: $0) }
        guard let packed, let data = try? (packed as NSData).decompressed(using: .lzfse) as Data else { return nil }
        return try? JSONDecoder().decode(SharedDesign.self, from: data)
    }

    private static func systemFields(of record: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    private static func record(fromSystemFields data: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    private func sent(_ event: CKSyncEngine.Event.SentRecordZoneChanges, by engine: CKSyncEngine) {
        for record in event.savedRecords {
            let zone = record.recordID.zoneID.zoneName
            try? FileManager.default.removeItem(at: outgoing.appendingPathComponent("\(zone)-\(record.recordID.recordName).lzfse"))
            problem = nil
            switch record.recordType {
            case Kind.change:
                let upTo = record["upTo"] as? Int64 ?? 0
                if sending[zone] == record.recordID { sending[zone] = nil }
                updateLink(zone) {
                    $0.sentUpTo = max($0.sentUpTo, upTo)
                    $0.changeRecords.insert(record.recordID.recordName)
                }
                afterSending(zone)
            case Kind.picture:
                guard let name = record["name"] as? String else { continue }
                queuedPictures[zone]?.remove(name)
                updateLink(zone) { $0.sentPictures.insert(name) }
            case Kind.snapshot:
                let upTo = record["upTo"] as? Int64 ?? 0
                let folded = link(zone)?.folding ?? []
                updateLink(zone) {
                    $0.snapshotFields = Self.systemFields(of: record)
                    $0.sentUpTo = max($0.sentUpTo, upTo)
                    $0.changeRecords.subtract(folded)
                    $0.folding = []
                }
                // What the snapshot holds now, the records it was made from no longer need to.
                engine.state.add(pendingRecordZoneChanges: folded.map { .deleteRecord(CKRecord.ID(recordName: $0, zoneID: record.recordID.zoneID)) })
            default:
                break
            }
        }

        for failure in event.failedRecordSaves {
            let record = failure.record, zone = record.recordID.zoneID.zoneName
            let isChange = record.recordType == Kind.change
            switch failure.error.code {
            case .serverRecordChanged:
                switch record.recordType {
                case Kind.change:
                    // One with this name went up before, perhaps with less in it: a new one goes.
                    if sending[zone] == record.recordID { sending[zone] = nil }
                    if let link = link(zone) { queueChange(zone, link) }
                case Kind.picture:
                    if let name = record["name"] as? String { updateLink(zone) { $0.sentPictures.insert(name) } }
                case Kind.snapshot:
                    // Another of the owner's Macs saved one: what it holds comes in, and a new one goes.
                    guard let server = failure.error.serverRecord, let theirs = Self.design(in: server) else {
                        updateLink(zone) { $0.folding = [] }
                        continue
                    }
                    deliver([theirs], to: record.recordID.zoneID)
                    updateLink(zone) { $0.snapshotFields = Self.systemFields(of: server) }
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                default:
                    break
                }
            case .zoneNotFound, .userDeletedZone:
                if link(zone)?.isOwner == true {
                    engine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: record.recordID.zoneID))])
                    engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
                } else {
                    stopSharing(zone)
                }
            case .unknownItem:
                if record.recordType == Kind.snapshot { updateLink(zone) { $0.snapshotFields = nil } }
                engine.state.add(pendingRecordZoneChanges: [.saveRecord(record.recordID)])
            case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .notAuthenticated,
                 .operationCancelled, .requestRateLimited:
                // The engine tries these again itself.
                break
            case .quotaExceeded:
                problem = String(localized: "Your iCloud storage is full, so changes can’t be sent.")
                if isChange, sending[zone] == record.recordID { sending[zone] = nil }
            case .permissionFailure:
                problem = String(localized: "You can look at this design but not change it.")
                if isChange, sending[zone] == record.recordID { sending[zone] = nil }
            default:
                problem = String(localized: "Changes could not be sent: \(failure.error.localizedDescription)")
                Self.log.error("Could not send \(record.recordID.recordName, privacy: .public): \(failure.error.localizedDescription, privacy: .public)")
                if isChange, sending[zone] == record.recordID { sending[zone] = nil }
            }
        }
    }

    /// Sends again if more was changed meanwhile, and now and then folds the records up.
    private func afterSending(_ zone: String) {
        guard let link = link(zone) else { return }
        if link.hasUnsent { queueChange(zone, link) }
        if link.isOwner, link.folding.isEmpty, link.changeRecords.count >= 200, let engine = engine(for: link) {
            updateLink(zone) { $0.folding = Array($0.changeRecords) }
            engine.state.add(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: "snapshot", zoneID: zoneID(link)))])
        }
    }

    // MARK: Receiving

    private func received(_ event: CKSyncEngine.Event.FetchedRecordZoneChanges) {
        var designs: [CKRecordZone.ID: [SharedDesign]] = [:]
        var pictures: [CKRecordZone.ID: [CKRecord]] = [:]
        var changeRecords: [CKRecordZone.ID: Set<String>] = [:]
        var snapshots: [CKRecordZone.ID: Data] = [:]
        for modification in event.modifications {
            let record = modification.record, zoneID = record.recordID.zoneID
            switch record.recordType {
            case Kind.change:
                // Only what was read is ever folded into a snapshot and deleted.
                guard let design = Self.design(in: record) else {
                    NSLog("Bezzle could not read the change %@", record.recordID.recordName)
                    continue
                }
                designs[zoneID, default: []].append(design)
                changeRecords[zoneID, default: []].insert(record.recordID.recordName)
            case Kind.snapshot:
                // One that cannot be read is never saved over.
                guard let design = Self.design(in: record) else { continue }
                designs[zoneID, default: []].append(design)
                snapshots[zoneID] = Self.systemFields(of: record)
            case Kind.picture:
                pictures[zoneID, default: []].append(record)
            case Kind.version:
                takeVersion(record)
            case CKRecord.SystemType.share:
                guard let share = record as? CKShare else { continue }
                if let title = share[CKShare.SystemFieldKey.title] as? String { titles[zoneID.zoneName] = title }
                let owner = Self.name(share.owner.userIdentity)
                owners[zoneID.zoneName] = owner
                updateLink(zoneID.zoneName) { link in
                    if link.isOwner { link.shared = true } else if let owner { link.ownerName = owner }
                }
            default:
                break
            }
        }
        for zoneID in Set(designs.keys).union(pictures.keys) {
            Self.log.info("Fetched \(designs[zoneID]?.count ?? 0) changes and \(pictures[zoneID]?.count ?? 0) pictures for \(zoneID.zoneName, privacy: .public)")
            deliver(designs[zoneID] ?? [], to: zoneID, pictures: pictures[zoneID] ?? [])
            updateLink(zoneID.zoneName) { link in
                link.changeRecords.formUnion(changeRecords[zoneID] ?? [])
                if let fields = snapshots[zoneID] { link.snapshotFields = fields }
            }
        }
        // The owner stopped sharing it, from another of their Macs.
        for deletion in event.deletions where deletion.recordType == CKRecord.SystemType.share {
            updateLink(deletion.recordID.zoneID.zoneName) { $0.shared = false }
        }
        Library.shared.refresh()
        // What was fetched is on disk before the engine notes that it was.
        DocumentStore.finishSaving()
    }

    /// A version someone named: kept with the design, open or not.
    private func takeVersion(_ record: CKRecord) {
        let zone = record.recordID.zoneID.zoneName
        guard let url = url(of: zone), let vid = UUID(uuidString: String(record.recordID.recordName.dropFirst("version-".count))),
              let file = (record["file"] as? CKAsset)?.fileURL, let data = try? Data(contentsOf: file) else { return }
        var version = DesignVersion(id: vid, date: Date(timeIntervalSince1970: Double(record["at"] as? Int64 ?? 0) / 1000))
        version.name = record["name"] as? String
        version.by = record["by"] as? String
        version.replica = record["replica"] as? String
        version.layers = Int(record["layers"] as? Int64 ?? 0)
        version.shared = true
        if let store = session(zone)?.store {
            store.versions.arrived(version, data: data)
            return
        }
        // Not open: kept with it all the same.
        DocumentStore.saving.async {
            var list = VersionFiles.index(of: url)
            if let i = list.firstIndex(where: { $0.id == vid }) { list[i].name = version.name } else { list.append(version) }
            if !FileManager.default.fileExists(atPath: VersionFiles.file(vid, of: url).path) { try? VersionFiles.write(data, as: vid, to: url) }
            try? VersionFiles.writeIndex(list.sorted { $0.date < $1.date }, to: url)
        }
    }

    /// Takes changes from others into the design they belong to, open or not. A shared design
    /// not on this Mac yet, just accepted or shared from another of the owner's Macs, is made.
    private func deliver(_ changes: [SharedDesign], to zoneID: CKRecordZone.ID, pictures: [CKRecord] = []) {
        let zone = zoneID.zoneName
        guard zone.hasPrefix("design-") else { return }
        var url = url(of: zone)
        // Whatever comes first makes it, pictures too, so none of them is lost.
        if url == nil, index[zone] == nil, !changes.isEmpty || !pictures.isEmpty {
            url = makeDesign(zone, owner: zoneID.ownerName == CKCurrentUserDefaultName ? nil : zoneID.ownerName)
            Self.log.notice("Made \(url?.lastPathComponent ?? "nothing", privacy: .public) for \(zone, privacy: .public)")
        }
        // One taken off this Mac stays off.
        guard let url else { return }
        // Pictures first, so the layers that show them have them.
        var arrived: [String] = []
        for record in pictures {
            if let name = savePicture(record, into: url) { arrived.append(name) }
        }
        if !arrived.isEmpty {
            updateLink(zone) { $0.sentPictures.formUnion(arrived) }
            for name in arrived {
                session(zone)?.store?.pictureArrived(name)
                session(zone)?.live?.arrived(name)
            }
        }
        if let session = session(zone) {
            session.receive(changes)
            session.persist()
        } else {
            Collaboration.merge(changes, intoDesignAt: url)
            Library.shared.touched(url)
        }
        if !changes.isEmpty, toOpen.remove(zone) != nil {
            arriving[zone] = nil
            WindowRouter.shared.open(url)
        }
    }

    private func makeDesign(_ zone: String, owner: String?) -> URL? {
        let name = (titles[zone] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "-")
        let url = Library.shared.freeURL(named: name.isEmpty ? String(localized: "Shared Design") : name, in: Library.shared.folder)
        do {
            try DesignFile.write(BezzleDocument(), to: url)
            try SharingFiles.write(SharedDesign(), to: url)
            var link = SharingLink(zone: zone, owner: owner, environment: Self.environment)
            link.ownerName = owners[zone]
            try SharingFiles.write(link, to: url)
        } catch {
            NSLog("Bezzle could not make %@: %@", url.path, error.localizedDescription)
            return nil
        }
        index[zone] = url.standardizedFileURL.path
        return url
    }

    private func savePicture(_ record: CKRecord, into design: URL) -> String? {
        guard let name = record["name"] as? String, !name.isEmpty, !name.hasPrefix("."), (name as NSString).lastPathComponent == name,
              let file = (record["file"] as? CKAsset)?.fileURL else { return nil }
        let images = design.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        let target = images.appendingPathComponent(name)
        guard !FileManager.default.fileExists(atPath: target.path) else { return name }
        do {
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: file, to: target)
        } catch {
            NSLog("Bezzle could not keep the picture %@: %@", name, error.localizedDescription)
            return nil
        }
        return name
    }

    /// The design is no longer shared with this Mac. One of this Mac's own stays as a design of
    /// its own; someone else's stays as it last was, read only, to look at and save a copy of.
    private func stopSharing(_ zone: String) {
        if let url = url(of: zone), let link = link(zone) {
            let session = session(zone)
            session?.store?.save()
            DocumentStore.finishSaving()
            if link.isOwner {
                session?.store?.sharing = nil
                SharingFiles.unlink(url)
            } else {
                updateLink(zone) { $0.ended = true }
                DocumentStore.finishSaving()
            }
            if let session { closed(session) }
            Self.log.notice("No longer sharing \(zone, privacy: .public)")
            Library.shared.refresh()
        }
        index[zone] = nil
        sending[zone] = nil
        queuedPictures[zone] = nil
    }

    // MARK: Sharing

    /// How far a design is in getting everything into iCloud before it can be shared, by where it is.
    struct Upload: Equatable {
        var done = 0
        var total = 0
    }

    private(set) var preparing: [URL: Upload] = [:]
    /// The share sheet showing, kept until it goes.
    @ObservationIgnored private var picker: NSSharingServicePicker?

    /// Shows the share sheet for the design, to invite people or see who has it, once everything
    /// in it is in iCloud: an invitation never leads anyone to a design with parts still missing.
    /// What is changed afterwards follows as always.
    ///
    /// `place` is where the Share button is in the design's window, from its top left.
    func showSharing(for store: DocumentStore, at place: () -> CGRect?) async {
        let key = store.url
        guard preparing[key] == nil else { return }
        preparing[key] = Upload()
        defer { preparing[key] = nil }
        do {
            let share = try await prepareShare(store, key: key)
            let provider = NSItemProvider()
            provider.registerCKShare(share, container: container, allowedSharingOptions: .standard)
            presentSheet([provider], for: store, at: place())
        } catch {
            Self.log.error("Could not share \(store.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(store.name)” could not be shared")
            alert.informativeText = (error as? SharingError)?.message ?? error.localizedDescription
            if let window = store.canvas?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
        }
    }

    /// Opens the share sheet in the design's window, under `place` there (from the window's top
    /// left), or failing that at the top of the window.
    @discardableResult
    func presentSheet(_ items: [Any], for store: DocumentStore, at place: CGRect?) -> Bool {
        guard let window = store.canvas?.window, let content = window.contentView else {
            Self.log.notice("The design’s window went before its share sheet could open")
            return false
        }
        var rect = place ?? CGRect(x: content.bounds.midX - 1, y: 0, width: 2, height: 52)
        if !content.isFlipped { rect.origin.y = content.bounds.height - rect.maxY }
        let picker = NSSharingServicePicker(items: items)
        self.picker = picker
        Self.log.notice("Showing the share sheet for \(store.name, privacy: .public)")
        picker.show(relativeTo: rect, of: content, preferredEdge: content.isFlipped ? .maxY : .minY)
        return true
    }

    /// Puts Bezzle's own invitation to the design on the pasteboard, once everything in it is in
    /// iCloud, and returns whether it did. It is the page on Bezzle's website that hands the
    /// invitation to Bezzle in any browser, since iCloud's own link opened in a browser only ever
    /// reaches iCloud's sign-in page. So the design is opened to anyone with the link, to edit with
    /// whatever iCloud account their Mac has; the owner sees and removes people in the share sheet.
    func copyInvitationLink(for store: DocumentStore) async -> Bool {
        let key = store.url
        guard preparing[key] == nil else { return false }
        preparing[key] = Upload()
        defer { preparing[key] = nil }
        do {
            let share = try await prepareShare(store, key: key, openToLink: true)
            guard let link = share.url.flatMap(Self.invitationPage(for:)) else {
                throw SharingError(message: String(localized: "The design could not be shared."))
            }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(link.absoluteString, forType: .string)
            Self.log.notice("Copied the invitation link to \(store.name, privacy: .public)")
            return true
        } catch {
            Self.log.error("Could not make an invitation link to \(store.name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = String(localized: "“\(store.name)” could not be shared")
            alert.informativeText = (error as? SharingError)?.message ?? error.localizedDescription
            if let window = store.canvas?.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            return false
        }
    }

    /// Bezzle's own invitation: its website's page with the share's code after the #, which the page
    /// hands to Bezzle as `bezzle://share/<code>` (see `invitationLink(from:)`). After a #, the code
    /// never leaves the browser.
    nonisolated static func invitationPage(for shareURL: URL) -> URL? {
        guard let link = invitationLink(from: shareURL) else { return nil }
        return URL(string: "https://mfrports.github.io/bezzle-web/open.html#\(link.lastPathComponent)")
    }

    /// `openToLink` lets anyone with the share's link in, which only the owner can do.
    private func prepareShare(_ store: DocumentStore, key: URL, openToLink: Bool = false) async throws -> CKShare {
        await checkAccount()
        if let accountProblem { throw SharingError(message: accountProblem) }
        let session = try makeShared(store)
        guard session.link.environment == Self.environment else {
            throw SharingError(message: session.link.environment == "Production"
                ? String(localized: "This design is shared through iCloud’s production environment, which this copy of Bezzle does not use.")
                : String(localized: "This design is shared through iCloud’s development environment, which this copy of Bezzle does not use."))
        }
        guard !session.link.ended else { throw SharingError(message: String(localized: "This design is no longer shared with you. Save a copy of it to share that.")) }
        let zoneID = zoneID(session.link)
        let database = session.isOwner ? container.privateCloudDatabase : container.sharedCloudDatabase
        if session.isOwner { _ = try await database.modifyRecordZones(saving: [CKRecordZone(zoneID: zoneID)], deleting: []) }

        // Everything first: what was changed here, as a snapshot of the whole, and every picture.
        store.save()
        DocumentStore.finishSaving()
        if session.link.snapshotFields == nil || session.link.hasUnsent {
            try await saveSnapshot(of: session, to: database, in: zoneID)
        }
        let images = session.url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
        let pictures = Collaboration.pictures(in: store.sharedDoc).subtracting(session.link.sentPictures)
            .filter { FileManager.default.fileExists(atPath: images.appendingPathComponent($0).path) }.sorted()
        preparing[key] = Upload(done: 0, total: pictures.count)
        try await upload(pictures, of: session, to: database, in: zoneID) { done in self.preparing[key]?.done = done }

        // Only then the share, the one there is or a new one.
        let shareID = CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID)
        var share: CKShare
        if let existing = try? await database.record(for: shareID) as? CKShare {
            share = existing
        } else {
            guard session.isOwner else { throw SharingError(message: String(localized: "The design’s owner has stopped sharing it.")) }
            let new = CKShare(recordZoneID: zoneID)
            new[CKShare.SystemFieldKey.title] = store.name
            if openToLink { new.publicPermission = .readWrite }
            guard let made = try await database.save(new) as? CKShare else { throw SharingError(message: String(localized: "The design could not be shared.")) }
            share = made
        }
        if openToLink, share.publicPermission != .readWrite {
            guard session.isOwner else { throw SharingError(message: String(localized: "Only the design’s owner can make an invitation link to it.")) }
            share.publicPermission = .readWrite
            guard let saved = try await database.save(share) as? CKShare else { throw SharingError(message: String(localized: "The design could not be shared.")) }
            share = saved
        }
        if session.isOwner, !session.link.shared {
            updateLink(session.zone) { $0.shared = true }
            Library.shared.refresh()
        }
        Self.log.notice("Everything in \(store.name, privacy: .public) is in iCloud; \(pictures.count) pictures went up")
        return share
    }

    /// Saves the whole design as the zone's snapshot. One there already, from another Mac, is
    /// merged in first and saved over in its own place, never just replaced.
    private func saveSnapshot(of session: Collaboration, to database: CKDatabase, in zoneID: CKRecordZone.ID) async throws {
        let snapshotID = CKRecord.ID(recordName: "snapshot", zoneID: zoneID)
        defer { try? FileManager.default.removeItem(at: outgoing.appendingPathComponent("\(zoneID.zoneName)-snapshot.lzfse")) }
        for attempt in 1...3 {
            let existing = try? await database.record(for: snapshotID)
            if let existing {
                guard let theirs = Self.design(in: existing) else { throw SharingError(message: String(localized: "This design was shared by a later Bezzle. Update Bezzle to share it.")) }
                session.receive([theirs])
            }
            let snapshot = existing ?? CKRecord(recordType: Kind.snapshot, recordID: snapshotID)
            let upTo = session.state.clock.time
            snapshot["upTo"] = upTo
            guard attach(session.state, to: snapshot) else { throw SharingError(message: String(localized: "The design could not be packed up to send.")) }
            do {
                let saved = try await database.save(snapshot)
                updateLink(session.zone) {
                    $0.snapshotFields = Self.systemFields(of: saved)
                    $0.sentUpTo = max($0.sentUpTo, upTo)
                }
                return
            } catch let error as CKError where error.code == .serverRecordChanged && attempt < 3 {
                // Saved from elsewhere just now: merged in on the next go.
                continue
            }
        }
    }

    /// Sends pictures a few at a time, saying how many are up after each few.
    private func upload(_ names: [String], of session: Collaboration, to database: CKDatabase, in zoneID: CKRecordZone.ID,
                        progress: (Int) -> Void) async throws {
        var done = 0
        for start in stride(from: 0, to: names.count, by: 8) {
            let batch = Array(names[start..<min(start + 8, names.count)])
            let records = batch.compactMap { pictureRecord($0, of: session.url, in: zoneID) }
            // Pictures never change, so one saved already from elsewhere is simply saved again.
            let saved = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: false)
            var sent: [String] = []
            var failure: Error?
            for (id, result) in saved.saveResults {
                switch result {
                case .success: sent.append(String(id.recordName.dropFirst("picture-".count)))
                case .failure(let error): failure = error
                }
            }
            updateLink(session.zone) { $0.sentPictures.formUnion(sent) }
            queuedPictures[session.zone]?.subtract(sent)
            engine(for: session.link)?.state.remove(pendingRecordZoneChanges: sent.map { .saveRecord(CKRecord.ID(recordName: "picture-\($0)", zoneID: zoneID)) })
            if let failure { throw failure }
            done += batch.count
            progress(done)
        }
    }

    private func pictureRecord(_ name: String, of design: URL, in zoneID: CKRecordZone.ID) -> CKRecord? {
        let file = design.appendingPathComponent(DesignFile.imagesFolder).appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        let record = CKRecord(recordType: Kind.picture, recordID: CKRecord.ID(recordName: "picture-\(name)", zoneID: zoneID))
        record["name"] = name
        record["file"] = CKAsset(fileURL: file)
        return record
    }

    /// Makes an open design shared, if it is not yet: everything in it is taken in as this Mac's.
    private func makeShared(_ store: DocumentStore) throws -> Collaboration {
        if let session = store.sharing { return session }
        store.save()
        DocumentStore.finishSaving()
        if !DesignFile.isPackage(store.url) {
            try DesignFile.makePackage(store.url)
            store.becamePackage()
        }
        let link = SharingLink(zone: "design-\(UUID().uuidString)", owner: nil, environment: Self.environment)
        let session = Collaboration(url: store.url, link: link, state: SharedDesign())
        index[session.zone] = store.url.standardizedFileURL.path
        store.sharing = session
        session.attach(to: store)
        session.persist()
        DocumentStore.finishSaving()
        return session
    }

    /// Someone clicked an invitation to a shared design. It is accepted, and the design opens as
    /// soon as its snapshot is here; its pictures and latest changes follow as the engine fetches
    /// them, which for a design with many pictures takes a while. One of the owner's own, clicked
    /// on another of their Macs, is in their own iCloud already.
    func accept(_ metadata: CKShare.Metadata) {
        let zoneID = metadata.share.recordID.zoneID, zone = zoneID.zoneName
        let owner = metadata.participantRole == .owner
        Self.log.notice("Invitation to \(zone, privacy: .public), as the owner: \(owner)")
        if let url = url(of: zone) {
            WindowRouter.shared.open(url)
            return
        }
        guard Self.isAvailable else { return }
        start()
        let title = (metadata.share[CKShare.SystemFieldKey.title] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? String(localized: "Shared Design")
        titles[zone] = title
        owners[zone] = Self.name(metadata.ownerIdentity)
        toOpen.insert(zone)
        arriving[zone] = Arrival(title: title, owner: owners[zone])
        invitationProblem = nil
        WindowRouter.shared.showHome()
        let container = container
        Task.detached {
            do {
                if !owner { _ = try await container.accept(metadata) }
                let database = owner ? container.privateCloudDatabase : container.sharedCloudDatabase
                let snapshot = try? await database.record(for: CKRecord.ID(recordName: "snapshot", zoneID: zoneID))
                await CloudSync.shared.accepted(zoneID, snapshot: snapshot)
            } catch {
                await CloudSync.shared.notAccepted(zone, error)
            }
        }
    }

    /// A person's name as an invitation gives it, short.
    private static func name(_ identity: CKUserIdentity) -> String? {
        guard let parts = identity.nameComponents else { return nil }
        let name = PersonNameComponentsFormatter.localizedString(from: parts, style: .short)
        return name.isEmpty ? nil : name
    }

    /// An invitation as its link: passed on by another copy of Bezzle, or opened from Bezzle's
    /// page on the web, where iCloud sends an invitation that a browser got instead of Bezzle.
    /// What went wrong shows on the home screen, as nobody would see it anywhere else.
    func accept(link: URL) {
        guard Self.isAvailable else { return }
        let container = container
        Task.detached {
            do {
                if try await container.accountStatus() == .noAccount {
                    await CloudSync.shared.notAccepted(String(localized: "Sign in to iCloud in System Settings to open invitations to shared designs."))
                    return
                }
                let metadata = try await container.shareMetadata(for: link)
                await CloudSync.shared.accept(metadata)
            } catch {
                await CloudSync.shared.notAccepted(nil, error)
                await WindowRouter.shared.showHome()
            }
        }
    }

    private func notAccepted(_ problem: String) {
        Self.log.error("Could not accept an invitation: \(problem, privacy: .public)")
        invitationProblem = problem
        WindowRouter.shared.showHome()
    }

    /// The iCloud link of an invitation, from Bezzle's own kind of link (`bezzle://share/<token>`,
    /// which Bezzle's page on the web makes of an iCloud link) or from the iCloud link itself.
    /// Anything else is not an invitation.
    nonisolated static func invitationLink(from url: URL) -> URL? {
        let token: String
        switch url.scheme?.lowercased() {
        case "bezzle":
            guard url.host()?.lowercased() == "share" else { return nil }
            token = url.path(percentEncoded: false).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        case "https":
            guard ["www.icloud.com", "icloud.com"].contains(url.host()?.lowercased() ?? ""),
                  url.pathComponents.count == 3, url.pathComponents[1] == "share" else { return nil }
            token = url.pathComponents[2]
        default:
            return nil
        }
        guard (1...200).contains(token.count),
              token.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") })
        else { return nil }
        return URL(string: "https://www.icloud.com/share/\(token)")
    }

    private func accepted(_ zoneID: CKRecordZone.ID, snapshot: CKRecord?) {
        let zone = zoneID.zoneName
        Self.log.notice("Accepted \(zone, privacy: .public); snapshot: \(snapshot != nil)")
        if let snapshot, let design = Self.design(in: snapshot) {
            deliver([design], to: zoneID)
            updateLink(zone) { $0.snapshotFields = Self.systemFields(of: snapshot) }
        }
        let engine = engines[zoneID.ownerName == CKCurrentUserDefaultName ? .private : .shared]
        Task.detached { try? await engine?.fetchChanges() }
    }

    private func notAccepted(_ zone: String?, _ error: Error) {
        Self.log.error("Could not accept \(zone ?? "an invitation", privacy: .public): \(error.localizedDescription, privacy: .public)")
        if let zone {
            toOpen.remove(zone)
            arriving[zone] = nil
        }
        switch (error as? CKError)?.code {
        case .participantMayNeedVerification?:
            invitationProblem = String(localized: "This invitation is for another Apple Account. Ask to be invited with the one this Mac is signed in to.")
        case .unknownItem?:
            invitationProblem = String(localized: "This design is not shared any more. Ask for a new invitation.")
        default:
            invitationProblem = String(localized: "The shared design could not be opened: \(error.localizedDescription)")
        }
    }

    /// iCloud was signed out of, or into another account: shared designs stay on this Mac as
    /// designs of their own, and the engines start again for the account there is now.
    private func accountChanged(to user: CKRecord.ID) {
        let known = Library.settings.string(forKey: Self.setting("sharingUser"))
        Library.settings.set(user.recordName, forKey: Self.setting("sharingUser"))
        guard let known, known != user.recordName else { return }
        for zone in index.keys { stopSharing(zone) }
        for scope in [CKDatabase.Scope.private, .shared] { try? FileManager.default.removeItem(at: stateFile(scope)) }
        sending = [:]
        // Not from inside the old engine's own call.
        DispatchQueue.main.async {
            self.engines = [:]
            self.makeEngines()
        }
    }
}

struct SharingError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

extension CloudSync: CKSyncEngineDelegate {
    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        switch event {
        case .stateUpdate(let update):
            if let data = try? JSONEncoder().encode(update.stateSerialization) {
                try? data.write(to: stateFile(scope(of: syncEngine)), options: .atomic)
            }
        case .accountChange(let change):
            switch change.changeType {
            case .signIn(let user):
                accountProblem = nil
                accountChanged(to: user)
            case .signOut:
                // Kept as they are, for when the same account comes back.
                await checkAccount()
            case .switchAccounts(_, let user):
                accountChanged(to: user)
            @unknown default:
                break
            }
        case .fetchedDatabaseChanges(let changes):
            // A zone gone: the owner stopped sharing, or this Mac was left out.
            for deletion in changes.deletions {
                Self.log.notice("Zone \(deletion.zoneID.zoneName, privacy: .public) is gone")
                stopSharing(deletion.zoneID.zoneName)
            }
        case .fetchedRecordZoneChanges(let changes):
            received(changes)
        case .sentRecordZoneChanges(let sent):
            self.sent(sent, by: syncEngine)
        case .sentDatabaseChanges(let sent):
            for failure in sent.failedZoneSaves {
                NSLog("Bezzle could not make the zone %@: %@", failure.zone.zoneID.zoneName, failure.error.localizedDescription)
            }
        case .willFetchChanges, .willSendChanges:
            busy = true
        case .didFetchChanges, .didSendChanges:
            busy = false
        default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext, syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await self.record(for: id)
        }
    }
}

#if DEBUG
extension CloudSync {
    /// For BEZZLE_ARRIVING: a shared design on its way, as an invitation makes one.
    func pretendArriving(_ title: String, from owner: String?) {
        arriving["design-preview-\(title)"] = Arrival(title: title, owner: owner)
    }

    /// Saves one record of each kind sharing uses, with every field, in a zone of its own, and
    /// takes the zone away again. iCloud's development environment learns record types from what
    /// is saved; production only has what is deployed to it from there, in the CloudKit Console.
    /// For BEZZLE_ICLOUD_SCHEMA: run it again whenever a record type or field is added.
    func teachSchema() async throws -> String {
        let database = container.privateCloudDatabase
        let zone = CKRecordZone(zoneName: "schema-\(UUID().uuidString)")
        _ = try await database.modifyRecordZones(saving: [zone], deleting: [])
        let file = outgoing.appendingPathComponent("schema.bin")
        try Data([0]).write(to: file)
        func record(_ kind: String, _ fields: [String: CKRecordValue]) -> CKRecord {
            let record = CKRecord(recordType: kind, recordID: CKRecord.ID(recordName: kind, zoneID: zone.zoneID))
            for (key, value) in fields { record[key] = value }
            record["file"] = CKAsset(fileURL: file)
            return record
        }
        let records = [
            record(Kind.change, ["by": "schema" as NSString, "upTo": NSNumber(value: Int64(0)), "data": Data([0]) as NSData]),
            record(Kind.snapshot, ["upTo": NSNumber(value: Int64(0)), "data": Data([0]) as NSData]),
            record(Kind.picture, ["name": "schema.png" as NSString]),
            record(Kind.version, ["name": "schema" as NSString, "at": NSNumber(value: Int64(0)), "by": "schema" as NSString,
                                  "replica": "schema" as NSString, "layers": NSNumber(value: Int64(0))]),
            CKShare(recordZoneID: zone.zoneID),
        ]
        var lines: [String] = []
        do {
            let saved = try await database.modifyRecords(saving: records, deleting: [])
            for (id, result) in saved.saveResults {
                switch result {
                case .success(let r): lines.append("saved \(r.recordType) (\(id.recordName))")
                case .failure(let error): lines.append("could not save \(id.recordName): \(error)")
                }
            }
        } catch {
            lines.append("could not save: \(error)")
        }
        _ = try? await database.modifyRecordZones(saving: [], deleting: [zone.zoneID])
        try? FileManager.default.removeItem(at: file)
        return lines.sorted().joined(separator: "\n") + "\n"
    }
}
#endif
