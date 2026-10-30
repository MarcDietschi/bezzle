import Foundation
import QuartzCore

/// Eases the canvas from what one preview showed to what the next shows, rather than jumping:
/// pointing along the corner choices rounds the corners a little at a time, and leaving them
/// lets them settle back the same way.
@MainActor
final class PreviewMotion {
    static let duration: CFTimeInterval = 0.2

    /// The preview last shown, and the layers it changed.
    private var token: UUID?
    private var previewed: [UUID] = []
    /// The moving layers as they looked when the move began, which may be part of the way
    /// through the move before.
    private var from: [UUID: Node] = [:]
    private var began: CFTimeInterval = 0
    /// The document as last drawn.
    private var drawn: BezzleDocument?

    var isMoving: Bool { !from.isEmpty }

    /// The document to draw at `now`: `shown`, with the layers a preview is coming to or
    /// leaving eased part of the way there.
    func frame(of shown: BezzleDocument, preview: DocumentStore.Preview?, at now: CFTimeInterval) -> BezzleDocument {
        if preview?.token != token {
            let before = drawn ?? shown
            from = [:]
            for id in Set(previewed).union(preview?.ids ?? []) {
                if let node = before.node(id) { from[id] = node }
            }
            began = now
            token = preview?.token
            previewed = preview?.ids ?? []
        }
        var out = shown
        if !from.isEmpty {
            let t = (now - began) / Self.duration
            if t >= 1 {
                from = [:]
            } else {
                // Quick to leave and gentle to arrive, as the panels' own springs are.
                let eased = 1 - pow(1 - t, 3)
                for (id, start) in from { out.update(id) { $0 = start.blended(to: $0, eased) } }
            }
        }
        drawn = out
        return out
    }
}

private func mix(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat { a + (b - a) * CGFloat(t) }
private func mix(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

extension RGBA {
    /// Part of the way from this colour to `other`.
    func mixed(_ other: RGBA, _ t: Double) -> RGBA {
        RGBA(r: mix(r, other.r, t), g: mix(g, other.g, t), b: mix(b, other.b, t), a: mix(a, other.a, t))
    }
}

private extension Node {
    /// Part of the way from this layer to `other`. What can be measured is mixed; what cannot,
    /// such as a font, a gradient or a dash, is `other`'s at once. Something coming on fades
    /// in, and a shadow coming on rises as it does.
    func blended(to other: Node, _ t: Double) -> Node {
        var n = other
        n.rotation = mix(rotation, other.rotation, t)
        n.opacity = mix(opacity, other.opacity, t)
        n.cornerRadius = mix(cornerRadius, other.cornerRadius, t)
        if cornerSmoothing != nil || other.cornerSmoothing != nil {
            n.cornerSmoothing = mix(cornerSmoothing ?? 0, other.cornerSmoothing ?? 0, t)
        }
        if let a = corners, let b = other.corners, a.count == b.count {
            n.corners = zip(a, b).map { mix($0, $1, t) }
        }
        n.fill = fill.blended(to: other.fill, t)
        n.border = border.blended(to: other.border, t)
        n.shadow = shadow.blended(to: other.shadow, t)
        if let a = blur, let b = other.blur, a.on == b.on, a.background == b.background {
            n.blur?.radius = mix(a.radius, b.radius, t)
        }
        if kind == .text, let a = style, let b = other.style, a != b {
            // Text keeps its frame fitted to its size, as it is when the size is set.
            n.style?.size = mix(a.size, b.size, t)
            n.style?.tracking = mix(a.tracking, b.tracking, t)
            if let la = a.lineSpacing, let lb = b.lineSpacing { n.style?.lineSpacing = mix(la, lb, t) }
            n.refit()
        } else {
            n.frame = CGRect(x: mix(frame.minX, other.frame.minX, t), y: mix(frame.minY, other.frame.minY, t),
                             width: mix(frame.width, other.frame.width, t), height: mix(frame.height, other.frame.height, t))
        }
        return n
    }
}

private extension Fill {
    func blended(to other: Fill, _ t: Double) -> Fill {
        guard gradient == nil, image == nil, other.gradient == nil, other.image == nil, on || other.on else { return other }
        var f = other
        f.on = true
        f.color = (on ? color : other.color.with(alpha: 0)).mixed(other.on ? other.color : color.with(alpha: 0), t)
        return f
    }
}

private extension Border {
    func blended(to other: Border, _ t: Double) -> Border {
        guard on || other.on else { return other }
        var b = other
        b.on = true
        b.color = (on ? color : other.color.with(alpha: 0)).mixed(other.on ? other.color : color.with(alpha: 0), t)
        if on && other.on { b.width = mix(width, other.width, t) }
        return b
    }
}

private extension Shadow {
    func blended(to other: Shadow, _ t: Double) -> Shadow {
        guard on || other.on else { return other }
        // Off, a shadow is one lying flat under the layer, with nothing to it.
        func lit(_ s: Shadow, as like: Shadow) -> Shadow {
            s.on ? s : Shadow(on: true, color: like.color.with(alpha: 0), x: 0, y: 0, blur: 0)
        }
        let a = lit(self, as: other), b = lit(other, as: self)
        return Shadow(on: true, color: a.color.mixed(b.color, t), x: mix(a.x, b.x, t), y: mix(a.y, b.y, t), blur: mix(a.blur, b.blur, t))
    }
}
