#if DEBUG
import AppKit

/// Animate, driven by a test run (see `DebugHooks`):
///   BEZZLE_ANIMATE=seconds         animate the design
///   BEZZLE_FILM=t:step;t:step;…    at these times, one step each:
///       seek=1.5                   put the playhead there
///       play | pause | start       play from the playhead, stop, play from the start
///       pick=name,name | pick=camera   pick layers by name ("Artboard/name" on that artboard alone), or the camera
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
///       scrub=from,to,seconds      drag the playhead from one moment to the other and back, as a
///                                  hand on the timeline would, 120 times a second; how often the
///                                  app found the time to is written to BEZZLE_SCRUB_OUT (or the log)
///       watch=seconds              the same without moving the playhead, while the film plays
///       movie=path | movie=ask[:folder]   save the film as a movie there, or where the save panel
///                                  says (opened in a folder), as Save as Movie… does but without
///                                  showing it in the Finder; how it ended is written to
///                                  BEZZLE_MOVIE_OUT (or the log). A sandboxed copy can only be
///                                  checked with "ask": the panel is what lets it write there.
///       pinch=x,y:a,a,…            two fingers pinched at a point of the window, each step by so much
///                                  (0.2 a fifth closer, -0.2 a fifth further off), then lifted
///       tap2=x,y                   a double tap with two fingers there
///       wheel=x,y:dx,dy[:keys]     the wheel turned there once, with command, option, control or shift held
///       swipe=x,y:dx,dy:steps      two fingers moved there, by so much at each of so many steps, then lifted
///                                  These four go into the app's own queue of events made as the
///                                  window server makes them, so they arrive as a trackpad's do
///                                  wherever the app's events are listened to, as the timeline does.
///                                  They name no window, so no view is sent them: the canvas is not
///                                  reached this way.
///       timeline                   writes which part of the film the timeline shows, to
///                                  BEZZLE_SCRUB_OUT (or the log)
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

    /// Moves the playhead as a hand on the timeline does, at the pace of the screen's frames,
    /// and writes how often the app found the time to: each step waits for the one before.
    /// Without a `to`, it only watches, as the film plays.
    @MainActor private final class Scrubber {
        static var running: Scrubber?
        let store: DocumentStore
        let from: Double, to: Double?, seconds: Double
        var began = 0.0
        var steps: [Double] = []
        var timer: Timer?
        var pictures = 0, parts = 0

        init(_ store: DocumentStore, from: Double, to: Double?, seconds: Double) {
            self.store = store
            self.from = from
            self.to = to
            self.seconds = seconds
        }

        static func run(_ store: DocumentStore, from: Double, to: Double?, seconds: Double) {
            let s = Scrubber(store, from: from, to: to, seconds: seconds)
            running = s
            s.began = CACurrentMediaTime()
            s.pictures = store.canvas?.filmStage.picturesMade ?? 0
            s.parts = store.canvas?.filmStage.partsMade ?? 0
            let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { _ in MainActor.assumeIsolated { s.tick() } }
            RunLoop.main.add(timer, forMode: .common)
            s.timer = timer
        }

        func tick() {
            let now = CACurrentMediaTime()
            steps.append(now)
            let k = min((now - began) / seconds, 1)
            // There and back, as a hand goes.
            let u = k < 0.5 ? k * 2 : 2 - k * 2
            if let to { store.seek(from + (to - from) * u) }
            guard k >= 1 else { return }
            timer?.invalidate()
            Scrubber.running = nil
            var gaps: [Double] = []
            for i in 1..<steps.count { gaps.append((steps[i] - steps[i - 1]) * 1000) }
            let sorted = gaps.sorted()
            func at(_ q: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))] }
            let stage = store.canvas?.filmStage
            let line = String(format: (to == nil ? "watched: " : "scrubbed: ") + "steps %d in %.2f s, %.1f a second; gap ms p50 %.1f p90 %.1f p99 %.1f max %.1f; over 17 ms %d, over 34 ms %d; pictures %d, parts %d\n",
                              steps.count, now - began, Double(steps.count) / (now - began), at(0.5), at(0.9), at(0.99), sorted.last ?? 0,
                              gaps.filter { $0 > 17 }.count, gaps.filter { $0 > 34 }.count,
                              (stage?.picturesMade ?? 0) - pictures, (stage?.partsMade ?? 0) - parts)
            if let path = ProcessInfo.processInfo.environment["BEZZLE_SCRUB_OUT"], !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                let had = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (had + line).write(to: url, atomically: true, encoding: .utf8)
            } else {
                NSLog("%@", line)
            }
        }
    }

    private static func numbers(_ s: String) -> [Double] { s.split(separator: ",").compactMap { Double($0) } }

    // MARK: Two fingers and the wheel

    /// A point of the window, measured from its top left as a picture of it shows, where the
    /// window server would say it is: on the screens, counted from the top of the first.
    private static func onScreen(_ xy: [Double], _ store: DocumentStore) -> CGPoint? {
        guard xy.count == 2, let window = store.canvas?.window, let content = window.contentView, let first = NSScreen.screens.first else { return nil }
        let p = window.convertPoint(toScreen: CGPoint(x: xy[0], y: Double(content.bounds.height) - xy[1]))
        return CGPoint(x: p.x, y: first.frame.maxY - p.y)
    }

    /// Two fingers' doing as the window server tells an app of it: a pinch by so much, or a
    /// double tap. (The fields are the ones AppKit reads a pinch from; they have no public names.)
    private static func fingers(pinch: Double?, phase: Int64, at p: CGPoint) -> NSEvent? {
        guard let cg = CGEvent(source: nil), let gesture = CGEventType(rawValue: 29),
              let which = CGEventField(rawValue: 110), let amount = CGEventField(rawValue: 113), let stage = CGEventField(rawValue: 132) else { return nil }
        cg.type = gesture
        // 8 is a pinch, 22 a double tap with two fingers.
        cg.setIntegerValueField(which, value: pinch == nil ? 22 : 8)
        cg.setDoubleValueField(amount, value: pinch ?? 0)
        // 1 as they are put down, 2 as they move, 4 as they are lifted.
        cg.setIntegerValueField(stage, value: phase)
        cg.location = p
        return NSEvent(cgEvent: cg)
    }

    /// The wheel, or two fingers moving: by so many points, with keys held; `phase` as above for
    /// fingers, and 0 for a wheel, which has no beginning or end.
    private static func wheel(dx: Double, dy: Double, keys: String, phase: Int64, at p: CGPoint) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        var flags: CGEventFlags = []
        if keys.contains("command") { flags.insert(.maskCommand) }
        if keys.contains("option") { flags.insert(.maskAlternate) }
        if keys.contains("control") { flags.insert(.maskControl) }
        if keys.contains("shift") { flags.insert(.maskShift) }
        cg.flags = flags
        cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        cg.location = p
        return NSEvent(cgEvent: cg)
    }

    /// Sends events one after another, a frame apart, through the app's own queue.
    private static func send(_ events: [NSEvent?]) {
        Task { @MainActor in
            for event in events {
                if let event { NSApp.postEvent(event, atStart: false) }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private static func say(_ line: String) {
        if let path = ProcessInfo.processInfo.environment["BEZZLE_SCRUB_OUT"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let had = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (had + line + "\n").write(to: url, atomically: true, encoding: .utf8)
        } else {
            NSLog("%@", line)
        }
    }

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
                // "Artboard/Layer" picks only the layers of that name on that artboard.
                var picked: [UUID] = []
                for name in rest.split(separator: ",").map(String.init) {
                    let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
                    if parts.count == 2, let board = store.doc.nodes.first(where: { $0.isArtboard && $0.name == parts[0] }) {
                        func walk(_ nodes: [Node]) { for n in nodes { if n.name == parts[1] { picked.append(n.id) }; walk(n.children) } }
                        walk(board.children)
                    } else {
                        picked += store.doc.allNodes.filter { $0.name == name }.map(\.id)
                    }
                }
                store.selection = picked
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
        case "scrub":
            let n = numbers(rest)
            guard n.count == 3 else { return }
            Scrubber.run(store, from: n[0], to: n[1], seconds: n[2])
        case "watch": Scrubber.run(store, from: 0, to: nil, seconds: Double(rest) ?? 5)
        case "movie": movie(rest, store)
        case "pinch":
            guard fields.count == 2, let p = onScreen(numbers(fields[0]), store) else { return }
            let amounts = numbers(fields[1])
            send(amounts.enumerated().map { fingers(pinch: $0.element, phase: $0.offset == 0 ? 1 : 2, at: p) } + [fingers(pinch: 0, phase: 4, at: p)])
        case "tap2":
            guard let p = onScreen(numbers(rest), store) else { return }
            send([fingers(pinch: nil, phase: 0, at: p)])
        case "wheel":
            guard fields.count >= 2, let p = onScreen(numbers(fields[0]), store) else { return }
            let by = numbers(fields[1])
            guard by.count == 2 else { return }
            send([wheel(dx: by[0], dy: by[1], keys: fields.count > 2 ? fields[2] : "", phase: 0, at: p)])
        case "swipe":
            guard fields.count == 3, let p = onScreen(numbers(fields[0]), store), let steps = Int(fields[2]), steps > 0 else { return }
            let by = numbers(fields[1])
            guard by.count == 2 else { return }
            send((0..<steps).map { wheel(dx: by[0], dy: by[1], keys: "", phase: $0 == 0 ? 1 : 2, at: p) } + [wheel(dx: 0, dy: 0, keys: "", phase: 4, at: p)])
        case "timeline":
            let whole = store.filmWhole
            if let part = store.film.window?.fitted(to: whole) {
                say(String(format: "timeline: from %.3f s, %.3f s of %.3f; playhead %.3f", part.start, part.span, whole, store.filmTime))
            } else {
                say(String(format: "timeline: whole, %.3f s; playhead %.3f", whole, store.filmTime))
            }
        default: break
        }
    }

    /// Saves the film as a movie, as large and as quick as the render sheet is set, and writes
    /// how it ended.
    private static func movie(_ spec: String, _ store: DocumentStore) {
        func say(_ line: String) {
            if let path = ProcessInfo.processInfo.environment["BEZZLE_MOVIE_OUT"], !path.isEmpty {
                let url = URL(fileURLWithPath: path)
                let had = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                try? (had + line + "\n").write(to: url, atomically: true, encoding: .utf8)
            } else {
                NSLog("%@", line)
            }
        }
        guard let board = store.filmBoard else { return say("movie: no film") }
        let place: URL?
        if spec == "ask" || spec.hasPrefix("ask:") {
            let folder = spec.dropFirst(4)
            place = store.askFilmPlace(for: board, in: folder.isEmpty ? nil : URL(fileURLWithPath: String(folder), isDirectory: true))
        } else {
            place = URL(fileURLWithPath: spec)
        }
        guard let place else { return say("movie: nowhere") }
        let defaults = UserDefaults.standard
        let scale = defaults.object(forKey: "film.movie.scale") as? Int ?? 2, fps = defaults.object(forKey: "film.movie.fps") as? Int ?? 60
        let began = ContinuousClock.now
        let started = store.writeFilm(to: place, scale: CGFloat(scale), fps: fps) { failure in
            let took = began.duration(to: .now)
            say(failure.map { "movie: failed after \(took): \($0)" } ?? "movie: saved \(place.path) in \(took)")
        }
        if !started { say("movie: not started") }
    }
}
#endif
