import Foundation
import CoreGraphics

// MARK: - Flows

/// Where a layer goes when it is tapped in the prototype: to another screen (an artboard), or back
/// to the one before. It is the layer's own, as its words are: a copy of a component, a cell of a
/// grid and a post of a deck each go where they were told to, whatever the others do.
///
/// How it moves is not set, but read from the canvas: a screen lying to the right of the one it
/// comes from slides in from the right, one lying below rises from below, one narrower or shorter
/// than it opens over it as a sheet, and what the two screens have alike (the same layers by name)
/// moves from where it was to where it is, as the rest of them change round it. Lay the screens
/// out the way they should move.
nonisolated struct FlowLink: Codable, Hashable, Sendable {
    /// The screen it goes to, by the artboard's id. Nil, unless it goes back, while it goes nowhere.
    var to: UUID?
    /// Goes back to the screen it was come to from.
    var back: Bool?
    /// Why, or when, in the designer's own words: "after a successful login".
    var note: String?
    /// How it moves; nil reads it from where the screens lie (`FlowMotion.auto`).
    var motion: FlowMotion?
    /// Artboards only: goes on by itself, this many seconds after the screen shows.
    var after: Double?

    init(to: UUID? = nil, back: Bool? = nil, note: String? = nil, motion: FlowMotion? = nil, after: Double? = nil) {
        self.to = to
        self.back = back
        self.note = note
        self.motion = motion
        self.after = after
    }

    var goesBack: Bool { back == true }
    /// Whether it goes anywhere at all.
    var leads: Bool { to != nil || goesBack }
}

/// How a screen comes on. Automatic is nearly always right: it is read from the canvas.
nonisolated enum FlowMotion: String, Codable, CaseIterable, Hashable, Sendable {
    /// Read from where the screens lie, and what they have alike.
    case auto
    /// Slides in from the side the screen lies on, the one before giving way.
    case slide
    /// The one before fades into it.
    case dissolve
    /// At once.
    case instant

    var title: String {
        switch self {
        case .auto: String(localized: "motion.auto", defaultValue: "Auto")
        case .slide: String(localized: "motion.slide", defaultValue: "Slide")
        case .dissolve: String(localized: "motion.dissolve", defaultValue: "Dissolve")
        case .instant: String(localized: "motion.instant", defaultValue: "Instant")
        }
    }
}

// MARK: - States

/// What a component's variant is for in a prototype, read from its name: a variant called
/// "Hover" shows while the pointer is on a copy, "Pressed" while it is pressed, "Selected" when
/// a tap turns it on, and so on. Nothing to set up: naming it says it, for people and for an
/// assistant building the prototype in code alike.
nonisolated enum VariantState: String, CaseIterable, Codable, Hashable, Sendable {
    case hover, pressed, focused, selected, disabled, loading, error, success

    /// The names it goes by, in each language Bezzle speaks and as designers write them, lower
    /// case with no accents.
    var aliases: [String] {
        switch self {
        case .hover: ["hover", "hovered", "hovering", "mouseover", "over", "survol", "survole", "uberfahren", "sopra", "passaggio"]
        case .pressed: ["pressed", "press", "down", "tap", "tapped", "active", "gedruckt", "gedrueckt", "appuye", "presse", "enfonce", "premuto"]
        case .focused: ["focus", "focused", "fokus", "fokussiert", "focalise", "focalizzato"]
        case .selected: ["selected", "on", "checked", "chosen", "current", "ausgewahlt", "ausgewaehlt", "aktiviert", "an", "gewahlt",
                         "selectionne", "coche", "actif", "selezionato", "attivo", "spuntato"]
        case .disabled: ["disabled", "inactive", "unavailable", "deaktiviert", "inaktiv", "gesperrt", "desactive", "indisponible",
                         "disabilitato", "disattivato", "inattivo"]
        case .loading: ["loading", "busy", "progress", "spinner", "wait", "waiting", "ladt", "laedt", "laden", "ladend",
                        "chargement", "caricamento", "attesa"]
        case .error: ["error", "invalid", "failed", "failure", "fehler", "ungultig", "fehlerhaft", "erreur", "invalide", "errore", "non valido"]
        case .success: ["success", "done", "valid", "complete", "completed", "erfolg", "erfolgreich", "fertig", "succes", "reussi",
                        "valide", "successo", "completato"]
        }
    }

    /// The name a variant is given to be this state.
    var title: String {
        switch self {
        case .hover: String(localized: "state.hover", defaultValue: "Hover")
        case .pressed: String(localized: "state.pressed", defaultValue: "Pressed")
        case .focused: String(localized: "state.focused", defaultValue: "Focused")
        case .selected: String(localized: "state.selected", defaultValue: "Selected")
        case .disabled: String(localized: "state.disabled", defaultValue: "Disabled")
        case .loading: String(localized: "state.loading", defaultValue: "Loading")
        case .error: String(localized: "state.error", defaultValue: "Error")
        case .success: String(localized: "state.success", defaultValue: "Success")
        }
    }

    /// What the state does in the player, in a few words.
    var does: String {
        switch self {
        case .hover: String(localized: "Shows while the pointer is on it")
        case .pressed: String(localized: "Shows while it is pressed")
        case .focused: String(localized: "Shows once it is tapped, like a field")
        case .selected: String(localized: "A tap turns it on and off")
        case .disabled: String(localized: "Takes no taps")
        case .loading: String(localized: "Shows for a moment before it goes on")
        case .error: String(localized: "For the code to show when something fails")
        case .success: String(localized: "For the code to show when something worked")
        }
    }

    /// The state a variant's name says it is, if it says one: the whole name, or one of its words
    /// ("Button / Hover", "Primary pressed").
    static func of(_ name: String) -> VariantState? {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        let whole = folded.trimmingCharacters(in: .whitespacesAndNewlines)
        if let s = allCases.first(where: { $0.aliases.contains(whole) }) { return s }
        let words = folded.split { !$0.isLetter }.map(String.init)
        // The last word that names a state wins: "Selected hover" is a hover.
        for word in words.reversed() {
            if let s = allCases.first(where: { $0.aliases.contains(word) }) { return s }
        }
        return nil
    }
}

nonisolated extension Components {
    /// The states a component's variants are, each by the first variant that is it.
    static func states(of master: Node) -> [VariantState: Int?] {
        var out: [VariantState: Int?] = [:]
        for v in variants(of: master) {
            guard let s = VariantState.of(name(of: v, in: master)), out[s] == nil else { continue }
            out[s] = .some(v)
        }
        return out
    }

    /// The state a variant is, from its name.
    static func state(of variant: Int?, in master: Node) -> VariantState? {
        // The first variant is only a state when it has been named one.
        guard variant != nil || master.master?.names?["0"]?.isEmpty == false else { return nil }
        return VariantState.of(name(of: variant, in: master))
    }
}

// MARK: - The prototype as a whole

nonisolated enum Prototype {
    /// A layer that goes somewhere, and the screen it lies on.
    struct Link: Hashable {
        let source: UUID
        let board: UUID
        let flow: FlowLink
    }

    /// Every flow in the design that leads somewhere, from layers and from screens themselves
    /// (those that go on by themselves), in the order the layers lie.
    static func links(in doc: BezzleDocument) -> [Link] {
        var out: [Link] = []
        // Only to screens there are: one deleted, or left behind in another design, leads nowhere.
        let screens = Set(doc.nodes.lazy.filter(\.isArtboard).map(\.id))
        func leads(_ f: FlowLink) -> Bool { f.goesBack || f.to.map(screens.contains) == true }
        for board in doc.nodes where board.isArtboard && !board.hidden {
            if let f = board.flow, leads(f) { out.append(Link(source: board.id, board: board.id, flow: f)) }
            func visit(_ nodes: [Node]) {
                for n in nodes where !n.hidden {
                    if let f = n.flow, leads(f) { out.append(Link(source: n.id, board: board.id, flow: f)) }
                    if !n.children.isEmpty { visit(n.children) }
                }
            }
            visit(board.children)
        }
        return out
    }

    /// The screens a prototype can show: every artboard there is to see.
    static func screens(in doc: BezzleDocument) -> [Node] {
        doc.nodes.filter { $0.isArtboard && !$0.hidden }
    }

    /// Where the prototype starts: the screen marked to, or else the first one any flow leaves
    /// from that none leads to, or else the first screen there is.
    static func start(of doc: BezzleDocument) -> Node? {
        let screens = screens(in: doc)
        if let marked = screens.first(where: { $0.starts == true }) { return marked }
        let all = links(in: doc)
        let reached = Set(all.compactMap(\.flow.to))
        if let first = all.first(where: { !reached.contains($0.board) }), let n = screens.first(where: { $0.id == first.board }) { return n }
        return screens.first
    }

    /// The screens a flow from each screen leads to, for following the prototype from its start.
    static func reach(in doc: BezzleDocument) -> [UUID: [UUID]] {
        var out: [UUID: [UUID]] = [:]
        let ids = Set(screens(in: doc).map(\.id))
        for l in links(in: doc) {
            guard let to = l.flow.to, ids.contains(to), to != l.board else { continue }
            if out[l.board]?.contains(to) != true { out[l.board, default: []].append(to) }
        }
        return out
    }

    /// How many flows it is from the start to each screen, following them.
    static func steps(from start: UUID, in doc: BezzleDocument) -> [UUID: Int] {
        let reach = reach(in: doc)
        var out: [UUID: Int] = [start: 0]
        var queue = [start]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for next in reach[id] ?? [] where out[next] == nil {
                out[next] = out[id]! + 1
                queue.append(next)
            }
        }
        return out
    }

    // MARK: How a screen comes on

    /// How one screen gives way to the next, as read from where they lie.
    enum Way: Equatable {
        /// The next comes in from `from` (a unit vector: 1,0 from the right), the one before
        /// giving way to the other side. With `morph`, what the two have alike moves from where
        /// it was to where it is, and the rest changes round it, rather than the whole sliding.
        case push(from: CGVector, morph: Bool)
        /// The next rises from the bottom over the one before, which dims behind it.
        case sheet
        case dissolve
        case instant

        var moves: Bool { self != .instant }
    }

    /// The side a screen lying at `to` comes in from, seen from one at `from`: the way the eye
    /// travels between them on the canvas.
    static func side(from a: CGRect, to b: CGRect) -> CGVector {
        let dx = b.midX - a.midX, dy = b.midY - a.midY
        let nx = dx / max((a.width + b.width) / 2, 1), ny = dy / max((a.height + b.height) / 2, 1)
        if abs(nx) < 0.01, abs(ny) < 0.01 { return CGVector(dx: 1, dy: 0) }
        return abs(nx) >= abs(ny) ? CGVector(dx: nx >= 0 ? 1 : -1, dy: 0) : CGVector(dx: 0, dy: ny >= 0 ? 1 : -1)
    }

    /// How `b` comes on after `a`.
    static func way(from a: Node, to b: Node, motion: FlowMotion?) -> Way {
        switch motion ?? .auto {
        case .instant: return .instant
        case .dissolve: return .dissolve
        case .slide: return .push(from: side(from: a.frame, to: b.frame), morph: false)
        case .auto:
            // Narrower or shorter than the screen it comes from, and not wider: it opens over it.
            if b.frame.width <= a.frame.width + 0.5, b.frame.height < a.frame.height * 0.92 || b.frame.width < a.frame.width * 0.92 {
                return .sheet
            }
            return .push(from: side(from: a.frame, to: b.frame), morph: alike(a, b))
        }
    }

    /// Whether two screens are mostly the same screen, changed: then what they share moves, and
    /// the rest changes round it, rather than one screen sliding over the other.
    static func alike(_ a: Node, _ b: Node) -> Bool {
        guard !b.children.filter({ !$0.hidden }).isEmpty else { return false }
        // Made from the same screen: most of their layers, shown or hidden, are the same layers by
        // name, as in a screen duplicated and changed.
        let all = matches(a.children, b.children, hidden: true)
        let share = Double(all.count) / Double(max(1, max(a.children.count, b.children.count)))
        guard share >= 0.6 else { return false }
        // Layers lying where they did, looking as they did, are what screens of one app share
        // (bars, a title); they stay put as the rest slides. Only when more than that moves or
        // changes, or comes and goes, are the two one screen changing.
        let byID = Dictionary(b.children.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        return all.contains { id, m in byID[id].map { !same(m, $0) } ?? false }
    }

    /// Whether a layer lies and looks on one screen as it does on the other, but for its id.
    static func same(_ a: Node, _ b: Node) -> Bool { plain(a) == plain(b) }

    /// A layer with every id in it the same blank one, going nowhere and as designed, whatever
    /// its film has it do, to be compared by look.
    private static func plain(_ n: Node) -> Node {
        var m = n
        m.id = blank
        m.flow = nil
        m.motion = nil
        m.film = nil
        m.children = n.children.map(plain)
        m.mask = n.mask?.map(plain)
        return m
    }

    private static let blank = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Which layer of `a` each layer of `b` is, by kind and name, the first of a name with the
    /// first, the second with the second; a copy of a component with a copy of the same one; a
    /// layer that is the very same (by id) with itself. Keyed by `b`'s ids.
    static func matches(_ a: [Node], _ b: [Node], hidden: Bool = false) -> [UUID: Node] {
        var out: [UUID: Node] = [:]
        var used = Set<UUID>()
        let byID = Dictionary(a.map { ($0.id, $0) }, uniquingKeysWith: { x, _ in x })
        for n in b where hidden || !n.hidden {
            if let m = byID[n.id], hidden || !m.hidden {
                out[n.id] = m
                used.insert(m.id)
            }
        }
        func key(_ n: Node) -> String {
            if let i = n.instance { return "copy:\(i.of.uuidString):\(n.name)" }
            return "\(n.kind.rawValue):\(n.name)"
        }
        var waiting: [String: [Node]] = [:]
        for m in a where (hidden || !m.hidden) && !used.contains(m.id) { waiting[key(m), default: []].append(m) }
        for n in b where (hidden || !n.hidden) && out[n.id] == nil {
            let k = key(n)
            guard var list = waiting[k], !list.isEmpty else { continue }
            out[n.id] = list.removeFirst()
            waiting[k] = list
        }
        return out
    }

    // MARK: Finding what was tapped

    /// The layers under a point of an artboard (in its own coordinates), the topmost first, each
    /// with what holds it after it: the layer itself, then its group, and so on up.
    @MainActor static func chain(at p: CGPoint, in board: Node, tolerance: CGFloat = 0) -> [Node] {
        func look(_ nodes: [Node], _ p: CGPoint, _ above: [Node]) -> [Node]? {
            for n in nodes.reversed() where !n.hidden {
                guard Geometry.contains(n, p, tolerance: tolerance) else { continue }
                if n.isGroup {
                    let inner = CGPoint(x: p.x - n.frame.minX, y: p.y - n.frame.minY)
                    if let deeper = look(n.children, inner, [n] + above) { return deeper }
                }
                return [n] + above
            }
            return nil
        }
        return look(board.children, p, []) ?? []
    }

    /// Where a layer lies on its artboard, however deep in groups.
    static func frame(of id: UUID, in board: Node) -> CGRect? {
        func look(_ nodes: [Node], _ o: CGPoint) -> CGRect? {
            for n in nodes {
                if n.id == id { return n.frame.offsetBy(dx: o.x, dy: o.y) }
                if !n.children.isEmpty, let r = look(n.children, CGPoint(x: o.x + n.frame.minX, y: o.y + n.frame.minY)) { return r }
            }
            return nil
        }
        return look(board.children, .zero)
    }
}

// MARK: - Linking

nonisolated extension BezzleDocument {
    /// The layer that takes a flow for one picked at `id`: the copy of a component it lies in (the
    /// innermost, so a button in a card is the button), or else the layer itself. Artboards take
    /// their own, for going on by themselves.
    func linkable(_ id: UUID) -> UUID? {
        guard let n = node(id) else { return nil }
        if n.isArtboard { return id }
        if n.isCopy { return id }
        if let copy = ancestors(of: id).last(where: \.isCopy) { return copy.id }
        return id
    }

    /// The screens marked as where the prototype starts become just this one.
    mutating func markStart(_ board: UUID?) {
        for n in nodes where n.isArtboard {
            let on = n.id == board
            if (n.starts == true) != on { update(n.id) { $0.starts = on ? true : nil } }
        }
    }

    /// Flows that lead to a screen no longer there go nowhere.
    func danglingFlows() -> [UUID] {
        let screens = Set(artboards.map(\.id))
        return allNodes.compactMap { n in
            guard let to = n.flow?.to, !screens.contains(to) else { return nil }
            return n.id
        }
    }
}
