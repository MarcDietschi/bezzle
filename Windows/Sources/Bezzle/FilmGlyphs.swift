import Foundation
import WinUI
import BezzleCore

/// Animate's small drawings, as the Mac draws them (Views/FilmTimeline.swift's CameraGlyph,
/// AnimateInspector.swift's CascadeGlyph, PoseGlyph and ReelGlyph, the repeat arrow), in the same
/// hand as the other glyphs.
extension Glyphs {
    /// The camera: a body with its lens, and the finder on top.
    static func camera(size s: Double = 15) -> [Part] {
        var body = PathData()
        body.rect(s * 0.1, s * 0.3, s * 0.8, s * 0.52, radius: 2)
        var lens = PathData()
        let c = (s * 0.5, s * 0.56), r = s * 0.14
        lens.move(c.0 + r, c.1)
        for k in 1...20 {
            let a = Double(k) / 20 * 2 * Double.pi
            lens.line(c.0 + r * cos(a), c.1 + r * sin(a))
        }
        var finder = PathData()
        finder.move(s * 0.36, s * 0.3); finder.line(s * 0.42, s * 0.17); finder.line(s * 0.58, s * 0.17); finder.line(s * 0.64, s * 0.3)
        return [Part(data: body.d, mode: .stroke, width: 1.3), Part(data: lens.d, mode: .stroke, width: 1.3), Part(data: finder.d, mode: .stroke, width: 1.3)]
    }

    /// Three strokes set in one after another, for moves.
    static func cascade(size s: Double = 18) -> [Part] {
        var p = PathData()
        for i in 0..<3 {
            let y = s * (0.3 + 0.2 * Double(i))
            p.move(s * (0.2 + 0.14 * Double(i)), y)
            p.line(s * (0.56 + 0.14 * Double(i)), y)
        }
        return [Part(data: p.d, mode: .stroke, width: 1.5)]
    }

    /// A layer away from where it belongs: its place dashed, and itself moved off it.
    static func pose(size s: Double = 18) -> [Part] {
        var home = PathData()
        home.rect(s * 0.14, s * 0.36, s * 0.5, s * 0.44, radius: 2)
        var away = PathData()
        away.rect(s * 0.38, s * 0.16, s * 0.5, s * 0.44, radius: 2)
        return [Part(data: home.d, mode: .stroke, width: 1.1, round: false), Part(data: away.d, mode: .cover, width: 1.4)]
    }

    /// A frame of film, for the film's own card.
    static func reel(size s: Double = 18) -> [Part] {
        var frame = PathData()
        frame.rect(s * 0.12, s * 0.24, s * 0.76, s * 0.52, radius: 2.5)
        var play = PathData()
        play.move(s * 0.42, s * 0.38); play.line(s * 0.62, s * 0.5); play.line(s * 0.42, s * 0.62); play.close()
        return [Part(data: frame.d, mode: .stroke, width: 1.3), Part(data: play.d, mode: .fill)]
    }

    /// An arrow that comes back to where it set off: a film that goes round.
    static func loop(size s: Double = 14) -> [Part] {
        var p = PathData()
        p.move(s * 0.22, s * 0.62); p.line(s * 0.22, s * 0.44)
        p.quad(s * 0.22, s * 0.3, s * 0.38, s * 0.3); p.line(s * 0.78, s * 0.3)
        p.move(s * 0.66, s * 0.18); p.line(s * 0.78, s * 0.3); p.line(s * 0.66, s * 0.42)
        p.move(s * 0.78, s * 0.38); p.line(s * 0.78, s * 0.56)
        p.quad(s * 0.78, s * 0.7, s * 0.62, s * 0.7); p.line(s * 0.22, s * 0.7)
        p.move(s * 0.34, s * 0.58); p.line(s * 0.22, s * 0.7); p.line(s * 0.34, s * 0.82)
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }

    /// An arrow up and to the right, for sending the camera.
    static func arrowOut(size s: Double = 12) -> [Part] {
        var p = PathData()
        p.move(s * 0.3, s * 0.7); p.line(s * 0.7, s * 0.3)
        p.move(s * 0.38, s * 0.3); p.line(s * 0.7, s * 0.3); p.line(s * 0.7, s * 0.62)
        return [Part(data: p.d, mode: .stroke, width: 1.4)]
    }
}
