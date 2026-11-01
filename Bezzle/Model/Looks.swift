import CoreGraphics

/// The three things a layer can have several of, one over another: fills, borders and shadows.
/// The first of each is the layer's own property, as it always was (`fill`, `border`, `shadow`),
/// kept while it is off so that bringing it back brings back its colour; the rest lie in
/// `moreFills`, `moreBorders` and `moreShadows`, and are always on. Each place in that order is a
/// slot: 0 is the first, the one at the bottom.
///
/// Kept apart this way, a layer with one of each is stored as it always was, and two people
/// changing the first shadow and adding a second both keep their change.
nonisolated enum Look: String, CaseIterable, Hashable, Sendable {
    case fill, border, shadow
}

nonisolated extension Node {
    // MARK: What is drawn

    /// Every fill the layer is painted with, bottom first. Set to none, the first is kept off,
    /// so that bringing it back brings back its colour.
    var fills: [Fill] {
        get { (fill.on ? [fill] : []) + (moreFills ?? []).filter(\.on) }
        set {
            if let first = newValue.first { fill = first } else { fill.on = false }
            moreFills = newValue.count > 1 ? Array(newValue.dropFirst()) : nil
        }
    }

    /// Every border drawn round the layer, the first at the bottom.
    var borders: [Border] {
        get { (border.on ? [border] : []) + (moreBorders ?? []).filter(\.on) }
        set {
            if let first = newValue.first { border = first } else { border.on = false }
            moreBorders = newValue.count > 1 ? Array(newValue.dropFirst()) : nil
        }
    }

    /// Every shadow the layer casts or holds, in the order they are cast.
    var shadows: [Shadow] {
        get { (shadow.on ? [shadow] : []) + (moreShadows ?? []).filter(\.on) }
        set {
            if let first = newValue.first { shadow = first } else { shadow.on = false }
            moreShadows = newValue.count > 1 ? Array(newValue.dropFirst()) : nil
        }
    }

    /// The shadows falling under the layer, and those falling inside it.
    var outerShadows: [Shadow] { shadows.filter(\.outside) }
    var innerShadows: [Shadow] { shadows.filter(\.inside) }

    /// How far out from the edge the widest border reaches, as the canvas measures what a border
    /// may cover: its whole width, whichever side of the edge it lies on.
    var borderWidth: CGFloat { borders.lazy.map(\.width).max() ?? 0 }

    // MARK: Slots

    /// How many places of a kind the layer has: the first, on or not, and each over it.
    func slots(_ look: Look) -> Int {
        switch look {
        case .fill: 1 + (moreFills?.count ?? 0)
        case .border: 1 + (moreBorders?.count ?? 0)
        case .shadow: 1 + (moreShadows?.count ?? 0)
        }
    }

    /// Whether the slot holds one that is on.
    func has(_ look: Look, _ slot: Int) -> Bool {
        guard slot >= 0, slot < slots(look) else { return false }
        switch look {
        case .fill: return self[fill: slot].on
        case .border: return self[border: slot].on
        case .shadow: return self[shadow: slot].on
        }
    }

    /// The fill in a slot. One the layer has no slot for reads as a fill that is off, and setting
    /// it changes nothing, so a change made to several layers passes over those without it.
    subscript(fill slot: Int) -> Fill {
        get { Stack.get(slot, fill, moreFills, missing: Fill(on: false, color: fill.color)) }
        set { Stack.set(slot, newValue, &fill, &moreFills) }
    }

    subscript(border slot: Int) -> Border {
        get { Stack.get(slot, border, moreBorders, missing: Border()) }
        set { Stack.set(slot, newValue, &border, &moreBorders) }
    }

    subscript(shadow slot: Int) -> Shadow {
        get { Stack.get(slot, shadow, moreShadows, missing: Shadow()) }
        set { Stack.set(slot, newValue, &shadow, &moreShadows) }
    }

    /// Where an editor reaches the fill in a slot: the layer's own `fill` for the first.
    static func fillPath(_ slot: Int) -> WritableKeyPath<Node, Fill> { slot == 0 ? \.fill : \.[fill: slot] }
    static func borderPath(_ slot: Int) -> WritableKeyPath<Node, Border> { slot == 0 ? \.border : \.[border: slot] }
    static func shadowPath(_ slot: Int) -> WritableKeyPath<Node, Shadow> { slot == 0 ? \.shadow : \.[shadow: slot] }

    // MARK: Adding, taking away and restacking

    /// Puts a fill on top of the others, or makes it the first while there is none.
    mutating func add(_ new: Fill) { Stack.add(new, &fill, &moreFills, firstOn: fill.on) }
    mutating func add(_ new: Border) { Stack.add(new, &border, &moreBorders, firstOn: border.on) }
    mutating func add(_ new: Shadow) { Stack.add(new, &shadow, &moreShadows, firstOn: shadow.on) }

    /// Takes away what is in a slot; the ones over it come down a place. Taking away the first
    /// while there are more makes the next the first; the last to go is only turned off.
    mutating func remove(_ look: Look, at slot: Int) {
        switch look {
        case .fill:
            Stack.remove(slot, &fill, &moreFills) { $0.on = false }
            // What it is mixed with goes with the last fill, as the card shows them together.
            if !fill.on && moreFills == nil { blend = nil }
        case .border: Stack.remove(slot, &border, &moreBorders) { $0.on = false }
        case .shadow: Stack.remove(slot, &shadow, &moreShadows) { $0.on = false }
        }
    }

    /// Moves what is in one slot to another, the ones between moving up or down a place. A
    /// picture stays at the bottom, where a repeat grid's cells and a stack's posts keep their own.
    mutating func move(_ look: Look, from: Int, to: Int) {
        switch look {
        case .fill:
            guard canMove(.fill, from: from, to: to) else { return }
            Stack.move(from, to: to, &fill, &moreFills)
        case .border: Stack.move(from, to: to, &border, &moreBorders)
        case .shadow: Stack.move(from, to: to, &shadow, &moreShadows)
        }
    }

    /// Whether one can move from a slot to another: not a picture, nor anything under one.
    func canMove(_ look: Look, from: Int, to: Int) -> Bool {
        let n = slots(look)
        guard from != to, (0..<n).contains(from), (0..<n).contains(to) else { return false }
        return look != .fill || fill.image == nil || min(from, to) > 0
    }
}

/// The first of a kind and those over it, worked on together.
nonisolated private enum Stack {
    static func get<T>(_ slot: Int, _ first: T, _ more: [T]?, missing: T) -> T {
        if slot == 0 { return first }
        guard let more, slot > 0, slot - 1 < more.count else { return missing }
        return more[slot - 1]
    }

    static func set<T>(_ slot: Int, _ value: T, _ first: inout T, _ more: inout [T]?) {
        if slot == 0 {
            first = value
        } else if var all = more, slot > 0, slot - 1 < all.count {
            all[slot - 1] = value
            more = all
        }
    }

    static func add<T>(_ value: T, _ first: inout T, _ more: inout [T]?, firstOn: Bool) {
        if firstOn { more = (more ?? []) + [value] } else { first = value }
    }

    static func remove<T>(_ slot: Int, _ first: inout T, _ more: inout [T]?, off: (inout T) -> Void) {
        if slot == 0 {
            if var all = more, !all.isEmpty {
                first = all.removeFirst()
                more = all.isEmpty ? nil : all
            } else {
                off(&first)
            }
        } else if var all = more, slot > 0, slot - 1 < all.count {
            all.remove(at: slot - 1)
            more = all.isEmpty ? nil : all
        }
    }

    static func move<T>(_ from: Int, to: Int, _ first: inout T, _ more: inout [T]?) {
        var all = [first] + (more ?? [])
        guard from != to, all.indices.contains(from), all.indices.contains(to) else { return }
        all.insert(all.remove(at: from), at: to)
        first = all[0]
        more = all.count > 1 ? Array(all.dropFirst()) : nil
    }
}

// MARK: - Spread

nonisolated extension Renderer {
    /// A layer's outline grown by `by` all round, or shrunk below 0, in its own coordinates, as a
    /// shadow's spread grows it: corners that are square stay square, round ones grow rounder.
    /// Nil for a layer with no outline of its own to grow, text or a group. A cut-out picture's
    /// `subject` is what is grown, as it is what casts a shadow under it.
    static func spreadOutline(of node: Node, by d: CGFloat, subject: Bool = true) -> CGPath? {
        let r = CGRect(origin: .zero, size: node.frame.size)
        if subject, let silhouette = node.silhouette { return grown(silhouette, by: d, rule: .evenOdd) }
        switch node.kind {
        case .rectangle where node.cornerSmoothing.map({ $0 > 0 }) != true:
            let grown = r.insetBy(dx: -d, dy: -d)
            guard grown.width > 0, grown.height > 0 else { return CGMutablePath() }
            var shape = node
            shape.frame.size = grown.size
            shape.radii = node.radii.map { $0 > 0 ? max($0 + d, 0) : 0 }
            var t = CGAffineTransform(translationX: -d, y: -d)
            let path = outline(of: shape)
            return path.copy(using: &t) ?? path
        case .ellipse:
            let grown = r.insetBy(dx: -d, dy: -d)
            guard grown.width > 0, grown.height > 0 else { return CGMutablePath() }
            return CGPath(ellipseIn: grown, transform: nil)
        case .rectangle, .path:
            return grown(outline(of: node), by: d, rule: node.evenOdd == true ? .evenOdd : .winding)
        case .line:
            // A line casts its stroke, which a spread makes heavier.
            let w = max(node.borderWidth + d * 2, 0)
            guard w > 0 else { return CGMutablePath() }
            return outline(of: node).copy(strokingWithWidth: w, lineCap: .round, lineJoin: .miter, miterLimit: 10)
        case .text, .group, .artboard:
            return nil
        }
    }

    /// Whether a shadow is cast from the layer's outline grown by its spread, rather than by the
    /// layer as it is drawn. Only a layer with an outline of its own is.
    static func spreads(_ node: Node, _ shadow: Shadow) -> Bool {
        shadow.grown != 0 && [.rectangle, .ellipse, .path, .line].contains(node.kind)
    }

    /// Any outline grown or shrunk by `d` all round: with a band as wide on each side of its edge
    /// joined to it or cut from it.
    private static func grown(_ path: CGPath, by d: CGFloat, rule: CGPathFillRule) -> CGPath {
        guard d != 0 else { return path }
        let band = path.copy(strokingWithWidth: abs(d) * 2, lineCap: .round, lineJoin: .miter, miterLimit: 10)
        return d > 0 ? path.union(band, using: rule) : path.subtracting(band, using: rule)
    }
}
