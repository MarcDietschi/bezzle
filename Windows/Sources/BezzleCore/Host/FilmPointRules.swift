import Foundation

// Animate: what a press, a pick and the panel do with a shape's points in hand, as the Mac's
// MotionTool and the Pose card's chip decide it (Canvas/MotionTool.swift, Views/AnimateInspector
// .swift). The points themselves are the shared pen's (`PenTool`), worked by `FilmPoints`; this
// is only when they are taken up and put down, and when some may be taken away. Nothing here
// asks Windows or the design anything, so Windows/Tests checks it on a Mac too.

nonisolated enum FilmPointRules {
    /// What a press does, while a shape's points are in hand, that is on none of its points or
    /// handles: on the shape or the bare film, a loop round points (`leaves` when a click there
    /// that does not drag puts them down, off the shape), or with a second click their putting
    /// down; on another layer, their putting down and that layer picked (`passOn`).
    enum Press: Equatable {
        case loop(leaves: Bool)
        case putDown
        case passOn
    }

    static func press(on pressed: UUID?, editing: UUID, clicks: Int) -> Press {
        guard pressed == nil || pressed == editing else { return .passOn }
        return clicks >= 2 ? .putDown : .loop(leaves: pressed == nil)
    }

    /// Whether a press takes a shape's points in hand: the second click on a shape picked alone,
    /// with no deeper layer under the pointer, whose outline is points and that is not locked.
    /// A second click on anything else picked goes one layer further in, as it did before.
    static func takesInHand(clicks: Int, pressed: UUID?, selection: [UUID], deepest: UUID?, reshapes: Bool, locked: Bool) -> Bool {
        guard clicks == 2, let pressed else { return false }
        return selection == [pressed] && deepest == pressed && reshapes && !locked
    }

    /// Whether points in hand stay there as the layers picked change: only while their shape is
    /// the one picked.
    static func keeps(_ editing: UUID, picked: [UUID]) -> Bool { picked == [editing] }

    /// The Pose card's chip for the layers picked: Done while their one shape's points are in
    /// hand, Edit Points otherwise, which only one layer picked can use.
    static func chip(editing: UUID?, picked: [UUID]) -> (done: Bool, enabled: Bool) {
        let done = editing != nil && picked == [editing!]
        return (done, picked.count == 1)
    }

    /// Whether the Pose card shows Draw and Shape: when every layer picked is a shape whose
    /// outline is points.
    static func showsShape(_ reshapes: [Bool]) -> Bool { !reshapes.isEmpty && reshapes.allSatisfy { $0 } }

    /// Whether points taken away at the playhead leave an outline a key can hold: `runs` is how
    /// many points each of its runs keeps, and one of them has to keep two, which is a line.
    /// Else nothing is taken away, and the canvas beeps: the last of a shape's points stay.
    static func leavesAnOutline(runs: [Int]) -> Bool { runs.contains { $0 >= 2 } }
}
