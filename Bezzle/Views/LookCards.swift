import SwiftUI
import AppKit

/// The cards for how the selected layers look: their corners, how much of them shows, and their
/// fill, border, shadow, blur and depth. Each one's sideways drag sets what it has most of.
extension SelectionInspector {
    // MARK: Corners

    /// How round the corners are, and whether they are plain arcs or squircles that run smoothly
    /// into the sides, and how smoothly. The drag rounds them, clicking at each preset up to a pill.
    func cornersCard(live: Bool) -> some View {
        let first = nodes[0]
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
        return AspectCard(aspect: .corners, title: "Corners", summary: summary, dial: dial, live: live) {
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

    // MARK: Opacity

    /// How much of the layers shows: the drag fades them, clicking at each quarter.
    func opacityCard(live: Bool) -> some View {
        let first = nodes[0]
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
    func addable(fill: Bool, border: Bool) -> [AddBar.Item] {
        var items: [AddBar.Item] = []
        if fill && common({ $0.fill.on }) == false {
            items.append(.init(id: "add-fill", aspect: .fill, title: "Fill", help: "Add a fill", action: "Add Fill") { $0.fill.on = true })
        }
        if border && common({ $0.border.on }) == false {
            items.append(.init(id: "add-border", aspect: .border, title: "Border", help: "Add a border", action: "Add Border") { n in
                n.border.on = true
                if n.border.width == 0 { n.border.width = 1 }
            })
        }
        if common({ $0.shadow.on }) == false {
            items.append(.init(id: "add-shadow", aspect: .shadow, title: "Shadow", help: "Add a shadow", action: "Add Shadow") { Presets.applyShadow(Presets.shadows[1], to: &$0) })
        }
        if common({ $0.blur?.on == true }) == false {
            items.append(.init(id: "add-blur", aspect: .blur, title: "Blur", help: "Add a blur", action: "Add Blur") { Presets.applyBlur(Presets.blurs[1].radius, to: &$0) })
        }
        if common({ $0.transform3D != nil }) == false {
            items.append(.init(id: "add-3d", aspect: .depth, title: "3D", help: "Add 3D", action: "Add 3D") { $0.transform3D = Presets.heldUp })
        }
        if store.canMakeRepeatGrid {
            items.append(.init(id: "add-repeat", aspect: .grid, title: "Repeat", help: "Add a repeat", action: "Make Repeat Grid", change: { _ in }, add: { store.makeRepeatGrid() }))
        }
        return items
    }

    /// The design's colours that the selection is not already: one click away beside a colour.
    func suggestions(besides color: RGBA?) -> [RGBA] {
        // A colour field shows the first few, of what can be hundreds.
        let own = color?.hex
        return Array(store.designColors.lazy.filter { $0.hex != own }.prefix(12))
    }

    /// What fills the layers. For one colour, the drag sets how much of it shows; past nothing,
    /// the fill comes away.
    func fillCard(removable: Bool, live: Bool) -> some View {
        // Text takes one colour; its letters are not drawn with a gradient.
        let blends = !nodes.contains { $0.kind == .text }
        let first = nodes[0]
        let kind = common { FillKind($0.fill) }
        let fill: Fill? = kind == nil ? nil : common { $0.fill } ?? first.fill
        let dial = kind == .solid ? Dial(value: first.fill.color.a * 100, range: 0...100, stops: [100], step: 5, action: "Change Fill") { v in
            store.updateSelection("Change Fill") { $0.fill.color = $0.fill.color.with(alpha: v.rounded() / 100) }
        } : nil
        return AspectCard(aspect: .fill, title: blends ? "Fill" : "Colour", summary: Self.summary(of: fill, blend: blends ? common { $0.blend } : nil),
                          dial: dial,
                          // The blend mode is shown with the fill, so it goes when the fill does.
                          remove: removable ? { store.updateSelection("Remove Fill") { $0.fill.on = false; $0.blend = nil } } : nil,
                          removal: blends ? "Remove fill" : "Remove colour", live: live) {
            FillSwatch(fill: first.fill, radius: 4)
                .frame(width: 15, height: 15)
        } picks: {
            fillControls(blends: blends, action: "Change Fill", suggest: true)
            if nodes.allSatisfy({ $0.fill.on && $0.fill.image != nil }) {
                backgroundRow
            }
            if store.editingPicture != nil {
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
            if blends { blendRow }
        }
    }

    /// Whether the selected pictures show whole, or their subject alone. The subject is found
    /// away from the main thread: meanwhile "Subject alone" fills with pencil as the work goes,
    /// and the canvas shows it being found. A line under it says why, when nothing stands out.
    @ViewBuilder private var backgroundRow: some View {
        let work = store.selection.compactMap { store.cuttingOut[$0]?.done }
        let alone = !work.isEmpty || common({ $0.fill.image?.cutout != nil }) == true
        SegmentedWell(selection: Binding(get: { alone }, set: { cut in
            if cut { store.removeBackground() } else if work.isEmpty { store.restoreBackground() }
        }), options: [(false, "Whole picture"), (true, "Subject alone")], progress: work.min())
        .help("Take the background away, leaving what stands out in the picture. Double-click the picture to keep or drop each subject in it. The picture itself is kept, to have it back.")
        if let trouble = store.cutoutTrouble {
            Text(trouble)
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.unfold)
        }
    }

    /// How the selected layers mix with what lies under them. Each mode shows on the canvas while
    /// it is pointed at in the menu.
    private var blendRow: some View {
        let blend = common { $0.blend }
        let groups: [[BlendMode?]] = [[nil], [.darken, .multiply, .colorBurn], [.lighten, .screen, .colorDodge],
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
    /// menu, where one colour or a gradient is chosen and its colours; text takes one colour.
    @ViewBuilder func fillControls(blends: Bool, action: LocalizedStringResource, suggest: Bool) -> some View {
        let color = common { $0.fill.color }
        let suggested = suggest ? suggestions(besides: color) : []
        let preview: (RGBA?) -> Void = { c in store.showPreview("fill-colour", c.map { c in { $0.fill.color = c; $0.fill.on = true } }) }
        let apply: (RGBA) -> Void = { c in store.updateSelection(action) { $0.fill.color = c; $0.fill.on = true } }
        if blends {
            FillField(fill: nodes[0].fill, color: color, action: action, suggestions: suggested, preview: preview, apply: apply)
        } else {
            ColorField(id: "fill", color: color, suggestions: suggested, action: action, preview: preview, apply: apply)
        }
    }

    // MARK: Border

    /// The border, or a line's stroke. The drag sets its weight, clicking at each preset; past
    /// nothing a border comes away, though a line keeps its stroke.
    func borderCard(lineOnly: Bool, removable: Bool, live: Bool) -> some View {
        let first = nodes[0]
        let color = common { $0.border.color }
        let width = common { $0.border.width }
        var summary = width.map { "\(Self.said($0)) pt" } ?? Self.several
        if !lineOnly, let position = common({ $0.border.position }) {
            switch position {
            case .inside: summary += " · \(String(localized: "Inside"))"
            case .center: summary += " · \(String(localized: LocalizedStringResource("border.centred", defaultValue: "Centred", comment: "A border lying across the edge of its layer, half in and half out.")))"
            case .outside: summary += " · \(String(localized: "Outside"))"
            }
        }
        if common({ $0.border.dash > 0 }) == true { summary += " · \(String(localized: "Dashed"))" }
        let floor: Double = lineOnly ? 0.5 : 0
        let dial = Dial(value: Double(first.border.width), range: floor...max(12, Double(first.border.width)), stops: [1, 2, 4], step: 0.5, action: "Change Border") { v in
            store.updateSelection("Change Border") { $0.border.width = CGFloat(max((v * 2).rounded() / 2, floor)); $0.border.on = true }
        }
        return AspectCard(aspect: .border, title: lineOnly ? "Line" : "Border", summary: summary, dial: dial,
                          remove: removable ? { store.updateSelection("Remove Border") { $0.border.on = false } } : nil,
                          removal: lineOnly ? "Remove line" : "Remove border", live: live) {
            BorderGlyph(width: first.border.dash > 0 ? nil : first.border.width)
        } picks: {
            PresetStrip(action: "Change Border", items: Presets.borders.map { preset in
                PresetItem(id: preset.id, name: preset.name, active: nodes.allSatisfy { Presets.isBorder(preset.width, $0.border) }) {
                    Presets.applyBorder(preset.width, to: &$0)
                }
            }) { item in
                BorderGlyph(width: Presets.borders.first { $0.id == item.id }?.width ?? nil)
            }
            ColorField(id: "border", color: color, suggestions: suggestions(besides: color), action: "Change Border",
                       preview: { c in store.showPreview("border-colour", c.map { c in { $0.border.color = c; $0.border.on = true } }) }) { c in
                store.updateSelection("Change Border") { $0.border.color = c; $0.border.on = true }
            }
        } exact: {
            HStack(spacing: 8) {
                layerField(LocalizedStringResource("border.size", defaultValue: "Size", comment: "How thick a border is."), range: 0...1000, scrub: 0.25, action: "Change Border",
                           get: { Double($0.border.width) }, set: { $0.border.width = CGFloat($1); $0.border.on = true })
                layerField("Dash", range: 0...1000, scrub: 0.25, action: "Change Border", get: { Double($0.border.dash) }) { n, v in
                    n.border.dash = CGFloat(v)
                    if n.border.gap == 0 { n.border.gap = CGFloat(v) }
                }
                layerField("Gap", range: 0...1000, scrub: 0.25, action: "Change Border",
                           get: { Double($0.border.gap) }, set: { $0.border.gap = CGFloat($1) })
            }
            if !lineOnly {
                IconChoice(selection: common { $0.border.position }, options: [
                    (.inside, "square.inset.filled", "Inside"),
                    (.center, "square.dashed", "Centred on the edge"),
                    (.outside, "square.fill", "Outside"),
                ]) { p in store.updateSelection("Change Border") { $0.border.position = p } }
            }
        }
    }

    // MARK: Shadow

    /// A shadow under the layers, or inside them as if they were pressed into the page; a line
    /// has no inside for one to fall in. The drag lifts them, from none through each preset to
    /// floating, blending two presets between them.
    func shadowCard(canInset: Bool, live: Bool) -> some View {
        let first = nodes[0]
        let inset = canInset && common { $0.shadow.inset == true } == true
        let presets = inset ? Presets.innerShadows : Presets.shadows
        let summary: String
        if let named = presets.first(where: { p in nodes.allSatisfy { Presets.isShadow(p, $0.shadow) } }) {
            summary = String(localized: named.name)
        } else if let s = common({ $0.shadow }) {
            let at = (s.x != 0 ? ["X \(Self.said(s.x))"] : []) + ["Y \(Self.said(s.y))", "\(String(localized: "B")) \(Self.said(s.blur))"]
            summary = ((inset ? [String(localized: "Inside")] : []) + at).joined(separator: " · ")
        } else {
            summary = Self.several
        }
        let dial = Dial(value: Presets.elevation(of: first.shadow), range: 0...Presets.topElevation, stops: [1, 2, 3, 4], step: 1, action: "Change Shadow") { v in
            store.updateSelection("Change Shadow") { Presets.setElevation(v, on: &$0) }
        }
        return AspectCard(aspect: .shadow, title: "Shadow", summary: summary, dial: dial,
                          remove: { store.updateSelection("Remove Shadow") { $0.shadow.on = false } }, removal: "Remove shadow", live: live) {
            ShadowGlyph(y: first.shadow.y, blur: first.shadow.blur, inset: inset)
        } picks: {
            if canInset {
                SegmentedWell(selection: Binding(get: { inset }, set: { v in
                    store.updateSelection("Change Shadow") { Presets.setShadowInset(v, on: &$0) }
                }), options: [(false, "Outside"), (true, "Inside")])
            }
            PresetStrip(action: "Change Shadow", items: presets.map { preset in
                PresetItem(id: preset.id, name: preset.name, active: nodes.allSatisfy { Presets.isShadow(preset, $0.shadow) }) {
                    Presets.applyShadow(preset, to: &$0)
                }
            }) { item in
                let preset = presets.first { $0.id == item.id }
                ShadowGlyph(y: preset?.y ?? 0, blur: preset?.blur ?? 0, inset: inset)
            }
            ColorField(id: "shadow", color: common { $0.shadow.color }, action: "Change Shadow") { c in
                store.updateSelection("Change Shadow") { $0.shadow.color = c }
            }
        } exact: {
            HStack(spacing: 8) {
                layerField("X", range: -1000...1000, scrub: 0.5, action: "Change Shadow",
                           get: { Double($0.shadow.x) }, set: { $0.shadow.x = CGFloat($1) })
                layerField("Y", range: -1000...1000, scrub: 0.5, action: "Change Shadow",
                           get: { Double($0.shadow.y) }, set: { $0.shadow.y = CGFloat($1) })
                layerField("B", range: 0...1000, scrub: 0.5, action: "Change Shadow",
                           get: { Double($0.shadow.blur) }, set: { $0.shadow.blur = CGFloat($1) })
            }
            // Inside, the shadow lies under the layer itself, where dragging moves the layer.
            if !inset {
                Caption("Or drag the shadow itself on the canvas.")
                    .transition(.unfold)
            }
        }
    }

    // MARK: Depth

    /// Layers held up off the page. The drag tips them further, the way they are already turned;
    /// aimed on the pad, where the card faces the pointer, or on the canvas by the knob in each
    /// one's middle; the exact turn, and how near, under it.
    func depthCard(live: Bool) -> some View {
        let turn = nodes.first?.transform3D ?? Transform3D()
        let summary = common { $0.transform3D }.map { t in "\(Int((t?.x ?? 0).rounded()))°, \(Int((t?.y ?? 0).rounded()))°" } ?? Self.several
        let dial = Dial(value: hypot(turn.x, turn.y), range: 0...60, step: 2, action: "Turn in Depth") { v in
            store.updateSelection("Turn in Depth") { n in
                var t = n.transform3D ?? Transform3D()
                let now = hypot(t.x, t.y), held = hypot(Presets.heldUp.x, Presets.heldUp.y)
                // Tipped the way it is turned already; laid flat, the way a layer is first held up.
                let (dx, dy) = now > 0.05 ? (t.x / now, t.y / now) : (Presets.heldUp.x / held, Presets.heldUp.y / held)
                let by = max(v, 0.1)
                t.x = (dx * by * 10).rounded() / 10
                t.y = (dy * by * 10).rounded() / 10
                n.transform3D = t
            }
        }
        return AspectCard(aspect: .depth, title: "3D", summary: summary, dial: dial,
                          remove: { store.updateSelection("Remove 3D") { $0.transform3D = nil } }, removal: "Remove 3D", live: live) {
            CardInDepth(turn: turn)
                .frame(width: 19, height: 15)
        } picks: {
            AimPad(turn: turn)
        } exact: {
            HStack(spacing: 8) {
                layerField("X", unit: "°", range: -180...180, scrub: 0.5, action: "Turn in Depth",
                           get: { $0.transform3D?.x ?? 0 }, set: { n, v in n.transform3D = n.transform3D ?? Transform3D(); n.transform3D?.x = v })
                layerField("Y", unit: "°", range: -180...180, scrub: 0.5, action: "Turn in Depth",
                           get: { $0.transform3D?.y ?? 0 }, set: { n, v in n.transform3D = n.transform3D ?? Transform3D(); n.transform3D?.y = v })
                layerField("Z", range: -10_000...10_000, scrub: 1, action: "Turn in Depth",
                           get: { Double($0.transform3D?.z ?? 0) }, set: { n, v in n.transform3D = n.transform3D ?? Transform3D(); n.transform3D?.z = CGFloat(v) })
            }
            Caption("On the canvas, drag the knob in its middle to aim it, with Option to bring it nearer. Just outside a side, a drag turns anything in depth.")
        }
    }

    // MARK: Blur

    /// A blur of the layer itself, or of what lies behind it, as frosted glass does; only shapes
    /// with an outline to show it through can blur what is behind them. The drag sets how much,
    /// clicking at each preset; past nothing, the blur comes away.
    func blurCard(canBlurBehind: Bool, live: Bool) -> some View {
        let first = nodes[0]
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
