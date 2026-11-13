import Foundation

/// Inspecting the design: a lens on the prototype's table that reads, and never writes.
extension DocumentStore {
    func inspectingChanged() {
        let fromDesign = !prototyping
        if inspecting {
            // Inspected on the prototype's table; one thing at a time.
            if animating { animating = false }
            if !prototyping { prototyping = true }
            if selection.count > 1 { selection = [selection[0]] }
            writingNote = nil
            flowPreview = nil
        }
        canvas?.inspectTool.modeChanged(inspecting, design: inspecting ? fromDesign : !prototyping)
    }

    /// Turns the canvas to the design, the prototype, the design inspected or the design animated.
    func show(_ mode: CanvasMode) {
        switch mode {
        case .design:
            prototyping = false
        case .prototype:
            animating = false
            inspecting = false
            prototyping = true
        case .inspect:
            inspecting = true
        case .animate:
            animating = true
        }
    }

    /// What the canvas shows the design as.
    var canvasMode: CanvasMode { animating ? .animate : inspecting ? .inspect : prototyping ? .prototype : .design }
}

/// The four ways of seeing a design, as the header's switch offers them.
enum CanvasMode: CaseIterable, Hashable {
    case design, prototype, inspect, animate
}
