import Foundation
import WinUI
import UWP
import WindowsFoundation
import WinSDK
import BezzleCore

/// Animate, driven by a test run, as the Mac's AnimateHooks (Bezzle/App/AnimateHooks.swift) drives
/// it, for the first design a copy opens:
///   BEZZLE_ANIMATE=seconds         animate the design that long after its window opens
///   BEZZLE_FILM=t:step;t:step;…    at these times after it opens, one step each:
///       seek=1.5                   put the playhead there
///       play | pause | start       play from the playhead, stop, play from the start
///       pick=name,name | pick=camera   pick layers by name ("Artboard/name" on that artboard
///                                  alone), or the camera
///       scrub=from,to,seconds      drag the playhead on the timeline from one moment to the other
///                                  and back, as a hand does, a step with each frame of the screen;
///                                  with ",caught" after the seconds it catches on the keys it
///                                  passes, as a bare hand's does (else as with Ctrl held)
///       watch=seconds              the same without moving the playhead, while the film plays
///       mode=0…3                   Design, Prototype, Inspect or Animate
///       zoom=factor[,x]            look at the timeline that many times closer (under 1, from
///                                  further off) about a point of its sheet, x points from where
///                                  its lines begin (else its middle), as the wheel with Ctrl and
///                                  two fingers pinched do
///       along=points               move a timeline looked at closer along by so many points, the
///                                  way its moments go (under 0, later ones come into sight), as
///                                  the wheel with Shift and two fingers moved sideways do
///       whole                      show the whole film again, as two clicks on the stroke under
///                                  the lines do
///       pinch=factor               two fingers pinched on the middle of the film (over 1, apart):
///                                  the camera's zoom when the camera is picked, one step of
///                                  undo; writes whose it was, the camera's or the view's
///       timeline                   write which part of the film the timeline shows, and where
///                                  the playhead is
///   BEZZLE_SCRUB_OUT=<file>        where a scrub, a watch or `timeline` writes (else the trace,
///                                  BEZZLE_TRACE)
/// zoom, along and whole call what the wheel calls (`FilmHand.zoom`, `scroll`, `showWhole`), so a
/// run needs no touchpad. A film playing out of the part shown turns the page: the measure of a
/// watch counts each under `timeline.refresh(looked)`, once a page and never once a frame.
/// A scrub's line says how many steps the app found the time for a second, the gaps between them,
/// how long the steps themselves took on the main thread, and how much of the main thread's time
/// went on anything at all (its processor time over the time that passed).
@MainActor
enum AnimateHooks {
    private static var attached = false

    static func attach(_ session: DesignSession, film: FilmView) {
        guard !attached else { return }
        let env = ProcessInfo.processInfo.environment
        let animate = env["BEZZLE_ANIMATE"].flatMap(Double.init)
        let script = env["BEZZLE_FILM"]
        guard animate != nil || script != nil else { return }
        attached = true
        if let animate {
            DispatchQueue.main.asyncAfter(deadline: .now() + animate) { MainActor.assumeIsolated { session.mode = 3 } }
        }
        guard let script else { return }
        let steps = script.split(separator: ";").compactMap { part -> (Double, String)? in
            let bits = part.split(separator: ":", maxSplits: 1).map(String.init)
            guard bits.count == 2, let at = Double(bits[0]) else { return nil }
            return (at, bits[1])
        }.sorted { $0.0 < $1.0 }
        // One after another, in their order, each when its time has come.
        let began = WindowsCore.now
        func next(_ i: Int) {
            guard i < steps.count else { return }
            let wait = max(0, steps[i].0 - (WindowsCore.now - began))
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                MainActor.assumeIsolated {
                    run(steps[i].1, session, film)
                    next(i + 1)
                }
            }
        }
        next(0)
    }

    private static func numbers(_ s: String) -> [Double] { s.split(separator: ",").compactMap { Double($0) } }

    private static func run(_ step: String, _ session: DesignSession, _ film: FilmView) {
        let halves = step.split(separator: "=", maxSplits: 1).map(String.init)
        let word = halves[0], rest = halves.count > 1 ? halves[1] : ""
        let desk = session.film
        switch word {
        case "seek": desk.seek(Double(rest) ?? 0)
        case "play": desk.play()
        case "start": desk.play(fromStart: true)
        case "pause": desk.pause()
        case "mode": session.mode = Int(rest) ?? 0
        case "pick":
            if rest == "camera" {
                desk.pickCamera()
            } else {
                // "Artboard/Layer" picks only the layers of that name on that artboard.
                var picked: [UUID] = []
                for name in rest.split(separator: ",").map(String.init) {
                    let parts = name.split(separator: "/", maxSplits: 1).map(String.init)
                    for board in WindowsCore.boards() where parts.count == 1 || board.name == parts[0] {
                        picked += WindowsCore.layers(board: board.index).filter { $0.name == parts[parts.count - 1] }.map(\.id)
                    }
                }
                desk.select(picked)
            }
        case "scrub":
            let n = numbers(rest)
            guard n.count == 3 else { return }
            Scrubber.run(session, film, from: n[0], to: n[1], seconds: n[2], free: !rest.hasSuffix(",caught"))
        case "watch": Scrubber.run(session, film, from: 0, to: nil, seconds: Double(rest) ?? 5)
        case "zoom":
            let n = numbers(rest)
            guard let factor = n.first else { return }
            let hand = session.filmHand
            hand.zoom(by: factor, at: n.count > 1 ? n[1] : hand.width / 2)
        case "along":
            guard let points = Double(rest) else { return }
            session.filmHand.scroll(by: points)
        case "whole": session.filmHand.showWhole()
        case "pinch":
            // Two fingers on the film, as the wheel tells of them: in three goes, then no more.
            guard let factor = Double(rest), factor > 0, let at = session.motion.filmMiddle else { return }
            var camera = true
            for _ in 0..<3 { camera = session.motion.pinch(by: pow(factor, 1.0 / 3), at: at) && camera }
            session.motion.pinchEnded()
            say("pinch: \(camera ? "the camera's" : "the view's")\n")
        case "timeline":
            let whole = desk.filmWhole
            if let part = desk.shownPart {
                say(String(format: "timeline: from %.3f s, %.3f s of %.3f; playhead %.3f\n", part.start, part.span, whole, desk.filmTime))
            } else {
                say(String(format: "timeline: whole, %.3f s; playhead %.3f\n", whole, desk.filmTime))
            }
        default: break
        }
    }

    /// A line for whoever drives the run: after what `BEZZLE_SCRUB_OUT` holds, or into the trace.
    private static func say(_ line: String) {
        if let path = ProcessInfo.processInfo.environment["BEZZLE_SCRUB_OUT"], !path.isEmpty {
            let url = URL(fileURLWithPath: path)
            let had = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            try? (had + line).write(to: url, atomically: true, encoding: .utf8)
        } else {
            Trace.say(line)
        }
    }

    /// Moves the playhead as a hand on the timeline does, with each frame of the screen, and
    /// writes how often the app found the time to: each step waits for the one before. Without a
    /// `to`, it only watches, as the film plays.
    @MainActor private final class Scrubber {
        static var running: Scrubber?
        let session: DesignSession
        let film: FilmView
        let from: Double, to: Double?, seconds: Double
        var free = true
        var began = 0.0
        var steps: [Double] = []
        var busy: [Double] = []
        var cpu = 0.0
        var pictures = 0, parts = 0
        var ticking: EventCleanup?
        var pressedAt: BezzleCore.CGFloat = 0

        init(_ session: DesignSession, _ film: FilmView, from: Double, to: Double?, seconds: Double) {
            self.session = session
            self.film = film
            self.from = from
            self.to = to
            self.seconds = seconds
        }

        /// The processor time the main thread has had, in seconds.
        static var mainThreadTime: Double {
            var made = FILETIME(), ended = FILETIME(), kernel = FILETIME(), user = FILETIME()
            guard GetThreadTimes(GetCurrentThread(), &made, &ended, &kernel, &user) else { return 0 }
            func seconds(_ f: FILETIME) -> Double { Double(UInt64(f.dwHighDateTime) << 32 | UInt64(f.dwLowDateTime)) / 10_000_000 }
            return seconds(kernel) + seconds(user)
        }

        static func run(_ session: DesignSession, _ film: FilmView, from: Double, to: Double?, seconds: Double, free: Bool = true) {
            guard running == nil else { return }
            let s = Scrubber(session, film, from: from, to: to, seconds: seconds)
            s.free = free
            running = s
            s.pictures = film.picturesMade
            s.parts = film.partsMade
            if to != nil {
                // Pressed on the ruler where the playhead goes first, as a hand would.
                let hand = session.filmHand
                s.pressedAt = hand.x(from)
                hand.pressRuler(at: BezzleCore.CGPoint(x: s.pressedAt, y: 12))
            }
            s.began = WindowsCore.now
            s.cpu = mainThreadTime
            Probe.begin()
            s.ticking = CompositionTarget.rendering.addHandler { _, _ in
                MainActor.assumeIsolated { s.tick() }
            }
        }

        func tick() {
            let now = WindowsCore.now
            steps.append(now)
            let k = min((now - began) / seconds, 1)
            // There and back, as a hand goes.
            let u = k < 0.5 ? k * 2 : 2 - k * 2
            if let to {
                let hand = session.filmHand
                let x = hand.x(from + (to - from) * u)
                let start = WindowsCore.now
                // Ctrl held: every step a moment of its own, caught on nothing.
                hand.dragged(to: BezzleCore.CGPoint(x: x, y: 12), by: x - pressedAt, free: free)
                busy.append((WindowsCore.now - start) * 1000)
            }
            guard k >= 1 else { return }
            ticking?.dispose()
            ticking = nil
            Scrubber.running = nil
            let costs = Probe.end(over: now - began)
            if to != nil { session.filmHand.ended() }
            let spent = Scrubber.mainThreadTime - cpu, took = now - began
            var gaps: [Double] = []
            for i in 1..<max(steps.count, 1) { gaps.append((steps[i] - steps[i - 1]) * 1000) }
            let sorted = gaps.sorted(), work = busy.sorted()
            func at(_ list: [Double], _ q: Double) -> Double { list.isEmpty ? 0 : list[min(list.count - 1, Int(Double(list.count) * q))] }
            var line = String(format: (to == nil ? "watched: " : "scrubbed: ")
                + "steps %d in %.2f s, %.1f a second; gap ms p50 %.1f p90 %.1f p99 %.1f max %.1f; over 17 ms %d, over 34 ms %d; "
                + "step ms p50 %.1f p90 %.1f max %.1f; main thread busy %.0f %%; pictures %d, parts %d\n",
                steps.count, took, Double(steps.count) / max(took, 1e-6), at(sorted, 0.5), at(sorted, 0.9), at(sorted, 0.99), sorted.last ?? 0,
                gaps.filter { $0 > 17 }.count, gaps.filter { $0 > 34 }.count,
                at(work, 0.5), at(work, 0.9), work.last ?? 0, spent / max(took, 1e-6) * 100,
                film.picturesMade - pictures, film.partsMade - parts)
            line += costs
            AnimateHooks.say(line)
        }
    }
}
