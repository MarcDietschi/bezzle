import Foundation

// The cover over a design's tab while it opens, as the Mac's (Views/OpeningCoverView.swift,
// README.md › The Mac app › Opening a design): the shared OpeningCover's timing and OpeningMark's
// gesture, said as the moves Windows' compositor makes, each handed over at once so that it plays
// whatever the window's thread is busy with meanwhile (Sources/Bezzle/OpeningCover.swift). The
// Mac's numbers throughout. Numbers in and numbers out: nothing here asks Windows or the design
// anything, so Windows/Tests checks it on a Mac too.

nonisolated public enum OpeningPlan {
    /// When the cover's mark comes and when it lifts (the shared OpeningCover), on the app's clock.
    public struct Cover: Sendable {
        let cover: OpeningCover

        public init(began: Double, growing: Bool) { cover = OpeningCover(began: began, growing: growing) }

        public var began: Double { cover.began }
        public var marks: Double { cover.marks }
        /// The design is ready at `now`: when the paper lifts, and whether the mark is there to lift with it.
        public func lift(readyAt now: Double) -> (at: Double, marked: Bool) { cover.lift(readyAt: now) }
        /// When the cover is gone, the design all the way through.
        public func gone(readyAt now: Double) -> Double { cover.gone(readyAt: now) }
        /// How long the cover waits, once the design is open, for its canvas to show it.
        public static var patience: Double { OpeningCover.patience }
    }

    /// What is moved: all of the paper, the mark, its name, a sheet (struck), a part of a sheet
    /// (breathing), the deepest sheet's ink (running in) and a letter of the name.
    public enum Target: Hashable, Sendable {
        case paper, mark, word
        case sheet(Int)
        case part(Int, Part)
        case ink
        case letter(Int)
    }

    /// A part of a sheet's impression, as `picture` draws it (the shared OpeningMark.Part).
    public enum Part: CaseIterable, Hashable, Sendable {
        case rim, floor, walls, ink, inkWalls

        var shared: OpeningMark.Part {
            switch self {
            case .rim: .rim
            case .floor: .floor
            case .walls: .walls
            case .ink: .ink
            case .inkWalls: .inkWalls
            }
        }
    }

    /// What is moved of it: how see-through, how large about its own middle, how far down from
    /// its place in points, and how much of the ink has run in, from the top.
    public enum Property: Sendable { case opacity, scale, drop, inked }
    public enum Ease: Sendable { case linear, easeIn, easeOut, easeInOut }

    /// One move: from `at` seconds (after the mark is pressed, or after the lift begins), for
    /// `duration`, through its key values at their moments (0 to 1 of the duration), eased between
    /// them. A breathing move goes there and back for ever.
    public struct Move: Sendable {
        public let target: Target
        public let property: Property
        public let at: Double
        public let duration: Double
        public let keys: [Key]
        public let ease: Ease
        public var breathing = false

        public struct Key: Equatable, Sendable {
            public let progress: Double
            public let value: Double
        }

        /// Where it starts, held until it does.
        public var from: Double { keys.first?.value ?? 0 }
        /// Where it rests once done.
        public var to: Double { keys.last?.value ?? 0 }
    }

    // MARK: Pressing

    /// Everything the mark does from when it is pressed. Calm (Reduce Motion, Windows' "Animation
    /// effects" off), the mark and its name only fade in.
    public static func pressing(calm: Bool) -> [Move] {
        if calm {
            return [fade(.mark, 0, 1, at: 0, 0.3, .easeInOut), fade(.word, 0, 1, at: 0, 0.3, .easeInOut)]
        }
        var moves: [Move] = []
        for (i, strike) in OpeningMark.strikes.enumerated() {
            moves.append(fade(.sheet(i), 0, 1, at: strike, OpeningMark.deepens, .easeOut))
            moves.append(spring(.sheet(i), .scale, from: Double(OpeningMark.strikeFrom), to: 1, at: strike, OpeningMark.strike))
            // Then it breathes, the paper round it, its floor and its walls; the ink stays.
            for part in [Part.rim, .floor, .walls, .inkWalls] where OpeningMark.has(part.shared, i) {
                var breath = Move(target: .part(i, part), property: .opacity, at: OpeningMark.breathes + OpeningMark.breathLag(i),
                                  duration: OpeningMark.breath / 2, keys: [Move.Key(progress: 0, value: 1),
                                                                           Move.Key(progress: 1, value: Double(OpeningMark.shallowest))],
                                  ease: .easeInOut)
                breath.breathing = true
                moves.append(breath)
            }
        }
        moves.append(Move(target: .ink, property: .inked, at: OpeningMark.inks, duration: OpeningMark.inking,
                          keys: [Move.Key(progress: 0, value: 0), Move.Key(progress: 1, value: 1)], ease: .easeInOut))
        for i in 0..<OpeningMark.word.count {
            let sets = OpeningMark.sets(i)
            moves.append(fade(.letter(i), 0, 1, at: sets, OpeningMark.letterShows, .easeOut))
            moves.append(spring(.letter(i), .scale, from: Double(OpeningMark.letterFrom), to: 1, at: sets, OpeningMark.letter))
            // From above: up is less down.
            moves.append(spring(.letter(i), .drop, from: -Double(OpeningMark.letterDrop * OpeningMark.wordSize), to: 0, at: sets, OpeningMark.letter))
        }
        return moves
    }

    // MARK: Lifting

    /// The lift, from when it begins: the mark pressed flat and the paper cleared; or, when the
    /// mark never came, the paper simply cleared.
    public static func lifting(marked: Bool, calm: Bool) -> [Move] {
        guard marked else { return [fade(.paper, 1, 0, at: 0, OpeningCover.quick, .easeOut)] }
        if calm { return [fade(.paper, 1, 0, at: 0, OpeningCover.lifting, .easeInOut)] }
        let flat = OpeningMark.flattens
        return [fade(.mark, 1, 0, at: 0, flat, .easeInOut),
                Move(target: .mark, property: .scale, at: 0, duration: flat,
                     keys: [Move.Key(progress: 0, value: 1), Move.Key(progress: 1, value: Double(OpeningMark.flatTo))], ease: .easeIn),
                fade(.word, 1, 0, at: 0, flat, .easeInOut),
                fade(.paper, 1, 0, at: OpeningMark.clears, OpeningCover.lifting - OpeningMark.clears, .easeInOut)]
    }

    // MARK: Laying it out

    /// How many sheets the mark has.
    public static var sheets: Int { OpeningMark.sheets.count }
    /// Which parts a sheet has: only the deepest is inked.
    public static func parts(of sheet: Int) -> [Part] { Part.allCases.filter { OpeningMark.has($0.shared, sheet) } }
    /// The mark's pictures' size in points, its shadows on the paper included, and where in it a
    /// sheet's middle is, which it is struck about, from its top left.
    public static var markSize: Double { Double(OpeningMark.canvas.width * OpeningMark.side / 500) }
    public static func middle(of sheet: Int) -> (x: Double, y: Double) {
        let p = OpeningMark.middle(of: sheet), k = Double(OpeningMark.side / 500)
        return (Double(p.x) * k, Double(p.y) * k)
    }
    /// The outer sheet's side, in points.
    public static var side: Double { Double(OpeningMark.side) }
    /// The name, its letters' size, how far below the outer sheet its letters' tops are, and how
    /// far apart they are set, of their size.
    public static var word: String { OpeningMark.word }
    public static var wordSize: Double { Double(OpeningMark.wordSize) }
    public static var wordGap: Double { Double(OpeningMark.wordGap) }
    public static var wordTracking: Double { Double(OpeningMark.wordTracking) }
    /// How far above the room's middle the mark and its name sit, of the room's height.
    public static var lift: Double { Double(OpeningMark.lift) }

    /// Where the outer sheet's top left and the name's cap height's top go in a room `width` by
    /// `height` points, for a name whose letters' caps are `capHeight` tall: the mark and its name
    /// together in the middle, a little above it.
    public static func place(width: Double, height: Double, capHeight: Double) -> (markTop: Double, markLeft: Double, wordTop: Double) {
        let tall = side + wordGap + capHeight
        let top = (height / 2 - height * lift - tall / 2).rounded()
        return (top, (width / 2 - side / 2).rounded(), top + side + wordGap)
    }

    // MARK: Moves

    private static func fade(_ target: Target, _ from: Double, _ to: Double, at: Double, _ duration: Double, _ ease: Ease) -> Move {
        Move(target: target, property: .opacity, at: at, duration: duration,
             keys: [Move.Key(progress: 0, value: from), Move.Key(progress: 1, value: to)], ease: ease)
    }

    /// A value carried along a spring's course, its key values evenly over the spring's settling.
    private static func spring(_ target: Target, _ property: Property, from: Double, to: Double, at: Double,
                               _ spring: OpeningMark.Spring) -> Move {
        let settles = spring.settles
        return Move(target: target, property: property, at: at, duration: settles,
                    keys: spring.course().map { Move.Key(progress: $0.t / settles, value: from + (to - from) * $0.v) }, ease: .linear)
    }
}
