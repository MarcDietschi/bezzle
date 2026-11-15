import SwiftUI
import AppKit

/// The cards for how the selected layers look: their corners, how much of them shows, and their
/// fill, border, shadow, blur and depth. Each one's sideways drag sets what it has most of.
///
/// Each card reads the selection as it is when SwiftUI asks for it, and SwiftUI may ask once more
/// after the layers it was made for have gone: a pile's cards when the selection has just been
/// emptied, the camera picked in Animate or the layers deleted, before the panel takes the pile
/// away. So a card that reads the first of them is made from the layers it finds then, and with
/// none it is no card at all (1.8 broke off reading the first of no layers, 2026-11-14).
extension SelectionInspector {
    // MARK: Corners

    /// How round the corners are, and whether they are plain arcs or squircles that run smoothly
    /// into the sides, and how smoothly. The drag rounds them, clicking at each preset up to a pill.
    @ViewBuilder func cornersCard(live: Bool) -> some View {
        if let first = nodes.first { cornersCard(first: first, live: live) }
    }

    private func cornersCard(first: Node, live: Bool) -> some View {
        let smooth = nodes.allSatisfy { ($0.cornerSmoothing ?? 0) > 0 }
        let pill = Double(Presets.cornerRadius(nil, for: first))
        let mixed = nodes.contains { $0.corners != nil } || common { $0.cornerRadius } == nil
        let radius = min(Double(first.cornerRadius), pill)
        var summary: String
        if mixed {
            summary = Self.several
        } else if pill > 0, radius >= pill - 0.5 {
            summary = String(localized: "Pill")
        } else if let named = Presets.corners.first(where: { $0.radius.map(Double.init) == radius }) {
            summary = "\(String(localized: named.name)) · \(Self.said(radius))"
        } else {
            summary = Self.said(radius)
        }
        if smooth { summary = "\(String(localized: "Squircle")) · \(summary)" }
        let dial = pill > 0 ? Dial(value: radius, range: 0...pill, stops: [0, 4, 12, 24, pill], step: 1, action: "Change Corners") { v in
            store.updateSelection("Change Corners") { n in
                n.radii = Array(repeating: min(CGFloat(v.rounded()), Presets.cornerRadius(nil, for: n)), count: 4)
            }
        } : nil
        return AspectCard(aspect: .corners, title: "Corners", summary: summary, dial: dial, live: live,
                          accessory: keyBead([.corners], "Corners"), styles: !filming) {
            CornerGlyph(radius: pill > 0 && radius >= pill - 0.5 ? nil : CGFloat(radius), smooth: smooth)
        } picks: {
            HStack(spacing: 8) {
                PresetStrip(action: "Change Corners", items: Presets.corners.map { preset in
                    PresetItem(id: preset.id, name: preset.name,
                               active: nodes.allSatisfy { $0.corners == nil && abs($0.cornerRadius - Presets.cornerRadius(preset.radius, for: $0)) < 0.5 }) {
                        $0.radii = Array(repeating: Presets.cornerRadius(preset.radius, for: $0), count: 4)
                    }
                }) { item in
                    CornerGlyph(radius: Presets.corners.first { $0.id == item.id }?.radius, smooth: smooth)
                }
                // Mixed while the corners differ; a value typed rounds them all alike, and a
                // scrub or "+2" changes each corner from its own radius.
                NumberField(label: "R", value: nodes.contains { $0.corners != nil } ? nil : common { Double($0.cornerRadius) },
                            range: 0...10_000, action: "Change Corners") { v in
                    store.updateSelection("Change Corners") { $0.radii = Array(repeating: CGFloat(v), count: 4) }
                } each: { f in
                    store.updateSelection("Change Corners") { n in n.radii = n.radii.map { CGFloat(f(Double($0))) } }
                }
                .frame(width: Inspector.endField)
            }
            // How smoothly they run into the sides is the design's, and not keyed.
            if !filming {
                HStack(spacing: 8) {
                    SegmentedWell(selection: Binding(get: { smooth }, set: { on in
                        store.updateSelection(on ? "Smooth Corners" : "Round Corners") { $0.cornerSmoothing = on ? Presets.squircle : nil }
                    }), options: [(false, "Round"), (true, "Squircle")])
                    layerField("", unit: "%", range: 0...100, scrub: 0.5, decimals: 0, action: "Smooth Corners",
                               get: { Double(($0.cornerSmoothing ?? 0) * 100) }, set: { $0.cornerSmoothing = $1 > 0 ? CGFloat($1 / 100) : nil })
                        .frame(width: Inspector.endField)
                }
            }
        }
    }

    // MARK: Opacity

    /// How much of the layers shows: the drag fades them, clicking at each quarter.
    @ViewBuilder func opacityCard(live: Bool) -> some View {
        if let first = nodes.first { opacityCard(first: first, live: live) }
    }

    private func opacityCard(first: Node, live: Bool) -> some View {
        let quarters: [Double] = [25, 50, 75, 100]
        return AspectCard(aspect: .opacity, title: "Opacity", summary: common { $0.opacity }.map { "\(Int(($0 * 100).rounded()))%" } ?? Self.several,
                          dial: Dial(value: first.opacity * 100, range: 0...100, stops: quarters, step: 5, action: "Change Opacity") { v in
                              store.updateSelection("Change Opacity") { $0.opacity = v.rounded() / 100 }
                          }, live: live) {
            LevelGlyph(level: first.opacity)
        } picks: {
            HStack(spacing: 8) {
                PresetStrip(action: "Change Opacity", items: quarters.map { q in
                    PresetItem(id: "opacity-\(Int(q))", name: .verbatim("\(Int(q))%"), active: nodes.allSatisfy { abs($0.opacity * 100 - q) < 0.5 }) {
                        $0.opacity = q / 100
                    }
                }) { item in
                    LevelGlyph(level: (quarters.first { "opacity-\(Int($0))" == item.id } ?? 100) / 100)
                }
                layerField("", unit: "%", range: 0...100, scrub: 0.5, decimals: 0, action: "Change Opacity",
                           get: { $0.opacity * 100 }, set: { $0.opacity = $1 / 100 })
                    .frame(width: Inspector.endField)
            }
        }
    }

    // MARK: Fill

    /// What the selection does not have yet and could, as the dashed cards below the others offer it.
    func addable(fill: Bool, border: Bool, inset: Bool = true) -> [AddBar.Item] {
        var items: [AddBar.Item] = []
        if fill && common({ $0.fill.on }) == false {
            items.append(.init(id: "add-fill", aspect: .fill(0), title: "Fill", help: "Add a fill", action: "Add Fill") { $0.fill.on = true })
        }
        if border && common({ $0.border.on }) == false {
            items.append(.init(id: "add-border", aspect: .border(0), title: "Border", help: "Add a border", action: "Add Border") { n in
                n.border.on = true
                if n.border.width == 0 { n.border.width = 1 }
            })
        }
        // A shadow under the layers; once they have one, a shadow inside them as well, so that
        // the bar offers what comes next rather than growing.
        let under = common { !$0.outerShadows.isEmpty }, within = common { !$0.innerShadows.isEmpty }
        let next = nodes.first.map { $0.shadow.on ? $0.slots(.shadow) : 0 } ?? 0
        if under == false {
            items.append(.init(id: "add-shadow", aspect: .shadow(next), title: "Shadow", help: "Add a shadow", action: "Add Shadow") { n in
                n.add(Presets.shadow(Presets.shadows[1], like: n.shadow))
            })
        } else if under == true, within == false, inset {
            items.append(.init(id: "add-inner-shadow", aspect: .shadow(next), title: "Inner shadow", help: "Add a shadow inside",
                               action: "Add Inner Shadow") { n in
                n.add(Presets.shadow(Presets.innerShadows[1], like: n.shadow))
            })
        }
        if common({ $0.blur?.on == true }) == false {
            items.append(.init(id: "add-blur", aspect: .blur, title: "Blur", help: "Add a blur", action: "Add Blur") { Presets.applyBlur(Presets.blurs[1].radius, to: &$0) })
        }
        if common({ $0.transform3D != nil }) == false {
            // Several lying together are held up as one body.
            let ids = nodes.map(\.id)
            items.append(.init(id: "add-3d", aspect: .depth, title: "3D", help: "Add 3D", action: "Add 3D", change: { $0.transform3D = Presets.heldUp },
                               add: { store.turnSelection("Add 3D") { _ in Presets.heldUp } },
                               reshape: { doc in doc.turnInDepth(ids) { _, _ in Presets.heldUp } }))
        }
        if let mark = markForExport { items.append(mark) }
        if store.canMakeRepeatGrid {
            items.append(.init(id: "add-repeat", aspect: .grid, title: "Repeat", help: "Add a repeat", action: "Make Repeat Grid", change: { _ in }, add: { store.makeRepeatGrid() }))
        }
        return items
    }

    /// Marking the selection for export, as a 1× PNG to begin with, when none of it is.
    var markForExport: AddBar.Item? {
        guard common({ $0.exports?.isEmpty == false }) == false else { return nil }
        return .init(id: "add-export", aspect: .export, title: "Export", help: "Mark for export", action: "Mark for Export") { $0.exports = [ExportPreset()] }
    }

    /// The design's colours that the selection is not already: one click away beside a colour.
    func suggestions(besides color: RGBA?) -> [RGBA] {
        // A colour field shows the first few, of what can be hundreds.
        let own = color?.hex
        return Array(store.designColors.lazy.filter { $0.hex != own }.prefix(12))
    }

    /// One of what fills the layers, those over the first in a pile above it. For one colour, the
    /// drag sets how much of it shows; past nothing, the fill comes away. The first, at the bottom,
    /// holds the picture there is and how the layer mixes with what lies under it; text takes one
    /// fill for its letters, a colour, a gradient or a picture, and no more.
    @ViewBuilder func fillCard(slot: Int, removable: Bool, live: Bool, restack: ((CGFloat?) -> Void)? = nil) -> some View {
        let those = holding(.fill, slot)
        if let first = those.first { fillCard(slot: slot, those: those, first: first, removable: removable, live: live, restack: restack) }
    }

    private func fillCard(slot: Int, those: [Node], first: Node, removable: Bool, live: Bool, restack: ((CGFloat?) -> Void)?) -> some View {
        let blends = !nodes.contains { $0.kind == .text }
        let path = Node.fillPath(slot)
        let kind = common(among: those) { FillKind($0[keyPath: path]) }
        let fill: Fill? = kind == nil ? nil : common(among: those) { $0[keyPath: path] } ?? first[keyPath: path]
        let dial = kind == .solid ? Dial(value: first[keyPath: path].color.a * 100, range: 0...100, stops: [100], step: 5, action: "Change Fill") { v in
            store.updateSelection("Change Fill") { $0[keyPath: path].color = $0[keyPath: path].color.with(alpha: v.rounded() / 100) }
        } : nil
        let more = blends ? AddBar.Item(id: "more-fill", aspect: .fill(topSlot(.fill) + 1), title: "Fill", help: "Add another fill",
                                        action: "Add Fill") { $0.add(Presets.overlay) } : nil
        // Text's letters take a gradient or a picture as well as a colour, so it is a fill too.
        return AspectCard(aspect: .fill(slot), title: "Fill",
                          summary: Self.summary(of: fill, blend: blends && slot == 0 ? common { $0.blend } : nil),
                          dial: dial,
                          // The blend mode is shown with the first fill, so it goes when the last does.
                          remove: !filming && (removable || slot > 0) ? { removeLook(.fill, slot, "Remove Fill") } : nil,
                          removal: blends ? "Remove fill" : "Remove colour", live: live,
                          accessory: keyBead([.fill(slot), .fillStops(slot)], "Fill"), more: filming ? nil : more, restack: restack,
                          styles: !filming) {
            FillSwatch(fill: first[keyPath: path], radius: 4)
                .frame(width: 15, height: 15)
        } picks: {
            fillControls(blends: blends, action: "Change Fill", suggest: true, slot: slot)
            if those.allSatisfy({ $0[keyPath: path].shader != nil }) { shaderRows(path) }
            // A subject is cut out of a picture filling a shape; in letters it would leave little to read.
            if slot == 0, nodes.allSatisfy({ $0.fill.on && $0.fill.image != nil && $0.kind != .text }) {
                backgroundRow
            }
            if slot == 0, store.editingPicture != nil {
                Group {
                    if first.fill.image?.cutout != nil {
                        Caption("Click a subject to keep or drop it. Drag the picture to move it in its frame, or a corner to resize it, and Return ends placing.")
                    } else {
                        Caption("Drag the picture to move it in its frame, or a corner to resize it. Option keeps its middle, and Return ends placing.")
                    }
                }
                .transition(.unfold)
            }
        } exact: {
            if blends && slot == 0 && !filming { blendRow }
        }
        // A picture selected may be cut out next: what that needs done once on this Mac is
        // done now, behind everything else.
        .task(id: slot == 0 && first.kind != .text ? first.fill.image?.asset : nil) {
            if slot == 0, first.kind != .text, first.fill.image != nil { store.readyToRemoveBackground(pointing: false) }
        }
    }

    /// A shader fill's time: how fast it runs, and the moment the design shows, which is where a
    /// film starts it. Its picture alone, as it came in, is a click away.
    @ViewBuilder private func shaderRows(_ path: WritableKeyPath<Node, Fill>) -> some View {
        HStack(spacing: 8) {
            layerField(LocalizedStringResource("shader.speed", defaultValue: "Speed", comment: "How fast a shader's time runs, 1 as the page ran it."),
                       unit: "×", range: -10...10, scrub: 0.02, decimals: 2, action: "Change Shader",
                       get: { $0[keyPath: path].shader?.speed ?? 1 }, set: { $0[keyPath: path].shader?.speed = $1 })
            layerField(LocalizedStringResource("shader.moment", defaultValue: "Moment", comment: "The second of a shader's time the design shows."),
                       unit: "s", range: -100_000...100_000, scrub: 0.02, decimals: 2, action: "Change Shader",
                       get: { $0[keyPath: path].shader?.at ?? 0 }, set: { $0[keyPath: path].shader?.at = $1 })
        }
        if nodes.allSatisfy({ $0[keyPath: path].image != nil }) {
            HStack {
                Spacer()
                TextButton(title: "Use the Picture") { store.updateSelection("Change Shader") { $0[keyPath: path].shader = nil } }
                    .help(Text("Show the picture it came in as, still, in place of what its shaders draw."))
            }
        }
    }

    /// Whether the selected pictures show whole, or their subject alone. The subject is found
    /// away from the main thread: meanwhile "Subject alone" fills with pencil as far as the work
    /// has come, as the line on the canvas closes in, and "Whole picture" gives it up. A line
    /// under it says why, when nothing stands out.
    @ViewBuilder private var backgroundRow: some View {
        let work = store.selection.compactMap { store.cuttingOut[$0]?.done }
        let alone = !work.isEmpty || common({ $0.fill.image?.cutout != nil }) == true
        SegmentedWell(selection: Binding(get: { alone }, set: { cut in
            if cut { store.removeBackground() } else if work.isEmpty { store.restoreBackground() } else { store.giveUpRemovingBackground() }
        }), options: [(false, "Whole picture"), (true, "Subject alone")], progress: work.min())
        // What finds the subject is made ready while the pointer is still on its way to the click.
        .onHover { if $0, !alone { store.readyToRemoveBackground() } }
        .help("Take the background away, leaving what stands out in the picture. Double-click the picture to keep or drop each subject in it. The picture itself is kept, to have it back.")
        if let trouble = store.cutoutTrouble {
            Text(trouble)
                .prose(11)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.unfold)
        }
    }

    /// How the selected layers mix with what lies under them. Each mode shows on the canvas while
    /// it is pointed at in the menu.
    private var blendRow: some View {
        let blend = common { $0.blend }
        let groups: [[BlendMode?]] = [[nil], [.darken, .multiply, .colorBurn, .plusDarker], [.lighten, .screen, .colorDodge, .plusLighter],
                                      [.overlay, .softLight, .hardLight], [.difference, .exclusion], [.hue, .saturation, .color, .luminosity]]
        return Row(title: "Blend") {
            MenuButton(id: "blend-mode", title: blend.map { $0.map { .verbatim($0.title) } ?? "Normal" } ?? "Several", width: 180, fills: true) {
                groups.enumerated().flatMap { i, modes in
                    (i > 0 ? [MenuEntry.separator] : []) + modes.map { mode in
                        MenuEntry.item(mode.map { .verbatim($0.title) } ?? "Normal", checked: blend == .some(mode),
                                       preview: { on in store.showPreview("blend", on ? { $0.blend = mode } : nil) }) {
                            store.updateSelection("Change Blend Mode") { $0.blend = mode }
                        }
                    }
                }
            }
        }
    }

    /// What fills the selection, a layer's or an artboard's background. Its swatch opens the fill
    /// menu, where one colour, a gradient or a picture is chosen, and a gradient's colours. Text's
    /// letters picked out while typing take a colour of their own.
    @ViewBuilder func fillControls(blends: Bool, action: LocalizedStringResource, suggest: Bool, slot: Int = 0) -> some View {
        let path = Node.fillPath(slot)
        let those = holding(.fill, slot)
        let color = common(among: those) { $0[keyPath: path].color }
        let suggested = suggest ? suggestions(besides: color) : []
        let preview: (RGBA?) -> Void = { c in store.showPreview("fill-colour", c.map { c in { $0[keyPath: path].color = c; $0[keyPath: path].on = true } }) }
        let apply: (RGBA) -> Void = { c in store.updateSelection(action) { $0[keyPath: path].color = c; $0[keyPath: path].on = true } }
        // None of the layers left, as a card asked for once more after they have gone: nothing to show.
        if let first = those.first, blends {
            FillField(fill: first[keyPath: path], color: color, action: action, suggestions: suggested, preview: preview, target: .fill(slot), apply: apply)
        } else if let first = those.first, slot == 0 {
            // Text: the colour of the letters picked out while typing, or what paints every letter.
            let letters = store.lettersShown(in: nodes)
            let shown = letters.first.flatMap { c in letters.allSatisfy { $0.color == c.color } ? c.color : nil }
            let restyle: (RGBA) -> Void = { c in store.restyleLetters(action) { $0.color = c } }
            if store.pickedLetters != nil {
                ColorField(id: "fill", color: shown, suggestions: suggest ? suggestions(besides: shown) : [], action: action, preview: { _ in }, apply: restyle)
            } else {
                FillField(fill: first.fill, color: shown, action: action, suggestions: suggest ? suggestions(besides: shown) : [], preview: preview,
                          target: .fill(0), apply: restyle)
            }
        } else if !those.isEmpty {
            ColorField(id: "fill", color: color, suggestions: suggested, action: action, preview: preview, apply: apply)
        }
    }

    // MARK: Border

    /// One of the borders, or of a line's strokes, those drawn over the first in a pile above it.
    /// The drag sets its weight, clicking at each preset; past nothing a border comes away,
    /// though a line keeps its first stroke.
    @ViewBuilder func borderCard(slot: Int, lineOnly: Bool, removable: Bool, live: Bool, restack: ((CGFloat?) -> Void)? = nil) -> some View {
        let those = holding(.border, slot)
        if let layer = those.first { borderCard(slot: slot, those: those, layer: layer, lineOnly: lineOnly, removable: removable, live: live, restack: restack) }
    }

    private func borderCard(slot: Int, those: [Node], layer: Node, lineOnly: Bool, removable: Bool, live: Bool, restack: ((CGFloat?) -> Void)?) -> some View {
        let path = Node.borderPath(slot)
        let first = layer[keyPath: path]
        let color = common(among: those) { $0[keyPath: path].color }
        let width = common(among: those) { $0[keyPath: path].width }
        var summary = width.map { "\(Self.said($0)) pt" } ?? Self.several
        if !lineOnly, let position = common(among: those, { $0[keyPath: path].position }) {
            switch position {
            case .inside: summary += " · \(String(localized: "Inside"))"
            case .center: summary += " · \(String(localized: LocalizedStringResource("border.centred", defaultValue: "Centred", comment: "A border lying across the edge of its layer, half in and half out.")))"
            case .outside: summary += " · \(String(localized: "Outside"))"
            }
        }
        if common(among: those, { $0[keyPath: path].dash > 0 }) == true { summary += " · \(String(localized: "Dashed"))" }
        switch common(among: those, { FillKind($0[keyPath: path].paint) }) {
        case .linear: summary += " · \(String(localized: "Linear gradient"))"
        case .radial: summary += " · \(String(localized: "Radial gradient"))"
        case .picture: summary += " · \(String(localized: "Picture"))"
        case .solid, nil: break
        }
        let floor: Double = lineOnly ? 0.5 : 0
        let dial = Dial(value: Double(first.width), range: floor...max(12, Double(first.width)), stops: [1, 2, 4], step: 0.5, action: "Change Border") { v in
            store.updateSelection("Change Border") { $0[keyPath: path].width = CGFloat(max((v * 2).rounded() / 2, floor)); $0[keyPath: path].on = true }
        }
        let more = AddBar.Item(id: "more-border", aspect: .border(topSlot(.border) + 1), title: lineOnly ? "Line" : "Border",
                               help: lineOnly ? "Add another line" : "Add another border", action: "Add Border") { $0.add(Presets.border(over: $0)) }
        return AspectCard(aspect: .border(slot), title: lineOnly ? "Line" : "Border", summary: summary, dial: dial,
                          remove: !filming && (removable || slot > 0) ? { removeLook(.border, slot, "Remove Border") } : nil,
                          removal: lineOnly ? "Remove line" : "Remove border", live: live,
                          accessory: keyBead([.border(slot), .borderStops(slot), .borderWidth(slot)], lineOnly ? "Line" : "Border"),
                          more: filming ? nil : more, restack: restack, styles: !filming) {
            BorderGlyph(width: first.dash > 0 ? nil : first.width)
        } picks: {
            // A dashed line is the design's: only its weights are keyed.
            PresetStrip(action: "Change Border", items: Presets.borders.filter { !filming || $0.width != nil }.map { preset in
                PresetItem(id: preset.id, name: preset.name, active: those.allSatisfy { Presets.isBorder(preset.width, $0[keyPath: path]) }) {
                    Presets.applyBorder(preset.width, to: &$0[keyPath: path])
                }
            }) { item in
                BorderGlyph(width: Presets.borders.first { $0.id == item.id }?.width ?? nil)
            }
            // One colour, or a gradient or a picture, chosen in the fill menu as a fill's is. A
            // picture is the design's: in Animate there is nothing of it to key.
            if !filming || those.allSatisfy({ $0[keyPath: path].image == nil }) {
                FillField(fill: first.paint, color: color, action: "Change Border", suggestions: suggestions(besides: color),
                          preview: { c in store.showPreview("border-colour", c.map { c in { $0[keyPath: path].color = c; $0[keyPath: path].on = true } }) },
                          target: .border(slot)) { c in
                    store.updateSelection("Change Border") { $0[keyPath: path].color = c; $0[keyPath: path].on = true }
                }
            }
        } exact: {
            HStack(spacing: 8) {
                layerField(LocalizedStringResource("border.size", defaultValue: "Size", comment: "How thick a border is."), range: 0...1000, scrub: 0.25, action: "Change Border",
                           get: { Double($0[keyPath: path].width) }, set: { $0[keyPath: path].width = CGFloat($1); $0[keyPath: path].on = true })
                if !filming {
                    layerField("Dash", range: 0...1000, scrub: 0.25, action: "Change Border", get: { Double($0[keyPath: path].dash) }) { n, v in
                        n[keyPath: path].dash = CGFloat(v)
                        if n[keyPath: path].gap == 0 { n[keyPath: path].gap = CGFloat(v) }
                    }
                    layerField("Gap", range: 0...1000, scrub: 0.25, action: "Change Border",
                               get: { Double($0[keyPath: path].gap) }, set: { $0[keyPath: path].gap = CGFloat($1) })
                }
            }
            if !lineOnly && !filming {
                IconChoice(selection: common(among: those) { $0[keyPath: path].position }, options: [
                    (.inside, "square.inset.filled", "Inside"),
                    (.center, "square.dashed", "Centred on the edge"),
                    (.outside, "square.fill", "Outside"),
                ]) { p in store.updateSelection("Change Border") { $0[keyPath: path].position = p } }
            }
        }
    }

    // MARK: Shadow

    /// One of the shadows under the layers, or inside them as if they were pressed into the page,
    /// those cast with the first in a pile above it; a line has no inside for one to fall in. The
    /// drag lifts them, from none through each preset to floating, blending two presets between
    /// them. A shape's can spread, cast from its outline grown or shrunk.
    @ViewBuilder func shadowCard(slot: Int, canInset: Bool, canSpread: Bool, live: Bool, restack: ((CGFloat?) -> Void)? = nil) -> some View {
        let those = holding(.shadow, slot)
        if let layer = those.first { shadowCard(slot: slot, those: those, layer: layer, canInset: canInset, canSpread: canSpread, live: live, restack: restack) }
    }

    private func shadowCard(slot: Int, those: [Node], layer: Node, canInset: Bool, canSpread: Bool, live: Bool, restack: ((CGFloat?) -> Void)?) -> some View {
        let path = Node.shadowPath(slot)
        let first = layer[keyPath: path]
        let inset = canInset && common(among: those) { $0[keyPath: path].inset == true } == true
        let presets = inset ? Presets.innerShadows : Presets.shadows
        var summary: String
        if let named = presets.first(where: { p in those.allSatisfy { Presets.isShadow(p, $0[keyPath: path]) } }) {
            summary = String(localized: named.name)
        } else if let s = common(among: those, { $0[keyPath: path] }) {
            var at = (s.x != 0 ? ["X \(Self.said(s.x))"] : []) + ["Y \(Self.said(s.y))", "\(String(localized: "B")) \(Self.said(s.blur))"]
            if canSpread, s.grown != 0 {
                at.append("\(String(localized: LocalizedStringResource("shadow.spread-short", defaultValue: "S", comment: "A shadow's spread, said in one letter in its card's summary."))) \(Self.said(s.grown))")
            }
            summary = at.joined(separator: " · ")
        } else {
            summary = Self.several
        }
        let dial = Dial(value: Presets.elevation(of: first), range: 0...Presets.topElevation, stops: [1, 2, 3, 4], step: 1, action: "Change Shadow") { v in
            store.updateSelection("Change Shadow") { Presets.setElevation(v, on: &$0[keyPath: path]) }
        }
        let more = AddBar.Item(id: "more-shadow", aspect: .shadow(topSlot(.shadow) + 1), title: "Shadow", help: "Add another shadow",
                               action: "Add Shadow") { $0.add(Presets.shadow(besides: $0[keyPath: path])) }
        return AspectCard(aspect: .shadow(slot), title: inset ? "Inner shadow" : "Shadow", summary: summary, dial: dial,
                          remove: filming ? nil : { removeLook(.shadow, slot, "Remove Shadow") }, removal: "Remove shadow", live: live,
                          accessory: keyBead([.shadow(slot)], inset ? "Inner shadow" : "Shadow"), more: filming ? nil : more, restack: restack,
                          styles: !filming) {
            ShadowGlyph(y: first.y, blur: first.blur, inset: inset)
        } picks: {
            // Which side of the layer it falls on is the design's, and not keyed.
            if canInset && !filming {
                SegmentedWell(selection: Binding(get: { inset }, set: { v in
                    store.updateSelection("Change Shadow") { Presets.setShadowInset(v, on: &$0[keyPath: path]) }
                }), options: [(false, "Outside"), (true, "Inside")])
            }
            PresetStrip(action: "Change Shadow", items: presets.map { preset in
                PresetItem(id: preset.id, name: preset.name, active: those.allSatisfy { Presets.isShadow(preset, $0[keyPath: path]) }) {
                    Presets.applyShadow(preset, to: &$0[keyPath: path])
                }
            }) { item in
                let preset = presets.first { $0.id == item.id }
                ShadowGlyph(y: preset?.y ?? 0, blur: preset?.blur ?? 0, inset: inset)
            }
            ColorField(id: slot == 0 ? "shadow" : "shadow-\(slot)", color: common(among: those) { $0[keyPath: path].color }, action: "Change Shadow") { c in
                store.updateSelection("Change Shadow") { $0[keyPath: path].color = c }
            }
        } exact: {
            HStack(spacing: 8) {
                layerField("X", range: -1000...1000, scrub: 0.5, action: "Change Shadow",
                           get: { Double($0[keyPath: path].x) }, set: { $0[keyPath: path].x = CGFloat($1) })
                layerField("Y", range: -1000...1000, scrub: 0.5, action: "Change Shadow",
                           get: { Double($0[keyPath: path].y) }, set: { $0[keyPath: path].y = CGFloat($1) })
                layerField("B", range: 0...1000, scrub: 0.5, action: "Change Shadow",
                           get: { Double($0[keyPath: path].blur) }, set: { $0[keyPath: path].blur = CGFloat($1) })
            }
            if canSpread {
                Row(title: LocalizedStringResource("shadow.spread", defaultValue: "Spread", comment: "How much bigger than its layer a shadow is cast, or smaller.")) {
                    layerField("", range: -1000...1000, scrub: 0.25, action: "Change Shadow",
                               get: { Double($0[keyPath: path].grown) }, set: { $0[keyPath: path].spread = $1 == 0 ? nil : CGFloat($1) })
                }
            }
            // Inside, the shadow lies under the layer itself, where dragging moves the layer.
            if !inset && !filming {
                Caption("Or drag the shadow itself on the canvas.")
                    .transition(.unfold)
            }
        }
    }

    // MARK: Depth

    /// Layers held up off the page. The drag tips them further, the way they are already turned;
    /// aimed on the pad, where the card faces the pointer, or on the canvas by the knob in each
    /// one's middle; the exact turn, and how near, under it. Several layers lying together are
    /// one body: the card says how its lead is turned, and what turns that turns them all about
    /// the middle they share (`DepthBody`). A group has a switch besides: whether what it holds
    /// keeps its depth, each layer standing in the scene, or the group is one card (`Node.keepsDepth`).
    func depthCard(live: Bool) -> some View {
        let lead = store.depthLead(of: nodes)
        let turn = (lead ?? nodes.first)?.transform3D ?? Transform3D()
        let summary = (lead.map { Optional($0.transform3D) } ?? common { $0.transform3D }).map { t -> String in
            // How far it is turned, and how near it is held; only held near, only that.
            let near = (t?.z ?? 0) == 0 ? nil : "Z \(CanvasView.number(t?.z ?? 0))"
            if let near, (t?.x ?? 0) == 0, (t?.y ?? 0) == 0, t?.pinned != true { return near }
            let turned = "\(Int((t?.x ?? 0).rounded()))°, \(Int((t?.y ?? 0).rounded()))°" + (near.map { ", \($0)" } ?? "")
            // A screen laid onto a photo: pinned by its corners, and perhaps turned besides.
            guard let t, t.pinned else { return turned }
            return t.x == 0 && t.y == 0 ? String(localized: "Corners pinned") : String(localized: "Corners pinned, \(turned)")
        } ?? Self.several
        let dial = Dial(value: hypot(turn.x, turn.y), range: 0...60, step: 2, action: "Turn in Depth") { v in
            store.turnSelection("Turn in Depth") { $0.tipped(v) }
        }
        return AspectCard(aspect: .depth, title: "3D", summary: summary, dial: dial,
                          remove: { store.removeDepth() }, removal: "Remove 3D", live: live) {
            CardInDepth(turn: turn)
                .frame(width: 19, height: 15)
        } picks: {
            AimPad(turn: turn)
        } exact: {
            HStack(spacing: 8) {
                depthField("X", unit: "°", range: -180...180, scrub: 0.5, lead: lead, get: { $0.x }, set: { $0.x = $1 })
                depthField("Y", unit: "°", range: -180...180, scrub: 0.5, lead: lead, get: { $0.y }, set: { $0.y = $1 })
                depthField("Z", range: -10_000...10_000, scrub: 1, lead: lead, get: { Double($0.z) }, set: { $0.z = CGFloat($1) })
            }
            // A group is one card, unless told that what it holds stands in the scene on its own.
            if !nodes.isEmpty, nodes.allSatisfy(\.isGroup) {
                Row(title: "Layers keep their depth") {
                    Switch(isOn: Binding(get: { nodes.allSatisfy { $0.keepsDepth == true } }, set: { v in
                        store.updateSelection(v ? "Keep Layers in Depth" : "Draw as One Card") { $0.keepsDepth = v ? true : nil }
                    }))
                }
            }
            Caption("On the canvas, drag the knob in its middle to aim it. Hold Control while you move a layer to bring it nearer or push it away. Just outside a side, a drag turns anything in depth.")
            Caption("Hold Control and drag beside the layers to look at an artboard from the side.")
        }
    }

    /// One number of how layers are turned in depth or how high they stand: a body's is its
    /// lead's, and setting it turns or lifts the whole body.
    private func depthField(_ label: LocalizedStringResource, unit: String = "", range: ClosedRange<Double>, scrub: Double, lead: Node?,
                            get: @escaping (Transform3D) -> Double, set: @escaping (inout Transform3D, Double) -> Void) -> NumberField {
        let value = lead.map { get($0.transform3D ?? Transform3D()) } ?? common { get($0.transform3D ?? Transform3D()) }
        return NumberField(label: label, value: value, unit: unit, range: range, scrub: scrub, decimals: 1, action: "Turn in Depth") { v in
            store.turnSelection("Turn in Depth") { t in
                var t = t
                set(&t, v)
                return t
            }
        } each: { f in
            store.turnSelection("Turn in Depth") { t in
                var t = t
                set(&t, f(get(t)))
                return t
            }
        }
    }

    // MARK: Blur

    /// A blur of the layer itself, or of what lies behind it, as frosted glass does; only shapes
    /// with an outline to show it through can blur what is behind them. The drag sets how much,
    /// clicking at each preset; past nothing, the blur comes away.
    @ViewBuilder func blurCard(canBlurBehind: Bool, live: Bool) -> some View {
        if let first = nodes.first { blurCard(first: first, canBlurBehind: canBlurBehind, live: live) }
    }

    private func blurCard(first: Node, canBlurBehind: Bool, live: Bool) -> some View {
        let behind = canBlurBehind && common { $0.blur?.background == true } == true
        let growing = common { $0.blur?.ramp != nil } == true
        let radius = common { $0.blur?.radius }
        var said: [String] = []
        if behind { said.append(String(localized: LocalizedStringResource("blur.behind", defaultValue: "Behind", comment: "A blur of what lies behind a layer, as frosted glass, said briefly."))) }
        if let radius = radius ?? nil {
            if let named = Presets.blurs.first(where: { $0.radius == radius }) {
                said += [String(localized: named.name), Self.said(radius)]
            } else {
                said.append(Self.said(radius))
            }
        } else {
            said.append(Self.several)
        }
        if growing { said.append(String(localized: "Growing")) }
        let r = Double(first.blur?.radius ?? 0)
        let dial = Dial(value: r, range: 0...max(40, r), stops: Presets.blurs.map { Double($0.radius) }, step: 1, action: "Change Blur") { v in
            store.updateSelection("Change Blur") { Presets.applyBlur(CGFloat(v.rounded()), to: &$0) }
        }
        return AspectCard(aspect: .blur, title: "Blur", summary: said.joined(separator: " · "), dial: dial,
                          remove: { store.updateSelection("Remove Blur") { $0.blur = nil } }, removal: "Remove blur", live: live) {
            BlurGlyph(amount: min(CGFloat(r) / 32, 1), behind: behind)
        } picks: {
            if canBlurBehind {
                SegmentedWell(selection: Binding(get: { behind }, set: { v in
                    store.updateSelection("Change Blur") { n in
                        Presets.applyBlur(n.blur?.radius ?? Presets.blurs[1].radius, to: &n)
                        n.blur?.background = v
                    }
                }), options: [(false, "The layer"), (true, "What's behind")])
            }
            PresetStrip(action: "Change Blur", items: Presets.blurs.map { preset in
                PresetItem(id: preset.id, name: preset.name, active: nodes.allSatisfy { $0.blur?.on == true && $0.blur?.radius == preset.radius }) {
                    Presets.applyBlur(preset.radius, to: &$0)
                }
            }) { item in
                let i = Presets.blurs.firstIndex { $0.id == item.id } ?? 0
                BlurGlyph(amount: CGFloat(i) / CGFloat(max(Presets.blurs.count - 1, 1)), behind: behind)
            }
            SegmentedWell(selection: Binding(get: { growing }, set: { v in
                store.updateSelection("Change Blur") { n in
                    Presets.applyBlur(n.blur?.radius ?? Presets.blurs[1].radius, to: &n)
                    let kept = n.blur?.ramp
                    n.blur?.ramp = v ? kept ?? .down : nil
                }
            }), options: [(false, "All over"), (true, "Growing")])
            if growing, let ramp = first.blur?.ramp {
                Group {
                    RampPad(ramp: ramp, aspect: first.frame.width / max(first.frame.height, 1))
                    PresetStrip(action: "Change Blur", items: Presets.ramps.map { preset in
                        PresetItem(id: preset.id, name: preset.name, active: nodes.allSatisfy { $0.blur?.ramp == BlurRamp.toward(preset.edge) }) {
                            $0.blur?.ramp = BlurRamp.toward(preset.edge)
                        }
                    }) { item in
                        RampGlyph(edge: Presets.ramps.first { $0.id == item.id }?.edge ?? 0)
                    }
                }
                .transition(.unfold)
            }
        } exact: {
            Row(title: "Amount") {
                layerField("", range: 0...500, scrub: 0.25, action: "Change Blur",
                           get: { Double($0.blur?.radius ?? 0) }, set: { Presets.applyBlur(CGFloat($1), to: &$0) })
            }
            if behind {
                Row(title: "Light") {
                    layerField("", unit: "%", range: -100...100, scrub: 0.5, decimals: 0, action: "Change Blur",
                               get: { ($0.blur?.brightness ?? 0) * 100 }, set: { $0.blur?.brightness = $1 / 100 })
                }
                Row(title: "Fill") {
                    layerField("", unit: "%", range: 0...100, scrub: 0.5, decimals: 0, action: "Change Blur",
                               get: { ($0.blur?.fillOpacity ?? 0) * 100 }, set: { $0.blur?.fillOpacity = $1 / 100 })
                }
                Caption("Light brightens what shows through, or darkens it below zero. Fill is how much of the layer's own colour lies over it.")
            }
            if growing {
                Caption("A growing blur is sharp at the ring and blurs by the whole amount at the dot.")
            }
        }
    }
}
