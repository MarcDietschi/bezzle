import Testing
import AppKit
import CryptoKit
@testable import Bezzle

/// A design shared through a synced folder, worked on by two Macs and by Bezzle for Windows at
/// once (Windows/Sources/BezzleShare, run in the Windows VM): the Macs here, as FolderShareTests
/// has them, and in between the stages the folder kept in step by hand, as the sync service would.
/// Off unless `TEST_RUNNER_BEZZLE_WINDOWS_FOLDER` names a folder; each run does the next stage, as
/// `stage.txt` there says:
///
/// 0. Anna and Ben share Poster.bezzle and change it, Anna enough to fold, and Anna names a version.
/// 1. Windows has opened it and changed it (not here yet): Anna changes it meanwhile, adding a picture.
/// 2. Windows took Anna's change in and changed it again, and its files came here: everything
///    anyone did is in the design on every Mac, the same design Windows has, and Windows wrote
///    only in its own folder.
@MainActor
@Suite(.serialized)
struct WindowsShareTests {
    nonisolated private static let folder = ProcessInfo.processInfo.environment["BEZZLE_WINDOWS_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }

    private func layer(_ session: Collaboration, _ name: String) -> Node? {
        session.state.flatDesign().document().allNodes.first { $0.name == name }
    }

    private func edit(_ session: Collaboration, _ name: String, _ change: (inout Node) -> Void) {
        var doc = session.state.flatDesign().document()
        guard let id = doc.allNodes.first(where: { $0.name == name })?.id else { Issue.record("No layer \(name)"); return }
        doc.update(id, change)
        session.takeIn(doc)
        session.persist()
        DocumentStore.finishSaving()
    }

    /// Every file in a folder of one person's, by name, with what it holds.
    private func hashes(_ dir: URL) -> [String: String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var out: [String: String] = [:]
        for name in names {
            guard let data = try? Data(contentsOf: dir.appendingPathComponent(name)) else { continue }
            out[name] = Data(SHA256.hash(data: data)).hex
        }
        return out
    }

    private func json(_ doc: BezzleDocument) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(doc), as: UTF8.self)
    }

    private func read(_ file: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }

    private func design(in report: [String: Any]) throws -> BezzleDocument {
        let text = try #require(report["design"] as? String)
        return try JSONDecoder().decode(BezzleDocument.self, from: Data(text.utf8))
    }

    /// A small picture, as a PNG: stripes from blue to orange.
    private func picture() throws -> Data {
        let ctx = try #require(CGContext(data: nil, width: 64, height: 48, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for x in 0..<64 {
            ctx.setFillColor(CGColor(srgbRed: CGFloat(x) / 63, green: 0.45, blue: 1 - CGFloat(x) / 63, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: 48))
        }
        let image = try #require(ctx.makeImage())
        return try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    }

    @Test(.enabled(if: folder != nil))
    func aFolderSharedWithWindows() throws {
        let folder = try #require(Self.folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        SyncedFolders.forTests[folder.path] = "Google Drive"
        defer { SyncedFolders.forTests[folder.path] = nil }
        let url = folder.appendingPathComponent("Poster.bezzle")
        let stageFile = folder.appendingPathComponent("stage.txt")
        let stage = (try? String(contentsOf: stageFile, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        let anna = FolderSync.folder(of: "anna", in: url), ben = FolderSync.folder(of: "ben", in: url)

        switch stage {
        case 0:
            var board = Node(kind: .artboard, name: "Poster", frame: CGRect(x: 0, y: 0, width: 400, height: 300))
            board.children = [CanvasTests.rect("R", CGRect(x: 10, y: 10, width: 50, height: 50)),
                              CanvasTests.rect("S", CGRect(x: 100, y: 10, width: 50, height: 50)),
                              CanvasTests.rect("T", CGRect(x: 200, y: 10, width: 50, height: 50)),
                              AdaptTests.text("Shared with Windows", 24, at: CGPoint(x: 20, y: 120))]
            var doc = BezzleDocument()
            doc.nodes = [board]
            try DesignFile.write(doc, to: url)
            let a = try #require(Collaboration.open(url, replica: "anna"))
            let b = try #require(Collaboration.open(url, replica: "ben"))
            edit(a, "R") { $0.frame.origin.x = 300 }
            edit(b, "R") { $0.fill.color = .black }
            edit(b, "S") { $0.name = "S, renamed" }
            // Enough of Anna's for her changes to fold into wholes.
            for i in 1...30 { edit(a, "T") { $0.frame.origin.y = CGFloat(i) } }
            a.folder?.lookForTesting(for: a)
            b.folder?.lookForTesting(for: b)
            #expect(a.state == b.state)
            // A version Anna named, for everyone.
            var named = DesignVersion(date: Date(), name: "For the client", by: "Anna", replica: "anna", layers: 5)
            named.shared = true
            try VersionFiles.write(try #require(VersionFiles.pack(a.state.flatDesign().document())), as: named.id, to: url)
            try VersionFiles.writeIndex([named], to: url, replica: "anna")
            let merged = a.state.flatDesign().document()
            a.close()
            b.close()
            DocumentStore.finishSaving()
            #expect(FolderShare.parts(files: Array(hashes(anna).keys)).contains { $0.kind == .whole })
            try JSONSerialization.data(withJSONObject: ["design": try json(merged), "anna": hashes(anna), "ben": hashes(ben)])
                .write(to: folder.appendingPathComponent("mac-0.json"))
            try "1".write(to: stageFile, atomically: true, encoding: .utf8)

        case 1:
            // Windows has the design open and has changed it; its files are not here yet.
            let a = try #require(Collaboration.open(url, replica: "anna"))
            edit(a, "R") { $0.frame.origin.y = 222 }
            edit(a, "T") { $0.name = "T, later on the Mac" }
            let images = url.appendingPathComponent(DesignFile.imagesFolder, isDirectory: true)
            try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
            try picture().write(to: images.appendingPathComponent("photo.png"))
            var doc = a.state.flatDesign().document()
            var p = CanvasTests.rect("P", CGRect(x: 280, y: 180, width: 96, height: 72))
            p.fill.image = ImageFill(asset: "photo.png", size: CGSize(width: 64, height: 48))
            doc.nodes[0].children.append(p)
            a.takeIn(doc)
            a.persist()
            a.close()
            DocumentStore.finishSaving()
            try JSONSerialization.data(withJSONObject: ["anna": hashes(anna), "ben": hashes(ben)]).write(to: folder.appendingPathComponent("mac-1.json"))
            try "2".write(to: stageFile, atomically: true, encoding: .utf8)

        default:
            // Windows' files have come, and what it wrote down of its own run (windows/).
            let windows = folder.appendingPathComponent("windows", isDirectory: true)
            let opened = try read(windows.appendingPathComponent("opened.json"))
            let looked = try read(windows.appendingPathComponent("look.json"))
            let final = try read(windows.appendingPathComponent("final.json"))
            let replica = try #require(opened["replica"] as? String)
            let mac0 = try read(folder.appendingPathComponent("mac-0.json")), mac1 = try read(folder.appendingPathComponent("mac-1.json"))

            // Windows opened the design as the Macs had it, knew who they were, and saw Anna's version.
            #expect(opened["shared"] as? Bool == true)
            #expect(try design(in: opened).nodes == (try design(in: mac0)).nodes)
            #expect(Set(opened["people"] as? [String] ?? []) == ["anna", "ben"])
            #expect((opened["versions"] as? [[String: Any]] ?? []).contains { $0["name"] as? String == "For the client" })
            // It took in what Anna did while it had the design open.
            #expect(looked["changed"] as? Bool == true)
            let seen = try design(in: looked)
            #expect(seen.allNodes.first { $0.name == "R" }?.frame.minY == 222)
            #expect(seen.allNodes.contains { $0.name == "T, later on the Mac" })
            #expect(seen.allNodes.contains { $0.name == "P" })

            // Windows wrote only in its own folder: Anna's and Ben's files are as the Macs left them.
            #expect(FolderShare.isReplica(replica) && replica != "anna" && replica != "ben")
            #expect(hashes(anna) == (mac1["anna"] as? [String: String] ?? [:]))
            #expect(hashes(ben) == (mac0["ben"] as? [String: String] ?? [:]))
            let mine = FolderSync.folder(of: replica, in: url)
            let parts = FolderShare.parts(files: try FileManager.default.contentsOfDirectory(atPath: mine.path))
            #expect(!parts.isEmpty)
            let me = try #require(FolderShare.decode(FolderShare.Person.self, from: Data(contentsOf: mine.appendingPathComponent(FolderShare.personFile))))
            #expect(me.replica == replica && me.app == "windows")
            let people = try FileManager.default.contentsOfDirectory(atPath: FolderSync.peopleFolder(of: url).path).filter { !$0.hasPrefix(".") }
            #expect(Set(people) == ["anna", "ben", replica])

            // On the Macs, nothing anyone did is lost.
            let a = try #require(Collaboration.open(url, replica: "anna"))
            let carl = try #require(Collaboration.open(url, replica: "carl"))
            defer { a.close(); carl.close(); DocumentStore.finishSaving() }
            for session in [a, carl] {
                let r = try #require(layer(session, "R"))
                #expect(r.frame.minX == 300 && r.frame.minY == 222)
                #expect(r.fill.color == .black)
                #expect(r.opacity == 0.5)
                #expect(layer(session, "S, from Windows") != nil)
                let t = try #require(layer(session, "T, later on the Mac"))
                #expect(t.frame.minY == 30)
                let w = try #require(layer(session, "W"))
                #expect(w.frame.minX == 60 && w.fill.color == RGBA(r: 0.2, g: 0.6, b: 0.3, a: 1))
                #expect(layer(session, "P")?.fill.image?.asset == "photo.png")
                // What nobody changed is as it was: Windows set no text of its own.
                #expect(layer(session, "Shared with Windows") == (try design(in: mac0)).allNodes.first { $0.name == "Shared with Windows" })
            }
            #expect(a.state == carl.state)
            // The same design on Windows as on the Macs.
            let windowsDesign = try design(in: final)
            let macDesign = a.state.flatDesign().document()
            #expect(windowsDesign == macDesign)
            print("Windows' design written the same, to the byte: \((final["design"] as? String) == (try json(macDesign)))")
            // The version Windows named is everyone's.
            let fromWindows = VersionFiles.index(of: url, replica: "anna").first { $0.name == "From Windows" }
            #expect(fromWindows?.replica == replica && fromWindows?.shared == true)
            if let fromWindows { #expect(VersionFiles.read(fromWindows.id, of: url) != nil) }
            try "3".write(to: stageFile, atomically: true, encoding: .utf8)
        }
    }
}
