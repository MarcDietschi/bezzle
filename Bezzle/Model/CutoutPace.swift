import Foundation

/// How far along the cutting out of a picture is, said from the clock. The work tells each step
/// as it begins; how long the steps took on this computer before says how much of the whole each
/// is. So what is shown moves all the while, also through a step that says nothing of itself for
/// many seconds (the model at work): steadily while the step takes as long as it did before,
/// slower and slower once it takes longer, and never all the way before the work has ended.
/// It never goes back.
nonisolated struct CutoutPace: Sendable, Equatable {
    /// The steps of the work, in the order they are taken. One not taken is simply never begun.
    enum Step: Int, CaseIterable, Sendable, Comparable {
        /// The picture read, and what stands out in it found roughly (the Mac's Vision; Windows
        /// finds it with the matte).
        case look
        /// What makes the matte made ready: the model loaded, where it is not yet.
        case load
        /// The matte made: how solid each pixel is.
        case matte
        /// The edge's colours worked out, the cutout drawn at the picture's own size and kept.
        case finish

        static func < (a: Step, b: Step) -> Bool { a.rawValue < b.rawValue }
    }

    /// How far is shown at most while the work goes on: the rest is for its end.
    static let most = 0.96

    /// How many seconds each step still to come is expected to take.
    private(set) var expected: [Step: Double]
    /// The step being taken, when it began, and how much was shown as done then.
    private(set) var step: Step?
    private var stepBegan: Double
    private var base = 0.0
    /// When the work ended, and how much was shown as done then.
    private(set) var ended: Double?
    /// How long each step took, of those over.
    private(set) var took: [Step: Double] = [:]

    init(expected: [Step: Double] = [:], at now: Double) {
        self.expected = expected
        stepBegan = now
    }

    /// `step` begins, and those before it are over. `expecting` says anew how long steps from
    /// here on will take, where the work knows better now (which model it runs, how large the
    /// picture is).
    mutating func begin(_ step: Step, expecting: [Step: Double] = [:], at now: Double) {
        guard ended == nil else { return }
        base = done(at: now)
        if let over = self.step, over != step { took[over, default: 0] += max(0, now - stepBegan) }
        for (s, seconds) in expecting { expected[s] = seconds }
        self.step = step
        stepBegan = now
    }

    /// The work is over.
    mutating func end(at now: Double) {
        guard ended == nil else { return }
        if let over = step { took[over, default: 0] += max(0, now - stepBegan) }
        ended = now
    }

    /// How much is done at `now`, 0…1: 1 only once the work has ended.
    func done(at now: Double) -> Double {
        if ended != nil { return 1 }
        guard let step else { return 0 }
        // What is left from this step on, as it was expected; the share of it the clock has
        // used up is the share shown of what was not yet shown as it began.
        let left = Step.allCases.filter { $0 >= step }.reduce(0) { $0 + max(0, expected[$1] ?? 0) }
        let used = max(0, now - stepBegan) / max(left, 0.05)
        return base + (Self.most - base) * Self.shown(used)
    }

    /// The share shown of what is left, for the share of its expected time used up: one to one
    /// to begin with, then nearing the whole ever slower and never reaching it, so a step that
    /// takes many times as long as it did before still moves.
    static func shown(_ used: Double) -> Double {
        let straight = 0.7
        guard used > straight else { return max(0, used) }
        let over = used - straight, rest = 1 - straight
        return straight + rest * over / (over + rest)
    }
}

/// How long the canvas takes over the end of a cut, in seconds: the same wherever Bezzle runs.
/// The design waits for the cut before it shows the cutout, so what is seen is one movement:
/// the line pulls tight round the subject, runs solid round it once, and what it cut off drops away.
nonisolated enum CutoutMotion {
    /// The line pulls tight round the subject once the cutout is made.
    static let pull = 0.24
    /// It runs solid round the subject, once: the cut.
    static let cut = 0.22
    /// What was cut off drops away from under the subject, and goes.
    static let drop = 0.42
    /// How far it drops, in points on the screen, and how far it turns meanwhile, in degrees.
    static let fall = 30.0
    static let turn = 1.6
    /// Given up, or nothing found: the line slackens back to the frame, and goes.
    static let slack = 0.32
    /// From coming loose of the frame to making for the subject, once that is found.
    static let found = 0.5
    /// How far the line is drawn in at most while the work still goes on.
    static let tightest = 0.9
    /// From the cutout made to the design showing it.
    static var untilCut: Double { pull + cut }

    /// From 0 to 1 over `t` from 0 to 1 as something pulled tight comes to rest: a little past,
    /// and back.
    static func sprung(_ t: Double) -> Double {
        guard t > 0 else { return 0 }
        guard t < 1 else { return 1 }
        let rate = 4.6, turn = 6.16
        return 1 - exp(-rate * t) * (cos(turn * t) + rate / turn * sin(turn * t))
    }
}
