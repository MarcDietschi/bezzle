import CoreGraphics
import Foundation

/// Where the notes go on screen: on the table between the sheets, never over one. A thread's card
/// keeps level with its spot in the margin of the sheet it is about, on the side nearer the spot,
/// and makes room for the others down that margin. Where the margin has no room for it, the thread
/// is a flag stuck to the sheet's edge instead, as a reviewer sticks one to a printout, as long as
/// the gap there allows. The thread open always gets a card: with no room for it, it lifts over the
/// table. All in the view's points.
nonisolated enum NotePlacement {
    static let width: CGFloat = 236
    /// From a sheet's edge to its cards.
    static let gap: CGFloat = 26
    /// Kept clear round every sheet and card.
    static let clearance: CGFloat = 12
    /// Between one card and the next down a margin.
    static let spacing: CGFloat = 10
    /// How far down a card its thread comes in.
    static let lineIn: CGFloat = 19
    static let flagHeight: CGFloat = 20
    static let flagReach: CGFloat = 24
    static let flagSpacing: CGFloat = 3
    /// A sheet shorter than this on screen takes flags only: cards beside it would dwarf it.
    static let smallest: CGFloat = 120
    /// What a thread that was a flag needs more than a card does, to be a card again; and how
    /// much shorter a sheet may get before a card on it folds to a flag. So that a thread at the
    /// edge of having room, as the view is zoomed, turns once and not to and fro.
    static let reluctance: CGFloat = 20
    static let keeping: CGFloat = 30
    /// From a spot on the table to its card.
    static let tableGap: CGFloat = 30

    enum Side: Hashable, Sendable { case right, left }

    enum Kind: Hashable, Sendable {
        /// A card in the margin.
        case card
        /// A flag on the sheet's edge.
        case flag
        /// The open card, lifted over what it could find no room beside.
        case lifted
        /// A spot on the table, its writer's token on it.
        case pin
    }

    struct Want: Sendable {
        var id: UUID
        var spot: CGPoint
        /// What the card goes beside: the sheet, and its id to tell the margins apart. None for the table.
        var home: CGRect?
        var sheet: UUID?
        var height: CGFloat
        /// Open or being written: a card, wherever it has to go.
        var open = false
        /// Ticked off, shown while writing notes: a flag, whatever room there is.
        var flagOnly = false
        /// The part circled, on screen: its pin is on the loop round it, on the card's side.
        var area: CGRect?
    }

    struct Place: Equatable, Sendable {
        var id: UUID
        var kind: Kind
        var frame: CGRect
        var side: Side
        /// Where its thread comes in.
        var anchor: CGPoint
    }

    /// How far a card keeps from its own pin, the middle of the pin to the card's edge, so the pin
    /// always shows beside it, to be pulled elsewhere.
    static let pinRoom: CGFloat = 24
    /// What a pin takes up, kept clear by every card and flag.
    static let pinSize: CGFloat = 22

    /// Where a note's thread leaves for a card on this side: its spot, or the loop's edge.
    static func pin(of want: Want, side: Side) -> CGPoint {
        guard let area = want.area else { return want.spot }
        return NoteLoop.pin(seed: NoteLoop.seed(want.id), around: area, right: side == .right)
    }

    /// What a note's pins take up: one for a spot, one either side of a loop.
    static func pins(of want: Want) -> [CGRect] {
        let points = want.area == nil ? [want.spot] : [pin(of: want, side: .left), pin(of: want, side: .right)]
        return points.map { CGRect(x: $0.x - pinSize / 2, y: $0.y - pinSize / 2, width: pinSize, height: pinSize) }
    }

    /// `was` is how each thread showed the last time, which it keeps while it is near the edge of
    /// having room: see `reluctance`. No card or flag ever lies over a pin, its own or another's.
    static func place(_ wants: [Want], around obstacles: [CGRect], was: [UUID: Kind] = [:]) -> [Place] {
        let pins = wants.flatMap { w in pins(of: w).map { (id: w.id, rect: $0) } }
        func others(_ id: UUID) -> [CGRect] { pins.filter { $0.id != id }.map(\.rect) }
        var cards: [CGRect] = []
        var out: [Place] = []
        var flags: [Want] = []
        /// The foot of the last card down each margin, so cards keep the order of their spots.
        var floors: [String: CGFloat] = [:]
        // The open card first, beside its spot; the others make room round it, top down.
        let ordered = wants.sorted { a, b in
            (a.open ? 0 : 1, a.spot.y, a.spot.x, a.id.uuidString) < (b.open ? 0 : 1, b.spot.y, b.spot.x, b.id.uuidString)
        }
        for want in ordered {
            if want.flagOnly && !want.open { flags.append(want); continue }
            let desired = want.spot.y - lineIn
            // A flag a moment ago wants a little more room than a card needs to be one again.
            let folded = was[want.id] == .flag || was[want.id] == .pin
            let card = was[want.id] == .card || was[want.id] == .lifted
            let clear = clearance + (folded && !want.open ? reluctance : 0)
            if let home = want.home {
                let least = folded ? smallest + reluctance : card ? smallest - keeping : smallest
                if !want.open, home.height < least { flags.append(want); continue }
                let sides: [Side] = want.spot.x >= home.midX ? [.right, .left] : [.left, .right]
                var placed = false
                for side in sides {
                    let x = column(for: want, home: home, side: side)
                    // Level with its pin, where the thread leaves it.
                    let desired = pin(of: want, side: side).y - lineIn
                    let margin = "\(want.sheet?.uuidString ?? "")\(side)"
                    let floor = want.open ? -CGFloat.infinity : floors[margin] ?? -.infinity
                    let range: ClosedRange<CGFloat> = want.open
                        ? (desired - want.height - 80)...(desired + 80)
                        : (home.minY - 40)...max(home.minY - 40, home.maxY - 14)
                    // Its own sheet is beside the margin, never in it, however much room is kept.
                    guard let y = freeY(x: x, height: want.height, near: max(desired, floor), atLeast: floor, within: range,
                                        blocked: obstacles.filter { $0 != home } + cards + others(want.id), clear: clear) else { continue }
                    let frame = CGRect(x: x, y: y, width: width, height: want.height)
                    out.append(Self.card(want.id, .card, frame, side))
                    cards.append(frame)
                    if !want.open { floors[margin] = frame.maxY + spacing }
                    placed = true
                    break
                }
                if !placed {
                    if want.open {
                        let side = sides[0]
                        let frame = CGRect(x: column(for: want, home: home, side: side), y: pin(of: want, side: side).y - lineIn,
                                           width: width, height: want.height)
                        out.append(Self.card(want.id, .lifted, frame, side))
                        cards.append(frame)
                    } else {
                        flags.append(want)
                    }
                }
            } else {
                // On the table: beside its pin, out past the loop if it is round something.
                var placed = false
                for side in [Side.right, .left] {
                    let pin = pin(of: want, side: side)
                    let x = side == .right ? pin.x + tableGap : pin.x - tableGap - width
                    let desired = pin.y - lineIn
                    let range: ClosedRange<CGFloat> = (desired - 140)...(desired + 140)
                    guard let y = freeY(x: x, height: want.height, near: desired, atLeast: -.infinity, within: range,
                                        blocked: obstacles + cards + others(want.id), clear: clear) else { continue }
                    let frame = CGRect(x: x, y: y, width: width, height: want.height)
                    out.append(Self.card(want.id, .card, frame, side))
                    cards.append(frame)
                    placed = true
                    break
                }
                if !placed {
                    if want.open {
                        let pin = pin(of: want, side: .right)
                        let frame = CGRect(x: pin.x + tableGap, y: pin.y - lineIn, width: width, height: want.height)
                        out.append(Self.card(want.id, .lifted, frame, .right))
                        cards.append(frame)
                    } else {
                        out.append(token(want))
                    }
                }
            }
        }
        // Flags down each sheet's edges, level with their spots, each clear of the one above and
        // all along the sheet, as far out into the gap as there is room for.
        var edges: [String: (home: CGRect, side: Side, wants: [Want])] = [:]
        for want in flags {
            guard let home = want.home else {
                out.append(token(want))
                continue
            }
            let side: Side = want.spot.x >= home.midX ? .right : .left
            let edge = "\(want.sheet?.uuidString ?? "\(home)")\(side)"
            edges[edge, default: (home, side, [])].wants.append(want)
        }
        for edge in edges.keys.sorted() {
            guard let (home, side, wants) = edges[edge].map({ ($0.home, $0.side, $0.wants) }) else { continue }
            let list = wants.sorted { ($0.spot.y, $0.spot.x, $0.id.uuidString) < ($1.spot.y, $1.spot.x, $1.id.uuidString) }
            let n = CGFloat(list.count)
            // More than the edge holds: smaller, closer together.
            var height = flagHeight, between = flagSpacing
            if n * height + (n - 1) * between > home.height {
                between = 1
                height = max((home.height - (n - 1) * between) / n, 3)
            }
            // Down the edge, each level with its spot and clear of the one above, then back up from
            // the foot whatever ran past it; round every pin near the edge, its own above all,
            // below a pin going down and above it coming back up: a flag never hides a pin. Only
            // an edge too crowded with pins for its flags has them run past the sheet.
            let band = side == .right ? (home.maxX - 8)...(home.maxX + flagReach + 4) : (home.minX - flagReach - 4)...(home.minX + 8)
            let blocked = pins.map(\.rect)
                .filter { $0.maxX >= band.lowerBound && $0.minX <= band.upperBound }
                .map { ($0.minY - 1, $0.maxY + 1) }
            func hit(_ y: CGFloat) -> (CGFloat, CGFloat)? { blocked.first { y < $0.1 - 0.001 && y + height > $0.0 + 0.001 } }
            var ys: [CGFloat] = []
            for want in list {
                var y = max(min(max(want.spot.y - height / 2, home.minY), home.maxY - height), ys.last.map { $0 + height + between } ?? -.infinity)
                for _ in 0...blocked.count { guard let pin = hit(y) else { break }; y = pin.1 }
                ys.append(y)
            }
            var limit = home.maxY - height
            for i in ys.indices.reversed() {
                if ys[i] > limit + 0.001 {
                    ys[i] = limit
                    for _ in 0...blocked.count { guard let pin = hit(ys[i]) else { break }; ys[i] = pin.0 - height }
                }
                limit = ys[i] - height - between
            }
            for (want, y) in zip(list, ys) {
                let room = room(beside: home, on: side, from: y, to: y + height, blocked: obstacles + cards)
                var frame: CGRect
                if room >= 2 * flagReach + 6 {
                    frame = CGRect(x: side == .right ? home.maxX : home.minX - flagReach, y: y, width: flagReach, height: height)
                } else if room >= 10 {
                    // A gap two sheets share is shared by their flags, half each.
                    let reach = min(flagReach, room / 2 - 2)
                    frame = CGRect(x: side == .right ? home.maxX : home.minX - reach, y: y, width: reach, height: height)
                } else {
                    // No gap to speak of: a sliver on the sheet's own edge.
                    frame = CGRect(x: side == .right ? home.maxX - 4 : home.minX, y: y, width: 4, height: height)
                }
                out.append(Place(id: want.id, kind: .flag, frame: frame, side: side,
                                 anchor: CGPoint(x: side == .right ? home.maxX : home.minX, y: frame.midY)))
            }
        }
        return out
    }

    /// Where a card beside a sheet starts across: in the margin, and further out if its pin is
    /// out there, as a loop round something at the edge or a pin pulled into the margin is.
    private static func column(for want: Want, home: CGRect, side: Side) -> CGFloat {
        let pin = pin(of: want, side: side)
        return side == .right ? max(home.maxX + gap, pin.x + pinRoom) : min(home.minX - gap - width, pin.x - pinRoom - width)
    }

    /// A thread on the table with no room for its card: its pin, its writer's token on it.
    private static func token(_ want: Want) -> Place {
        let pin = pin(of: want, side: .right)
        return Place(id: want.id, kind: .pin, frame: CGRect(x: pin.x - pinSize / 2, y: pin.y - pinSize / 2, width: pinSize, height: pinSize),
                     side: .right, anchor: pin)
    }

    private static func card(_ id: UUID, _ kind: Kind, _ frame: CGRect, _ side: Side) -> Place {
        Place(id: id, kind: kind, frame: frame, side: side,
              anchor: CGPoint(x: side == .right ? frame.minX : frame.maxX, y: frame.minY + lineIn))
    }

    /// The top of a card `height` tall in the column at `x` nearest `near`, at or below `atLeast`
    /// and within `range`, clear of everything blocked; nil when there is none.
    static func freeY(x: CGFloat, height: CGFloat, near: CGFloat, atLeast: CGFloat, within range: ClosedRange<CGFloat>,
                      blocked: [CGRect], clear clearance: CGFloat = NotePlacement.clearance) -> CGFloat? {
        let low = max(range.lowerBound, atLeast), high = range.upperBound
        guard low <= high else { return nil }
        // What lies in the column, as the tops a card may not have.
        let gaps: [(CGFloat, CGFloat)] = blocked.compactMap { r in
            guard r.minX < x + width + clearance, r.maxX > x - clearance else { return nil }
            return (r.minY - clearance - height, r.maxY + clearance)
        }
        func free(_ y: CGFloat) -> Bool { !gaps.contains { y > $0.0 + 0.001 && y < $0.1 - 0.001 } }
        var tries: [CGFloat] = [min(max(near, low), high), low, high]
        for g in gaps { tries.append(g.0); tries.append(g.1) }
        return tries.filter { $0 >= low - 0.001 && $0 <= high + 0.001 && free($0) }
            .min { (abs($0 - near), $0) < (abs($1 - near), $1) }
    }

    /// How far the table runs out from a sheet's edge, between two heights, before it meets something.
    static func room(beside home: CGRect, on side: Side, from top: CGFloat, to bottom: CGFloat, blocked: [CGRect]) -> CGFloat {
        var room = CGFloat.infinity
        for r in blocked where r.maxY > top && r.minY < bottom && r != home {
            if side == .right, r.minX >= home.maxX - 0.5 { room = min(room, r.minX - home.maxX) }
            if side == .left, r.maxX <= home.minX + 0.5 { room = min(room, home.minX - r.maxX) }
        }
        return room
    }
}
