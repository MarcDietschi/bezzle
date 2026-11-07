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

    /// One way through the prototype, as the Mac's StoryRow tells it: from which layer (or a
    /// screen that goes on by itself) to where, the screen the layer lies on, and why.
    public struct StoryLine {
        public let source: UUID
        public let title: String
        public let to: String
        public let back: Bool
        /// The screen the layer lies on, when it is not the screen itself.
        public let from: String?
        public let note: String?
        /// How long a screen waits before it goes on by itself.
        public let after: Double?
    }

    /// The ways through the prototype, in the order the design holds them.
    public static func flowStory() -> [StoryLine] {
        guard let doc = design else { return [] }
        return Prototype.links(in: doc).prefix(60).map { link in
            let screen = doc.node(link.board)?.name ?? ""
            let itself = link.source == link.board
            return StoryLine(source: link.source, title: itself ? screen : doc.node(link.source)?.name ?? "",
                             to: link.flow.goesBack ? say("Back") : link.flow.to.flatMap { doc.node($0)?.name } ?? "",
                             back: link.flow.goesBack, from: itself ? nil : screen, note: link.flow.note,
                             after: itself ? link.flow.after : nil)
        }
    }

    /// How the screen a layer goes to would come on, read from the canvas, for the automatic
    /// choice to say so: its kind ("push", "morph", "sheet", "dissolve", "instant"), the side a
    /// push comes from, and in a few words.
    public static func flowWay(_ selection: [UUID]) -> (kind: String, dx: Double, dy: Double, reading: String)? {
        guard let doc = design, let id = selection.compactMap({ doc.linkable($0) }).first, let to = doc.node(id)?.flow?.to,
              let a = doc.artboard(of: id), let b = doc.node(to) else { return nil }
        switch Prototype.way(from: a, to: b, motion: nil) {
        case .push(let from, let morph):
            if morph { return ("morph", Double(from.dx), Double(from.dy), say("What both screens share moves; the rest changes round it.")) }
            let words = from.dx > 0 ? "Slides in from the right, as it lies on the canvas."
                : from.dx < 0 ? "Slides in from the left, as it lies on the canvas."
                : from.dy > 0 ? "Rises from below, as it lies on the canvas." : "Comes down from above, as it lies on the canvas."
            return ("push", Double(from.dx), Double(from.dy), say(words))
        case .sheet: return ("sheet", 0, 0, say("Smaller than the screen it opens on: rises over it as a sheet."))
        case .dissolve: return ("dissolve", 0, 0, say("Fades in."))
        case .instant: return ("instant", 0, 0, say("Comes on at once."))
        }
    }

    // MARK: The design as code

    /// How many named looks the design has, which come out as tokens.
    public static var tokenCount: Int { design.map(DesignTokens.count) ?? 0 }

    /// The design's named looks as tokens: "css", "swiftui" or "json".
    public static func tokens(_ format: String, named name: String) -> String? {
        guard let doc = design, let f = DesignTokens.Format(rawValue: format) else { return nil }
        return DesignTokens.write(doc, named: name, as: f)
    }

    // MARK: A copy's states

    /// What a copy of a component shows as it is used, as the Mac's StatesCard: each variant,
    /// the state its name says and what that does in the player; the states it has no variant for.
    public struct CopyStates {
        public struct Row {
            public let variant: Int?
            public let name: String
            /// The state's own name and what it does, when the variant's name says one.
            public let state: String?
            public let does: String?
        }
        public let copy: UUID
        public let rows: [Row]
        /// The states named, or "None".
        public let summary: String
        /// The states to add: their keys, names and what each does.
        public let missing: [(key: String, title: String, does: String)]
        public let locked: Bool
    }

    public static func copyStates(_ selection: [UUID]) -> CopyStates? {
        guard let doc = design, let copy = doc.selectedCopy(selection), let master = doc.component(of: copy) else { return nil }
        let variants = Components.variants(of: master)
        let states = Components.states(of: master)
        let rows = variants.map { v -> CopyStates.Row in
            let state = Components.state(of: v, in: master)
            return CopyStates.Row(variant: v, name: Components.name(of: v, in: master), state: state?.title, does: state?.does)
        }
        let named = variants.compactMap { Components.state(of: $0, in: master)?.title }
        let missing = [VariantState.hover, .pressed, .selected, .disabled, .loading].filter { states[$0] == nil }.map { ($0.rawValue, $0.title, $0.does) }
        return CopyStates(copy: copy.id, rows: rows, summary: named.isEmpty ? say("None") : named.joined(separator: ", "), missing: missing,
                          locked: copy.locked)
    }

    /// Every state a variant can be made by its name: its key and name.
    public static var variantStates: [(key: String, title: String)] { VariantState.allCases.map { ($0.rawValue, $0.title) } }

    /// A new variant, as the copy looks now, named for the state and shown in the copy to change,
    /// as one step: what is picked then, in the new variant's layers.
    public static func addState(_ key: String, _ selection: [UUID]) -> [UUID] {
        guard let state = VariantState(rawValue: key), let doc = design, let copy = doc.selectedCopy(selection), let inst = copy.instance,
              let master = doc.component(of: copy) else { return selection }
        var made: Int?
        edit {
            made = $0.addVariant(from: copy)
            if let made { $0.renameVariant(made, of: master.id, to: state.title) }
        }
        guard let made, let now = design else { return selection }
        let k = Deck.key(inst.variant) ^ Deck.key(made)
        return selection.map { id in now.node(id) == nil && now.node(id.mixed(k)) != nil ? id.mixed(k) : id }.filter { now.node($0) != nil }
    }

    /// A variant made a state by its name.
    public static func useAs(_ key: String, variant: Int?, of copy: UUID) {
        guard let state = VariantState(rawValue: key) else { return }
        renameVariant(variant, of: copy, to: state.title)
    }
}
