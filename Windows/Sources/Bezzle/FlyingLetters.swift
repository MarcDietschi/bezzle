import Foundation
import WinUI
import UWP
import WindowsFoundation
import BezzleCore

/// Letters springing to new places over the canvas, as the Mac's CurveTool draws its fliers: the
/// core's LetterFlights stepped on every change and every frame while any are on their way, and the
/// letters it shows drawn by Skia into one picture over the artboards, under every mark. While a
/// text's letters fly, the canvas leaves it out of its artboard's picture (`hidden`); once they
/// land, it is drawn there again.
@MainActor
final class FlyingLetters {
    let flights = WindowsCore.LetterFlights()
    /// Between the artboards and the marks over them.
    let layer = Canvas()
    private let image = Image()
    private var bitmap: WriteableBitmap?
    private var ticking: EventCleanup?
    /// The texts left out of the artboards' pictures: those whose letters are on their way.
    private(set) var hidden: Set<UUID> = []

    /// What the canvas watches: what is selected, the text typed into and the one held on an edge.
    var watching: () -> (selection: [UUID], editing: UUID?, holding: UUID?) = { ([], nil, nil) }
    /// Where the canvas is: a canvas point `p` is at `pan + p · zoom` on the stage, which is `size`
    /// big, in its points, `scale` pixels each.
    var view: () -> (zoom: Double, pan: CGPoint, size: CGSize, scale: Double) = { (1, .zero, .zero, 1) }
    /// Letters that set off or landed, between frames: their texts' pictures are drawn again.
    var turned: (_ texts: Set<UUID>) -> Void = { _ in }

    init() {
        layer.isHitTestVisible = false
        image.isHitTestVisible = false
        image.stretch = .fill
        image.visibility = .collapsed
        layer.children.append(image)
    }

    /// Steps the letters on from the design as it shows now. Answers the texts whose letters set
    /// off or landed, whose pictures are to be drawn again (`hidden` says how).
    @discardableResult func step() -> Set<UUID> {
        let w = watching()
        flights.step(selection: w.selection, editing: w.editing, holding: w.holding, zoom: CGFloat(view().zoom))
        let now = flights.flying
        let changed = now.symmetricDifference(hidden)
        hidden = now
        if flights.animating { tick() }
        return changed
    }

    /// Has a text's next change fly letter by letter, from the letter nearest `p` on the canvas,
    /// or from the middle.
    func fly(_ id: UUID, from p: CGPoint? = nil) { flights.fly(id, from: p) }

    /// The letters on their way drawn where they are now, or nothing once none are.
    func draw() {
        let v = view()
        var bitmap = self.bitmap
        let covered = hidden.isEmpty ? nil : flights.picture(zoom: CGFloat(v.zoom), pan: v.pan, scale: v.scale, stage: v.size) { width, height in
            if bitmap == nil || bitmap!.pixelWidth != Int32(width) || bitmap!.pixelHeight != Int32(height) {
                bitmap = WriteableBitmap(Int32(width), Int32(height))
            }
            return (try? bitmap?.pixelBuffer.buffer).flatMap { $0.map(UnsafeMutableRawPointer.init) }
        }
        guard let covered else {
            image.visibility = .collapsed
            return
        }
        try? bitmap?.invalidate()
        if self.bitmap !== bitmap { image.source = bitmap }
        self.bitmap = bitmap
        try? Canvas.setLeft(image, Double(covered.minX))
        try? Canvas.setTop(image, Double(covered.minY))
        image.width = Double(covered.width)
        image.height = Double(covered.height)
        image.visibility = .visible
    }

    /// Frame by frame while any letters are on their way.
    private func tick() {
        guard ticking == nil else { return }
        ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let changed = self.step()
                if !changed.isEmpty { self.turned(changed) }
                self.draw()
                if !self.flights.animating {
                    self.ticking?.dispose()
                    self.ticking = nil
                }
            }
        }
    }
}
