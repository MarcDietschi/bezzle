import SwiftUI
import AppKit

/// The panel on the right while the design is seen as a prototype. With nothing picked: the
/// screen it starts on, standing in its device on a small stage, to play; the ways through it, as
/// a story; and the design as code. With a layer picked: where it goes, what is said of it and how
/// it moves; with a copy of a component, its states; with a screen, its own part.
struct PrototypeInspector: View {
    let store: DocumentStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                let picked = store.selectedNodes
                if picked.isEmpty {
                    StartCard(store: store)
                    FlowStory(store: store)
                    HandOffCard(store: store)
                } else if picked.count == 1, picked[0].isArtboard {
                    ScreenCard(store: store, board: picked[0])
                    StartHint(store: store, board: picked[0])
                } else {
                    LinkCard(store: store)
                    if let copy = store.selectedCopy, let master = store.master(of: copy) {
                        StatesCard(store: store, copy: copy, master: master)
                    }
                }
            }
            .padding(.horizontal, Inspector.gutter)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .animation(Theme.spring, value: store.selection)
        }
        .scrollIndicators(.never)
        .edgeFade(length: 20)
        .onChange(of: store.selection, initial: true) {
            // Where a picked layer goes is what there is to see of it: its card opens by itself.
            let picked = store.selectedNodes
            if picked.count == 1, picked[0].isArtboard {
                if store.openAspect != .screen { store.openAspect = .screen }
            } else if !picked.isEmpty, store.openAspect != .flow, store.openAspect != .states {
                store.openAspect = .flow
            }
        }
        .onDisappear { store.flowPreview = nil }
    }
}

// MARK: - Pictures of screens

/// Small pictures of the screens, made again only when a screen changes.
@MainActor
final class ScreenThumbs {
    static let shared = ScreenThumbs()
    private var kept: [UUID: (node: Node, width: CGFloat, image: CGImage)] = [:]

    /// The top of a screen, as much as a device shows, `width` points wide.
    func image(of board: Node, width: CGFloat, assets: Assets?) -> CGImage? {
        if let k = kept[board.id], k.width == width, k.node == board { return k.image }
        let shown = board.shownAlone
        let f = shown.frame
        let tall = min(f.height, max(f.width * 2.17, 1))
        let scale = width * 2 / max(f.width, 1)
        guard let image = Renderer.image(of: shown, part: CGRect(x: f.minX, y: f.minY, width: f.width, height: tall), scale: scale, assets: assets) else { return nil }
        if kept.count > 300 { kept.removeAll() }
        kept[board.id] = (board, width, image)
        return image
    }
}

/// A screen as a small picture, in its own proportions up to a phone's.
private struct ScreenPicture: View {
    let store: DocumentStore
    let board: Node
    let width: CGFloat

    var body: some View {
        let f = board.frame
        let h = min(f.height, f.width * 2.17) / max(f.width, 1) * width
        Group {
            if let image = ScreenThumbs.shared.image(of: board, width: width, assets: store.assets) {
                Image(decorative: image, scale: 2).resizable()
            } else {
                Color.white
            }
        }
        .frame(width: width, height: max(h, 8))
    }
}

// MARK: - Nothing picked

/// The screen the prototype starts on, standing in its device on a small stage, lit as on the
/// canvas. A click plays it; the flag under it names it and offers the other screens to start on.
private struct StartCard: View {
    let store: DocumentStore
    @Environment(MenuHost.self) private var menus
    @State private var hovering = false
    @State private var pressed = false

    var body: some View {
        let start = store.startScreen
        VStack(spacing: 0) {
            ZStack {
                Color(nsColor: FlowInk.stage)
                GraphPaper(step: 7)
                    .mask(RadialGradient(colors: [.black, .black.opacity(0.4), .clear], center: .center, startRadius: 30, endRadius: 190))
                if let start {
                    device(start)
                        .rotation3DEffect(.degrees(hovering ? 6 : 0), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                        .offset(y: hovering ? -3 : 0)
                        .scaleEffect(pressed ? 0.97 : 1)
                    PlayDisc(hovering: hovering)
                } else {
                    // No screen yet: a phone's outline, waiting.
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.ink4, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3]))
                        .frame(width: 74, height: 150)
                }
            }
            .frame(height: 206)
            .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 12, style: .continuous))
            .contentShape(Rectangle())
            .onHover { hovering = $0 && start != nil }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if start != nil { pressed = true } }
                .onEnded { _ in
                    pressed = false
                    if start != nil { store.play() }
                })
            .animation(.spring(response: 0.4, dampingFraction: 0.7), value: hovering)
            .animation(Theme.quick, value: pressed)
            .help(start.map { Text("Play from \($0.name)  ⌘↩") } ?? Text(""))
            HStack(spacing: 7) {
                FlagGlyph()
                    .frame(width: 13, height: 11)
                Text(verbatim: start?.name ?? "")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if Prototype.screens(in: store.seenDoc).count > 1 {
                    MenuButton(id: "prototype.start", title: "Start", width: 220) {
                        Prototype.screens(in: store.seenDoc).map { s in
                            .item(.verbatim(s.name), checked: s.id == start?.id) { store.setStart(s.id) }
                        }
                    }
                    .help("Where the prototype starts. On the canvas, drag the flag onto another screen.")
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
        }
        .card(radius: 12, lifted: hovering)
        .accessibilityElement(children: .contain)
    }

    private func device(_ board: Node) -> some View {
        let (form, screen) = Player.device(for: board.frame.size)
        let raw = form.metrics(screen)
        let k = min(150 / max(raw.size.height, 1), 210 / max(raw.size.width, 1))
        let m = form.metrics(CGSize(width: screen.width * k, height: screen.height * k))
        return ZStack(alignment: .topLeading) {
            FormDrawing(form: form, m: m)
            ScreenPicture(store: store, board: board, width: m.screen.width)
                .frame(width: m.screen.width, height: m.screen.height, alignment: .top)
                .clipShape(form.outline(m))
                .offset(x: m.screen.minX, y: m.screen.minY)
            if case .phone(true) = form {
                let w = m.screen.width
                Capsule().fill(Color.black)
                    .frame(width: w * 0.3, height: max(1.5, w * 0.085))
                    .offset(x: m.screen.midX - w * 0.15, y: m.screen.minY + max(1.2, w * 0.035))
            }
        }
        .frame(width: m.size.width, height: m.size.height, alignment: .topLeading)
        .compositingGroup()
        .shadow(color: Theme.shadow.opacity(0.22), radius: 12, y: 8)
        .shadow(color: Theme.shadow.opacity(0.18), radius: 2, y: 1)
    }
}

/// The disc of play over the device, swelling as it is pointed at.
private struct PlayDisc: View {
    let hovering: Bool

    var body: some View {
        Circle()
            .fill(Theme.pencil)
            .overlay {
                Image(systemName: "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: 1.5)
            }
            .frame(width: 46, height: 46)
            .shadow(color: Theme.pencil.opacity(0.6), radius: hovering ? 16 : 8, y: 4)
            .scaleEffect(hovering ? 1.1 : 0.92)
            .opacity(hovering ? 1 : 0.88)
            .allowsHitTesting(false)
    }
}

/// The start flag, as it sticks out of a screen on the canvas.
struct FlagGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            p.move(to: .zero)
            p.addLine(to: CGPoint(x: s.width, y: 0))
            p.addLine(to: CGPoint(x: s.width, y: s.height))
            p.addLine(to: CGPoint(x: 0, y: s.height))
            p.addLine(to: CGPoint(x: s.width * 0.25, y: s.height / 2))
            p.closeSubpath()
            ctx.fill(p, with: .color(Theme.pencil))
            var t = Path()
            t.move(to: CGPoint(x: s.width * 0.45, y: s.height * 0.25))
            t.addLine(to: CGPoint(x: s.width * 0.78, y: s.height * 0.5))
            t.addLine(to: CGPoint(x: s.width * 0.45, y: s.height * 0.75))
            t.closeSubpath()
            ctx.fill(t, with: .color(.white))
        }
    }
}

/// The ways through the prototype, as a story: from which layer of which screen to where, and why,
/// in the designer's words. A row picks that layer on the canvas. With none yet, a small drawing
/// shows how one is made.
private struct FlowStory: View {
    let store: DocumentStore

    var body: some View {
        let seen = store.seenDoc
        let links = Prototype.links(in: seen)
        VStack(alignment: .leading, spacing: 0) {
            if links.isEmpty {
                PullDemo()
                    .frame(height: 112)
                    .padding(.top, 10)
                Text("Pull a thread from a button onto a screen")
                    .font(.custom("Bradley Hand", size: 15))
                    .foregroundStyle(Theme.pencil)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 14)
            } else {
                ForEach(Array(links.prefix(60).enumerated()), id: \.element.source) { i, link in
                    if i > 0 { Hairline().padding(.leading, 12) }
                    StoryRow(store: store, link: link)
                }
            }
        }
        .card(radius: 12)
    }
}

private struct StoryRow: View {
    let store: DocumentStore
    let link: Prototype.Link
    @State private var hovering = false

    var body: some View {
        let seen = store.seenDoc
        let source = seen.node(link.source)
        let from = seen.node(link.board)?.name ?? ""
        let to = link.flow.goesBack ? String(localized: "Back") : link.flow.to.flatMap { seen.node($0)?.name } ?? ""
        let picked = store.selection.contains(link.source)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(verbatim: link.source == link.board ? from : source?.name ?? "")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                ThreadGlyph(back: link.flow.goesBack)
                    .frame(width: 18, height: 10)
                    .foregroundStyle(picked || hovering ? Theme.pencil : Theme.ink3)
                Text(verbatim: to)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let after = link.flow.after, link.source == link.board {
                    Text(verbatim: String(format: "%.1f s", after))
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Theme.ink3)
                }
            }
            if link.source != link.board {
                Text(verbatim: from)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            if let note = link.flow.note {
                Text(verbatim: note)
                    .font(.custom("Bradley Hand", size: 14))
                    .foregroundStyle(Theme.pencil)
                    .lineLimit(2)
                    .padding(.top, 1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(picked ? Theme.pencilWash : hovering ? Theme.ink.opacity(0.035) : .clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture {
            store.selection = [link.source]
            store.show(link.source)
        }
        .animation(Theme.quick, value: hovering)
    }
}

/// A thread with its arrow, or the hook of one going back.
struct ThreadGlyph: View {
    var back = false

    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            if back {
                p.move(to: CGPoint(x: s.width * 0.85, y: s.height * 0.85))
                p.addCurve(to: CGPoint(x: s.width * 0.2, y: s.height * 0.3), control1: CGPoint(x: s.width * 0.9, y: s.height * 0.1), control2: CGPoint(x: s.width * 0.4, y: s.height * 0.2))
                p.move(to: CGPoint(x: s.width * 0.4, y: s.height * 0.02))
                p.addLine(to: CGPoint(x: s.width * 0.15, y: s.height * 0.3))
                p.addLine(to: CGPoint(x: s.width * 0.4, y: s.height * 0.6))
            } else {
                p.move(to: CGPoint(x: s.width * 0.05, y: s.height * 0.7))
                p.addCurve(to: CGPoint(x: s.width * 0.92, y: s.height * 0.4), control1: CGPoint(x: s.width * 0.4, y: s.height * 0.95), control2: CGPoint(x: s.width * 0.55, y: s.height * 0.35))
                p.move(to: CGPoint(x: s.width * 0.72, y: s.height * 0.12))
                p.addLine(to: CGPoint(x: s.width * 0.94, y: s.height * 0.4))
                p.addLine(to: CGPoint(x: s.width * 0.7, y: s.height * 0.7))
            }
            ctx.stroke(p, with: .foreground, style: style)
        }
    }
}

/// How a flow is made, shown by doing it: a thread is pulled out of a button on one screen and
/// tied to the next, which answers; then it starts over.
private struct PullDemo: View {
    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, s in
                let t = timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3.4)
                let pencil = Theme.pencil
                let w: CGFloat = 46, h: CGFloat = 84
                let a = CGRect(x: s.width / 2 - 92, y: (s.height - h) / 2, width: w, height: h)
                let b = CGRect(x: s.width / 2 + 46, y: (s.height - h) / 2, width: w, height: h)
                for r in [a, b] {
                    let p = Path(roundedRect: r, cornerRadius: 7)
                    ctx.fill(p, with: .color(Theme.card))
                    ctx.stroke(p, with: .color(Theme.ink4), lineWidth: 1)
                }
                // A few lines of a screen, and the button.
                for i in 0..<3 {
                    ctx.fill(Path(roundedRect: CGRect(x: a.minX + 7, y: a.minY + 12 + CGFloat(i) * 8, width: w - 14 - CGFloat(i) * 6, height: 3), cornerRadius: 1.5), with: .color(Theme.ink4))
                    ctx.fill(Path(roundedRect: CGRect(x: b.minX + 7, y: b.minY + 12 + CGFloat(i) * 8, width: w - 18 + CGFloat(i) * 3, height: 3), cornerRadius: 1.5), with: .color(Theme.ink4))
                }
                let button = CGRect(x: a.minX + 7, y: a.maxY - 22, width: w - 14, height: 11)
                let pull = min(max((t - 0.5) / 1.1, 0), 1)
                let held = t > 0.25 && t < 2.9
                ctx.fill(Path(roundedRect: button, cornerRadius: 5.5), with: .color(held ? pencil : Theme.ink3))
                let p0 = CGPoint(x: button.maxX, y: button.midY)
                let p3 = CGPoint(x: b.minX, y: b.midY + 10)
                let e = 1 - pow(1 - pull, 3)
                let end = CGPoint(x: p0.x + (p3.x - p0.x) * e, y: p0.y + (p3.y - p0.y) * e - sin(e * .pi) * 10)
                if held, pull > 0 {
                    var thread = Path()
                    thread.move(to: p0)
                    let sag = (1 - e) * 16
                    thread.addCurve(to: end, control1: CGPoint(x: p0.x + 30, y: p0.y + sag), control2: CGPoint(x: end.x - 30, y: end.y + sag))
                    ctx.stroke(thread, with: .color(pencil), style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)), with: .color(pencil))
                }
                // The screen answers once it is tied.
                if t > 1.6, t < 2.9 {
                    let u = min((t - 1.6) / 0.7, 1)
                    let ring = Path(roundedRect: b.insetBy(dx: -CGFloat(2 + 10 * u), dy: -CGFloat(2 + 10 * u)), cornerRadius: 9 + 5 * u)
                    ctx.stroke(ring, with: .color(pencil.opacity(1 - u)), lineWidth: 1.5)
                    ctx.stroke(Path(roundedRect: b.insetBy(dx: -2, dy: -2), cornerRadius: 8), with: .color(pencil), lineWidth: 1.5)
                }
                // The pointer that pulls it.
                if held {
                    let at = pull > 0 ? end : CGPoint(x: button.midX, y: button.midY)
                    var arrow = Path()
                    arrow.move(to: CGPoint(x: at.x + 2, y: at.y + 2))
                    arrow.addLine(to: CGPoint(x: at.x + 2, y: at.y + 14))
                    arrow.addLine(to: CGPoint(x: at.x + 5.5, y: at.y + 10.5))
                    arrow.addLine(to: CGPoint(x: at.x + 10.5, y: at.y + 10))
                    arrow.closeSubpath()
                    ctx.fill(arrow, with: .color(Theme.ink))
                    ctx.stroke(arrow, with: .color(Theme.card), lineWidth: 0.8)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

/// The design as code: its named looks as tokens, copied in a click, and the whole prototype handed
/// to Claude through Bezzle's AI server, which can write a change made in the code back here.
struct HandOffCard: View {
    let store: DocumentStore
    @State private var copied: String?

    var body: some View {
        let count = DesignTokens.count(store.doc)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                CodeGlyph()
                    .frame(width: 22, height: 22)
                    .foregroundStyle(Theme.ink2)
                Text("Code")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text(count == 1 ? String(localized: "1 token") : String(localized: "\(count) tokens"))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.ink2)
            }
            .frame(height: 22)
            HStack(spacing: 6) {
                ForEach(DesignTokens.Format.allCases, id: \.self) { format in
                    TokenChip(title: format.title, copied: copied == format.rawValue) {
                        put(DesignTokens.write(store.doc, named: store.name, as: format))
                        flash(format.rawValue)
                    }
                    .disabled(count == 0)
                }
            }
            .opacity(count == 0 ? 0.45 : 1)
            .help(count == 0 ? "Give colours, type, shadows or corners a name in the design, and they come out here as tokens." : "Copy the design's named looks as tokens")
            Button {
                put(Self.prompt(for: store.name))
                flash("claude")
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: copied == "claude" ? "checkmark" : "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                    Text(copied == "claude" ? "Copied" : "Build It with Claude")
                        .font(.system(size: 12.5, weight: .semibold))
                }
                .foregroundStyle(Theme.onInk)
                .frame(maxWidth: .infinity)
                .frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.ink))
            }
            .buttonStyle(Pressable())
            .help("Copies what to tell Claude. With Bezzle connected, Claude gets every screen, flow, state and token in one go, and can write what changes in the code back into the design.")
            // Building it by hand: the design inspected, measured and written as code a layer at a time.
            if !store.inspecting {
                CardButton(title: LocalizedStringResource("mode.inspect", defaultValue: "Inspect"), symbol: "ruler", height: 30) {
                    store.show(.inspect)
                    if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
                }
                .frame(maxWidth: .infinity)
                .help(CanvasMode.inspect.tip)
            }
        }
        .padding(12)
        .card(radius: 12)
        .animation(Theme.quick, value: copied)
    }

    private func put(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func flash(_ what: String) {
        copied = what
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { if copied == what { copied = nil } }
    }

    /// What to tell Claude to build the prototype: the server's prompt does the rest.
    static func prompt(for design: String) -> String {
        """
        Build a working prototype of my Bezzle design "\(design)". Use the Bezzle MCP server: run its build_prototype prompt \
        (or call get_prototype) for the screens, flows, component states, design tokens and assets. Make it one self-contained \
        HTML file with its pictures beside it, that opens straight from the Finder: no server, no build step, nothing to \
        install. Keep every element tagged with its Bezzle layer id, and when the prototype changes, write the change back \
        into the design with Bezzle's tools.
        """
    }
}

private extension DesignTokens.Format {
    var title: String {
        switch self {
        case .css: "CSS"
        case .swiftui: "SwiftUI"
        case .json: "JSON"
        }
    }
}

private struct TokenChip: View {
    let title: String
    let copied: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if copied {
                    CheckMark(size: 9, color: Theme.pencil)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(verbatim: title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(copied ? Theme.pencil : Theme.ink)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(copied ? Theme.pencil.opacity(0.6) : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .animation(Theme.pop, value: copied)
    }
}

struct CodeGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            let w = s.width, h = s.height
            p.move(to: CGPoint(x: w * 0.36, y: h * 0.3))
            p.addLine(to: CGPoint(x: w * 0.16, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.36, y: h * 0.7))
            p.move(to: CGPoint(x: w * 0.64, y: h * 0.3))
            p.addLine(to: CGPoint(x: w * 0.84, y: h * 0.5))
            p.addLine(to: CGPoint(x: w * 0.64, y: h * 0.7))
            p.move(to: CGPoint(x: w * 0.55, y: h * 0.24))
            p.addLine(to: CGPoint(x: w * 0.45, y: h * 0.76))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - A layer picked

/// Where the picked layers go: every screen as a small picture to click, and back; what is said of
/// it, written by hand; and how it moves. Pointing at a screen shows the thread it would take.
private struct LinkCard: View {
    let store: DocumentStore

    var body: some View {
        let seen = store.seenDoc
        let ids = store.linkSources
        let flow = store.sharedFlow
        let mixed = ids.count > 1 && ids.map { seen.node($0)?.flow }.contains { $0 != ids.first.flatMap { seen.node($0)?.flow } }
        let summary: String = mixed ? String(localized: "Mixed")
            : flow?.goesBack == true ? String(localized: "Back")
            : flow?.to.flatMap { seen.node($0)?.name } ?? String(localized: "Nowhere")
        AspectCard(aspect: .flow, title: LocalizedStringResource("flow.card", defaultValue: "Goes To"), summary: summary,
                   remove: flow?.leads == true ? { store.unlinkFlow(ids) } : nil, removal: "Remove Link") {
            ThreadGlyph()
                .frame(width: 18, height: 11)
        } picks: {
            let home = ids.first.flatMap { seen.artboard(of: $0)?.id }
            // Where, what is said of it, and how: each its own part, with room between them.
            VStack(alignment: .leading, spacing: 18) {
                ScreenGrid(store: store, chosen: flow?.to, back: flow?.goesBack == true, except: home, offersBack: true) { to, back in
                    store.linkFlow(ids, to: to, back: back)
                }
                if flow?.leads == true {
                    NoteField(store: store, ids: ids, note: flow?.note ?? "")
                    MotionRow(store: store, ids: ids, motion: flow?.motion ?? .auto, way: way(of: ids.first, flow: flow, in: seen))
                }
            }
            .padding(.top, 2)
        } exact: {
            EmptyView()
        }
    }

    /// How the screen would come on, read from the canvas, for the automatic choice to say so.
    private func way(of id: UUID?, flow: FlowLink?, in seen: BezzleDocument) -> Prototype.Way? {
        guard let id, let to = flow?.to, let a = seen.artboard(of: id), let b = seen.node(to) else { return nil }
        return Prototype.way(from: a, to: b, motion: nil)
    }
}

/// Every screen to go to, as a small picture with its name; and the hook to go back.
private struct ScreenGrid: View {
    let store: DocumentStore
    let chosen: UUID?
    let back: Bool
    let except: UUID?
    let offersBack: Bool
    let pick: (UUID?, Bool) -> Void

    var body: some View {
        let screens = Prototype.screens(in: store.seenDoc).filter { $0.id != except }
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3), spacing: 14) {
            ForEach(screens, id: \.id) { screen in
                ScreenTile(store: store, board: screen, chosen: chosen == screen.id && !back) {
                    pick(chosen == screen.id && !back ? nil : screen.id, false)
                }
            }
            if offersBack {
                BackTile(chosen: back) { pick(nil, !back) }
            }
        }
        .onDisappear { store.flowPreview = nil }
    }
}

private struct ScreenTile: View {
    let store: DocumentStore
    let board: Node
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ScreenPicture(store: store, board: board, width: 52)
                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
                .padding(3)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Theme.pencil, lineWidth: chosen ? 2 : hovering ? 1 : 0)
                }
                .shadow(color: Theme.shadow.opacity(hovering ? 0.2 : 0.08), radius: hovering ? 6 : 2, y: hovering ? 3 : 1)
                .offset(y: hovering ? -2 : 0)
            Text(verbatim: board.name)
                .font(.system(size: 10.5, weight: chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? Theme.pencil : Theme.ink2)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { store.flowPreview = board.id } else if store.flowPreview == board.id { store.flowPreview = nil }
        }
        .onTapGesture(perform: action)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .animation(Theme.pop, value: chosen)
        .accessibilityLabel(Text(verbatim: board.name))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

private struct BackTile: View {
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .strokeBorder(chosen ? Theme.pencil : Theme.ink4, style: StrokeStyle(lineWidth: chosen ? 2 : 1, dash: chosen ? [] : [3, 2.5]))
                    .background(Circle().fill(chosen ? Theme.pencilWash : .clear))
                ThreadGlyph(back: true)
                    .frame(width: 20, height: 14)
                    .foregroundStyle(chosen || hovering ? Theme.pencil : Theme.ink2)
                    .rotationEffect(.degrees(hovering ? -12 : 0))
            }
            .frame(width: 42, height: 42)
            .padding(.vertical, 12)
            .scaleEffect(hovering ? 1.06 : 1)
            Text("Back")
                .font(.system(size: 10.5, weight: chosen ? .semibold : .regular))
                .foregroundStyle(chosen ? Theme.pencil : Theme.ink2)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: hovering)
        .help("Goes back to the screen it was come to from")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// What is said of where it goes, in the designer's hand, as it is written on its thread.
private struct NoteField: View {
    let store: DocumentStore
    let ids: [UUID]
    let note: String
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil.line")
                .font(.system(size: 11))
                .foregroundStyle(Theme.pencil.opacity(0.8))
            TextField(String(localized: "Why, or when: after signing in"), text: $draft)
                .textFieldStyle(.plain)
                .font(.custom("Bradley Hand", size: 16))
                .foregroundStyle(Theme.pencil)
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, now in if !now { commit() } }
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.pencilWash.opacity(focused ? 1 : 0.6)))
        .overlay(alignment: .bottom) {
            // A ruled line to write on.
            Rectangle().fill(Theme.pencil.opacity(focused ? 0.5 : 0.2)).frame(height: 1).padding(.horizontal, 10).padding(.bottom, 6)
        }
        .onAppear { draft = note }
        .onChange(of: note) { _, now in if !focused { draft = now } }
        .onChange(of: ids) { draft = note }
    }

    private func commit() {
        guard draft != note else { return }
        store.setNote(draft, for: ids)
    }
}

/// How the next screen comes on: read from the canvas, or one of three plain ways. Each choice
/// shows its motion as it is pointed at.
private struct MotionRow: View {
    let store: DocumentStore
    let ids: [UUID]
    let motion: FlowMotion
    let way: Prototype.Way?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ForEach(FlowMotion.allCases, id: \.self) { m in
                    MotionChip(motion: m, way: m == .auto ? way : nil, chosen: motion == m) {
                        store.setMotion(m, for: ids)
                    }
                }
            }
            if motion == .auto, let way {
                Text(verbatim: Self.reading(way))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
        .animation(Theme.quick, value: motion)
    }

    /// What the canvas says of how the screen comes on, in a few words.
    static func reading(_ way: Prototype.Way) -> String {
        switch way {
        case .push(let from, let morph):
            if morph { return String(localized: "What both screens share moves; the rest changes round it.") }
            if from.dx > 0 { return String(localized: "Slides in from the right, as it lies on the canvas.") }
            if from.dx < 0 { return String(localized: "Slides in from the left, as it lies on the canvas.") }
            if from.dy > 0 { return String(localized: "Rises from below, as it lies on the canvas.") }
            return String(localized: "Comes down from above, as it lies on the canvas.")
        case .sheet: return String(localized: "Smaller than the screen it opens on: rises over it as a sheet.")
        case .dissolve: return String(localized: "Fades in.")
        case .instant: return String(localized: "Comes on at once.")
        }
    }
}

private struct MotionChip: View {
    let motion: FlowMotion
    let way: Prototype.Way?
    let chosen: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        // The motion itself is the label: it plays while pointed at, and its name is in the tip.
        MotionGlyph(motion: motion, way: way, playing: hovering)
            .frame(width: 30, height: 24)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(chosen ? Theme.pencilWash : Theme.ink.opacity(hovering ? 0.05 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(chosen ? Theme.pencil.opacity(0.7) : Theme.hairline, lineWidth: chosen ? 1.5 : 1))
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help(Text(verbatim: motion.title))
            .scaleEffect(hovering ? 1.04 : 1)
            .animation(Theme.quick, value: hovering)
        .accessibilityLabel(Text(verbatim: motion.title))
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// Two screens, the second coming on the way the motion brings it: played over and over while
/// pointed at, resting part of the way through otherwise.
private struct MotionGlyph: View {
    let motion: FlowMotion
    let way: Prototype.Way?
    let playing: Bool

    var body: some View {
        TimelineView(.animation(paused: !playing)) { timeline in
            Canvas { ctx, s in
                // At rest, each a moment of its own motion, so the four read apart: the next screen
                // half in, half faded in, not yet there; played over and over while pointed at.
                let rest: Double = switch motion {
                case .slide: 0.32
                case .dissolve: 0.3
                case .instant: 0
                case .auto: 0.4
                }
                let t = playing ? timeline.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.2 : rest
                let u = CGFloat(min(max(t, 0), 1))
                let e = 1 - pow(1 - u, 3)
                let frame = CGRect(x: s.width * 0.18, y: 1, width: s.width * 0.64, height: s.height - 2)
                ctx.clip(to: Path(roundedRect: frame, cornerRadius: 3))
                ctx.fill(Path(frame), with: .color(Theme.ink4))
                let next = Theme.pencil
                switch motion {
                case .instant:
                    ctx.fill(Path(frame), with: .color(u > 0.5 ? next : Theme.ink4))
                case .dissolve:
                    ctx.fill(Path(frame), with: .color(next.opacity(Double(e))))
                case .slide:
                    ctx.fill(Path(frame.offsetBy(dx: frame.width * (1 - e), dy: 0)), with: .color(next))
                case .auto:
                    if case .sheet = way {
                        var r = frame
                        r.origin.y += r.height * 0.35 + r.height * 0.65 * (1 - e)
                        ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(next))
                    } else if case .push(_, true) = way {
                        // What they share grows to its new place.
                        let r = CGRect(x: frame.minX + 3 + 6 * e, y: frame.minY + 3 + 4 * e, width: frame.width * (0.4 + 0.3 * e), height: frame.height * (0.3 + 0.25 * e))
                        ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(next))
                    } else {
                        var dx: CGFloat = 1, dy: CGFloat = 0
                        if case .push(let from, false) = way { dx = from.dx; dy = from.dy }
                        ctx.fill(Path(frame.offsetBy(dx: -frame.width * 0.28 * e * dx, dy: -frame.height * 0.28 * e * dy)), with: .color(Theme.ink3.opacity(0.6)))
                        ctx.fill(Path(frame.offsetBy(dx: frame.width * (1 - e) * dx, dy: frame.height * (1 - e) * dy)), with: .color(next))
                    }
                }
            }
        }
    }
}

// MARK: - A screen picked

/// A screen's own part in the prototype: whether it starts here, and whether it goes on by itself
/// after a while, and where to: the card's dial is how long it waits.
private struct ScreenCard: View {
    let store: DocumentStore
    let board: Node

    var body: some View {
        let seen = store.seenDoc
        let after = board.flow?.after ?? 0
        let ins = Prototype.links(in: seen).filter { $0.flow.to == board.id && $0.board != board.id }.count
        let summary: String = after > 0 ? String(localized: "On after \(String(format: "%.1f", after)) s")
            : board.starts == true || Prototype.start(of: seen)?.id == board.id ? String(localized: "Starts here")
            : ins == 1 ? String(localized: "1 way in") : String(localized: "\(ins) ways in")
        AspectCard(aspect: .screen, title: LocalizedStringResource("screen.card", defaultValue: "Screen"), summary: summary,
                   dial: Dial(value: after, range: 0...10, stops: [0, 0.5, 1, 1.5, 2, 3, 5], step: 0.5, action: "Go On by Itself") { v in
                       store.setGoesOn(after: v < 0.05 ? nil : v, board: board.id)
                   }) {
            Image(systemName: "rectangle.portrait")
                .font(.system(size: 13))
        } picks: {
            VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                FlagGlyph().frame(width: 13, height: 11)
                Text("Starts here")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink)
                Spacer()
                CheckBox(isOn: Binding(get: { board.starts == true }, set: { store.setStart($0 ? board.id : nil) }))
            }
            .frame(height: Theme.controlHeight)
            if after > 0 {
                Text("Then goes on by itself to")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                ScreenGrid(store: store, chosen: board.flow?.to, back: board.flow?.goesBack == true, except: board.id, offersBack: false) { to, _ in
                    store.linkFlow([board.id], to: to)
                }
            }
            CardButton(title: "Play from Here", symbol: "play.fill", height: 28) { store.play(from: board.id) }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        } exact: {
            EmptyView()
        }
    }
}

/// Under a picked screen: how to make it go on by itself, said once, quietly.
private struct StartHint: View {
    let store: DocumentStore
    let board: Node

    var body: some View {
        if board.flow?.after == nil {
            Text("Drag the card sideways and the screen goes on by itself, as a splash screen does.")
                .prose(11.5)
                .foregroundStyle(Theme.ink3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 4)
        }
    }
}

// MARK: - A copy picked

/// What a copy of a component shows as it is used: each variant whose name says a state plays it
/// in the prototype (Hover while pointed at, Pressed while pressed, Selected turned on by a tap);
/// another can be made a state by its name, and a missing state added as a new variant.
private struct StatesCard: View {
    let store: DocumentStore
    let copy: Node
    let master: Node

    var body: some View {
        let variants = Components.variants(of: master)
        let states = Components.states(of: master)
        let named = variants.compactMap { v in Components.state(of: v, in: master) }
        let summary = named.isEmpty ? String(localized: "None") : named.map(\.title).joined(separator: ", ")
        AspectCard(aspect: .states, title: LocalizedStringResource("states.card", defaultValue: "States"), summary: summary) {
            StatesGlyph()
                .frame(width: 18, height: 14)
        } picks: {
            VStack(alignment: .leading, spacing: 14) {
                VStack(spacing: 2) {
                    ForEach(Array(variants.enumerated()), id: \.offset) { _, v in
                        StateRow(store: store, master: master, variant: v)
                    }
                }
                let missing = [VariantState.hover, .pressed, .selected, .disabled, .loading].filter { states[$0] == nil }
                if !missing.isEmpty, !store.isReadOnly {
                    FlowingChips(states: missing) { state in addState(state) }
                }
            }
        } exact: {
            EmptyView()
        }
    }

    /// A new variant, as the copy looks now, named for the state, and shown in the copy to change.
    private func addState(_ state: VariantState) {
        let before = Set(master.master?.variants ?? [])
        store.addVariant(from: copy.id)
        if let made = store.doc.master(master.id)?.master?.variants.first(where: { !before.contains($0) }) {
            store.renameVariant(made, of: master.id, to: state.title)
        }
    }
}

private struct StateRow: View {
    let store: DocumentStore
    let master: Node
    let variant: Int?

    var body: some View {
        let name = Components.name(of: variant, in: master)
        let state = Components.state(of: variant, in: master)
        HStack(spacing: 8) {
            Circle()
                .fill(state != nil ? Theme.pencil : Theme.ink4)
                .frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: name)
                    .font(.system(size: 12, weight: state != nil ? .medium : .regular))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if let state {
                    Text(verbatim: state.does)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                } else if variant == nil {
                    Text("As it rests")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink3)
                }
            }
            Spacer(minLength: 4)
            if variant != nil, state == nil, !store.isReadOnly {
                MenuButton(id: "state.\(variant ?? 0)", title: "Use As", width: 200) {
                    VariantState.allCases.map { s in
                        .item(.verbatim(s.title)) { store.renameVariant(variant, of: master.id, to: s.title) }
                    }
                }
            }
        }
        .frame(minHeight: 34)
    }
}

/// Dashed chips for the states the component has no variant for, each adding one.
private struct FlowingChips: View {
    let states: [VariantState]
    let add: (VariantState) -> Void

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(states, id: \.self) { s in
                AddStateChip(state: s) { add(s) }
            }
        }
    }
}

private struct AddStateChip: View {
    let state: VariantState
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "plus")
                .font(.system(size: 9, weight: .bold))
            Text(verbatim: state.title)
                .font(.system(size: 11.5, weight: .medium))
                .lineLimit(1)
        }
        .foregroundStyle(hovering ? Theme.pencil : Theme.ink2)
        .padding(.horizontal, 8)
        .frame(height: 24)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(hovering ? Theme.pencilWash : .clear))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(hovering ? Theme.pencil : Theme.ink4, style: StrokeStyle(lineWidth: 1, dash: [3, 2.5])))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help(Text(verbatim: state.does))
        .animation(Theme.quick, value: hovering)
    }
}

private struct StatesGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let back = Path(roundedRect: CGRect(x: s.width * 0.3, y: 0.5, width: s.width * 0.66, height: s.height * 0.55), cornerRadius: s.height * 0.27)
            let front = Path(roundedRect: CGRect(x: s.width * 0.04, y: s.height * 0.4, width: s.width * 0.66, height: s.height * 0.55), cornerRadius: s.height * 0.27)
            ctx.stroke(back, with: .foreground, style: style)
            ctx.fill(front, with: .color(Theme.card))
            ctx.stroke(front, with: .foreground, style: style)
        }
    }
}

// MARK: - Writing on a thread

/// A note being written on a thread, on the canvas where the thread's middle is, in the hand the
/// note will be drawn in.
struct FlowNoteField: View {
    let store: DocumentStore
    let source: UUID
    let at: CGPoint
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(String(localized: "Why, or when"), text: $draft)
            .textFieldStyle(.plain)
            .font(.custom("Bradley Hand", size: 16))
            .foregroundStyle(Color(nsColor: FlowInk.note))
            .multilineTextAlignment(.center)
            .focused($focused)
            .frame(width: 220)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Color(nsColor: FlowInk.notePlate)))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color(nsColor: FlowInk.thread), lineWidth: 1.2))
            .shadow(color: Color(nsColor: FlowInk.paperShadow), radius: 6, y: 2)
            .position(at)
            .onAppear {
                draft = store.doc.node(source)?.flow?.note ?? ""
                focused = true
            }
            .onSubmit { commit() }
            .onExitCommand { store.writingNote = nil }
            .onChange(of: focused) { _, now in if !now { commit() } }
            .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    private func commit() {
        guard store.writingNote?.source == source else { return }
        store.writingNote = nil
        store.setNote(draft, for: [source])
        if let canvas = store.canvas { canvas.window?.makeFirstResponder(canvas) }
    }
}
