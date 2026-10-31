import Testing
import AppKit
@testable import Bezzle

/// The welcome tour: its sheets in order, what is there to read locked and what is there to try
/// free, a stack made as the app makes one, and the canvas opening on the first sheet.
@MainActor
struct WelcomeTests {
    @Test func sheetsRunDownFromTheWelcome() {
        let doc = Welcome.design()
        // Listed from the first down: the welcome sheet lies on top.
        let sheets = Array(doc.nodes.reversed())
        #expect(sheets.count == 11)
        #expect(sheets.allSatisfy { $0.isArtboard })
        #expect(sheets.first?.id == Welcome.coverID)
        #expect(sheets.map(\.name).dropFirst().allSatisfy { $0.first?.isNumber == true })
        for (above, below) in zip(sheets, sheets.dropFirst()) {
            #expect(below.frame.minY > above.frame.maxY + 100)
            #expect(below.frame.minX == above.frame.minX)
        }
    }

    @Test func wordsAreLockedAndThingsToTryAreFree() {
        let doc = Welcome.design()
        for name in ["Sun", "Poster", "Tile", "Lemon", "Card", "Panel", "Photo frame"] {
            let found = doc.allNodes.filter { $0.name == name }
            #expect(!found.isEmpty, "no \(name)")
            #expect(found.contains { !$0.locked && !doc.ancestors(of: $0.id).contains { $0.locked } }, "\(name) is locked")
        }
        // Words straight on a sheet are there to be read, and stay put; but for the headline to type over.
        for sheet in doc.nodes {
            for layer in sheet.children where layer.kind == .text {
                #expect(layer.locked == (layer.text != "Your words here."), "\(layer.name)")
            }
        }
    }

    @Test func stackHasThreePostsEachWithItsOwnWords() throws {
        let doc = Welcome.design()
        let stack = try #require(doc.nodes.first { $0.isDeck })
        #expect(stack.posts.count == 3)
        let titles = stack.posts.compactMap { post in
            stack.layers(of: post).first { $0.kind == .text && $0.style?.family == "Charter" && $0.style?.size == 34 }?.text
        }
        #expect(titles == ["This sheet is a stack.", "Restyle one, restyle all.", "Each post has its own words."])
        // Made whole already: opening it has nothing to repair.
        var repaired = doc
        repaired.repairDecks()
        repaired.repairGrids()
        #expect(repaired == doc)
    }

    @Test func survivesTheFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Welcome.bezzle")
        let doc = Welcome.design()
        try DesignFile.write(doc, to: url)
        #expect(try DesignFile.read(url) == doc)
    }

    @Test func opensOnTheWelcomeSheet() throws {
        let doc = Welcome.design()
        let store = DocumentStore(url: FileManager.default.temporaryDirectory, document: doc)
        store.canvasSize = CGSize(width: 860, height: 820)
        store.lookFirst()
        let cover = try #require(doc.node(Welcome.coverID)).frame
        let seen = store.viewport.toView(cover)
        #expect(seen.minX >= 0 && seen.maxX <= 860 && seen.minY >= 0 && seen.maxY <= 820)
        #expect(seen.width > 860 * 0.8)
        // Anything else still opens on everything.
        let other = DocumentStore(url: FileManager.default.temporaryDirectory, document: BezzleDocument())
        other.canvasSize = CGSize(width: 860, height: 820)
        other.lookFirst()
        #expect(other.viewport.zoom == 1)
    }
}
