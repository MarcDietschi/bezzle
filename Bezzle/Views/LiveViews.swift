import SwiftUI

/// The others in a live room who are somewhere this canvas does not show: each sits on the rim of
/// the canvas where they are from here, a token in their pencil pointing their way, sliding along
/// the rim as either of you moves. Clicking one flies there and goes along with them.
struct LiveCompass: View {
    let store: DocumentStore
    let room: LiveRoom

    var body: some View {
        GeometryReader { geo in
            let _ = room.beat
            ZStack(alignment: .topLeading) {
                ForEach(room.people) { person in
                    if let spot = spot(of: person, in: geo.size) {
                        CompassToken(person: person, zone: room.zone(of: person), angle: spot.angle, wink: room.wink(of: person.id, at: CACurrentMediaTime())) {
                            if let wink = room.wink(of: person.id, at: CACurrentMediaTime()) { room.go(toWink: wink) } else { room.go(to: person.id) }
                        }
                        .position(spot.point)
                        .animation(.spring(response: 0.45, dampingFraction: 0.82), value: spot.point)
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .animation(Theme.pop, value: room.people.map(\.id))
        }
    }

    /// Where on the rim someone sits: on the line from the middle of the canvas to their pointer,
    /// or to the middle of what they look at. Nowhere while that is in sight, or they are followed.
    private func spot(of person: LiveRoom.Person, in size: CGSize) -> (point: CGPoint, angle: Angle)? {
        guard room.following != person.id, let p = room.presence[person.id] else { return nil }
        let target = store.viewport.toView(p.pointer ?? CGPoint(x: p.view.midX, y: p.view.midY))
        let bounds = CGRect(origin: .zero, size: size)
        guard !bounds.insetBy(dx: 4, dy: 4).contains(target) else { return nil }
        // Clear of the rulers along the top and left.
        let inner = CGRect(x: 40, y: 42, width: max(size.width - 70, 1), height: max(size.height - 72, 1))
        let c = CGPoint(x: inner.midX, y: inner.midY)
        let d = CGPoint(x: target.x - c.x, y: target.y - c.y)
        guard abs(d.x) > 0.001 || abs(d.y) > 0.001 else { return nil }
        let s = min(abs(d.x) > 0.001 ? inner.width / 2 / abs(d.x) : .infinity, abs(d.y) > 0.001 ? inner.height / 2 / abs(d.y) : .infinity)
        return (CGPoint(x: c.x + d.x * s, y: c.y + d.y * s), .radians(atan2(d.y, d.x)))
    }
}

private struct CompassToken: View {
    let person: LiveRoom.Person
    let zone: TimeZone?
    let angle: Angle
    let wink: LiveRoom.Wink?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                if person.doing != .looking && !person.away { Breathing(color: person.pencil.color) }
                // The point, toward them.
                Triangle()
                    .fill(person.pencil.color)
                    .frame(width: 9, height: 8)
                    .offset(x: 17)
                    .rotationEffect(angle)
                Circle()
                    .fill(person.pencil.color)
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 2))
                    .frame(width: 28, height: 28)
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
                Text(person.initial)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .contentShape(Circle().scale(0.75))
            .scaleEffect(hovering ? 1.12 : 1)
            // Out of sight, their wink rings their token instead, in the same hand.
            .overlay { if let wink { Circled(color: person.pencil.color, seed: UInt64(bitPattern: Int64(wink.time * 1000))).id(wink.time) } }
        }
        .buttonStyle(.plain)
        .opacity(person.away ? 0.55 : 1)
        .saturation(person.away ? 0.35 : 1)
        // Always there, only shown: it moves nothing, and is ready the first time.
        .overlay(alignment: labelAlignment) {
            NamePill(person: person, zone: zone)
                .fixedSize()
                .scaleEffect(hovering ? 1 : 0.88, anchor: labelAnchor)
                .opacity(hovering ? 1 : 0)
                .offset(labelOffset)
                .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
        .animation(hovering ? Theme.open : Theme.close, value: hovering)
    }

    /// The name goes toward the inside of the canvas, away from the rim.
    private var inward: CGPoint { CGPoint(x: -cos(angle.radians), y: -sin(angle.radians)) }
    private var labelAlignment: Alignment { inward.x >= 0 ? .leading : .trailing }
    private var labelAnchor: UnitPoint { inward.x >= 0 ? .leading : .trailing }
    private var labelOffset: CGSize { CGSize(width: inward.x >= 0 ? 44 : -44, height: inward.y * 18) }
}

/// A slow glow behind someone who is working this moment.
private struct Breathing: View {
    let color: Color
    @State private var on = false

    var body: some View {
        Circle()
            .fill(color.opacity(on ? 0.34 : 0.12))
            .frame(width: 42, height: 42)
            .blur(radius: 4)
            .scaleEffect(on ? 1.08 : 0.92)
            .animation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// A token circled by hand in its person's pencil, drawn on quickly, held, and let fade.
private struct Circled: View {
    let color: Color
    let seed: UInt64
    @State private var began = Date()

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSince(began)
            let (drawn, alpha) = PencilLoop.shown(at: t)
            PencilLoopShape(seed: seed)
                .trim(from: 0, to: drawn)
                .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                .background {
                    PencilLoopShape(seed: seed)
                        .trim(from: 0, to: drawn)
                        .stroke(.white.opacity(0.6), style: StrokeStyle(lineWidth: 4.2, lineCap: .round, lineJoin: .round))
                }
                .opacity(alpha)
                .frame(width: 44, height: 44)
        }
        .allowsHitTesting(false)
    }
}

private nonisolated struct PencilLoopShape: Shape {
    let seed: UInt64

    func path(in rect: CGRect) -> Path {
        let points = PencilLoop.points(seed: seed, radius: min(rect.width, rect.height) / 2 - 1)
        return Path { p in
            p.addLines(points.map { CGPoint(x: rect.midX + $0.x, y: rect.midY + $0.y) })
        }
    }
}

private nonisolated struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.maxX, y: rect.midY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// Someone's name in their pencil, with the time where they are if it is not the time here.
private struct NamePill: View {
    let person: LiveRoom.Person
    let zone: TimeZone?

    var body: some View {
        HStack(spacing: 5) {
            Text(verbatim: person.name)
                .font(.system(size: 11.5, weight: .semibold))
            if let zone {
                TimelineView(.everyMinute) { context in
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .opacity(0.75)
                        .environment(\.timeZone, zone)
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 9)
        .frame(height: 21)
        .background(Capsule().fill(person.pencil.color))
        .shadow(color: .black.opacity(0.16), radius: 3, y: 1)
    }
}

// MARK: - In the top bar

/// Who else is in the design this moment: their tokens, side by side, each opening into their
/// name when pointed at. Clicking one goes to them, and again lets them go. Nobody here, nothing.
struct LivePeople: View {
    let room: LiveRoom

    var body: some View {
        HStack(spacing: -4) {
            ForEach(room.people) { person in
                PersonToken(person: person, zone: room.zone(of: person), following: room.following == person.id) { room.go(to: person.id) }
                    .transition(.asymmetric(insertion: .scale(scale: 0.2).combined(with: .opacity),
                                            removal: .scale(scale: 0.5).combined(with: .opacity).combined(with: .offset(y: 8))))
            }
        }
        .animation(Theme.pop, value: room.people.map(\.id))
    }
}

/// Someone in the bar: a token in their pencil, ringed while they are at work, dimmed while they
/// are elsewhere. Pointed at, their name hangs below it, over what lies under the bar, so that
/// nothing in the bar has to make room for it.
private struct PersonToken: View {
    let person: LiveRoom.Person
    let zone: TimeZone?
    let following: Bool
    let action: () -> Void
    @State private var hovering = PersonToken.tagsShown

    /// BEZZLE_LIVE_TAGS: names shown from the start, for looking at them.
    #if DEBUG
    private static let tagsShown = ProcessInfo.processInfo.environment["BEZZLE_LIVE_TAGS"] != nil
    #else
    private static let tagsShown = false
    #endif

    var body: some View {
        Button(action: action) {
            Text(person.initial)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(person.pencil.color))
                .padding(2)
                .background(Circle().fill(following ? person.pencil.color.opacity(0.35) : Theme.paper))
                .overlay {
                    if person.doing != .looking && !person.away {
                        Circle().strokeBorder(person.pencil.color.opacity(0.55), lineWidth: 1.5)
                            .padding(-1)
                            .phaseAnimator([false, true]) { view, on in view.opacity(on ? 1 : 0.25) } animation: { _ in .easeInOut(duration: 0.9) }
                    }
                }
                .opacity(person.away ? 0.5 : 1)
                .saturation(person.away ? 0.4 : 1)
                .scaleEffect(hovering ? 1.08 : 1)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .overlay(alignment: .top) {
            NameTag(person: person, zone: zone, shown: hovering)
                .fixedSize()
                .offset(y: 32)
                .allowsHitTesting(false)
        }
        .onHover { hovering = $0 }
        .animation(hovering ? Theme.open : Theme.close, value: hovering)
        .animation(Theme.spring, value: following)
        .zIndex(hovering ? 1 : 0)
    }
}

/// A person's name hanging from their token on a little point, coming down as it shows.
private struct NameTag: View {
    let person: LiveRoom.Person
    let zone: TimeZone?
    let shown: Bool

    var body: some View {
        VStack(spacing: -1) {
            TagPoint()
                .fill(person.pencil.color)
                .frame(width: 9, height: 5)
            NamePill(person: person, zone: zone)
        }
        .scaleEffect(shown ? 1 : 0.9, anchor: .top)
        .offset(y: shown ? 0 : -4)
        .opacity(shown ? 1 : 0)
    }
}

private nonisolated struct TagPoint: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.midX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

extension Pencil {
    nonisolated var color: Color { Color(.sRGB, red: rgb.r, green: rgb.g, blue: rgb.b, opacity: 1) }
}
