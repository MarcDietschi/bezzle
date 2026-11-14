import SwiftUI
import AppKit

/// A design, under the bar along the top: the tools on the left beside the layers, the canvas
/// pressed into the paper in the middle, and the inspector on the right.
struct Workspace: View {
    let store: DocumentStore
    /// The design's tab's menus, which the window draws over everything, the bar included.
    let menus: MenuHost
    @State private var gradients = GradientSession()

    var body: some View {
        VStack(spacing: 0) {
            // Where the window's tab bar lies.
            Color.clear
                .frame(height: Theme.barHeight)
            HStack(spacing: 0) {
                ToolRail(store: store)
                    .readOnly(store.isReadOnly || store.versions.travel != nil)
                if store.showsLayers || store.showsResources {
                    // One place beside the tools, for the layers or the resources, which trade
                    // places sliding past each other.
                    ZStack {
                        if store.showsResources {
                            ResourcesPanel(store: store)
                                .transition(.asymmetric(insertion: .offset(x: 24).combined(with: .opacity), removal: .offset(x: 24).combined(with: .opacity)))
                        } else {
                            LayersPanel(store: store)
                                .transition(.asymmetric(insertion: .offset(x: -24).combined(with: .opacity), removal: .offset(x: -24).combined(with: .opacity)))
                        }
                    }
                    .frame(width: 236)
                    .clipped()
                    .transition(Unfold(axis: .horizontal))
                }
                CanvasHost(store: store, menus: menus)
                    .overlay { TableEdge().allowsHitTesting(false) }
                    .overlay {
                        CardMarks(store: store)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .overlay {
                        StyleMarks(store: store)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .overlay(alignment: .bottom) {
                        // The ruler of time, along the foot of the canvas.
                        if store.versions.browsing {
                            TimeRuler(store: store)
                                .padding(.horizontal, 28)
                                .padding(.bottom, 16)
                                .transition(.offset(y: 14).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.spring, value: store.versions.browsing)
                    .overlay(alignment: .bottom) {
                        // The film's timeline, along the foot of the canvas while the design is animated.
                        if store.animating {
                            FilmTimeline(store: store)
                                .padding(.horizontal, 18)
                                .padding(.bottom, 14)
                                .transition(.offset(y: 18).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.spring, value: store.animating)
                    .overlay {
                        // Notes in the margins, beside the artboards they are about; of now, so
                        // away while looking back.
                        if !store.prototyping && store.versions.travel == nil {
                            NotesLayer(store: store)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        }
                    }
                    .overlay {
                        // The others in a live room who are out of sight, on the rim toward them.
                        if let live = store.sharing?.live {
                            LiveCompass(store: store, room: live)
                        }
                    }
                    .overlay {
                        GradientHandles(store: store)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .overlay(alignment: .top) {
                        if let finder = store.finder {
                            FindBar(store: store, finder: finder)
                                .padding(.top, 14)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                    }
                    .animation(Theme.spring, value: store.finder != nil)
                    // What changed in other designs this one took components or styles from.
                    .overlay(alignment: .top) { LibraryNewsChip(store: store) }
                    .overlay(alignment: .bottom) {
                        if let report = store.importReport { ImportReportCard(store: store, report: report).transition(.opacity) }
                    }
                    .overlay {
                        if let note = store.writingNote {
                            FlowNoteField(store: store, source: note.source, at: note.at)
                        }
                    }
                    .padding(.bottom, 9)
                    .padding(.trailing, 2)
                ZStack {
                    if store.animating {
                        AnimateInspector(store: store)
                            .transition(.asymmetric(insertion: .offset(x: 18).combined(with: .opacity).animation(Theme.spring.delay(0.06)),
                                                    removal: .opacity.animation(.easeOut(duration: 0.08))))
                    } else if store.inspecting {
                        InspectInspector(store: store)
                            .transition(.asymmetric(insertion: .offset(x: 18).combined(with: .opacity).animation(Theme.spring.delay(0.06)),
                                                    removal: .opacity.animation(.easeOut(duration: 0.08))))
                    } else if store.prototyping {
                        PrototypeInspector(store: store)
                            .transition(.asymmetric(insertion: .offset(x: 18).combined(with: .opacity).animation(Theme.spring.delay(0.06)),
                                                    removal: .opacity.animation(.easeOut(duration: 0.08))))
                    } else {
                        Inspector(store: store)
                            .transition(.asymmetric(insertion: .offset(x: -18).combined(with: .opacity).animation(Theme.spring.delay(0.06)),
                                                    removal: .opacity.animation(.easeOut(duration: 0.08))))
                    }
                }
                .frame(width: Inspector.width)
                // Inspecting only reads the design, so a design shared to read can be inspected.
                .readOnly((store.isReadOnly && !store.inspecting) || store.versions.travel != nil)
                .animation(Theme.spring, value: store.prototyping)
                .animation(Theme.spring, value: store.inspecting)
                .animation(Theme.spring, value: store.animating)
            }
            // The prototype played: over the panels and the canvas, under the bar.
            .overlay {
                if let player = store.player {
                    PlayerOverlay(store: store, player: player)
                        .id(ObjectIdentifier(player))
                }
            }
        }
        .background(Theme.paper)
        .ignoresSafeArea()
        .frame(minWidth: 1000, minHeight: 640)
        .animation(Theme.unfold, value: store.showsLayers)
        .animation(Theme.unfold, value: store.showsResources)
        .environment(menus)
        .environment(gradients)
        .environment(store)
        .focusedSceneValue(\.store, store)
        .onAppear {
            gradients.store = store
            gradients.menus = menus
        }
        // A menu about the old selection closes when it changes; a right-click menu opens together
        // with the selection it acts on, so that change is its own.
        .onChange(of: store.selection) {
            if menus.open?.id != MenuHost.contextID { menus.dismiss() }
        }
    }
}

/// The rim of the table: a soft shadow along its top edge where it dips under the paper, and a
/// hairline all round.
private struct TableEdge: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Theme.shadow.opacity(0.22), lineWidth: 1.5)
            .blur(radius: 1.5)
            .offset(y: 1)
            .mask(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            }
    }
}

extension FocusedValues {
    @Entry var store: DocumentStore?
}

extension View {
    /// Looked at but not changed: a design someone else no longer shares.
    fileprivate func readOnly(_ readOnly: Bool) -> some View {
        disabled(readOnly)
            .opacity(readOnly ? 0.45 : 1)
            .animation(Theme.spring, value: readOnly)
    }
}

// MARK: - Top bar

/// The right of the bar along the top while a design is in front: how close, sharing and export.
struct DesignBarControls: View {
    let store: DocumentStore

    var body: some View {
        HStack(spacing: 10) {
            if let live = store.sharing?.live, live.hasPeople {
                LivePeople(room: live)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            } else if let mark = store.sharing?.mark {
                SharingTag(mark: mark)
            }
            ZoomButton(store: store)
            VersionsButton(store: store)
            if Sharing.isAvailable || store.isReadOnly { ShareButton(store: store) }
            ModeSwitch(store: store)
            ModeAction(store: store)
        }
        .animation(Theme.pop, value: store.sharing?.mark)
        .animation(Theme.pop, value: store.sharing?.live?.hasPeople)
    }
}

/// How close the design is seen, and the menu of zooms. The percent is written by a label of
/// AppKit's (`ZoomPercent`), which follows the zoom by itself: SwiftUI hears only how many digits
/// it takes room for, three up to 999 % and more beyond, which is when the button's width changes.
private struct ZoomButton: View {
    let store: DocumentStore

    var body: some View {
        let digits = store.zoomDigits
        MenuButton(id: "zoom", title: "Zoom", width: 220,
                   label: AnyView(ZoomPercent(store: store).frame(width: ZoomPercent.width(digits), height: ZoomPercent.height))) { zoomMenu }
            .help("Zoom")
    }

    private var zoomMenu: [MenuEntry] {
        [
            .item("Zoom In", shortcut: "⌘+") { store.zoomStep(in: true) },
            .item("Zoom Out", shortcut: "⌘−") { store.zoomStep(in: false) },
            .separator,
            .item("Zoom to Fit", shortcut: "⌘0") { store.zoomToFit() },
            .item("Zoom to Selection", shortcut: "⌘2", enabled: !store.selection.isEmpty) { store.zoomToSelection() },
            .separator,
            .item(.verbatim("50%"), checked: abs(store.viewport.zoom - 0.5) < 0.001) { store.zoom(to: 0.5) },
            .item(.verbatim("100%"), shortcut: "⌘1", checked: abs(store.viewport.zoom - 1) < 0.001) { store.zoom(to: 1) },
            .item(.verbatim("200%"), checked: abs(store.viewport.zoom - 2) < 0.001) { store.zoom(to: 2) },
            .item(.verbatim("400%"), checked: abs(store.viewport.zoom - 4) < 0.001) { store.zoom(to: 4) },
            .separator,
        ] + Helpers.shared.entries(for: store)
    }
}

/// The zoom's percent, in the bar's words: drawn by AppKit and changed as the zoom changes,
/// without SwiftUI being told (`DocumentStore.zoomPercent`). Its digits are all as wide as each
/// other, so it keeps its width until it has another number of them.
private struct ZoomPercent: NSViewRepresentable {
    let store: DocumentStore

    static let font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
    static let height = ceil(font.ascender - font.descender + font.leading)

    static func width(_ digits: Int) -> CGFloat {
        ceil((String(repeating: "0", count: max(digits, 1)) + "%" as NSString).size(withAttributes: [.font: font]).width)
    }

    func makeNSView(context: Context) -> Label { Label(store: store) }
    func updateNSView(_ label: Label, context: Context) { label.follow(store) }

    final class Label: NSView {
        private weak var store: DocumentStore?
        private var text = ""
        /// Counts the stores followed, so a change told of one no longer followed is let go.
        private var watching = 0

        init(store: DocumentStore) {
            super.init(frame: .zero)
            setAccessibilityElement(true)
            setAccessibilityRole(.staticText)
            follow(store)
        }

        required init?(coder: NSCoder) { fatalError() }

        override var isFlipped: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }

        func follow(_ store: DocumentStore) {
            guard store !== self.store else { return }
            self.store = store
            watching += 1
            watch(watching)
        }

        private func watch(_ mine: Int) {
            guard mine == watching, let store else { return }
            withObservationTracking {
                let now = "\(store.zoomPercent)%"
                if now != text {
                    text = now
                    needsDisplay = true
                    setAccessibilityValue(now)
                }
            } onChange: { [weak self] in
                Task { @MainActor in self?.watch(mine) }
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }

        override func draw(_ dirtyRect: NSRect) {
            let attributes: [NSAttributedString.Key: Any] = [.font: ZoomPercent.font, .foregroundColor: Theme.inkNS]
            let width = (text as NSString).size(withAttributes: attributes).width
            // At the right, beside the chevron, as the bar's other titles end there.
            (text as NSString).draw(at: CGPoint(x: bounds.width - width, y: (bounds.height - ZoomPercent.height) / 2), withAttributes: attributes)
        }
    }
}

// MARK: - Tools

/// The tools, one above the other, with the layers switch at the foot.
struct ToolRail: View {
    let store: DocumentStore

    var body: some View {
        VStack(spacing: 4) {
            // Nothing is drawn in the prototype: the tools step aside, one after another, sliding
            // and fading together, and come back the same way. They keep their places meanwhile,
            // so nothing else in the rail moves.
            let away = store.prototyping
            ForEach(Array(Tool.allCases.enumerated()), id: \.element) { index, tool in
                RailButton(selected: store.tool == tool, help: .verbatim("\(tool.title)  \(tool.key)")) {
                    ToolGlyph(tool: tool)
                } action: {
                    store.tool = tool
                    if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
                }
                .opacity(away ? 0 : 1)
                .offset(x: away ? -14 : 0)
                .scaleEffect(away ? 0.86 : 1)
                .animation(away ? .spring(response: 0.3, dampingFraction: 1).delay(Double(index) * 0.022)
                                : .spring(response: 0.38, dampingFraction: 0.78).delay(Double(index) * 0.03), value: away)
                .allowsHitTesting(!away)
                .accessibilityHidden(away)
            }
            Spacer()
            RailButton(selected: store.showsResources, help: "Resources  ⇧⌘Y") {
                ResourcesGlyph()
            } action: {
                store.toggleResources()
            }
            RailButton(selected: store.showsLayers, help: "Layers  ⌘Y") {
                LayersGlyph()
            } action: {
                store.showsLayers.toggle()
            }
            // As far from the bottom as from the left, level with the canvas's bottom edge.
            .padding(.bottom, 9)
        }
        .padding(.top, 6)
        .frame(width: 56)
    }
}

private struct RailButton<Glyph: View>: View {
    let selected: Bool
    let help: LocalizedStringResource
    @ViewBuilder let glyph: Glyph
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        glyph
            .foregroundStyle(selected ? Theme.ink : hovering ? Theme.ink : Theme.ink2)
            .frame(width: 38, height: 38)
            .background {
                if selected {
                    Color.clear.well(radius: 10)
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.06 : 0))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(Text(help))
            .animation(Theme.quick, value: hovering)
            .animation(Theme.quick, value: selected)
            .accessibilityLabel(Text(help))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The tools' pictures, drawn in the same hand as the check mark: round ends, one weight.
struct ToolGlyph: View {
    let tool: Tool
    var size: CGFloat = 18

    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let stroke = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            var p = Path()
            switch tool {
            case .select:
                p.move(to: CGPoint(x: w * 0.26, y: h * 0.14))
                p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.56))
                p.addLine(to: CGPoint(x: w * 0.52, y: h * 0.60))
                p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.88))
                p.addLine(to: CGPoint(x: w * 0.56, y: h * 0.92))
                p.addLine(to: CGPoint(x: w * 0.43, y: h * 0.64))
                p.addLine(to: CGPoint(x: w * 0.26, y: h * 0.80))
                p.closeSubpath()
                ctx.fill(p, with: .foreground)
                return
            case .artboard:
                // A sheet with crop marks at its corners.
                p.addRect(CGRect(x: w * 0.26, y: h * 0.26, width: w * 0.48, height: h * 0.48))
                for (x, y) in [(0.26, 0.26), (0.74, 0.26), (0.74, 0.74), (0.26, 0.74)] {
                    let dx = x < 0.5 ? -1.0 : 1.0, dy = y < 0.5 ? -1.0 : 1.0
                    p.move(to: CGPoint(x: w * x, y: h * (y + dy * 0.06)))
                    p.addLine(to: CGPoint(x: w * x, y: h * (y + dy * 0.2)))
                    p.move(to: CGPoint(x: w * (x + dx * 0.06), y: h * y))
                    p.addLine(to: CGPoint(x: w * (x + dx * 0.2), y: h * y))
                }
                ctx.stroke(p, with: .foreground, style: stroke)
                return
            case .rectangle:
                p.addRoundedRect(in: CGRect(x: w * 0.16, y: h * 0.22, width: w * 0.68, height: h * 0.56), cornerSize: CGSize(width: 2, height: 2))
            case .ellipse:
                p.addEllipse(in: CGRect(x: w * 0.17, y: h * 0.17, width: w * 0.66, height: h * 0.66))
            case .line:
                p.move(to: CGPoint(x: w * 0.2, y: h * 0.8))
                p.addLine(to: CGPoint(x: w * 0.8, y: h * 0.2))
            case .pen:
                // A nib writing towards the bottom left, with the collar above it: drawn upright,
                // point down, then turned.
                let k = w / 18 * 1.12
                let place = CGAffineTransform(translationX: w / 2 - 4.24 * k, y: h / 2 + 4.24 * k).rotated(by: .pi / 4).scaledBy(x: k, y: k)
                var nib = Path()
                nib.move(to: .zero)
                nib.addQuadCurve(to: CGPoint(x: 4.2, y: -8.6), control: CGPoint(x: 4.4, y: -4.2))
                nib.addLine(to: CGPoint(x: -4.2, y: -8.6))
                nib.addQuadCurve(to: .zero, control: CGPoint(x: -4.4, y: -4.2))
                nib.closeSubpath()
                nib.move(to: CGPoint(x: 0, y: -0.8))
                nib.addLine(to: CGPoint(x: 0, y: -4.6))
                nib.move(to: CGPoint(x: -2.8, y: -11.6))
                nib.addLine(to: CGPoint(x: 2.8, y: -11.6))
                ctx.stroke(nib.applying(place), with: .foreground, style: stroke)
                ctx.fill(Path(ellipseIn: CGRect(x: -1.25, y: -6.9, width: 2.5, height: 2.5)).applying(place), with: .foreground)
                return
            case .knife:
                // A box cutter cutting towards the bottom left, as the pen writes: the slanted
                // blade, the collar holding it, and the long handle with its slider. Drawn upright,
                // point down, then turned.
                let k = w / 18 * 0.92
                let place = CGAffineTransform(translationX: w / 2 - 6.4 * k, y: h / 2 + 6.4 * k).rotated(by: .pi / 4).scaledBy(x: k, y: k)
                var knife = Path()
                knife.move(to: CGPoint(x: -2.4, y: 0))
                knife.addLine(to: CGPoint(x: 2.4, y: -4.4))
                knife.addLine(to: CGPoint(x: 2.4, y: -6.4))
                knife.addLine(to: CGPoint(x: -2.4, y: -6.4))
                knife.closeSubpath()
                knife.move(to: CGPoint(x: -3.6, y: -8))
                knife.addLine(to: CGPoint(x: 3.6, y: -8))
                knife.addRoundedRect(in: CGRect(x: -2.8, y: -18.1, width: 5.6, height: 8.4), cornerSize: CGSize(width: 1.6, height: 1.6))
                knife.move(to: CGPoint(x: 0, y: -12.2))
                knife.addLine(to: CGPoint(x: 0, y: -15.4))
                ctx.stroke(knife.applying(place), with: .foreground, style: stroke)
                return
            case .text:
                p.move(to: CGPoint(x: w * 0.22, y: h * 0.28))
                p.addLine(to: CGPoint(x: w * 0.22, y: h * 0.2))
                p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.2))
                p.addLine(to: CGPoint(x: w * 0.78, y: h * 0.28))
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.2))
                p.addLine(to: CGPoint(x: w * 0.5, y: h * 0.82))
                p.move(to: CGPoint(x: w * 0.38, y: h * 0.82))
                p.addLine(to: CGPoint(x: w * 0.62, y: h * 0.82))
            case .note:
                // A note in the margin, with its line to the spot it is about.
                p.addRoundedRect(in: CGRect(x: w * 0.4, y: h * 0.16, width: w * 0.44, height: h * 0.36), cornerSize: CGSize(width: w * 0.06, height: w * 0.06))
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.28)); p.addLine(to: CGPoint(x: w * 0.74, y: h * 0.28))
                p.move(to: CGPoint(x: w * 0.5, y: h * 0.4)); p.addLine(to: CGPoint(x: w * 0.66, y: h * 0.4))
                p.move(to: CGPoint(x: w * 0.4, y: h * 0.46))
                p.addQuadCurve(to: CGPoint(x: w * 0.24, y: h * 0.74), control: CGPoint(x: w * 0.26, y: h * 0.5))
                ctx.fill(Path(ellipseIn: CGRect(x: w * 0.24 - 1.6, y: h * 0.74 - 1.6, width: 3.2, height: 3.2)), with: .foreground)
            }
            ctx.stroke(p, with: .foreground, style: stroke)
        }
        .frame(width: size, height: size)
    }
}

/// Two sheets, one over the other.
struct LayersGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            func sheet(_ y: CGFloat) -> Path {
                var p = Path()
                p.move(to: CGPoint(x: w * 0.5, y: h * (y - 0.18)))
                p.addLine(to: CGPoint(x: w * 0.88, y: h * y))
                p.addLine(to: CGPoint(x: w * 0.5, y: h * (y + 0.18)))
                p.addLine(to: CGPoint(x: w * 0.12, y: h * y))
                p.closeSubpath()
                return p
            }
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
            ctx.stroke(sheet(0.6), with: .foreground, style: style)
            ctx.fill(sheet(0.4), with: .color(Theme.paper))
            ctx.stroke(sheet(0.4), with: .foreground, style: style)
        }
        .frame(width: 18, height: 18)
    }
}

/// A small picture of a layer's kind, for the layers list.
struct KindGlyph: View {
    let kind: Node.Kind

    var body: some View {
        Group {
            switch kind {
            case .artboard: ToolGlyph(tool: .artboard, size: 15)
            case .rectangle: ToolGlyph(tool: .rectangle, size: 15)
            case .ellipse: ToolGlyph(tool: .ellipse, size: 15)
            case .line: ToolGlyph(tool: .line, size: 15)
            case .text: ToolGlyph(tool: .text, size: 15)
            case .group: GroupGlyph()
            case .path: PathGlyph()
            }
        }
    }
}

/// Two sheets laid one over the other, for a group.
private struct GroupGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let back = Path(roundedRect: CGRect(x: w * 0.14, y: h * 0.14, width: w * 0.5, height: h * 0.5), cornerRadius: 1.5)
            let front = Path(roundedRect: CGRect(x: w * 0.36, y: h * 0.36, width: w * 0.5, height: h * 0.5), cornerRadius: 1.5)
            ctx.stroke(back, with: .foreground, style: style)
            ctx.fill(front, with: .color(Theme.paper))
            ctx.stroke(front, with: .foreground, style: style)
        }
        .frame(width: 15, height: 15)
    }
}

/// A curve between two points, for a path.
private struct PathGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let w = s.width, h = s.height
            var p = Path()
            p.move(to: CGPoint(x: w * 0.16, y: h * 0.8))
            p.addCurve(to: CGPoint(x: w * 0.84, y: h * 0.22), control1: CGPoint(x: w * 0.2, y: h * 0.2), control2: CGPoint(x: w * 0.6, y: h * 0.86))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
            for q in [CGPoint(x: w * 0.16, y: h * 0.8), CGPoint(x: w * 0.84, y: h * 0.22)] {
                ctx.fill(Path(ellipseIn: CGRect(x: q.x - 1.6, y: q.y - 1.6, width: 3.2, height: 3.2)), with: .foreground)
            }
        }
        .frame(width: 15, height: 15)
    }
}
