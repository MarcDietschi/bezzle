import Foundation
import WinUI
import WindowsFoundation
import BezzleCore

/// The Mac's motion for WinUI, which has none of SwiftUI's: its springs (Views/Theme.swift) as the
/// stiffness and damping a `DeckSpring` steps by, its timing curves, and a ticker that steps them
/// once a frame while they move.
@MainActor
enum Motion {
    /// A SwiftUI spring, its response in seconds and its damping fraction, as stiffness and damping.
    static func spring(response: Double, damping fraction: Double) -> (stiffness: Double, damping: Double) {
        let w = 2 * Double.pi / response
        return (w * w, 2 * fraction * w)
    }

    /// Theme.spring: response 0.34 s, damping 0.86.
    static let spring = spring(response: 0.34, damping: 0.86)
    /// Theme.quick: response 0.18 s, damping 0.9.
    static let quick = spring(response: 0.18, damping: 0.9)
    /// Theme.menu, what a menu opens with: response 0.26 s, damping 0.74.
    static let menu = spring(response: 0.26, damping: 0.74)

    /// SwiftUI's curves, cubic Béziers from nought to one: easeIn (0.42, 0, 1, 1), easeOut
    /// (0, 0, 0.58, 1), easeInOut (0.42, 0, 0.58, 1); `t` from 0 to 1.
    static func easeIn(_ t: Double) -> Double { bezier(t, 0.42, 0, 1, 1) }
    static func easeOut(_ t: Double) -> Double { bezier(t, 0, 0, 0.58, 1) }
    static func easeInOut(_ t: Double) -> Double { bezier(t, 0.42, 0, 0.58, 1) }

    private static func bezier(_ t: Double, _ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double) -> Double {
        let x = min(max(t, 0), 1)
        func at(_ s: Double, _ a: Double, _ b: Double) -> Double { 3 * a * s * (1 - s) * (1 - s) + 3 * b * s * s * (1 - s) + s * s * s }
        // The curve's own parameter where it is `x` across, by halving.
        var lo = 0.0, hi = 1.0, s = x
        for _ in 0..<24 {
            s = (lo + hi) / 2
            if at(s, x1, x2) < x { lo = s } else { hi = s }
        }
        return at(s, y1, y2)
    }

    /// For looking at the motion frame by frame: `BEZZLE_SLOW=8` plays it eight times slower.
    static let slow: Double = ProcessInfo.processInfo.environment["BEZZLE_SLOW"].flatMap(Double.init).map { max($0, 1) } ?? 1

    /// Calls `step` with the time since the frame before (slowed as asked), once a frame, while it
    /// answers true; `start` again after it stops.
    @MainActor final class Ticker {
        private let step: (Double) -> Bool
        private var ticking: EventCleanup?
        private var last = 0.0

        init(_ step: @escaping (Double) -> Bool) { self.step = step }

        var running: Bool { ticking != nil }

        func start() {
            guard ticking == nil else { return }
            last = WindowsCore.now
            ticking = CompositionTarget.rendering.addHandler { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let now = WindowsCore.now
                    let dt = min(max(now - self.last, 1.0 / 240), 1.0 / 20) / Motion.slow
                    self.last = now
                    if !self.step(dt) { self.stop() }
                }
            }
        }

        func stop() {
            ticking?.dispose()
            ticking = nil
        }
    }
}
