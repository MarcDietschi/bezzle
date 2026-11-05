import Foundation

// Editing a design in the browser, the way the Mac's DocumentStore edits one: every change goes
// through the same steps after it (repeat grids, decks, components, styles, masks, notes, groups
// fitted), a drag is one gesture measured from where it began, and undo takes back only what was
// done here, leaving what others changed since (`FlatDesign.apply`). The page says what to do in
// JSON; the layers come back as JSON for it to pick, draw handles round and fill its inspector.

@MainActor
enum WebEditing {
    /// The design as the drag going on began.
    static var gestureStart: BezzleDocument?
    static var undos: [(before: BezzleDocument, after: BezzleDocument)] = []
    static var redos: [(before: BezzleDocument, after: BezzleDocument)] = []

    /// `change` made to `doc`, followed as DocumentStore.edit follows every change.
    static func edited(_ doc: BezzleDocument, start: BezzleDocument?, _ change: (inout BezzleDocument) -> Void) -> BezzleDocument {
        var next = doc
        change(&next)
        next.syncGrids(since: doc, start: start)
        next.syncDecks(since: doc)
        _ = next.syncComponents(since: doc, start: start)
        next.syncStyles(since: doc)
        next.keepMasks(since: doc)
        next.keepNotes(since: doc)
        next.fitGroups(since: doc)
        next.fitCarousels()
        return next
    }

    /// The edit asked for, on `doc`: one step of the history, or, inside a gesture, the gesture as
    /// it stands, made again from where it began.
    static func apply(_ ops: [[String: Any]], to doc: BezzleDocument) -> BezzleDocument {
        let base = gestureStart ?? doc
        let next = edited(base, start: gestureStart) { d in for op in ops { perform(op, on: &d) } }
        guard next != doc else { return doc }
        if gestureStart == nil { record(before: doc, after: next) }
        return next
    }

    static func begin(_ doc: BezzleDocument) { if gestureStart == nil { gestureStart = doc } }

    /// The gesture is done: cells settle, copies are made again, groups fit, and it is one step.
    static func end(_ doc: BezzleDocument) -> BezzleDocument {
        guard let start = gestureStart else { return doc }
        gestureStart = nil
        var settled = doc
        settled.relayoutGrids(since: start)
        settled.remakeCopies(since: doc)
        settled.fitGroups(since: doc)
        if settled != start { record(before: start, after: settled) }
        return settled
    }

    private static func record(before: BezzleDocument, after: BezzleDocument) {
        undos.append((before, after))
        if undos.count > 200 { undos.removeFirst() }
        redos = []
    }

    /// Takes back the last step done here; others' changes since stay.
    static func undo(_ now: BezzleDocument) -> BezzleDocument? {
        guard gestureStart == nil, let step = undos.popLast() else { return nil }
        let back = now == step.after ? step.before : FlatDesign.apply(from: step.after, to: step.before, onto: now)
        redos.append((before: back, after: now))
        return back
    }

    static func redo(_ now: BezzleDocument) -> BezzleDocument? {
        guard gestureStart == nil, let step = redos.popLast() else { return nil }
        let again = now == step.before ? step.after : FlatDesign.apply(from: step.before, to: step.after, onto: now)
        undos.append((now, again))
        return again
    }

    // MARK: What can be done

    private static func ids(_ op: [String: Any]) -> [UUID] {
        ((op["ids"] as? [String]) ?? (op["id"] as? String).map { [$0] } ?? []).compactMap(UUID.init(uuidString:))
    }

    private static func color(_ v: Any?) -> RGBA? {
        guard let c = v as? [Double], c.count >= 3 else { return nil }
        return RGBA(r: c[0], g: c[1], b: c[2], a: c.count > 3 ? c[3] : 1)
    }

    private static func number(_ v: Any?) -> CGFloat? { (v as? Double).map { CGFloat($0) } ?? (v as? Int).map { CGFloat($0) } }

    static func perform(_ op: [String: Any], on d: inout BezzleDocument) {
        switch op["op"] as? String {
        case "move":
            let dx = number(op["dx"]) ?? 0, dy = number(op["dy"]) ?? 0
            for id in ids(op) { d.update(id) { $0.frame.origin.x += dx; $0.frame.origin.y += dy } }
        case "frame":
            // A frame on the artboard's canvas, as the page measures it.
            guard let id = ids(op).first, let f = op["frame"] as? [Double], f.count == 4, let was = d.absoluteFrame(of: id) else { return }
            let to = CGRect(x: f[0], y: f[1], width: max(1, f[2]), height: max(1, f[3]))
            d.update(id) { n in
                n.frame = CGRect(x: n.frame.minX + to.minX - was.minX, y: n.frame.minY + to.minY - was.minY, width: to.width, height: to.height)
                if n.kind == .text, var style = n.style {
                    // As on the Mac: a text made wider wraps there; one given a height keeps it.
                    let wider = abs(to.width - was.width) > 0.01, taller = abs(to.height - was.height) > 0.01
                    if wider || taller { style.sizing = taller ? .fixed : .autoHeight }
                    n.style = style
                    n.refit()
                }
            }
        case "delete":
            for id in ids(op) { _ = d.detach(id) }
        case "text":
            guard let id = ids(op).first, let words = op["text"] as? String else { return }
            d.update(id) { n in
                guard n.kind == .text else { return }
                n.text = words
                n.spans = n.spans.flatMap { TextSpan.stored(TextSpan.aligned($0, onto: words)) }
                n.refit()
            }
        case "fill":
            guard let c = color(op["color"]) else { return }
            for id in ids(op) { d.update(id) { $0.fill.color = c; $0.fill.on = true; $0.fill.gradient = nil } }
        case "border":
            for id in ids(op) {
                d.update(id) { n in
                    if let c = color(op["color"]) { n.border.color = c }
                    if let w = number(op["width"]) { n.border.width = max(0, w) }
                    if let on = op["on"] as? Bool { n.border.on = on }
                }
            }
        case "opacity":
            guard let v = number(op["value"]) else { return }
            for id in ids(op) { d.update(id) { $0.opacity = Double(min(max(v, 0), 1)) } }
        case "radius":
            guard let v = number(op["value"]) else { return }
            for id in ids(op) { d.update(id) { $0.cornerRadius = max(0, v); $0.corners = nil } }
        case "font":
            for id in ids(op) {
                d.update(id) { n in
                    guard n.kind == .text, var style = n.style else { return }
                    if let family = op["family"] as? String { style.family = family }
                    if let face = op["face"] as? String { style.face = face }
                    if let size = number(op["size"]), size > 0 { style.size = size }
                    if let align = (op["align"] as? String).flatMap(TextAlign.init(rawValue:)) { style.align = align }
                    n.style = style
                    n.refit()
                }
            }
        case "note":
            // A new thread about a layer, at the middle of it, or about a spot on the artboard.
            guard let words = (op["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty,
                  let by = op["by"] as? String else { return }
            var note = MarginNote(text: words, by: by, replica: op["replica"] as? String, time: Date().timeIntervalSince1970)
            let layer = ids(op).first
            if let p = op["at"] as? [Double], p.count == 2 { note.put(at: CGPoint(x: p[0], y: p[1]), on: layer, in: d) }
            else if let layer, let f = d.absoluteFrame(of: layer) { note.put(at: CGPoint(x: f.midX, y: f.midY), on: layer, in: d) }
            d.notes = (d.notes ?? []) + [note]
        case "answer":
            guard let thread = (op["thread"] as? String).flatMap(UUID.init(uuidString:)),
                  d.notes?.contains(where: { $0.id == thread && $0.startsThread }) == true,
                  let words = (op["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty,
                  let by = op["by"] as? String else { return }
            d.notes = (d.notes ?? []) + [MarginNote(thread: thread, text: words, by: by, replica: op["replica"] as? String, time: Date().timeIntervalSince1970)]
        case "done":
            guard let thread = (op["thread"] as? String).flatMap(UUID.init(uuidString:)),
                  let i = d.notes?.firstIndex(where: { $0.id == thread && $0.startsThread }) else { return }
            d.notes?[i].done = (op["done"] as? Bool ?? true) ? true : nil
        default:
            break
        }
    }

    // MARK: What the page shows

    private static func rgba(_ c: RGBA) -> [Double] { [c.r, c.g, c.b, c.a] }

    /// The layers of the artboard at `index`, each before what it holds, with their frames on the
    /// artboard: for the page to pick, put handles round and show in its inspector.
    static func layers(of doc: BezzleDocument, board index: Int) -> [[String: Any]] {
        guard index >= 0, index < doc.nodes.count else { return [] }
        let board = doc.nodes[index]
        var out: [[String: Any]] = []
        func walk(_ nodes: [Node], parent: UUID?, origin: CGPoint, depth: Int) {
            for n in nodes {
                let f = n.frame.offsetBy(dx: origin.x, dy: origin.y)
                var o: [String: Any] = [
                    "id": n.id.uuidString, "name": n.name, "kind": n.kind.rawValue, "depth": depth,
                    "frame": [f.minX, f.minY, f.width, f.height], "rotation": n.rotation,
                    "hidden": n.hidden, "locked": n.locked, "container": n.isContainer,
                    "fill": rgba(n.fill.color), "fillOn": n.fill.on, "picture": n.fill.image != nil, "gradient": n.fill.gradient != nil,
                    "border": ["on": n.border.on, "color": rgba(n.border.color), "width": Double(n.border.width)],
                    "opacity": n.opacity, "radius": Double(n.cornerRadius), "copy": n.isCopy,
                ]
                if let parent { o["parent"] = parent.uuidString }
                if n.kind == .text, let style = n.style {
                    o["text"] = n.text ?? ""
                    o["style"] = ["family": style.family, "face": style.face, "size": Double(style.size), "align": style.align.rawValue, "sizing": style.sizing.rawValue]
                }
                out.append(o)
                walk(n.children, parent: n.id, origin: CGPoint(x: f.minX, y: f.minY), depth: depth + 1)
            }
        }
        walk(board.children, parent: nil, origin: .zero, depth: 0)
        return out
    }

    /// The design's notes, threads first in the order they were written, each with its answers.
    static func notes(of doc: BezzleDocument) -> [[String: Any]] {
        let all = doc.notes ?? []
        func one(_ n: MarginNote) -> [String: Any] {
            var o: [String: Any] = ["id": n.id.uuidString, "text": n.text, "by": n.by, "time": n.time, "done": n.isDone]
            if let r = n.replica { o["replica"] = r }
            if let on = n.on {
                o["on"] = on.uuidString
                if let board = doc.artboard(of: on) ?? doc.node(on).flatMap({ $0.isArtboard ? $0 : nil }) { o["board"] = board.id.uuidString }
            }
            return o
        }
        return all.filter(\.startsThread).sorted { $0.time < $1.time }.map { start in
            var o = one(start)
            o["answers"] = all.filter { $0.thread == start.id }.sorted { $0.time < $1.time }.map(one)
            return o
        }
    }
}
