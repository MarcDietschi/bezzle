import Foundation

// The prototype on Windows as the Mac's store changes it (Store/PrototypeOperations.swift), through
// the shared edits (Model/PrototypeEditing.swift): where layers go, what is said of it, how screens
// come on, a screen going on by itself, and where it starts; and what the inspector says of it.

extension WindowsCore {
    public static func linkFlow(_ ids: [UUID], to board: UUID?, back: Bool = false) {
        edit { $0.linkFlow(ids, to: board, back: back) }
    }

    public static func setFlowNote(_ note: String?, for ids: [UUID]) {
        edit { $0.setFlowNote(note, for: ids) }
    }

    /// How the screens come on, by the motion's name ("auto", "push", …).
    public static func setFlowMotion(_ motion: String, for ids: [UUID]) {
        guard let m = FlowMotion(rawValue: motion) else { return }
        edit { $0.setFlowMotion(m, for: ids) }
    }

    public static func setGoesOn(after seconds: Double?, board: UUID) {
        edit { $0.setGoesOn(after: seconds, board: board) }
    }

    public static func setStart(_ board: UUID?) {
        edit { $0.markStart(board) }
    }

    /// What is said of where a layer goes.
    public static func flowNote(_ id: UUID) -> String? { design?.node(id)?.flow?.note }

    /// The screens, in the order they lie: their ids, names, and which the prototype starts on.
    public static func prototypeScreens() -> [(id: UUID, name: String, starts: Bool)] {
        guard let doc = design else { return [] }
        return Prototype.screens(in: doc).map { ($0.id, $0.name, $0.starts == true) }
    }

    /// The motions a flow can have: their names and titles.
    public static var flowMotions: [(name: String, title: String)] {
        FlowMotion.allCases.map { ($0.rawValue, $0.title) }
    }

    /// Where the layers the selection links from go, as the inspector's Goes To card says it: the
    /// layers (each, or the copy it lies in), whether one is a screen, the screen they go to or
    /// back, alike for all, what is said of it, its motion, and how long a picked screen waits
    /// before going on by itself.
    public struct FlowLook: Sendable {
        public let sources: [UUID]
        public let screen: UUID?
        public let to: UUID?
        public let back: Bool
        public let alike: Bool
        public let note: String?
        public let motion: String
        public let after: Double?
        public let home: UUID?
    }

    public static func flowLook(_ selection: [UUID]) -> FlowLook? {
        guard let doc = design else { return nil }
        var seen = Set<UUID>()
        let sources = selection.compactMap { doc.linkable($0) }.filter { seen.insert($0).inserted }
        guard let first = sources.first else { return nil }
        let flows = sources.map { doc.node($0)?.flow }
        let alike = flows.allSatisfy { $0?.to == flows[0]?.to && $0?.back == flows[0]?.back }
        let f = flows[0]
        let node = doc.node(first)
        let screen = node?.isArtboard == true ? first : nil
        return FlowLook(sources: sources, screen: screen, to: f?.to, back: f?.goesBack == true, alike: alike, note: f?.note,
                        motion: (f?.motion ?? .auto).rawValue, after: f?.after,
                        home: node?.isArtboard == true ? first : doc.artboard(of: first)?.id)
    }

    /// How many ways lead into a screen from other screens.
    public static func waysIn(_ board: UUID) -> Int {
        guard let doc = design else { return 0 }
        return Prototype.links(in: doc).filter { $0.flow.to == board && $0.board != board }.count
    }

    /// The ways through the prototype, from the start: what each layer is called, where it goes,
    /// and what is said of it.
    public static func flowStory() -> [(from: String, to: String, note: String?)] {
        guard let doc = design else { return [] }
        let order = Prototype.start(of: doc).map { Prototype.steps(from: $0.id, in: doc) } ?? [:]
        return Prototype.links(in: doc).sorted { (order[$0.board] ?? 99, $0.board.uuidString) < (order[$1.board] ?? 99, $1.board.uuidString) }
            .map { link in
                let from = doc.node(link.source)?.name ?? ""
                let to = link.flow.goesBack ? say("Back") : link.flow.to.flatMap { doc.node($0)?.name } ?? ""
                return (from, to, link.flow.note)
            }
    }
}
