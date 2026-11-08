import Foundation

// The look cards on Windows, as the Mac's LookCards and FillMenu: what the selected layers have
// alike of their opacity, corners, fills, borders and shadows (several of each, one over another),
// and the changes the cards make with the shared presets (`Presets`) and paints (`Paints.swift`).
// Pointing at a preset or a colour shows it first, as the Text card's menus do.

extension WindowsCore {
    /// A colour, 0…1 each, and its hex as the cards write it.
    nonisolated public struct Colour: Sendable, Equatable, Hashable {
        public var r: Double, g: Double, b: Double, a: Double
        public init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
        public var hex: String { RGBA(self).hex }
        /// Its hue, saturation and brightness, 0…1.
        public var hsb: (h: Double, s: Double, b: Double) { RGBA(self).hsb }
        public init(h: Double, s: Double, b: Double, a: Double = 1) { self.init(RGBA(h: h, s: s, b: b, a: a)) }
        public init?(hex: String, alpha: Double) {
            guard let c = RGBA(hex: hex, alpha: alpha) else { return nil }
            self.init(c)
        }
        public func with(alpha: Double) -> Colour { var c = self; c.a = alpha; return c }
        init(_ c: RGBA) { self.init(r: c.r, g: c.g, b: c.b, a: c.a) }
    }

    /// One stop of a gradient.
    nonisolated public struct Stop: Sendable {
        public let offset: Double
        public let colour: Colour
        public init(offset: Double, colour: Colour) { self.offset = offset; self.colour = colour }
    }

    /// What paints a fill or a border: solid, linear, radial or picture, the colour they share
    /// (nil where they differ) and the first one's, and a gradient's stops and where it runs.
    nonisolated public struct PaintLook: Sendable {
        public let kind: String
        public let colour: Colour?
        public let first: Colour
        public let stops: [Stop]
        public let start: CGPoint
        public let end: CGPoint
        /// What the card says of it.
        public let summary: String
    }

    nonisolated public struct BorderLook: Sendable {
        public let paint: PaintLook
        public let width: Double?
        public let firstWidth: Double
        /// inside, center or outside.
        public let position: String?
        public let dash: Double?
        public let gap: Double?
        public let summary: String
        /// Which of the presets each of the layers has: none, or that one.
        public let preset: Int?
    }

    nonisolated public struct ShadowLook: Sendable {
        public let x: Double?, y: Double?, blur: Double?, spread: Double?
        public let first: (x: Double, y: Double, blur: Double)
        public let colour: Colour?
        public let inset: Bool
        public let elevation: Double
        public let summary: String
        public let preset: Int?
    }

    /// The looks of the selected layers, as their cards show them.
    nonisolated public struct Looks: Sendable {
        public let opacity: Double?
        public let firstOpacity: Double
        /// Corners: the radius they share (nil where they differ, or a corner is rounded its own
        /// way), the first one's, the most it can be (a pill), and squircle smoothing.
        public let radius: Double?
        public let firstRadius: Double
        public let pill: Double
        public let smooth: Bool
        public let smoothing: Double?
        public let cornerPreset: Int?
        /// Fills, borders and shadows, the first at the bottom: every slot any of the layers has,
        /// the first's card shown while any of them has it on (`fillOn` and the others).
        public let fills: [PaintLook]
        public let borders: [BorderLook]
        public let shadows: [ShadowLook]
        /// Whether every layer has a fill, a border, a shadow under it and one inside it, or none
        /// has (nil: some have).
        public let fillOn: Bool?
        public let borderOn: Bool?
        public let shadowOn: Bool?
        public let shadowUnder: Bool?
        public let shadowWithin: Bool?
        /// How the layers mix with what is under them (nil Normal); `blendSeveral` where they differ.
        public let blend: String?
        public let blendSeveral: Bool
        /// Text's letters are painted by the first fill: a colour, a gradient or a picture, one alone.
        public let isText: Bool
        /// Letters picked out while typing, which take a colour of their own alone (as on the
        /// Mac): the first fill then shows theirs.
        public var lettersPicked = false
        public let isLine: Bool
        /// Whether a picture fills the first fill of every layer.
        public let pictures: Bool
        /// Whether any of them has a picture in its first fill, which stays at the bottom of the
        /// pile, where a repeat grid's cells keep their own.
        public var pictureUnder = false
        /// The blur, while any of the layers has one on; `blurOn` whether all, none or some do.
        public let blur: BlurLook?
        public let blurOn: Bool?
        /// How the layers are turned in depth, while any of them is; `depthOn` whether all,
        /// none or some are.
        public let depth: DepthLook?
        public let depthOn: Bool?
    }

    /// A turn in depth as the 3D card shows it: the first's tip, swing and nearness, each shared
    /// value (nil where they differ), and the line's words.
    nonisolated public struct DepthLook: Sendable {
        public let x: Double, y: Double, z: Double
        public let xs: Double?, ys: Double?, zs: Double?
        public let summary: String
    }

    private static func depthLook(_ nodes: [Node]) -> DepthLook? {
        guard nodes.contains(where: { $0.transform3D != nil }) else { return nil }
        let t = nodes.first?.transform3D ?? Transform3D()
        let summary: String
        if let shared = alike(nodes, { $0.transform3D }) {
            let turned = "\(Int((shared?.x ?? 0).rounded()))°, \(Int((shared?.y ?? 0).rounded()))°"
            // A screen laid onto a photo: pinned by its corners, and perhaps turned besides.
            if let shared, shared.pinned {
                summary = shared.x == 0 && shared.y == 0 ? "Corners pinned" : "Corners pinned, \(turned)"
            } else {
                summary = turned
            }
        } else {
            summary = "Several"
        }
        return DepthLook(x: t.x, y: t.y, z: Double(t.z), xs: alike(nodes) { $0.transform3D?.x ?? 0 }, ys: alike(nodes) { $0.transform3D?.y ?? 0 },
                         zs: alike(nodes) { Double($0.transform3D?.z ?? 0) }, summary: summary)
    }

    /// A card turned `x` and `y` degrees, drawn small in `size`: its corners (top left first),
    /// whether its back shows, and how much black darkens its face.
    public static func cardInDepth(x: Double, y: Double, size: CGSize) -> (corners: [CGPoint], back: Bool, shade: Double) {
        DepthAim.card(Transform3D(x: x, y: y), in: size)
    }

    /// A turn tipped `by` degrees off the page, as the 3D card's dial tips it.
    public static func tipped(x: Double, y: Double, by: Double) -> (x: Double, y: Double) {
        let t = Transform3D(x: x, y: y).tipped(by)
        return (t.x, t.y)
    }

    /// Where a face turned `x` and `y` points, across and down from -1 to 1.
    public static func facing(x: Double, y: Double) -> CGPoint { DepthAim.facing(Transform3D(x: x, y: y)) }

    /// The turn that faces there (across and down from -1 to 1), settled: in steps of 15° with
    /// `steps`, and flat when nearly face on.
    public static func turn(facing d: CGPoint, steps: Bool) -> (x: Double, y: Double) {
        let (x, y) = DepthAim.turn(facing: d)
        return DepthAim.settled(x, y, steps: steps)
    }

    /// A blur as its card shows it: of what is behind (frosted glass) or of the layers; how much
    /// (nil where they differ) and the first's; the preset it is, if any; growing toward an edge,
    /// and where (the first's ends, the preset edge if any); and behind, how light and how much
    /// fill lies over it (in per cent, nil where they differ).
    nonisolated public struct BlurLook: Sendable {
        public let behind: Bool
        public let growing: Bool
        public let radius: Double?
        public let firstRadius: Double
        public let preset: Int?
        public let ramp: (start: CGPoint, end: CGPoint)?
        public let rampPreset: Int?
        public let light: Double?
        public let fill: Double?
        /// The first layer's width over its height, for the pad the ramp is drawn on.
        public let aspect: Double
    }

    /// The blurs offered: their names and how much each blurs.
    public static var blurPresets: [(name: String, radius: Double)] { Presets.blurs.map { ($0.name.key, Double($0.radius)) } }
    /// The ways a blur grows, by name, and the edge each grows toward (0 the bottom, then the
    /// left, top and right).
    public static var rampPresets: [(name: String, edge: Int)] { Presets.ramps.map { ($0.name.key, $0.edge) } }

    private static func blurLook(_ nodes: [Node]) -> BlurLook? {
        guard let first = nodes.first(where: { $0.blur?.on == true }) ?? nodes.first, nodes.contains(where: { $0.blur?.on == true }) else { return nil }
        let ramp = first.blur?.ramp
        return BlurLook(behind: alike(nodes) { $0.blur?.background == true } == true,
                        growing: alike(nodes) { $0.blur?.ramp != nil } == true,
                        radius: alike(nodes) { $0.blur.map { Double($0.radius) } } ?? nil,
                        firstRadius: Double(first.blur?.radius ?? 0),
                        preset: Presets.blurs.firstIndex { p in nodes.allSatisfy { $0.blur?.on == true && $0.blur?.radius == p.radius } },
                        ramp: ramp.map { ($0.start, $0.end) },
                        rampPreset: Presets.ramps.firstIndex { p in nodes.allSatisfy { $0.blur?.ramp == BlurRamp.toward(p.edge) } },
                        light: alike(nodes) { ($0.blur?.brightness ?? 0) * 100 },
                        fill: alike(nodes) { ($0.blur?.fillOpacity ?? 0) * 100 },
                        aspect: Double(first.frame.width / max(first.frame.height, 1)))
    }

    /// The presets, by name, as the cards offer them.
    public static var cornerPresets: [(name: String, radius: Double?)] { Presets.corners.map { ($0.name.key, $0.radius.map { Double($0) }) } }
    public static var shadowPresets: [(name: String, y: Double, blur: Double)] { shadows(Presets.shadows) }
    public static var innerShadowPresets: [(name: String, y: Double, blur: Double)] { shadows(Presets.innerShadows) }
    private static func shadows(_ presets: [Presets.ShadowPreset]) -> [(name: String, y: Double, blur: Double)] {
        presets.map { p -> (name: String, y: Double, blur: Double) in
            let y: CGFloat = p.y, blur: CGFloat = p.blur
            return (p.name.key, Double(y), Double(blur))
        }
    }
    public static var borderPresets: [(name: String, width: Double?)] { Presets.borders.map { ($0.name.key, $0.width.map { Double($0) }) } }
    public static var topElevation: Double { Presets.topElevation }
    public static var blendModes: [[(raw: String?, name: String)]] {
        let groups: [[BlendMode?]] = [[nil], [.darken, .multiply, .colorBurn, .plusDarker], [.lighten, .screen, .colorDodge, .plusLighter],
                                      [.overlay, .softLight, .hardLight], [.difference, .exclusion], [.hue, .saturation, .color, .luminosity]]
        return groups.map { $0.map { ($0?.rawValue, $0?.title ?? "Normal") } }
    }

    /// The colours the design uses, the most used first: one click away beside a colour.
    public static var designColours: [Colour] { (design?.colorsUsed ?? []).map(Colour.init) }

    private static func said(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }

    private static func alike<T: Equatable>(_ nodes: [Node], _ value: (Node) -> T) -> T? {
        guard let first = nodes.first.map(value) else { return nil }
        return nodes.allSatisfy { value($0) == first } ? first : nil
    }

    /// The selected layers that have a slot of a look: all for the first, and for those over it
    /// the ones that have that many (the Mac's `holding`).
    private static func holding(_ nodes: [Node], _ look: Look, _ slot: Int) -> [Node] {
        guard slot > 0 else { return nodes }
        let those = nodes.filter { $0.slots(look) > slot }
        return those.isEmpty ? nodes : those
    }

    /// A fill as a card shows it.
    static func paintLook(_ fill: Fill) -> PaintLook {
        var n = Node(kind: .rectangle, name: "", frame: .zero)
        n.fill = fill
        return paint([n], \.fill)
    }

    private static func paint(_ those: [Node], _ path: WritableKeyPath<Node, Fill>, blend: String? = nil) -> PaintLook {
        let first = those[0][keyPath: path]
        let kind = alike(those) { FillKind($0[keyPath: path]) }
        let colour = alike(those) { $0[keyPath: path].color }
        var said: [String]
        switch kind {
        case .solid?: said = ["#\(first.color.hex)"] + (first.color.a < 0.995 ? ["\(Int((first.color.a * 100).rounded()))%"] : [])
        case .linear?: said = ["Linear"]
        case .radial?: said = ["Radial"]
        case .picture?: said = ["Picture"]
        case nil: said = ["Several"]
        }
        if kind == .solid, colour == nil { said = ["Several"] }
        if let blend { said.append(blend) }
        let kindName: String = switch FillKind(first) {
        case .solid: "solid"
        case .linear: "linear"
        case .radial: "radial"
        case .picture: "picture"
        }
        let g = first.gradient
        return PaintLook(kind: kindName, colour: colour.map(Colour.init), first: Colour(first.color),
                      stops: (g?.stops ?? []).map { Stop(offset: $0.offset, colour: Colour($0.color)) },
                      start: g?.start ?? .zero, end: g?.end ?? CGPoint(x: 0, y: 1), summary: said.joined(separator: " · "))
    }

    public static func looks(_ ids: [UUID]) -> Looks? {
        guard let doc = design else { return nil }
        let nodes = ids.compactMap { doc.node($0) }
        guard let n0 = nodes.first else { return nil }
        let pill = Double(Presets.cornerRadius(nil, for: n0))
        let mixed = nodes.contains { $0.corners != nil } || alike(nodes, { $0.cornerRadius }) == nil
        let cornerPreset = Presets.corners.firstIndex { preset in
            nodes.allSatisfy { $0.corners == nil && abs($0.cornerRadius - Presets.cornerRadius(preset.radius, for: $0)) < 0.5 }
        }
        let top = { (look: Look) in (nodes.map { $0.slots(look) }.max() ?? 1) - 1 }
        let blend = alike(nodes) { $0.blend }
        let isText = nodes.contains { $0.kind == .text }
        var fills = (0...top(.fill)).map { slot in
            paint(holding(nodes, .fill, slot), Node.fillPath(slot), blend: !isText && slot == 0 ? (blend ?? nil)?.title : nil)
        }
        // Text's fill is its letters' colour, as the Mac's Text card shows it: while typing, the
        // colour of the letters picked out, whatever paints the rest.
        let picked = typingInto(ids) ? pickedLetters : nil
        if isText, let first = fills.first, first.kind == "solid" || picked != nil {
            let shown = TextSummary(nodes: nodes, letters: picked.map { nodes[0].letters(in: $0) }).letter(\.color)
            let c = shown ?? nodes[0].fill.color
            let said = shown == nil ? "Several" : "#\(c.hex)" + (c.a < 0.995 ? " · \(Int((c.a * 100).rounded()))%" : "")
            fills[0] = PaintLook(kind: "solid", colour: shown.map(Colour.init), first: Colour(c), stops: [], start: .zero, end: CGPoint(x: 0, y: 1), summary: said)
        }
        let borders = (0...top(.border)).map { slot -> BorderLook in
            let path = Node.borderPath(slot), those = holding(nodes, .border, slot)
            let width = alike(those) { Double($0[keyPath: path].width) }
            let position = alike(those) { $0[keyPath: path].position }
            var summary = width.map { "\(said($0)) pt" } ?? "Several"
            if !nodes.allSatisfy({ $0.kind == .line }), let position {
                summary += " · " + ["inside": "Inside", "center": "Centred", "outside": "Outside"][position.rawValue]!
            }
            if alike(those, { $0[keyPath: path].dash > 0 }) == true { summary += " · Dashed" }
            switch alike(those, { FillKind($0[keyPath: path].paint) }) {
            case .linear?: summary += " · Linear gradient"
            case .radial?: summary += " · Radial gradient"
            case .picture?: summary += " · Picture"
            default: break
            }
            return BorderLook(paint: paint(those, path.appending(path: \.paint)), width: width, firstWidth: Double(those[0][keyPath: path].width),
                              position: position?.rawValue, dash: alike(those) { Double($0[keyPath: path].dash) },
                              gap: alike(those) { Double($0[keyPath: path].gap) }, summary: summary,
                              preset: Presets.borders.firstIndex { p in those.allSatisfy { Presets.isBorder(p.width, $0[keyPath: path]) } })
        }
        let shadows = (0...top(.shadow)).map { slot -> ShadowLook in
            let path = Node.shadowPath(slot), those = holding(nodes, .shadow, slot)
            let first = those[0][keyPath: path]
            let inset = nodes.allSatisfy { $0.kind != .line } && alike(those) { $0[keyPath: path].inset == true } == true
            let presets = inset ? Presets.innerShadows : Presets.shadows
            let preset = presets.firstIndex { p in those.allSatisfy { Presets.isShadow(p, $0[keyPath: path]) } }
            var summary: String
            if let preset {
                summary = presets[preset].name.key
            } else if let s = alike(those, { $0[keyPath: path] }) {
                var at = (s.x != 0 ? ["X \(said(Double(s.x)))"] : []) + ["Y \(said(Double(s.y)))", "B \(said(Double(s.blur)))"]
                if s.grown != 0 { at.append("S \(said(Double(s.grown)))") }
                summary = at.joined(separator: " · ")
            } else {
                summary = "Several"
            }
            return ShadowLook(x: alike(those) { Double($0[keyPath: path].x) }, y: alike(those) { Double($0[keyPath: path].y) },
                              blur: alike(those) { Double($0[keyPath: path].blur) }, spread: alike(those) { Double($0[keyPath: path].grown) },
                              first: (Double(first.x), Double(first.y), Double(first.blur)), colour: alike(those) { $0[keyPath: path].color }.map(Colour.init),
                              inset: inset, elevation: Presets.elevation(of: first), summary: summary, preset: preset)
        }
        var looks = Looks(opacity: alike(nodes) { $0.opacity }, firstOpacity: n0.opacity,
                     radius: mixed ? nil : Double(n0.cornerRadius), firstRadius: min(Double(n0.cornerRadius), pill), pill: pill,
                     smooth: nodes.allSatisfy { ($0.cornerSmoothing ?? 0) > 0 },
                     smoothing: alike(nodes) { Double(($0.cornerSmoothing ?? 0) * 100) }, cornerPreset: cornerPreset,
                     fills: fills, borders: borders, shadows: shadows,
                     fillOn: alike(nodes) { $0.fill.on }, borderOn: alike(nodes) { $0.border.on }, shadowOn: alike(nodes) { $0.shadow.on },
                     shadowUnder: alike(nodes) { !$0.outerShadows.isEmpty }, shadowWithin: alike(nodes) { !$0.innerShadows.isEmpty },
                     blend: (blend ?? nil)?.rawValue, blendSeveral: blend == nil, isText: isText,
                     isLine: nodes.allSatisfy { $0.kind == .line },
                     pictures: nodes.allSatisfy { $0.fill.on && $0.fill.image != nil && $0.kind != .text },
                     blur: blurLook(nodes), blurOn: alike(nodes) { $0.blur?.on == true },
                     depth: depthLook(nodes), depthOn: alike(nodes) { $0.transform3D != nil })
        looks.lettersPicked = picked != nil
        looks.pictureUnder = nodes.contains { $0.fill.image != nil }
        return looks
    }

    /// A change a look card makes; `slot` is which of the fills, borders or shadows, the first 0.
    public enum LookChange: Sendable {
        case opacity(Double)
        case corners(Double), cornerPreset(Int), smooth(Bool), smoothing(Double)
        case fillColour(Int, Colour), fillAlpha(Int, Double), fillKind(Int, String), stopColour(Int, stop: Int, Colour), stops(Int, [Stop]), blend(String?)
        case borderPreset(Int, Int), borderWidth(Int, Double), dash(Int, Double), gap(Int, Double), borderPosition(Int, String)
        case borderColour(Int, Colour), borderKind(Int, String), borderStopColour(Int, stop: Int, Colour), borderStops(Int, [Stop])
        case shadowPreset(Int, Int), shadowInset(Int, Bool), elevation(Int, Double)
        case shadowX(Int, Double), shadowY(Int, Double), shadowBlur(Int, Double), shadowSpread(Int, Double), shadowColour(Int, Colour)
        case addFill, addBorder, addShadow, addInnerShadow, moreFill, moreBorder, moreShadow
        case remove(String, Int)
        /// One of the fills, borders or shadows put in another place, those between moving up
        /// or down a place (the Mac's pile restacked): slots counted from the bottom.
        case restack(String, from: Int, to: Int)
        /// The blur: how much (whole points from the dial), a preset, of what is behind or of the
        /// layer, all over or growing, toward a preset edge or between two points, how light and
        /// how much fill over it (per cent); added, taken away.
        case blurAmount(Double), blurPreset(Int), blurBehind(Bool), blurGrowing(Bool), blurRampPreset(Int)
        case blurRamp(start: CGPoint, end: CGPoint), blurLight(Double), blurFill(Double), addBlur, removeBlur
        /// The turn in depth: tipped so far off the page (the dial), aimed, each of its numbers,
        /// laid flat; added (held up a little), taken away.
        case tip(Double), aim(Double, Double), depthX(Double), depthY(Double), depthZ(Double), layFlat, addDepth, removeDepth
    }

    public static func change(_ ids: [UUID], _ c: LookChange) {
        // Letters picked out while typing take a colour of their own, as one change of the typing.
        if case .fillColour(0, let colour) = c, typingInto(ids), restyleTyped({ $0.color = rgba(colour) }, caret: false) { return }
        let apply = make(c)
        edit { d in for id in ids { d.update(id, apply) } }
    }

    public static func preview(_ ids: [UUID], _ c: LookChange?) {
        guard let c else { endPreview(); return }
        // Letters picked out while typing show their colour once it is chosen, as on the Mac.
        if case .fillColour(0, _) = c, typingInto(ids), pickedLetters != nil { return }
        let apply = make(c)
        preview { d in for id in ids { d.update(id, apply) } }
    }

    private static func rgba(_ c: Colour) -> RGBA { RGBA(r: c.r, g: c.g, b: c.b, a: c.a) }

    private static func kind(_ raw: String) -> FillKind {
        switch raw {
        case "linear": .linear
        case "radial": .radial
        case "picture": .picture
        default: .solid
        }
    }

    /// What a change does to one layer.
    private static func make(_ change: LookChange) -> (inout Node) -> Void {
        // A paint changed: a layer without such a border is passed over, and text painted anew
        // loses the colours its letters had of their own (the Mac's updatePaint).
        func paint(_ target: PaintTarget, _ f: @escaping (inout Fill, Node) -> Void) -> (inout Node) -> Void {
            { n in
                if case .border(let slot) = target, slot >= n.slots(.border) { return }
                let path = target.path
                let was = n[keyPath: path]
                var fill = was
                f(&fill, n)
                guard fill != was else { return }
                n[keyPath: path] = fill
                if target.paintsLetters(of: n) { n.clearLetterColors() }
            }
        }
        func colour(_ target: PaintTarget, _ c: Colour) -> (inout Node) -> Void {
            // Text's letters take the colour, every one of them, as the Mac's Text card colours them.
            if target == .fill(0) {
                return { n in
                    if n.kind == .text {
                        n.restyleLetters(in: nil) { $0.color = rgba(c) }
                    } else {
                        n.fill.color = rgba(c)
                        n.fill.on = true
                    }
                }
            }
            return paint(target) { f, _ in f.color = rgba(c); f.on = true }
        }
        func stop(_ target: PaintTarget, _ k: Int, _ c: Colour) -> (inout Node) -> Void {
            paint(target) { f, _ in
                f.on = true
                if f.gradient?.stops.indices.contains(k) == true { f.gradient?.stops[k].color = rgba(c) }
            }
        }
        func stops(_ target: PaintTarget, _ s: [Stop]) -> (inout Node) -> Void {
            paint(target) { f, _ in
                guard f.gradient != nil else { return }
                f.gradient?.stops = s.map { GradientStop(offset: $0.offset, color: rgba($0.colour)) }
                f.on = true
            }
        }
        switch change {
        case .opacity(let v): return { $0.opacity = min(max(v, 0), 1) }
        case .corners(let v): return { n in n.radii = Array(repeating: min(CGFloat(max(v, 0)), Presets.cornerRadius(nil, for: n)), count: 4) }
        case .cornerPreset(let k): return { n in n.radii = Array(repeating: Presets.cornerRadius(Presets.corners[k].radius, for: n), count: 4) }
        case .smooth(let on): return { $0.cornerSmoothing = on ? Presets.squircle : nil }
        case .smoothing(let v): return { $0.cornerSmoothing = v > 0 ? CGFloat(min(v, 100) / 100) : nil }
        case .fillColour(let slot, let c): return colour(.fill(slot), c)
        // How much of each one's own colour shows, as the Fill card's dial sets it.
        case .fillAlpha(let slot, let a): return { n in n[keyPath: Node.fillPath(slot)].color = n[keyPath: Node.fillPath(slot)].color.with(alpha: min(max(a, 0), 1)) }
        case .fillKind(let slot, let k): return paint(.fill(slot)) { f, n in f.paint(as: kind(k), on: n) }
        case .stopColour(let slot, let k, let c): return stop(.fill(slot), k, c)
        case .stops(let slot, let s): return stops(.fill(slot), s)
        case .blend(let raw): return { $0.blend = raw.flatMap(BlendMode.init) }
        case .borderPreset(let slot, let k):
            return { n in if slot < n.slots(.border) || slot == 0 { Presets.applyBorder(Presets.borders[k].width, to: &n[keyPath: Node.borderPath(slot)]) } }
        case .borderWidth(let slot, let v):
            let floor = 0.0
            return { n in
                guard slot < n.slots(.border) || slot == 0 else { return }
                n[keyPath: Node.borderPath(slot)].width = CGFloat(max(v, n.kind == .line ? 0.5 : floor))
                n[keyPath: Node.borderPath(slot)].on = true
            }
        case .dash(let slot, let v):
            return { n in
                n[keyPath: Node.borderPath(slot)].dash = CGFloat(max(v, 0))
                if n[keyPath: Node.borderPath(slot)].gap == 0 { n[keyPath: Node.borderPath(slot)].gap = CGFloat(max(v, 0)) }
            }
        case .gap(let slot, let v): return { $0[keyPath: Node.borderPath(slot)].gap = CGFloat(max(v, 0)) }
        case .borderPosition(let slot, let raw): return { n in if let p = Border.Position(rawValue: raw) { n[keyPath: Node.borderPath(slot)].position = p } }
        case .borderColour(let slot, let c): return colour(.border(slot), c)
        case .borderKind(let slot, let k): return paint(.border(slot)) { f, n in f.paint(as: kind(k), on: n) }
        case .borderStopColour(let slot, let k, let c): return stop(.border(slot), k, c)
        case .borderStops(let slot, let s): return stops(.border(slot), s)
        case .shadowPreset(let slot, let k):
            return { n in
                let path = Node.shadowPath(slot)
                let presets = n[keyPath: path].inset == true && n.kind != .line ? Presets.innerShadows : Presets.shadows
                Presets.applyShadow(presets[k], to: &n[keyPath: path])
            }
        case .shadowInset(let slot, let on): return { Presets.setShadowInset(on, on: &$0[keyPath: Node.shadowPath(slot)]) }
        case .elevation(let slot, let v): return { Presets.setElevation(v, on: &$0[keyPath: Node.shadowPath(slot)]) }
        case .shadowX(let slot, let v): return { $0[keyPath: Node.shadowPath(slot)].x = CGFloat(v) }
        case .shadowY(let slot, let v): return { $0[keyPath: Node.shadowPath(slot)].y = CGFloat(v) }
        case .shadowBlur(let slot, let v): return { $0[keyPath: Node.shadowPath(slot)].blur = CGFloat(max(v, 0)) }
        case .shadowSpread(let slot, let v): return { $0[keyPath: Node.shadowPath(slot)].spread = v == 0 ? nil : CGFloat(v) }
        case .shadowColour(let slot, let c): return { $0[keyPath: Node.shadowPath(slot)].color = rgba(c) }
        // What the dashed chips add, as the Mac's AddBar does.
        case .addFill: return { $0.fill.on = true }
        case .addBorder:
            return { n in
                n.border.on = true
                if n.border.width == 0 { n.border.width = 1 }
            }
        case .addShadow: return { n in n.add(Presets.shadow(Presets.shadows[1], like: n.shadow)) }
        case .addInnerShadow: return { n in n.add(Presets.shadow(Presets.innerShadows[1], like: n.shadow)) }
        // Another on top, from an open card's +.
        case .moreFill: return { $0.add(Presets.overlay) }
        case .moreBorder: return { n in n.add(Presets.border(over: n)) }
        case .moreShadow: return { n in n.add(Presets.shadow(besides: n.shadow)) }
        case .blurAmount(let v): return { Presets.applyBlur(CGFloat(max(v, 0)), to: &$0) }
        case .blurPreset(let k): return { Presets.applyBlur(Presets.blurs[k].radius, to: &$0) }
        case .blurBehind(let on):
            return { n in
                Presets.applyBlur(n.blur?.radius ?? Presets.blurs[1].radius, to: &n)
                n.blur?.background = on
            }
        case .blurGrowing(let on):
            return { n in
                Presets.applyBlur(n.blur?.radius ?? Presets.blurs[1].radius, to: &n)
                let kept = n.blur?.ramp
                n.blur?.ramp = on ? kept ?? .down : nil
            }
        case .blurRampPreset(let k): return { $0.blur?.ramp = BlurRamp.toward(Presets.ramps[k].edge) }
        case .blurRamp(let a, let b): return { $0.blur?.ramp = BlurRamp(start: a, end: b) }
        case .blurLight(let v): return { $0.blur?.brightness = min(max(v, -100), 100) / 100 }
        case .blurFill(let v): return { $0.blur?.fillOpacity = min(max(v, 0), 100) / 100 }
        case .addBlur: return { Presets.applyBlur(Presets.blurs[1].radius, to: &$0) }
        case .removeBlur: return { $0.blur = nil }
        case .tip(let v): return { $0.transform3D = ($0.transform3D ?? Transform3D()).tipped(v) }
        case .aim(let x, let y):
            return { n in
                var t = n.transform3D ?? Transform3D()
                t.x = x
                t.y = y
                n.transform3D = t
            }
        case .depthX(let v): return { n in n.transform3D = n.transform3D ?? Transform3D(); n.transform3D?.x = min(max(v, -180), 180) }
        case .depthY(let v): return { n in n.transform3D = n.transform3D ?? Transform3D(); n.transform3D?.y = min(max(v, -180), 180) }
        case .depthZ(let v): return { n in n.transform3D = n.transform3D ?? Transform3D(); n.transform3D?.z = CGFloat(min(max(v, -10_000), 10_000)) }
        case .layFlat: return { n in n.transform3D?.x = 0; n.transform3D?.y = 0 }
        case .addDepth: return { $0.transform3D = Presets.heldUp }
        case .removeDepth: return { $0.transform3D = nil }
        case .remove(let look, let slot):
            let which: Look = look == "fill" ? .fill : look == "border" ? .border : .shadow
            return { $0.remove(which, at: slot) }
        case .restack(let look, let from, let to):
            let which: Look = look == "fill" ? .fill : look == "border" ? .border : .shadow
            return { $0.move(which, from: from, to: to) }
        }
    }
}

nonisolated extension RGBA {
    init(_ c: WindowsCore.Colour) { self.init(r: c.r, g: c.g, b: c.b, a: c.a) }
}
