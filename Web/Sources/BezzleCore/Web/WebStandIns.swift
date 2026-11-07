import Foundation
import AppKit

// What the shared drawing needs from parts of the app that are not here yet, kept as small as
// it can be: pictures from the page, photos drawn as taken, text on curves not drawn yet, and
// the two things the model takes from the app's Store.

/// The design's pictures, which the page has read and decoded before the design is drawn.
nonisolated final class Assets: @unchecked Sendable {
    let folder: URL?
    nonisolated(unsafe) private var kept: [String: CGImage?] = [:]

    init(folder: URL?) { self.folder = folder }

    func image(_ name: String, pixels: CGFloat = .infinity) -> CGImage? {
        if let image = kept[name] { return image }
        let reply = Host.call(.image, doubles: Array(name.utf8).map { Double($0) })
        let image: CGImage? = reply.count == 3 && reply[0] > 0 ? CGImage(width: Int(reply[1]), height: Int(reply[2]), source: .asset(Int(reply[0]))) : nil
        // One not here yet, as from a shared design's room, is asked for again next time.
        if image != nil { kept[name] = image }
        return image
    }

    func image(_ name: String, pixels: CGFloat, later: Bool) -> CGImage? { image(name, pixels: pixels) }
}

/// Photos are drawn as they were taken for now: the Mac develops them with Core Image.
nonisolated enum Developer {
    static func developed(_ picture: CGImage, _ develop: Develop?) -> CGImage { picture }
}

/// Text along a curve is not drawn here yet; it keeps its frame.
nonisolated enum CurvedText {
    final class Laid: @unchecked Sendable {
        let box: CGRect
        let anchor: CGPoint
        let anchorAngle: CGFloat
        let alignK: CGFloat
        init(box: CGRect) { self.box = box; anchor = CGPoint(x: box.midX, y: box.midY); anchorAngle = 0; alignK = 0.5 }
    }

    static func laid(_ node: Node) -> Laid? { nil }
    static func lay(_ node: Node, along path: CGPath, curve: TextCurve) -> Laid { Laid(box: CGRect(origin: .zero, size: node.frame.size)) }
    static func arc(for node: Node, apex: CGPoint, bend: Double) -> CGPath? { nil }
    static func hits(_ laid: Laid, _ p: CGPoint, tolerance: CGFloat) -> Bool { false }
    static func draw(_ laid: Laid, in ctx: CGContext, painting: ((CGContext) -> Void)? = nil) {}
}

/// The canvas's ink, light, as the page's canvas is.
enum CanvasInk {
    static let shadow = NSColor(srgbRed: 0x3A / 255, green: 0x32 / 255, blue: 0x26 / 255, alpha: 1)
}

/// Which drawing aids show, and so what snaps (the app's, in LayoutOperations.swift).
final class Helpers {
    static let shared = Helpers()
    var rulers = true
    var guides = true
    var grids = true
    var guidesLocked = false
}

/// A lock round a value, shared by drawings on several threads (the app's, in TileMaker.swift).
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

// The app's, in Assets.swift.
nonisolated extension Node {
    /// Whether this layer, or any it holds, is filled or bordered with the picture.
    func shows(picture name: String) -> Bool {
        paintedPictures.contains { $0.assets.contains(name) } || children.contains { $0.shows(picture: name) }
    }
}

/// How a design is kept on disk (the app's, in Store/DesignFile.swift): in the browser, a design
/// comes as its document and its pictures, so only the names are needed.
nonisolated enum DesignFile {
    static let documentName = "document.json"
    static let imagesFolder = "images"
    static func read(_ url: URL) throws -> BezzleDocument {
        var doc = try JSONDecoder().decode(BezzleDocument.self, from: Data(contentsOf: url.appendingPathComponent(documentName)))
        doc.repairStyles()
        return doc
    }
}

nonisolated extension DesignFile {
    static func isPackage(_ url: URL) -> Bool { true }
}
