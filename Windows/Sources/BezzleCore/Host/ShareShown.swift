import Foundation

// What the window and home show of how designs are shared, as the Mac has it: the mark of a design
// not open (Library.mark(of:), FolderSync.mark(of:)), whether it may be renamed
// (SharingMark.renamable), whether sending it to the Recycle Bin stops a share (Library.mayTrash),
// stopping that share even while the relay cannot be reached (Sharing.stopSharing(designAt:)),
// and a copy made a design of its own (Library.duplicate).

extension WindowsCore.ShareMark {
    /// Whether the design may be given a new name here: someone else's keeps the name it was
    /// shared under, as on the Mac.
    public var renamable: Bool {
        switch self {
        case .sharedBy, .ended: false
        case .shared, .inFolder: true
        }
    }
}

extension WindowsCore {
    /// Something about the open design's share that the window shows changed: others' changes
    /// came, the owner stopped sharing it, a picture arrived, the relay could or could not be
    /// reached. Called on the main thread; the app looks again.
    nonisolated(unsafe) public static var shareNews: (() -> Void)?

    static func tellShareNews() {
        DispatchQueue.main.async { MainActor.assumeIsolated { shareNews?() } }
    }

    /// Bezzle came to the front: the open design's room is looked at at once, and the shares
    /// still to stop are tried again (the Mac's Sharing.lookNow).
    public static func cameToFront() {
        sharing?.cloud?.syncSoon()
        stopWhatIsLeft()
    }

    /// Whether this copy of Bezzle can share designs by link: it has a relay to share through.
    public static var canShare: Bool { Linking.server != nil }

    /// How a design not open is shared, for its card on home: by link, or through the synced
    /// folder it is kept in, with others' files in it.
    public static func shareMark(of url: URL) -> ShareMark? {
        if let link = Linking.link(of: url) {
            if link.ended { return .ended }
            if let room = link.keys?.room { return Linking.owns(room) ? .shared : .sharedBy(link.ownerName) }
        }
        guard FolderShare.isShared(url), let service = SyncedPlaces.service(of: url) else { return nil }
        let me = FolderCopy.me(replica: replica)
        let folders = (try? FileManager.default.contentsOfDirectory(at: FolderShare.people(of: url), includingPropertiesForKeys: nil,
                                                                    options: [.skipsHiddenFiles])) ?? []
        let others = folders.contains { dir in
            guard dir.lastPathComponent != me.replica,
                  let data = try? Data(contentsOf: dir.appendingPathComponent(FolderShare.personFile)),
                  let person = FolderShare.decode(FolderShare.Person.self, from: data) else { return false }
            return !person.isSamePerson(as: me)
        }
        return others ? .inFolder(service) : nil
    }

    /// Whether this computer shared the design at `url`: sending it to the Recycle Bin stops the
    /// share, so the person is asked first (the Mac's Library.mayTrash).
    public static func isSharedFromHere(_ url: URL) -> Bool {
        guard let room = Linking.link(of: url)?.keys?.room else { return false }
        return Linking.owns(room)
    }

    /// Stops sharing a design this computer shared that is not open, as when it goes to the
    /// Recycle Bin: the others keep it as it last was. Should the relay not be reached, it is
    /// tried again whenever Bezzle comes to the front, until it is.
    public static func stopSharing(designAt url: URL) {
        guard let keys = Linking.link(of: url)?.keys, let owner = Linking.ownerToken(for: keys.room) else { return }
        var stopping = sharesToStop
        stopping[keys.room] = ["write": keys.writeToken, "owner": owner]
        sharesToStop = stopping
        stopWhatIsLeft()
    }

    /// Rooms to stop sharing, with what that takes, until the relay has heard (the Mac's key).
    private static var sharesToStop: [String: [String: String]] {
        get { UserDefaults.standard.dictionary(forKey: "sharesToStop") as? [String: [String: String]] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "sharesToStop") }
    }

    /// Tries again to stop the shares still to stop; at launch and whenever Bezzle comes to the front.
    public static func stopWhatIsLeft() {
        guard let server = Linking.server else { return }
        for (room, tokens) in sharesToStop {
            guard let write = tokens["write"], let owner = tokens["owner"] else { continue }
            Task { @MainActor in
                do {
                    try await server.unshare(room, write: write, owner: owner)
                } catch ShareError.gone, ShareError.missing {
                } catch {
                    NSLog("Bezzle could not stop sharing a design in the Recycle Bin yet: %@", "\(error)")
                    return
                }
                var stopping = sharesToStop
                stopping[room] = nil
                sharesToStop = stopping
                Linking.forgetRoom(room)
            }
        }
    }

    /// Makes `copy`, just copied from `original` in the same folder, a design of its own, never
    /// shared: what everyone's files had of it goes into its own file, and its sharing goes (the
    /// Mac's Library.duplicate).
    public static func forgetSharing(ofCopy copy: URL, from original: URL) {
        if FolderShare.isShared(original), var doc = FolderShare.document(of: original) {
            let file = original.appendingPathComponent("document.json")
            doc.viewport = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode(BezzleDocument.self, from: $0) }?.viewport
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(doc) { try? data.write(to: copy.appendingPathComponent("document.json"), options: .atomic) }
        }
        try? FileManager.default.removeItem(at: FolderShare.sharing(of: copy))
    }
}
