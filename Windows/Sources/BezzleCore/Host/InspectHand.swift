import Foundation

// The design inspected on Windows, as the Mac's InspectTool (Canvas/InspectTool.swift) has it,
// measured with the shared `Inspect` (Model/Inspect.swift): it is read, never changed. The pointer
// finds the smallest thing under it; a click picks that, and a click on what is picked takes the
// next thing out, the group or screen it lies in, until the screen, and then back in. What is
// picked is drawn with its width and height as on a technical drawing; the pointer on anything
// else measures the way to it, in the pink the canvas gives gaps, and on the picked layer itself
// it measures how far that lies inside what a click would pick next, which is outlined dashed.

extension WindowsCore {
    @MainActor public final class InspectHand {
        /// The design being inspected: the canvas is read, never changed.
        public var on = false { didSet { if on != oldValue { hovered = nil; redraw() } } }
        public var selection: [UUID] = []
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        public var redraw: () -> Void = {}
        /// The artboard whose name is at a point on the stage.
        public var titleHit: (CGPoint) -> UUID? = { _ in nil }

        public init() {}

        private var doc: BezzleDocument? { WindowsCore.design }
        private func view(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        private func view(_ r: CGRect) -> CGRect {
            let a = view(r.origin)
            return CGRect(x: a.x, y: a.y, width: r.width * zoom, height: r.height * zoom)
        }

        // MARK: Finding things

        /// The smallest thing under a point on the stage: a layer, however deep in groups and
        /// copies; the screen where nothing else is; a screen by its name.
        public func deepest(at v: CGPoint) -> UUID? {
            if let t = titleHit(v) { return t }
            guard let seen = doc else { return nil }
            let p = CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom)
            let tolerance = 2 / zoom
            for n in seen.nodes.reversed() where !n.hidden {
                if n.isArtboard {
                    guard n.frame.contains(p) else { continue }
                    let local = CGPoint(x: p.x - n.frame.minX, y: p.y - n.frame.minY)
                    return Prototype.chain(at: local, in: n, tolerance: tolerance).first?.id ?? n.id
                }
                // Lying loose on the canvas.
                guard Geometry.contains(n, p, tolerance: tolerance) else { continue }
                if n.isGroup {
                    var loose = Node(kind: .artboard, name: "", frame: .zero)
                    loose.children = [n]
                    return Prototype.chain(at: p, in: loose, tolerance: tolerance).first?.id ?? n.id
                }
                return n.id
            }
            return nil
        }

        /// What a click on `d` picks: `d` itself, unless what is picked is `d` or holds it; then
        /// the next thing out from what is picked, and from the screen back to `d`.
        public func pick(for d: UUID) -> UUID {
            guard let seen = doc, selection.count == 1, let picked = selection.first else { return d }
            let chain = Inspect.path(of: d, in: seen).map(\.id)
            guard let i = chain.firstIndex(of: picked), i > 0 else { return d }
            return chain[i - 1]
        }

        /// Escape: the next thing out from what is picked, and from the screen nothing.
        public func climb() -> [UUID] {
            guard let seen = doc, selection.count == 1, let id = selection.first, let parent = seen.parent(of: id) else { return [] }
            return [parent.id]
        }

        // MARK: What is shown

        private enum Showing: Equatable {
            case none
            /// Nothing picked: what the pointer is on, and its size.
            case outline(UUID)
            /// The picked layer alone: its width and height.
            case size(UUID)
            /// From the picked layer to another.
            case between(UUID, UUID)
            /// The picked layer inside what a click would pick next.
            case around(UUID, UUID)
        }

        private var hovered: UUID?

        /// What is shown, as words: when it changes, the canvas grows the marks in anew, as the
        /// Mac's InspectTool does.
        public var shownKey: String { on ? "\(showing)" : "" }

        private var showing: Showing {
            guard let seen = doc else { return .none }
            let picked = selection.count == 1 ? selection.first.flatMap { seen.node($0) != nil ? $0 : nil } : nil
            guard let picked else { return hovered.map { .outline($0) } ?? .none }
            guard let h = hovered, h != picked || seen.node(picked)?.isArtboard == false else { return .size(picked) }
            let chain = Inspect.path(of: h, in: seen).map(\.id)
            if chain.contains(picked) {
                // On the picked layer: inside the next thing out, which a click would pick.
                if seen.node(picked)?.isArtboard == true { return h == picked ? .size(picked) : .between(h, picked) }
                let next = pick(for: h)
                return next == picked ? .size(picked) : .around(picked, next)
            }
            return .between(picked, h)
        }

        /// The pointer at rest on the stage, or gone; whether what shows changed.
        @discardableResult public func hover(_ v: CGPoint?) -> Bool {
            let h = v.flatMap { on ? deepest(at: $0) : nil }
            guard h != hovered else { return false }
            hovered = h
            redraw()
            return true
        }

        // MARK: What shows

        /// What the canvas draws, on the stage: outlines (in pencil, or the gaps' pink), lines
        /// drawn over a casing of white with their ticks, dashed lines where a measure reaches an
        /// edge past its end, hatched gaps, numbers on pills (solid, or white with an ink rim), and
        /// the name of what a click picks next over its top left.
        public struct Marks {
            public var outlines: [(rect: CGRect, gap: Bool, width: Double, dashed: Bool)] = []
            /// A measure's line, or a tick at its end (`tick`), which shows once the line is drawn out.
            public var lines: [(from: CGPoint, to: CGPoint, gap: Bool, tick: Bool)] = []
            public var dashes: [(from: CGPoint, to: CGPoint)] = []
            public var hatches: [CGRect] = []
            public var labels: [(text: String, at: CGPoint, gap: Bool, solid: Bool)] = []
            public var nameTag: (text: String, at: CGPoint, width: Double)?
        }

        public static func number(_ v: CGFloat) -> String {
            let r = (v * 10).rounded() / 10 + 0
            return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", Double(r))
        }

        /// How wide a number's pill is, as the canvas draws it: about 6.3 points a digit, and room.
        public static func labelWidth(_ text: String) -> Double { Double(text.count) * 6.3 + 10 }

        public func marks() -> Marks {
            var m = Marks()
            guard on, let seen = doc else { return m }
            func box(_ id: UUID) -> CGRect? { Inspect.box(of: id, in: seen).map(view) }
            switch showing {
            case .none:
                break
            case .outline(let id):
                guard let r = box(id) else { break }
                m.outlines.append((r, false, 1, false))
                let size = measured(id, in: seen)
                m.labels.append(("\(Self.number(size.width)) × \(Self.number(size.height))", CGPoint(x: r.midX.rounded(), y: (r.maxY + 13).rounded()), false, false))
            case .size(let id):
                guard let r = box(id) else { break }
                m.outlines.append((r, false, 1.5, false))
                dimensions(of: id, in: r, seen: seen, into: &m)
            case .around(let id, let next):
                guard let r = box(id), let o = box(next), let a = Inspect.box(of: id, in: seen), let b = Inspect.box(of: next, in: seen) else { break }
                m.outlines.append((o, false, 1, true))
                if seen.node(next)?.isArtboard == false, let name = seen.node(next)?.name, !name.isEmpty {
                    m.nameTag = (name, CGPoint(x: o.minX.rounded(), y: o.minY.rounded()), max(Double(o.width), 60))
                }
                m.outlines.append((r, false, 1.5, false))
                spans(Inspect.spans(from: a, to: b), into: &m)
            case .between(let id, let other):
                guard let r = box(id), let o = box(other), let a = Inspect.box(of: id, in: seen), let b = Inspect.box(of: other, in: seen) else { break }
                for gap in Inspect.gaps(between: a, and: b) { m.hatches.append(view(gap)) }
                m.outlines.append((o, true, 1, false))
                m.outlines.append((r, false, 1.5, false))
                spans(Inspect.spans(from: a, to: b), into: &m)
            }
            return m
        }

        /// A layer's size as it is measured: a turned layer as it is, not by the box it covers.
        private func measured(_ id: UUID, in seen: BezzleDocument) -> CGSize {
            guard let n = seen.node(id) else { return .zero }
            return n.isArtboard || n.rotation == 0 ? (Inspect.box(of: id, in: seen)?.size ?? n.frame.size) : n.frame.size
        }

        /// The distances, each a line in pink with a short tick at either end and its length in its
        /// middle; dashed where it meets an edge past its end; the number beside a line too short to hold it.
        private func spans(_ spans: [Inspect.Span], into m: inout Marks) {
            for s in spans {
                var a = view(s.from), b = view(s.to)
                if s.across { b.y = a.y } else { b.x = a.x }
                m.lines.append((a, b, true, false))
                for end in [a, b] {
                    if s.across {
                        m.lines.append((CGPoint(x: end.x, y: end.y - 3.5), CGPoint(x: end.x, y: end.y + 3.5), true, true))
                    } else {
                        m.lines.append((CGPoint(x: end.x - 3.5, y: end.y), CGPoint(x: end.x + 3.5, y: end.y), true, true))
                    }
                }
                if let reach = s.reach, reach.count == 2 {
                    let r0 = view(reach[0]), r1 = view(reach[1])
                    m.dashes.append(s.across ? (CGPoint(x: r0.x, y: r0.y), CGPoint(x: r1.x, y: b.y)) : (CGPoint(x: r0.x, y: r0.y), CGPoint(x: b.x, y: r1.y)))
                }
                let text = Self.number(s.length)
                let w = Self.labelWidth(text)
                var c = CGPoint(x: ((a.x + b.x) / 2).rounded(), y: ((a.y + b.y) / 2).rounded())
                let room = Double(s.across ? abs(b.x - a.x) : abs(b.y - a.y))
                if room < (s.across ? w : 17) + 6 {
                    if s.across { c.y -= 14 } else { c.x += CGFloat(w / 2 + 6) }
                }
                m.labels.append((text, c, true, true))
            }
        }

        /// The picked layer's width along its top and height down its right, as a drawing marks
        /// them: a line out from the edge with a tick at each end and the number in its middle.
        private func dimensions(of id: UUID, in r: CGRect, seen: BezzleDocument, into m: inout Marks) {
            let size = measured(id, in: seen)
            let top = r.minY - 12, right = r.maxX + 12
            if r.width > 30 {
                m.lines.append((CGPoint(x: r.minX, y: top), CGPoint(x: r.maxX, y: top), false, false))
                for x in [r.minX, r.maxX] { m.lines.append((CGPoint(x: x, y: top - 4), CGPoint(x: x, y: top + 4), false, true)) }
            }
            if r.height > 30 {
                m.lines.append((CGPoint(x: right, y: r.minY), CGPoint(x: right, y: r.maxY), false, false))
                for y in [r.minY, r.maxY] { m.lines.append((CGPoint(x: right - 4, y: y), CGPoint(x: right + 4, y: y), false, true)) }
            }
            let w = Self.number(size.width), h = Self.number(size.height)
            m.labels.append((w, CGPoint(x: r.midX.rounded(), y: (r.width > 30 ? top : r.minY - 14).rounded()), false, true))
            let hx = r.height > 30 ? Double(right) : Double(r.maxX) + 6 + Self.labelWidth(h) / 2
            m.labels.append((h, CGPoint(x: CGFloat(hx).rounded(), y: r.midY.rounded()), false, true))
        }
    }
}
