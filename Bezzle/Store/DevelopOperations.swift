import Foundation
import QuartzCore

/// Developing the selected layers' pictures: see `Develop` and `PhotoCard`.
extension DocumentStore {
    /// Whether a layer shows a picture that can be developed.
    static func develops(_ n: Node) -> Bool { n.fill.on && n.fill.image != nil }

    /// The selected layers that show a picture.
    var developing: [Node] { selectedNodes.filter(Self.develops) }

    /// Changes each selected picture's development, as one step named `action` (or as part of
    /// the gesture going on).
    func develop(_ action: LocalizedStringResource, _ change: (inout Develop) -> Void) {
        updateSelection(action) { n in
            guard Self.develops(n), var image = n.fill.image else { return }
            var d = image.develop ?? Develop()
            change(&d)
            image.develop = d.kept
            n.fill.image = image
        }
    }

    /// Takes every selected picture back to how it was taken.
    func resetDevelop() {
        develop("Reset Photo") { $0 = Develop() }
    }

    /// The picture a layer's development is worked out from: small, as it is shown.
    func developSource(_ n: Node, pixels: CGFloat = 256) -> CGImage? {
        guard let image = n.fill.image else { return nil }
        return assets.image(image.shown, pixels: pixels) ?? assets.image(image.asset, pixels: pixels)
    }

    /// What would suit a layer's picture best, worked out once for each picture.
    func autoDevelop(for n: Node) -> Develop {
        guard let image = n.fill.image else { return Develop() }
        if let known = autoKept[image.asset] { return known }
        let d = assets.image(image.asset, pixels: 256).map(Develop.auto(for:)) ?? Develop()
        autoKept[image.asset] = d
        return d
    }

    /// Develops each selected picture as suits it best, gliding there on the canvas.
    func autoDevelop() {
        let targets = Dictionary(uniqueKeysWithValues: developing.map { ($0.id, autoDevelop(for: $0)) })
        guard !targets.isEmpty else { return }
        glide("Auto Photo") { id, _ in targets[id] ?? Develop() }
    }

    /// Moves each selected picture's development to what `target` gives it, over a moment, the
    /// canvas showing each step on the way, and undoes as one step.
    func glide(_ action: LocalizedStringResource, duration: CFTimeInterval = 0.42, to target: @escaping (UUID, Develop) -> Develop) {
        let ids = developing.map(\.id)
        let from = Dictionary(uniqueKeysWithValues: developing.map { ($0.id, $0.fill.image?.develop ?? Develop()) })
        let to = Dictionary(uniqueKeysWithValues: from.map { ($0.key, target($0.key, $0.value)) })
        guard from.contains(where: { to[$0.key] != $0.value }) else { return }
        gliding?.cancel()
        // A glide cut short by another still ends as one step.
        if inGesture { endGesture(action) }
        beginGesture()
        let began = CACurrentMediaTime()
        func step(_ t: Double) {
            // Quick to start and gentle to land, as the panel's springs are.
            let eased = 1 - pow(1 - min(max(t, 0), 1), 3)
            edit(action) { doc in
                for id in ids {
                    doc.update(id) { n in
                        guard let a = from[id], let b = to[id] else { return }
                        n.fill.image?.develop = (t >= 1 ? b : Develop.mix(a, b, eased)).kept
                    }
                }
            }
        }
        gliding = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let t = (CACurrentMediaTime() - began) / duration
                step(t)
                if t >= 1 {
                    self?.endGesture(action)
                    self?.gliding = nil
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    /// Shows the selected pictures as they were taken, while `on`.
    func showOriginal(_ on: Bool) {
        showPreview("develop-original", on ? { n in n.fill.image?.develop = nil } : nil)
    }

    /// Shows only the part of the selected pictures that `isolation` works on, or with nil, all of them again.
    func showIsolated(_ isolation: Develop.Isolation?) {
        showPreview("develop-isolate", isolation.map { iso in
            { n in
                guard n.fill.image != nil else { return }
                var d = n.fill.image?.develop ?? Develop()
                d.isolate = iso
                n.fill.image?.develop = d
            }
        })
    }

    /// Makes the colour at a point of the picture neutral grey: the white balance set so it has
    /// no colour of its own, its tint too. `color` is that colour as it is shown now.
    func neutralize(_ color: SIMD3<Double>) {
        develop("Set White Balance") { d in
            // Taken back through the white balance it has now, to the colour as it was lit.
            let now = PointMap.whiteBalance(d[.temperature] / 100)
            var lit = PointMap.decode(color) / now
            lit.y /= exp2(-0.42 * d[.tint] / 100)
            guard lit.min() > 1e-4 else { return }
            var lo = -100.0, hi = 100.0
            for _ in 0..<30 {
                let mid = (lo + hi) / 2
                let g = PointMap.whiteBalance(mid / 100)
                if (lit.x * g.x) / (lit.z * g.z) < 1 { lo = mid } else { hi = mid }
            }
            let warm = (lo + hi) / 2
            let g = PointMap.whiteBalance(warm / 100)
            let balanced = lit * g
            // Green against the mean of red and blue.
            let pink = log2(balanced.y / ((balanced.x + balanced.z) / 2)) / 0.42 * 100
            d[.temperature] = warm
            d[.tint] = pink
        }
    }
}
