#if DEBUG
import AppKit

/// Animate, driven by a test run (see `DebugHooks`):
///   BEZZLE_ANIMATE=seconds         animate the design
///   BEZZLE_FILM=t:step;t:step;…    at these times, one step each:
///       seek=1.5                   put the playhead there
///       play | pause | start       play from the playhead, stop, play from the start
///       pick=name,name | pick=camera   pick layers by name, or the camera
///       pose=property:v[,v]        pose what is picked at the playhead (move, scale, turn, fade, lift,
///                                  tilt, swing, blur; cameraMove, cameraZoom, cameraRoll, cameraTilt, cameraSwing)
///       key=name:property:t:v[,v][:pace]   set one key exactly (name "camera" for the camera)
///       move=rise[:going]          give what is picked a ready-made move at the playhead
///       apart=0.08                 how far apart several layers are given it
///       length=4 | once=1          the film's own settings
///       clear                      take all motion from what is picked
///       fly                        fly the camera to what is picked
///       press=x,y | press=x,y>x,y  press the window at a point measured from its top left, as a
///                                  picture of it shows, and let go, or drag to another first. The
///                                  view under the point is told directly, so the pointer stays
///                                  where it is and the window where it lies.
enum AnimateHooks {
    static func attach(_ store: DocumentStore, env: [String: String], after: (Double, @escaping @MainActor () -> Void) -> Void) {
        if let s = env["BEZZLE_ANIMATE"].flatMap(Double.init) { after(s) { store.animating = true } }
        guard let script = env["BEZZLE_FILM"] else { return }
        let steps = script.split(separator: ";").compactMap { part -> (Double, String)? in
            let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard bits.count == 2, let at = Double(bits[0]) else { return nil }
            return (at, bits[1])
        }.sorted { $0.0 < $1.0 }
        // One after another, in their order: sleeps of their own come back when the system
        // likes, and a step would overtake the one before it.
        Task { @MainActor in
            let began = ContinuousClock.now
            for (at, step) in steps {
                try? await Task.sleep(until: began + .seconds(at), tolerance: .milliseconds(5))
                run(step, store)
            }
        }
    }

    private static func press(_ spec: String, _ store: DocumentStore) {
        guard let window = store.canvas?.window, let content = window.contentView else { return }
        let tall = Double(content.bounds.height)
        var ends: [CGPoint] = []
        for part in spec.split(separator: ">") {
            let xy = numbers(String(part))
            if xy.count == 2 { ends.append(CGPoint(x: xy[0], y: tall - xy[1])) }
        }
        // Asked of the window's frame view, as the window itself asks: in the window's own points.
        guard let from = ends.first, let view = (content.superview ?? content).hitTest(from) else { return }
        let to = ends.count > 1 ? ends[1] : from
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        }
        if let e = event(.leftMouseDown, from) { view.mouseDown(with: e) }
        Task { @MainActor in
            if to != from {
                for i in 1...10 {
                    try? await Task.sleep(for: .milliseconds(24))
                    let k = Double(i) / 10
                    if let e = event(.leftMouseDragged, CGPoint(x: from.x + (to.x - from.x) * k, y: from.y + (to.y - from.y) * k)) { view.mouseDragged(with: e) }
                }
            }
            try? await Task.sleep(for: .milliseconds(40))
            if let e = event(.leftMouseUp, to) { view.mouseUp(with: e) }
        }
    }

    private static func numbers(_ s: String) -> [Double] { s.split(separator: ",").compactMap { Double($0) } }

    private static func run(_ step: String, _ store: DocumentStore) {
        let halves = step.split(separator: "=", maxSplits: 1).map(String.init)
        let word = halves[0], rest = halves.count > 1 ? halves[1] : ""
        let fields = rest.split(separator: ":").map(String.init)
        switch word {
        case "seek": store.seek(Double(rest) ?? 0)
        case "play": store.playFilm()
        case "start": store.playFilm(fromStart: true)
        case "pause": store.pauseFilm()
        case "pick":
            if rest == "camera" {
                store.pickCamera()
            } else {
                let wanted = rest.split(separator: ",").map(String.init)
                store.selection = store.doc.allNodes.filter { wanted.contains($0.name) }.map(\.id)
            }
        case "pose":
            guard fields.count == 2, let property = MotionProperty(rawValue: fields[0]) else { return }
            if property.isCamera { store.poseCamera(property, numbers(fields[1])) } else { store.pose(property, of: store.posedLayers) { _ in numbers(fields[1]) } }
        case "key":
            guard fields.count >= 4, let property = MotionProperty(rawValue: fields[1]), let t = Double(fields[2]) else { return }
            let ease = fields.count > 4 ? MotionEase.Kind(rawValue: fields[4]).map { MotionEase(kind: $0, bounce: $0 == .spring ? 0.3 : nil) } : nil
            let ids = fields[0] == "camera" ? [store.filmBoard?.id].compactMap { $0 } : store.doc.allNodes.filter { $0.name == fields[0] }.map(\.id)
            store.edit("Add Key") { doc in
                for id in ids { doc.update(id) { $0.setKey(property, numbers(fields[3]), at: t, ease: ease) } }
            }
        case "move":
            guard let move = MotionMove(rawValue: fields.first ?? "") else { return }
            store.film.going = fields.count > 1 && fields[1] == "going"
            store.applyMove(move)
        case "apart": store.film.apart = Double(rest) ?? 0
        case "length": store.setFilm("Film Length") { $0.length = Double(rest) }
        case "once": store.setFilm("Play Once") { $0.once = rest == "1" ? true : nil }
        case "clear": store.clearFilmMotion()
        case "fly": store.flyCamera(to: store.posedLayers)
        case "press": press(rest, store)
        default: break
        }
    }
}
#endif
