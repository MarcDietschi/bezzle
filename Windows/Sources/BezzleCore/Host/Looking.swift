import Foundation

// Looking at an artboard's scene from the side on Windows, as the Mac's DocumentStore.looks and
// its LookTool have it (Canvas/LookTool.swift). What that is the shared DepthLook says
// (Model/DepthLooking.swift): the eye is moved aside and the page stays where it is. The look is
// the open design's own, kept here beside it and handed to it (`BezzleDocument.looks`), so that
// everything on the canvas that asks the design where a layer shows is given the moved eye. It is
// never a step of the history, never saved, and only while designing.

extension WindowsCore {
    /// From where each artboard's scene is looked at for now, when not from the front, by the
    /// artboard's id. One of the values an open design keeps in the core (`visitState`); the
    /// design is handed it whenever it is set (`design`).
    nonisolated(unsafe) static var sceneLooks: [UUID: DepthLook] = [:]

    /// Looks at an artboard's scene from the side, or from the front again with nil. Whether
    /// that changed how it is looked at.
    @discardableResult
    static func look(at board: UUID, from look: DepthLook?) -> Bool {
        var next = sceneLooks
        if let look, !look.isFront, design?.node(board)?.isArtboard == true { next[board] = look.held } else { next[board] = nil }
        guard next != sceneLooks else { return false }
        sceneLooks = next
        design?.looks = next.isEmpty ? nil : next
        return true
    }

    /// Looks at the artboard with this id from `across` degrees to the right of straight in
    /// front and `down` degrees below it, no further round than sixty; from the front again when
    /// both are nought. Whether that changed how it is looked at.
    @discardableResult
    public static func look(at board: UUID, across: Double, down: Double) -> Bool {
        look(at: board, from: DepthLook(across: across, down: down))
    }

    /// From where an artboard is looked at: nil from the front.
    public static func look(of board: UUID) -> (across: Double, down: Double)? {
        sceneLooks[board].map { ($0.across, $0.down) }
    }

    /// Every artboard from the front again. Whether any was looked at from the side.
    @discardableResult
    public static func lookFromTheFront() -> Bool {
        guard !sceneLooks.isEmpty else { return false }
        sceneLooks = [:]
        design?.looks = nil
        return true
    }

    /// Whether any artboard is looked at from the side.
    public static var lookingFromTheSide: Bool { !sceneLooks.isEmpty }

    /// An artboard as the canvas shows it, `scale` pixels to the point, or only `part` of it:
    /// from where it is looked at for now. The canvas alone draws so; whatever leaves it (a
    /// picture exported, a film, a thumbnail, what an AI assistant is shown) is from the front.
    static func picture(of board: Node, part: CGRect?, scale: CGFloat) -> CGImage? {
        guard sceneLooks[board.id] != nil else { return Renderer.image(of: board, part: part, scale: scale, assets: assets) }
        var options = Renderer.Options(deviceScale: scale, assets: assets)
        options.looks = sceneLooks
        return Renderer.tile(of: board, rect: part ?? board.frame, scale: scale, options: options)
    }

    /// The Mac's LookTool for the Windows canvas. Alt held, a drag that begins on nothing, beside
    /// the layers, takes the scene of the artboard under the pointer and turns the look with it:
    /// what is held up off the page goes with the pointer, Shift in fives. A click there with
    /// Alt looks from the front again. While an artboard is looked at from the side a post
    /// stands under each corner of what is off the page (of what is picked alone, when some of
    /// it is), and a word by its top right corner looks from the front again. The canvas hands
    /// it the pointer and draws what `marks` says shows.
    @MainActor public final class LookHand {
        /// Where the canvas is on screen: a canvas point `p` is at `pan + p · zoom`.
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        /// The artboard being worked on, by its place in the design: looked at when the press
        /// is on none.
        public var focused: Int?
        private var held: (board: UUID, from: DepthLook?, start: CGPoint, moved: Bool)?

        public init() {}

        public var dragging: Bool { held != nil }
        /// The artboard whose look is in hand.
        public var board: UUID? { held?.board }

        private func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        private func toCanvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }

        /// Alt pressed on nothing, at `v` on the stage: takes the look of the artboard there, or
        /// of the one being worked on. False with no artboard to look at.
        public func down(at v: CGPoint) -> Bool {
            guard let doc = WindowsCore.design else { return false }
            let worked = focused.flatMap { doc.nodes.indices.contains($0) && doc.nodes[$0].isArtboard ? doc.nodes[$0] : nil }
            guard let board = doc.artboard(at: toCanvas(v)) ?? worked, !board.hidden else { return false }
            held = (board.id, WindowsCore.sceneLooks[board.id], v, false)
            return true
        }

        /// The drag goes on to `v`, `steps` (Shift) in fives. Whether the artboard is looked at
        /// from elsewhere now, for the canvas to draw it again.
        @discardableResult
        public func drag(to v: CGPoint, steps: Bool) -> Bool {
            guard var d = held else { return false }
            let by = CGPoint(x: v.x - d.start.x, y: v.y - d.start.y)
            if !d.moved, hypot(by.x, by.y) < 3 { return false }
            d.moved = true
            held = d
            let look = (d.from ?? .front).dragged(by: by, steps: steps)
            let changed = WindowsCore.look(at: d.board, from: look)
            WindowsCore.measure = (Self.words(look), CGRect(origin: toCanvas(CGPoint(x: v.x, y: v.y + 14)), size: .zero))
            return changed
        }

        /// The press is let go. A click, nothing dragged, looks from the front again. Whether
        /// the artboard is looked at from elsewhere now.
        @discardableResult
        public func up() -> Bool {
            guard let d = held else { return false }
            held = nil
            WindowsCore.measure = nil
            return d.moved ? false : WindowsCore.look(at: d.board, from: nil)
        }

        /// Escape during the drag: looked at as before it.
        @discardableResult
        public func cancel() -> Bool {
            guard let d = held else { return false }
            held = nil
            WindowsCore.measure = nil
            return WindowsCore.look(at: d.board, from: d.from)
        }

        /// From which side, and how far round: an arrow for the side the eye stands on.
        static func words(_ look: DepthLook) -> String {
            var parts: [String] = []
            if look.across != 0 { parts.append("\(look.across > 0 ? "→" : "←") \(Int(abs(look.across).rounded()))°") }
            if look.down != 0 { parts.append("\(look.down > 0 ? "↓" : "↑") \(Int(abs(look.down).rounded()))°") }
            return parts.isEmpty ? "0°" : parts.joined(separator: "  ")
        }

        /// What shows while artboards are looked at from the side, on the stage.
        public struct Marks {
            /// A post under each corner of what stands off the page: from where the corner would
            /// lie in the page, its foot, to where it shows.
            public var posts: [(foot: CGPoint, top: CGPoint)] = []
            /// The artboards looked at from the side, each with its frame: the word that looks
            /// from the front again stands by its top right corner (`wordRect`).
            public var boards: [(id: UUID, frame: CGRect)] = []
        }

        /// The posts and the artboards that have a word, with `selection` picked, on a stage
        /// `size` big. Nothing while every artboard is looked at from the front.
        public func marks(selection: [UUID], size: CGSize) -> Marks {
            var marks = Marks()
            // A deck as it is seen: the post in front.
            guard !WindowsCore.sceneLooks.isEmpty, let doc = WindowsCore.seen ?? WindowsCore.design else { return marks }
            let view = CGRect(origin: .zero, size: size)
            func onStage(_ r: CGRect) -> CGRect {
                let a = toView(r.origin)
                return CGRect(x: a.x, y: a.y, width: r.width * zoom, height: r.height * zoom)
            }
            for board in doc.artboards where !board.hidden && doc.looks?[board.id] != nil {
                let frame = onStage(board.frame)
                if frame.intersects(view) { marks.boards.append((board.id, frame)) }
                guard frame.insetBy(dx: -400, dy: -400).intersects(view) else { continue }
                for post in doc.posts(of: board, picked: Set(selection)) {
                    marks.posts.append((toView(post.foot), toView(post.top)))
                }
            }
            return marks
        }

        /// Where the word stands for an artboard whose frame on the stage is `frame`: by its top
        /// right corner, in the line its name is in, and inside `view` while any of the artboard
        /// is. `width` is how wide the words themselves are.
        public static func wordRect(by frame: CGRect, words width: CGFloat, in view: CGRect) -> CGRect {
            let size = CGSize(width: width.rounded(.up) + 20, height: 20)
            var origin = CGPoint(x: (frame.maxX - size.width).rounded(), y: (frame.minY - size.height - 5).rounded())
            origin.x = min(max(origin.x, view.minX + 8), view.maxX - size.width - 8)
            origin.y = min(max(origin.y, view.minY + 8), view.maxY - size.height - 8)
            return CGRect(origin: origin, size: size)
        }
    }
}
