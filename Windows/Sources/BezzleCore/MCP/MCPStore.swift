import Foundation

// The AI server on Windows works on the one design the window has open (`WindowsCore.design`),
// as the Mac's works on the designs open in its tabs. The tools copied from Bezzle/MCP ask a
// DocumentStore for it; this one answers from the core, and from the app (`MCPHost`) for what
// only the window knows: what is selected, what is in view, and which design is open.

/// What the app does for the AI server: it fills these in as it starts.
@MainActor public final class MCPHost {
    public static let shared = MCPHost()

    /// Where designs are kept: the home screen's folder.
    public var designsFolder: () -> URL = { FileManager.default.temporaryDirectory }
    /// Opens a design in the window, as home does; whether it is open now.
    public var open: (URL) -> Bool = { _ in false }
    /// Shows the home screen, the design saved and let go.
    public var close: () -> Void = {}
    /// The layers selected, and selecting others (on the artboard they are on).
    public var selection: () -> [UUID] = { [] }
    public var select: ([UUID]) -> Void = { _ in }
    /// The design changed: the window draws it again and saves it a moment later.
    public var edited: () -> Void = {}
    /// The part of the canvas in view, and how near it is looked at.
    public var visible: () -> CGRect = { .zero }
    public var zoom: () -> Double = { 1 }
    /// The view brought round: to everything, to a part of the canvas, or to a zoom.
    public var zoomToFit: () -> Void = {}
    public var show: (CGRect) -> Void = { _ in }
    public var setZoom: (Double) -> Void = { _ in }
    /// The artboard the selection is on, or the one last worked on, by its place in the design.
    public var focusedBoard: () -> Int? = { nil }
    /// Typing into a text ends, so a change comes after it.
    public var endEditing: () -> Void = {}
}

/// The Mac's DocumentStore as the tools ask it, over the open design.
@MainActor final class DocumentStore {
    static let open = DocumentStore()

    var doc: BezzleDocument { WindowsCore.design ?? BezzleDocument() }
    var seenDoc: BezzleDocument { WindowsCore.seen ?? doc }
    var url: URL { WindowsCore.designURL ?? URL(fileURLWithPath: "/") }
    var name: String { url.deletingPathExtension().lastPathComponent }
    var assets: Assets { WindowsCore.assets }
    var isOpen: Bool { WindowsCore.design != nil }
    var selection: [UUID] {
        get { MCPHost.shared.selection() }
        set { MCPHost.shared.select(newValue) }
    }
    var fronts: [UUID: Int] {
        get { WindowsCore.fronts }
        set { WindowsCore.fronts = newValue }
    }
    /// Nothing is pointed at by a person while the assistant works.
    var hovered: UUID? {
        get { nil }
        set {}
    }
    var layerCount: Int { doc.allNodes.count }
    /// The size new artboards are given: the Mac's standard one.
    var lastPreset: CGSize? { nil }
    var visibleCanvasRect: CGRect { MCPHost.shared.visible() }
    var zoom: Double { MCPHost.shared.zoom() }

    var focusedArtboard: Node? {
        guard let i = MCPHost.shared.focusedBoard(), doc.nodes.indices.contains(i), doc.nodes[i].isArtboard else { return nil }
        return doc.nodes[i]
    }

    var canUndo: Bool { !Editing.undos.isEmpty && Editing.gestureStart == nil }
    var canRedo: Bool { !Editing.redos.isEmpty && Editing.gestureStart == nil }

    /// Whether this is the design at `url`. A package's address may or may not end in a slash.
    func isAt(_ url: URL) -> Bool {
        isOpen && self.url.standardizedFileURL.path.lowercased() == url.standardizedFileURL.path.lowercased()
    }

    func zoomToFit() { MCPHost.shared.zoomToFit() }

    // MARK: What the Mac's store does to a design, as the tools ask it

    static func duplicate(_ ids: [UUID], in doc: inout BezzleDocument, offset: CGPoint) -> [UUID] {
        doc.duplicate(ids.filter { doc.node($0)?.locked == false }, offset: offset)
    }

    static func groupable(_ ids: [UUID], in doc: BezzleDocument) -> [UUID]? { doc.groupable(ids) }

    static let grouping: LocalizedStringResource = "Group"

    static func group(_ ids: [UUID], in doc: inout BezzleDocument, name: String?) -> UUID? {
        guard let group = doc.group(ids) else { return nil }
        if let name, !name.isEmpty { doc.update(group) { $0.name = name } }
        return group
    }

    static func ungroup(_ ids: [UUID], in doc: inout BezzleDocument) -> [UUID] {
        doc.ungroup(ids.filter { doc.node($0).map { $0.isGroup && !$0.isRepeatGrid } == true })
    }

    static func broken(_ deck: Node) -> Set<Int> { Deck.broken(deck) }
}
