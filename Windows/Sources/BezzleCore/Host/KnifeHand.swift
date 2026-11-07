import Foundation
import WinSDK

// The knife on Windows: the shared Knife (Model/Knife.swift), as the Mac's canvas uses it, its
// host the open design, cutting with the shared `cuts` and `cut` (Model/Cutting.swift).

extension WindowsCore {
    @MainActor public final class KnifeHand: KnifeHost {
        public var knifeInHand = false
        /// What is selected, which the knife cuts first, and the pieces it made.
        public var selection: [Foundation.UUID] = []
        public var zoom: CGFloat = 1
        public var pan: CGPoint = .zero
        private lazy var knife = Knife(host: self)

        public init() {}

        public var redraw: () -> Void {
            get { knife.redraw }
            set { knife.redraw = newValue }
        }

        func toView(_ p: CGPoint) -> CGPoint { CGPoint(x: pan.x + p.x * zoom, y: pan.y + p.y * zoom) }
        func toCanvas(_ v: CGPoint) -> CGPoint { CGPoint(x: (v.x - pan.x) / zoom, y: (v.y - pan.y) / zoom) }

        func cut(along line: CGPath) -> Bool {
            guard let doc = WindowsCore.design else { return false }
            let cuts = doc.cuts(along: line, selection: selection)
            guard !cuts.isEmpty else { return false }
            var made: [Foundation.UUID] = []
            WindowsCore.edit { made = $0.cut(cuts) }
            selection = made
            return true
        }

        func refuse() { _ = MessageBeep(UInt32(MB_OK)) }

        private func flags(_ shift: Bool, _ option: Bool, _ command: Bool) -> PenFlags {
            var f: PenFlags = []
            if shift { f.insert(.shift) }
            if option { f.insert(.option) }
            if command { f.insert(.command) }
            return f
        }

        public var dragging: Bool { knife.dragging }
        public func down(at v: CGPoint, shift: Bool, clicks: Int) { knife.down(at: v, flags: flags(shift, false, false), clicks: clicks) }
        public func drag(to v: CGPoint, shift: Bool) { knife.drag(to: v, flags: flags(shift, false, false)) }
        public func up(at v: CGPoint) { knife.up(at: v) }
        public func hover(_ v: CGPoint?, shift: Bool) { knife.hover(v, flags: flags(shift, false, false)) }

        /// escape, enter or delete.
        public func key(_ name: String) -> Bool {
            let key: PenKey = switch name {
            case "escape": .escape
            case "enter": .enter
            case "delete": .delete
            default: .other
            }
            return knife.key(key)
        }

        /// The blade on the stage (view points): its line as path data, and its points, the newest filled.
        public func blade() -> (path: String, anchors: [(point: CGPoint, newest: Bool)])? {
            guard let (path, anchors) = knife.blade() else { return nil }
            var t = CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: pan.x, ty: pan.y)
            guard let placed = path.copy(using: &t) else { return nil }
            return (PathData.string(placed), anchors.map { (toView($0.point), $0.newest) })
        }
    }
}

extension WindowsCore {
    /// What a straight cut from `a` to `b` on the canvas does, in words: for trying the knife without a window.
    public static func debugCut(from a: CGPoint, to b: CGPoint) -> String {
        guard let doc = design else { return "no design" }
        let line = CGMutablePath()
        line.move(to: a)
        line.addLine(to: b)
        var said: [String] = []
        for n in doc.allNodes where BezzleDocument.cuttable.contains(n.kind) {
            let outline = doc.outline(of: n.id)
            let parts = outline.flatMap { Outlines.cut($0, along: line) }
            said.append("\(n.name): outline \(outline.map { "\($0.boundingBoxOfPath)" } ?? "none"), parts \(parts?.count ?? 0)")
        }
        let cuts = doc.cuts(along: line, selection: [])
        said.append("cuts: \(cuts.count)")
        if let (id, parts) = cuts.first, let n = doc.node(id) {
            let o = doc.parentOrigin(of: id)
            said.append("as path: \(n.asPath() != nil), reshaped: \(parts.map { n.reshaped(to: $0, origin: o) != nil }), holder: \(doc.parent(of: id)?.holder?.id == id)")
        }
        var made: [Foundation.UUID] = []
        if !cuts.isEmpty { WindowsCore.edit { made = $0.cut(cuts) } }
        said.append("made \(made.count)")
        return said.joined(separator: "\n")
    }
}

