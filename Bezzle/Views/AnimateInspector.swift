import SwiftUI
import AppKit

/// The panel on the right while the design is animated. With nothing picked: moves for the whole
/// artboard, and the film itself. With layers picked: moves for them, their pose at the playhead
/// to the number, and the camera sent to look at them. With the camera picked: where it looks and
/// how. A bead beside every number is its key at the playhead: filled where there is one.
struct AnimateInspector: View {
    let store: DocumentStore

    var body: some View {
        let board = store.filmBoard
        let layers = store.posedLayers
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let board {
                    if store.film.camera {
                        CameraCard(store: store, board: board)
                            .transition(.card)
                    } else {
                        MovesCard(store: store, board: board, layers: layers)
                        if !layers.isEmpty {
                            PoseCard(store: store, board: board, layers: layers)
                                .transition(.card)
                            FlyCard(store: store, layers: layers)
                                .transition(.card)
                        }
                    }
                    FilmCard(store: store, board: board)
                }
            }
            .padding(.horizontal, Inspector.gutter)
            .padding(.top, 14)
            .padding(.bottom, 28)
            .animation(Theme.spring, value: store.film.camera)
            .animation(Theme.spring, value: layers.isEmpty)
        }
        .scrollIndicators(.never)
        .edgeFade(length: 20)
    }
}

/// A card of this panel: what it is and what it comes to on one line, and its controls under it.
private struct PanelCard<Glyph: View, Content: View>: View {
    let title: LocalizedStringResource
    let summary: String
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                glyph
                    .foregroundStyle(Theme.ink2)
                    .frame(width: 22, height: 22)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 6)
                Text(verbatim: summary)
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .contentTransition(.numericText())
                    .animation(Theme.quick, value: summary)
            }
            .padding(.leading, 9)
            .padding(.trailing, 11)
            .frame(height: 40)
            VStack(alignment: .leading, spacing: 8) {
                content
            }
            .padding(.horizontal, Inspector.cardInset)
            .padding(.bottom, Inspector.cardInset)
        }
        .card(radius: 12)
    }
}

/// Seconds as they are written here.
private func seconds(_ t: Double) -> String {
    t.formatted(.number.precision(.fractionLength(0...2))) + " s"
}

// MARK: - Moves

/// Moves given in one go: each chip plays its move in miniature while pointed at, and a click
/// gives it to what is picked at the playhead, one layer after another, and shows it.
private struct MovesCard: View {
    let store: DocumentStore
    let board: Node
    let layers: [UUID]

    var body: some View {
        let count = layers.isEmpty ? board.children.filter { !$0.hidden && !$0.locked }.count : layers.count
        let summary = layers.isEmpty ? String(localized: "Everything")
            : layers.count == 1 ? board.descendant(layers[0])?.name ?? "" : String(localized: "\(layers.count) layers")
        PanelCard(title: "Moves", summary: summary) {
            CascadeGlyph()
        } content: {
            SegmentedWell(selection: Binding(get: { store.film.going }, set: { store.film.going = $0 }),
                          options: [(false, "Comes On"), (true, "Goes")])
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                ForEach(MotionMove.allCases, id: \.self) { move in
                    MoveChip(move: move, going: store.film.going) { store.applyMove(move) }
                }
            }
            .padding(.vertical, 2)
            // Always there, so the card keeps its size: only readier when there are several.
            HStack(spacing: 8) {
                Text("One After Another")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Spacer(minLength: 4)
                NumberField(label: .verbatim(""), value: store.film.apart, unit: "s", range: 0...1, step: 0.01, scrub: 0.004, decimals: 2,
                            action: "One After Another") { store.film.apart = $0 }
                    .frame(width: 84)
            }
            .opacity(count > 1 ? 1 : 0.35)
            .allowsHitTesting(count > 1)
            .animation(Theme.quick, value: count > 1)
        }
    }
}

private struct MoveChip: View {
    let move: MotionMove
    let going: Bool
    let action: () -> Void
    @State private var hovering = false
    @State private var began = Date.now

    var body: some View {
        VStack(spacing: 3) {
            MoveGlyph(move: move, going: going, playing: hovering, began: began)
                .frame(width: 36, height: 24)
            Text(verbatim: move.title)
                .font(.system(size: 10.5, weight: hovering ? .medium : .regular))
                .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.07 : 0.035)))
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { began = .now }
            hovering = inside
        }
        .onTapGesture(perform: action)
        .scaleEffect(hovering ? 1.04 : 1)
        .animation(Theme.quick, value: hovering)
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: move.title))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// A small card making a move over the place it belongs: played over and over while pointed at,
/// and part of the way there otherwise, so each reads apart from the others at rest.
private struct MoveGlyph: View {
    let move: MotionMove
    let going: Bool
    let playing: Bool
    let began: Date

    var body: some View {
        TimelineView(.animation(paused: !playing)) { timeline in
            Canvas { ctx, s in
                // How far away it is, 1 to 0 as it comes on: a spring goes a little past home.
                var away = 0.46
                if playing {
                    let u = min(max(timeline.date.timeIntervalSince(began).truncatingRemainder(dividingBy: 1.5) / move.time / 1.5, 0), 1)
                    away = going ? MotionEase.progress(.easeIn, u) : 1 - (move == .fade || move == .focus ? MotionEase.progress(.easeOut, u) : move.arriving.progress(u))
                }
                let home = CGRect(x: s.width / 2 - 9, y: s.height / 2 - 6.5, width: 18, height: 13)
                ctx.stroke(Path(roundedRect: home.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 2.5), with: .color(Theme.ink.opacity(0.2)),
                           style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                var r = home
                var opacity = 1.0
                let a = CGFloat(away), faded = 1 - min(max(away, 0), 1)
                switch move {
                case .fade:
                    opacity = faded
                case .rise:
                    r = r.offsetBy(dx: 0, dy: 8 * a)
                    opacity = faded
                case .drop:
                    r = r.offsetBy(dx: 0, dy: -9 * a)
                    opacity = faded
                case .slide:
                    r = r.offsetBy(dx: -26 * a, dy: 0)
                case .pop:
                    r = r.insetBy(dx: r.width * 0.2 * a, dy: r.height * 0.2 * a)
                    opacity = faded
                case .zoom:
                    r = r.insetBy(dx: -r.width * 0.2 * a, dy: -r.height * 0.2 * a)
                    opacity = faded
                case .flip:
                    // Tipped back, it is seen foreshortened.
                    let seen = max(cos(80 * .pi / 180 * min(abs(a), 1)), 0.08)
                    r = r.insetBy(dx: r.width * 0.06 * a, dy: r.height * (1 - seen) / 2)
                    opacity = faded
                case .focus:
                    ctx.addFilter(.blur(radius: 3.2 * max(a, 0)))
                    opacity = 1 - 0.75 * (1 - faded)
                }
                ctx.clip(to: Path(CGRect(origin: .zero, size: s)))
                ctx.fill(Path(roundedRect: r, cornerRadius: 2.5), with: .color(Theme.ink.opacity(0.82 * opacity)))
            }
        }
    }
}

/// Three strokes set in one after another, for moves.
private struct CascadeGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let style = StrokeStyle(lineWidth: 1.5, lineCap: .round)
            for i in 0..<3 {
                let y = s.height * (0.3 + 0.2 * CGFloat(i))
                var p = Path()
                p.move(to: CGPoint(x: s.width * (0.2 + 0.14 * CGFloat(i)), y: y))
                p.addLine(to: CGPoint(x: s.width * (0.56 + 0.14 * CGFloat(i)), y: y))
                ctx.stroke(p, with: .foreground, style: style)
            }
        }
        .frame(width: 18, height: 18)
    }
}

// MARK: - A property's key

/// A property's key at the playhead: faint while the property never changes, a ring while it
/// does but has no key here, and filled where it has one. A click sets a key here, holding what
/// it is; on a key, it takes that away.
private struct KeyBead: View {
    let store: DocumentStore
    let property: MotionProperty
    @State private var hovering = false

    var body: some View {
        let state = store.keyState(property)
        ZStack {
            Circle().fill(Theme.ink.opacity(hovering ? 0.07 : 0))
            Circle()
                .fill(state == .here ? Theme.pencil : Theme.card)
                .overlay {
                    Circle().strokeBorder(state == .here ? Theme.pencil : state == .between ? Theme.ink2 : Theme.ink4, lineWidth: 1.4)
                }
                .frame(width: 9, height: 9)
                .scaleEffect(state == .here ? 1.1 : 1)
        }
        .frame(width: 20, height: 20)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { store.toggleKey(property) }
        .help(state == .here ? Text("A key here. Click to take it away.") : Text("Set a key here"))
        .animation(Theme.pop, value: state)
        .animation(Theme.quick, value: hovering)
        .accessibilityLabel(Text(verbatim: property.title))
        .accessibilityAddTraits(state == .here ? [.isButton, .isSelected] : .isButton)
    }
}

/// One property on a line: its key, its name, and its numbers.
private struct PropertyRow<Fields: View>: View {
    let store: DocumentStore
    let property: MotionProperty
    @ViewBuilder let fields: Fields

    var body: some View {
        HStack(spacing: 4) {
            KeyBead(store: store, property: property)
            Text(verbatim: property.title)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            fields
        }
        .padding(.leading, -5)
    }
}

// MARK: - A pose

/// The picked layers' pose at the playhead, to the number: each a change from the design, so
/// nothing here is where a layer is, only how far it is from where it belongs.
private struct PoseCard: View {
    let store: DocumentStore
    let board: Node
    let layers: [UUID]

    var body: some View {
        PanelCard(title: "Pose", summary: seconds(store.filmTime)) {
            PoseGlyph()
        } content: {
            PropertyRow(store: store, property: .move) {
                field(.move, 0, label: "X", width: 68)
                field(.move, 1, label: "Y", width: 68)
            }
            PropertyRow(store: store, property: .scale) {
                field(.scale, 0, unit: "%", range: 0.1...10_000, times: 100, decimals: 0)
            }
            PropertyRow(store: store, property: .turn) {
                field(.turn, 0, unit: "°", range: -3600...3600)
            }
            PropertyRow(store: store, property: .fade) {
                field(.fade, 0, unit: "%", range: 0...100, times: 100, decimals: 0)
            }
            PropertyRow(store: store, property: .blur) {
                field(.blur, 0, range: 0...200, scrub: 0.25)
            }
            Hairline()
                .padding(.vertical, 2)
            PropertyRow(store: store, property: .lift) {
                field(.lift, 0, range: -4000...4000)
            }
            PropertyRow(store: store, property: .tilt) {
                field(.tilt, 0, unit: "°", range: -360...360)
            }
            PropertyRow(store: store, property: .swing) {
                field(.swing, 0, unit: "°", range: -360...360)
            }
        }
    }

    /// One number of a property: what the layers share, or a dash where they differ.
    private func field(_ property: MotionProperty, _ index: Int, label: String = "", unit: String = "", range: ClosedRange<Double> = -100_000...100_000,
                       times: Double = 1, scrub: Double = 1, decimals: Int = 1, width: CGFloat = 84) -> some View {
        NumberField(label: .verbatim(label), value: store.sharedValue(property, index, of: layers).map { $0 * times }, unit: unit, range: range,
                    scrub: scrub, decimals: decimals, action: property.action) { shown in
            store.pose(property, number: index, to: shown / times, of: layers)
        }
        .frame(width: width)
    }
}

/// A layer away from where it belongs: its place, and itself moved off it.
private struct PoseGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let home = CGRect(x: s.width * 0.14, y: s.height * 0.36, width: s.width * 0.5, height: s.height * 0.44)
            ctx.stroke(Path(roundedRect: home, cornerRadius: 2), with: .foreground, style: StrokeStyle(lineWidth: 1.1, dash: [1.8, 2]))
            let away = home.offsetBy(dx: s.width * 0.24, dy: -s.height * 0.2)
            ctx.fill(Path(roundedRect: away, cornerRadius: 2), with: .color(Theme.card))
            ctx.stroke(Path(roundedRect: away, cornerRadius: 2), with: .foreground, style: StrokeStyle(lineWidth: 1.4))
        }
        .frame(width: 18, height: 18)
    }
}

/// Sends the camera to the picked layers: a key at the playhead that looks at them, as close as
/// shows them whole. Pose after pose of it, the camera flies from one to the next.
private struct FlyCard: View {
    let store: DocumentStore
    let layers: [UUID]
    @State private var hovering = false

    var body: some View {
        Button { store.flyCamera(to: layers) } label: {
            HStack(spacing: 8) {
                CameraGlyph()
                    .foregroundStyle(hovering ? Theme.pencil : Theme.ink2)
                    .frame(width: 22, height: 22)
                Text("Fly the Camera Here")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(hovering ? Theme.pencil : Theme.ink3)
                    .offset(x: hovering ? 1.5 : 0, y: hovering ? -1.5 : 0)
            }
            .padding(.leading, 9)
            .padding(.trailing, 12)
            .frame(height: 40)
            .card(radius: 12, lifted: hovering)
            .offset(y: hovering ? -1 : 0)
            .contentShape(Rectangle())
        }
        .buttonStyle(Pressable())
        .onHover { hovering = $0 }
        .animation(Theme.quick, value: hovering)
        .help("The camera looks at what is picked from the playhead on, and flies there from where it was before")
    }
}

// MARK: - The camera

/// The camera at the playhead: the artboard as it sees it, to tip and swing by hand, and its
/// numbers under that.
private struct CameraCard: View {
    let store: DocumentStore
    let board: Node

    var body: some View {
        let camera = board.camera(at: store.filmTime)
        PanelCard(title: LocalizedStringResource("animate.camera", defaultValue: "Camera"), summary: "×" + camera.zoom.formatted(.number.precision(.fractionLength(0...2)))) {
            CameraGlyph()
        } content: {
            CameraPad(store: store, board: board, camera: camera)
            PropertyRow(store: store, property: .cameraZoom) {
                field(.cameraZoom, 0, unit: "×", range: 0.1...16, scrub: 0.01, decimals: 2)
            }
            PropertyRow(store: store, property: .cameraMove) {
                field(.cameraMove, 0, label: "X", width: 68)
                field(.cameraMove, 1, label: "Y", width: 68)
            }
            PropertyRow(store: store, property: .cameraRoll) {
                field(.cameraRoll, 0, unit: "°", range: -3600...3600)
            }
            PropertyRow(store: store, property: .cameraTilt) {
                field(.cameraTilt, 0, unit: "°", range: -80...80)
            }
            PropertyRow(store: store, property: .cameraSwing) {
                field(.cameraSwing, 0, unit: "°", range: -80...80)
            }
            HStack {
                Spacer(minLength: 0)
                ChipButton(title: "See the Whole Artboard") { store.restCamera() }
                    .opacity(camera.isRest ? 0.4 : 1)
                    .allowsHitTesting(!camera.isRest)
                    .animation(Theme.quick, value: camera.isRest)
            }
            .padding(.top, 2)
        }
    }

    private func field(_ property: MotionProperty, _ index: Int, label: String = "", unit: String = "", range: ClosedRange<Double> = -100_000...100_000,
                       scrub: Double = 1, decimals: Int = 1, width: CGFloat = 84) -> some View {
        NumberField(label: .verbatim(label), value: board.value(of: property, at: store.filmTime)[index], unit: unit, range: range,
                    step: decimals >= 2 ? 0.1 : 1, scrub: scrub, decimals: decimals, action: property.action) { v in
            store.poseCamera(property, number: index, to: v)
        }
        .frame(width: width)
    }
}

/// The artboard as the camera sees it, small, in the frame the film has: drag it to tip the
/// scene back and swing it round under the camera, as a card turned in the hand. A double click
/// looks straight down again.
private struct CameraPad: View {
    let store: DocumentStore
    let board: Node
    let camera: FilmCamera
    @State private var from: FilmCamera?

    var body: some View {
        Canvas { ctx, s in
            let size = board.frame.size
            guard size.width > 0, size.height > 0 else { return }
            // The film's frame, fitted in the pad with room round it.
            let fit = min((s.width - 36) / size.width, (s.height - 26) / size.height)
            let frame = CGRect(x: (s.width - size.width * fit) / 2, y: (s.height - size.height * fit) / 2, width: size.width * fit, height: size.height * fit)
            let map = FilmLens.ground(camera, size: size)
            func seen(_ x: CGFloat, _ y: CGFloat) -> CGPoint? {
                let at = CGPoint(x: x, y: y)
                guard map.depth(at: at) > 1e-3 else { return nil }
                let p = map(at)
                return CGPoint(x: frame.minX + p.x * fit, y: frame.minY + p.y * fit)
            }
            ctx.clip(to: Path(roundedRect: CGRect(origin: .zero, size: s), cornerRadius: 9))
            // The artboard's sheet, ruled in thirds so its lie reads.
            let corners = [seen(0, 0), seen(size.width, 0), seen(size.width, size.height), seen(0, size.height)].compactMap { $0 }
            if corners.count == 4 {
                var sheet = Path()
                sheet.addLines(corners)
                sheet.closeSubpath()
                ctx.fill(sheet, with: .color(Theme.card))
                var rules = Path()
                for i in 1..<3 {
                    let k = CGFloat(i) / 3
                    if let a = seen(size.width * k, 0), let b = seen(size.width * k, size.height) { rules.move(to: a); rules.addLine(to: b) }
                    if let a = seen(0, size.height * k), let b = seen(size.width, size.height * k) { rules.move(to: a); rules.addLine(to: b) }
                }
                ctx.stroke(rules, with: .color(Theme.ink.opacity(0.12)), lineWidth: 0.75)
                ctx.stroke(sheet, with: .color(Theme.ink.opacity(0.75)), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
            }
            // What the film shows of it.
            ctx.stroke(Path(roundedRect: frame, cornerRadius: 2), with: .color(Theme.pencil), style: StrokeStyle(lineWidth: 1.25))
            var cross = Path()
            cross.move(to: CGPoint(x: frame.midX - 3.5, y: frame.midY)); cross.addLine(to: CGPoint(x: frame.midX + 3.5, y: frame.midY))
            cross.move(to: CGPoint(x: frame.midX, y: frame.midY - 3.5)); cross.addLine(to: CGPoint(x: frame.midX, y: frame.midY + 3.5))
            ctx.stroke(cross, with: .color(Theme.pencil), lineWidth: 1)
        }
        .frame(height: 118)
        .well(radius: 9)
        .contentShape(Rectangle())
        .pointerStyle(from == nil ? .grabIdle : .grabActive)
        .gesture(DragGesture(minimumDistance: 2)
            .onChanged { g in
                if from == nil {
                    from = camera
                    store.beginGesture()
                }
                guard let from else { return }
                store.turnScene(from: from, by: g.translation, stepped: NSEvent.modifierFlags.contains(.shift))
            }
            .onEnded { _ in
                from = nil
                store.endGesture("Turn the Scene")
            })
        .simultaneousGesture(TapGesture(count: 2).onEnded { store.straightenScene() })
        .help("Drag to tip the scene back and swing it round under the camera. Double click to look straight down.")
        .accessibilityElement()
        .accessibilityLabel(Text(LocalizedStringResource("animate.camera", defaultValue: "Camera")))
        .accessibilityValue(Text(verbatim: "\(Int(camera.tilt.rounded()))°, \(Int(camera.swing.rounded()))°"))
    }
}

// MARK: - The film

/// The film itself: how long it runs and whether it goes round, what shows past the artboard's
/// edges, and the way out, as a movie.
private struct FilmCard: View {
    let store: DocumentStore
    let board: Node
    @AppStorage("film.movie.scale") private var scale = 2
    @AppStorage("film.movie.fps") private var fps = 60

    var body: some View {
        let fixed = board.film?.length != nil
        let exporting = store.film.exporting
        PanelCard(title: "Film", summary: seconds(board.filmLength)) {
            ReelGlyph()
        } content: {
            HStack(spacing: 6) {
                Text("Length")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                Spacer(minLength: 4)
                // Only once the length was set: back to as long as the keys.
                TextButton(title: "Follow the Keys") {
                    withAnimation(Theme.spring) { store.setFilm("Film Length") { $0.length = nil } }
                }
                .opacity(fixed ? 1 : 0)
                .allowsHitTesting(fixed)
                .animation(Theme.quick, value: fixed)
                NumberField(label: .verbatim(""), value: board.filmLength, unit: "s", range: 0.25...600, step: 0.25, scrub: 0.02, decimals: 2,
                            action: "Film Length") { v in
                    store.setFilm("Film Length") { $0.length = MotionTiming.time(v) }
                }
                .frame(width: 84)
            }
            SegmentedWell(selection: Binding(get: { board.film?.once == true }, set: { once in
                store.setFilm(once ? "Play Once" : "Play Round and Round") { $0.once = once ? true : nil }
            }), options: [(false, "Round and Round"), (true, "Once")])
            HStack(spacing: 6) {
                Text("Backdrop")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .help("What shows past the artboard's edges when the camera sees them")
                Spacer(minLength: 4)
                ColorField(id: "film.backdrop", color: board.filmBackdrop, action: "Backdrop") { color in
                    store.setFilm("Backdrop") { $0.backdrop = color }
                }
                .frame(width: 132)
            }
            Hairline()
                .padding(.vertical, 2)
            HStack(spacing: 8) {
                SegmentedWell(selection: $scale, options: [(1, "1×"), (2, "2×"), (3, "3×")])
                SegmentedWell(selection: $fps, options: [(30, "30"), (60, "60")])
                    .frame(width: 84)
                    .help("Pictures a second")
            }
            .disabled(exporting != nil)
            let size = FilmExport.size(of: board, settings: FilmExport.Settings(scale: CGFloat(scale), fps: fps))
            Text("\(String(Int(size.width))) × \(String(Int(size.height))) pixels, \(fps) a second")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.ink3)
                .frame(maxWidth: .infinity, alignment: .center)
            PrimaryButton(title: exporting == nil ? "Save as Movie…" : "Stop Saving", progress: exporting) {
                if exporting == nil { store.saveFilm(scale: CGFloat(scale), fps: fps) } else { store.stopSavingFilm() }
            }
        }
    }
}

/// A frame of film, for the film's own card.
private struct ReelGlyph: View {
    var body: some View {
        Canvas { ctx, s in
            let style = StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round)
            let frame = CGRect(x: s.width * 0.12, y: s.height * 0.24, width: s.width * 0.76, height: s.height * 0.52)
            ctx.stroke(Path(roundedRect: frame, cornerRadius: 2.5), with: .foreground, style: style)
            var play = Path()
            play.move(to: CGPoint(x: s.width * 0.42, y: s.height * 0.38))
            play.addLine(to: CGPoint(x: s.width * 0.62, y: s.height * 0.5))
            play.addLine(to: CGPoint(x: s.width * 0.42, y: s.height * 0.62))
            play.closeSubpath()
            ctx.fill(play, with: .foreground)
        }
        .frame(width: 18, height: 18)
    }
}
