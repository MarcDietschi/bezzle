import SwiftUI
import AppKit

/// A design window: the strip along the top, the tools on the left beside the layers, the canvas
/// pressed into the paper in the middle, and the inspector on the right.
struct Workspace: View {
    let store: DocumentStore
    @State private var menus = MenuHost()
    @State private var gradients = GradientSession()

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store)
                .zIndex(1)
            HStack(spacing: 0) {
                ToolRail(store: store)
                if store.showsLayers {
                    LayersPanel(store: store)
                        .frame(width: 236)
                        .transition(Unfold(axis: .horizontal))
                }
                CanvasHost(store: store, menus: menus)
                    .overlay { TableEdge().allowsHitTesting(false) }
                    .overlay {
                        GradientHandles(store: store)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .overlay(alignment: .bottom) {
                        if let report = store.importReport { ImportReportCard(store: store, report: report).transition(.opacity) }
                    }
                    .padding(.bottom, 8)
                    .padding(.trailing, 2)
                Inspector(store: store)
                    .frame(width: Inspector.width)
            }
        }
        .background(Theme.paper)
        .ignoresSafeArea()
        .frame(minWidth: 1000, minHeight: 640)
        .animation(Theme.unfold, value: store.showsLayers)
        .overlay {
            if store.exporting {
                ExportSheet(store: store)
                    .transition(.opacity)
            }
        }
        .animation(store.exporting ? Theme.open : Theme.close, value: store.exporting)
        .overlayPreferenceValue(MenuAnchorKey.self) { anchors in
            MenuLayer(anchors: anchors)
        }
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

// MARK: - Top bar

/// The strip along the top, level with the traffic lights: where you are, and how close.
struct TopBar: View {
    let store: DocumentStore
    @Environment(\.openWindow) private var openWindow
    @State private var renaming = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Bezzle")
                    .font(Theme.serif(15, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .contentShape(Rectangle())
                    .onTapGesture { openWindow(id: "home") }
                    .help("Home")
                Text("/")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink4)
                if renaming {
                    TextField("", text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .focused($focused)
                        .frame(width: 220)
                        .onSubmit { commit() }
                        .onExitCommand { renaming = false }
                        .onChange(of: focused) { _, now in if !now { commit() } }
                } else {
                    Text(store.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            draft = store.name
                            renaming = true
                            focused = true
                        }
                        .help("Rename")
                }
            }
            Spacer(minLength: 12)
            MenuButton(id: "zoom", title: "\(Int((store.viewport.zoom * 100).rounded()))%", width: 220) { zoomMenu }
                .help("Zoom")
            if CloudSync.isAvailable { ShareButton(store: store) }
            CardButton(title: "Export…", height: 28) { store.exporting = true }
                .help("Export  ⌘E")
        }
        .padding(.leading, 92)
        .padding(.trailing, 16)
        .frame(height: Theme.barHeight)
    }

    private func commit() {
        guard renaming else { return }
        renaming = false
        store.rename(to: draft)
    }

    private var zoomMenu: [MenuEntry] {
        [
            .item("Zoom In", shortcut: "⌘+") { store.zoomStep(in: true) },
            .item("Zoom Out", shortcut: "⌘−") { store.zoomStep(in: false) },
            .separator,
            .item("Zoom to Fit", shortcut: "⌘0") { store.zoomToFit() },
            .item("Zoom to Selection", shortcut: "⌘2", enabled: !store.selection.isEmpty) { store.zoomToSelection() },
            .separator,
            .item("50%", checked: abs(store.viewport.zoom - 0.5) < 0.001) { store.zoom(to: 0.5) },
            .item("100%", shortcut: "⌘1", checked: abs(store.viewport.zoom - 1) < 0.001) { store.zoom(to: 1) },
            .item("200%", checked: abs(store.viewport.zoom - 2) < 0.001) { store.zoom(to: 2) },
            .item("400%", checked: abs(store.viewport.zoom - 4) < 0.001) { store.zoom(to: 4) },
        ]
    }
}

// MARK: - Tools

/// The tools, one above the other, with the layers switch at the foot.
struct ToolRail: View {
    let store: DocumentStore

    var body: some View {
        VStack(spacing: 4) {
            ForEach(Tool.allCases, id: \.self) { tool in
                RailButton(selected: store.tool == tool, help: "\(tool.title)  \(tool.key)") {
                    ToolGlyph(tool: tool)
                } action: {
                    store.tool = tool
                    store.canvas.map { $0.window?.makeFirstResponder($0) }
                }
            }
            Spacer()
            RailButton(selected: store.showsLayers, help: "Layers  ⌘Y") {
                LayersGlyph()
            } action: {
                store.showsLayers.toggle()
            }
            .padding(.bottom, 14)
        }
        .padding(.top, 6)
        .frame(width: 56)
    }
}

private struct RailButton<Glyph: View>: View {
    let selected: Bool
    let help: String
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
            .help(help)
            .animation(Theme.quick, value: hovering)
            .animation(Theme.quick, value: selected)
            .accessibilityLabel(help)
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
