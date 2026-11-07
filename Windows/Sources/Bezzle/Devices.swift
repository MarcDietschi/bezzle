import Foundation
import WinUI
import UWP
import WindowsFoundation

/// What a size is drawn as on home's table: the Mac's SizeForm and FormDrawing
/// (Views/HomeStage.swift), part for part, in WinUI shapes: graphite and aluminium devices, the
/// Duo in titanium, a browser window, a watch, stories and posts, paper and slides.
@MainActor
enum Devices {
    enum Form: Equatable {
        case phone(island: Bool)
        case foldable(open: Bool)
        case tablet, laptop
        case desktop(iMac: Bool)
        case browser, watch
        case story(sideButtons: Bool)
        case banner, video
        case post(roundness: Double)
        case paper, businessCard, postcard, slide
    }

    static func form(group: String, name: String, width: Double, height: Double) -> Form {
        switch group {
        case "iPhone": return name.hasPrefix("iPhone Duo") ? .foldable(open: name == "iPhone Duo, open") : .phone(island: true)
        case "android": return .phone(island: false)
        case "iPad": return .tablet
        case "mac": return name.hasPrefix("MacBook") ? .laptop : .desktop(iMac: name.hasPrefix("iMac"))
        case "web": return .browser
        case "watch": return .watch
        case "print":
            if name == "Business card" { return .businessCard }
            if name == "Postcard" { return .postcard }
            return .paper
        case "slides": return .slide
        default:
            let lower = name.lowercased()
            if lower.contains("banner") || lower.contains("cover") || lower.contains("header") { return .banner }
            if height / width >= 1.6 { return .story(sideButtons: group == "tiktok" || group == "youtube") }
            if group == "youtube" { return .video }
            return .post(roundness: group == "pinterest" ? 0.07 : 0.012)
        }
    }

    /// The Duo's inner screen has 430 pixels to the inch against 460 on every other iPhone's, so
    /// open it stands as tall as closed, as in the hand.
    static func density(_ form: Form) -> Double { form == .foldable(open: true) ? 460.0 / 430 : 1 }

    struct Metrics {
        var size: CGSize
        var screen: CGRect
        var radius: Double
        var bezel = 0.0
    }

    /// How large the thing is round a screen of `s`, where the screen lies in it, how round.
    static func metrics(_ form: Form, _ s: CGSize) -> Metrics {
        let w = Double(s.width), h = Double(s.height), m = min(w, h)
        let flat = Metrics(size: s, screen: CGRect(x: 0, y: 0, width: w, height: h), radius: 0)
        switch form {
        case .phone:
            let b = max(1.5, m * 0.045), nub = max(1, b * 0.5)
            let body = (w: w + b * 2, h: h + b * 2)
            return Metrics(size: CGSize(width: body.w + nub * 2, height: body.h), screen: CGRect(x: nub + b, y: b, width: w, height: h),
                           radius: max(body.w * 0.16 - b, 1), bezel: b)
        case .foldable(let open):
            let b = max(1.2, h * (open ? 0.031 : 0.0245)), nub = max(0.7, b * 0.32)
            let spine = open ? b : b * 1.5
            let body = (w: spine + w + b, h: h + b * 2)
            let radius = open ? body.h * 0.105 : body.w * 0.145
            return Metrics(size: CGSize(width: body.w + nub, height: body.h + nub), screen: CGRect(x: spine, y: nub + b, width: w, height: h),
                           radius: max(radius - b, 1), bezel: b)
        case .tablet:
            let b = max(2, m * 0.05)
            let body = (w: w + b * 2, h: h + b * 2)
            return Metrics(size: CGSize(width: body.w, height: body.h), screen: CGRect(x: b, y: b, width: w, height: h),
                           radius: max(min(body.w, body.h) * 0.07 - b, 1), bezel: b)
        case .laptop:
            let b = max(1.2, w * 0.016), chin = b * 1.8
            let lid = (w: w + b * 2, h: h + b + chin)
            let base = (w: lid.w * 1.13, h: max(2.5, lid.w * 0.03))
            return Metrics(size: CGSize(width: base.w, height: lid.h + base.h), screen: CGRect(x: (base.w - lid.w) / 2 + b, y: b, width: w, height: h),
                           radius: 0.5, bezel: b)
        case .desktop(let iMac):
            let b = max(1.2, w * 0.02), chin = iMac ? h * 0.17 : b
            let head = (w: w + b * 2, h: b + h + chin)
            let neck = head.h * 0.3, foot = max(1.5, head.h * 0.028)
            return Metrics(size: CGSize(width: head.w, height: head.h + neck + foot), screen: CGRect(x: b, y: b, width: w, height: h), radius: 0.5, bezel: b)
        case .browser:
            let bar = max(5, w * 0.045)
            return Metrics(size: CGSize(width: w, height: h + bar), screen: CGRect(x: 0, y: bar, width: w, height: h), radius: max(2, w * 0.012), bezel: bar)
        case .watch:
            let b = m * 0.09, band = h * 0.2, crown = b * 0.9
            let body = (w: w + b * 2, h: h + b * 2)
            return Metrics(size: CGSize(width: body.w + crown, height: body.h + band * 2), screen: CGRect(x: b, y: band + b, width: w, height: h),
                           radius: body.w * 0.2, bezel: b)
        case .story: return Metrics(size: s, screen: flat.screen, radius: m * 0.04)
        case .banner: return Metrics(size: CGSize(width: w, height: h + avatar(w, h) / 2), screen: flat.screen, radius: m * 0.02)
        case .video: return Metrics(size: s, screen: flat.screen, radius: m * 0.05)
        case .post(let roundness): return Metrics(size: s, screen: flat.screen, radius: m * roundness)
        case .paper, .postcard: return flat
        case .businessCard: return Metrics(size: s, screen: flat.screen, radius: m * 0.05)
        case .slide:
            let rod = max(2, h * 0.05), over = w * 0.035, cord = max(5, h * 0.12)
            return Metrics(size: CGSize(width: w + over * 2, height: rod * 0.6 + h + cord), screen: CGRect(x: over, y: rod * 0.6, width: w, height: h),
                           radius: 0, bezel: rod)
        }
    }

    static func avatar(_ w: Double, _ h: Double) -> Double { min(h * 0.62, w * 0.15) }

    // MARK: Finishes (the Mac's Finish, light and dark)

    private static func pick(_ light: UInt32, _ dark: UInt32) -> UInt32 { Theme.dark ? dark : light }
    static var graphite: UInt32 { pick(0x2F2E2C, 0x4A4844) }
    static var graphiteDeep: UInt32 { pick(0x1D1C1B, 0x383633) }
    static var silver: UInt32 { pick(0xDCD8D1, 0x7A7670) }
    static var silverDeep: UInt32 { pick(0xC0BBB3, 0x605D58) }
    static var frontWhite: UInt32 { pick(0xF8F6F2, 0xE4E0D9) }
    static var iMacBlue: UInt32 { pick(0xA8BCDF, 0x7387AC) }
    static var iMacBlueDeep: UInt32 { pick(0x8EA4CC, 0x60739A) }
    static var band: UInt32 { pick(0x55524E, 0x5E5B56) }
    static var toolbar: UInt32 { pick(0xEDEAE4, 0xE2DED7) }
    static var fold: UInt32 { pick(0xE7E2D9, 0xD5D0C7) }
    static var titanium: UInt32 { pick(0xE6E3DD, 0x8E8A84) }
    static var titaniumDeep: UInt32 { pick(0xBAB5AC, 0x67635E) }
    static var titaniumRim: UInt32 { pick(0x8F8A81, 0x4F4C48) }
    static let glass: UInt32 = 0x0A0A0B
    /// The screen, or the page: white, as an artboard is (Paper.stock).
    static var stock: UInt32 { pick(0xFFFFFF, 0xF4F1EB) }

    // MARK: Drawing

    /// The thing for `form` round a screen of `screen` points, and its metrics.
    static func view(_ form: Form, screen size: CGSize) -> (FrameworkElement, Metrics) {
        let m = metrics(form, size)
        let d = Drawing(m)
        let s = m.screen, w = Double(s.width), h = Double(s.height), mm = min(w, h)
        let sx = Double(s.minX), sy = Double(s.minY), smx = Double(s.midX)
        switch form {
        case .phone(let island):
            let b = m.bezel, nub = max(1, b * 0.5)
            let body = R(nub, 0, w + b * 2, h + b * 2)
            for (y, l) in zip([0.17, 0.26, 0.37], [0.05, 0.09, 0.09]) { d.capsule(R(0, body.h * y, nub * 2, body.h * l), graphiteDeep) }
            d.capsule(R(body.x + body.w - nub, body.y + body.h * 0.29, nub * 2, body.h * 0.14), graphiteDeep)
            d.device(body, radius: body.w * 0.16)
            d.screen(radius: m.radius)
            if island {
                d.capsule(R(smx - w * 0.15, sy + max(1.2, w * 0.035), w * 0.3, max(1.5, w * 0.085)), 0x000000)
            } else {
                let c = max(1.5, w * 0.05)
                d.circle(R(smx - c / 2, sy + max(1.2, w * 0.04), c, c), 0x000000)
            }

        case .foldable(let open):
            let b = m.bezel, nub = sy - b
            let body = R(0, nub, Double(m.size.width) - nub, Double(m.size.height) - nub)
            let frame = max(0.5, b * 0.38)
            let side = open ? (from: 0.275, length: 0.155) : (from: 0.29, length: 0.15)
            let volume = open ? [0.728, 0.806] : [0.46, 0.62]
            for v in volume { d.capsule(R(body.w * v, 0, body.w * (open ? 0.064 : 0.12), nub * 2.4), titaniumDeep) }
            d.capsule(R(body.x + body.w - nub * 1.4, body.y + body.h * side.from, nub * 2.4, body.h * side.length), titaniumDeep)
            if open {
                let r = m.radius + b
                d.titanium(body, corners: (r, r, r, r))
                d.rounded(body.inset(frame), radius: r - frame, glass)
                d.screen(radius: m.radius)
                for top in [true, false] { d.rounded(R(body.x + body.w / 2 - 0.35, top ? body.y : body.y + body.h - frame, 0.7, frame), radius: 0, titaniumDeep) }
                d.fold(R(smx - max(1.5, w * 0.014), sy, max(3, w * 0.028), h))
            } else {
                let r = m.radius + b, small = max(0.6, body.w * 0.022)
                d.titanium(body, corners: (small, r, r, small))
                d.rounded(R(sx * 0.42, body.y + small, max(0.5, sx * 0.1), body.h - small * 2), radius: 0, titaniumDeep)
                d.uneven(R(sx * 0.62, body.y + frame, body.x + body.w - frame - sx * 0.62, body.h - frame * 2),
                         (small * 0.5, r - frame, r - frame, small * 0.5), glass)
                let p = max(0.5, m.radius * 0.1)
                d.uneven(R(sx, sy, w, h), (p, m.radius, m.radius, p), stock)
                let c = max(1.2, w * 0.076)
                d.circle(R(sx + w * 0.89 - c / 2, sy + h * 0.077 - c / 2, c, c), 0x000000)
            }

        case .tablet:
            let b = m.bezel
            let body = R(0, 0, w + b * 2, h + b * 2)
            d.device(body, radius: min(body.w, body.h) * 0.07)
            d.screen(radius: m.radius)
            let c = max(1, b * 0.35)
            d.circle(R(body.w / 2 - c / 2, b / 2 - c / 2, c, c), 0x000000, 0.6)

        case .laptop:
            let b = m.bezel
            let lid = R(sx - b, 0, w + b * 2, h + b * 2.8)
            let base = R(0, lid.y + lid.h, Double(m.size.width), Double(m.size.height) - (lid.y + lid.h))
            d.device(lid, corners: (lid.w * 0.03, lid.w * 0.03, 0.5, 0.5))
            d.screen(radius: 0)
            let nw = w * 0.09, nh = max(1, b * 1.1)
            d.uneven(R(smx - nw / 2, sy, nw, nh), (0, 0, nh * 0.4, nh * 0.4), graphite)
            d.uneven(base, (0.5, 0.5, base.h * 0.7, base.h * 0.7), gradient: (silver, silverDeep))
            d.rounded(R(base.x, base.y, base.w, 0.5), radius: 0, 0xFFFFFF, 0.2)
            let gw = lid.w * 0.15, gh = max(0.6, base.h * 0.32)
            d.uneven(R(base.x + base.w / 2 - gw / 2, base.y, gw, gh), (0, 0, gh * 0.8, gh * 0.8), silverDeep)

        case .desktop(let iMac):
            let b = m.bezel
            let head = R(0, 0, Double(m.size.width), b + h + (iMac ? h * 0.17 : b))
            let neckHeight = head.h * 0.3, foot = Double(m.size.height) - head.h - neckHeight
            let neck = R(head.w / 2 - head.w * 0.1, head.h - 1, head.w * 0.2, neckHeight + 1)
            d.uneven(neck, (0, 0, 0, 0), gradient: iMac ? (iMacBlueDeep, iMacBlue) : (silverDeep, silver))
            d.capsule(R(head.w / 2 - head.w * 0.15, neck.y + neck.h - 0.5, head.w * 0.3, foot + 0.5), iMac ? iMacBlueDeep : silverDeep)
            if iMac {
                d.uneven(head, (head.w * 0.022, head.w * 0.022, head.w * 0.022, head.w * 0.022), gradient: (iMacBlue, iMacBlueDeep))
                d.uneven(R(0, 0, head.w, h + b * 2), (head.w * 0.022, head.w * 0.022, 0, 0), frontWhite, stroke: (0x000000, 0.08, 0.5))
            } else {
                d.device(head, radius: head.w * 0.016)
            }
            d.screen(radius: 0)

        case .browser:
            let bar = m.bezel, r = m.radius
            let window = R(0, 0, Double(m.size.width), Double(m.size.height))
            d.rounded(window, radius: r, stock)
            d.uneven(R(0, 0, w, bar), (r, r, 0, 0), toolbar)
            d.rounded(R(0, bar - 0.5, w, 0.5), radius: 0, 0x000000, 0.08)
            let c = bar * 0.26
            for (k, colour) in [UInt32(0xFF5F57), 0xFFBD2E, 0x29C740].enumerated() { d.circle(R(bar * 0.4 + Double(k) * c * 1.7, bar / 2 - c / 2, c, c), colour) }
            d.capsule(R(w * 0.33, bar * 0.28, w * 0.34, bar * 0.44), 0x000000, 0.07)
            d.outline(window, radius: r, 0x000000, 0.12, width: 0.5)

        case .watch:
            let b = m.bezel, band = h * 0.2
            let body = R(0, band, w + b * 2, h + b * 2)
            let bw = body.w * 0.72
            d.uneven(R(body.w / 2 - bw / 2, 0, bw, band + b), (bw * 0.12, bw * 0.12, 0, 0), gradient: (band0, Devices.band), fadeTop: true)
            d.uneven(R(body.w / 2 - bw / 2, body.y + body.h - b, bw, band + b), (0, 0, bw * 0.12, bw * 0.12), gradient: (Devices.band, band0), fadeBottom: true)
            let crown = Double(m.size.width) - body.w
            d.uneven(R(body.w - crown * 0.6, body.y + body.h * 0.22, crown * 1.6, body.h * 0.17), (crown * 0.35, crown * 0.35, crown * 0.35, crown * 0.35), gradient: (silver, silverDeep))
            d.capsule(R(body.w - crown * 0.5, body.y + body.h * 0.5, crown, body.h * 0.22), graphiteDeep)
            d.device(body, radius: body.w * 0.28)
            d.screen(radius: m.radius)

        case .story(let sideButtons):
            d.screen(radius: m.radius)
            let inset = w * 0.06, c = w * 0.1
            if sideButtons {
                for k in 0..<3 { d.circle(R(w * 0.84 - c / 2, h * (0.5 + Double(k) * 0.08), c, c), 0x000000, 0.13) }
                d.capsule(R(inset, h * 0.85, w * 0.5, max(1, h * 0.013)), 0x000000, 0.12)
                d.capsule(R(inset, h * 0.885, w * 0.32, max(1, h * 0.013)), 0x000000, 0.09)
            } else {
                let gap = max(1, w * 0.02), bar = (w - inset * 2 - gap * 2) / 3
                for k in 0..<3 { d.capsule(R(inset + Double(k) * (bar + gap), h * 0.025, bar, max(1, h * 0.008)), 0x000000, k == 0 ? 0.32 : 0.13) }
                d.circle(R(inset, h * 0.05, c, c), 0x000000, 0.12)
                d.capsule(R(inset + c * 1.3, h * 0.05 + c * 0.35, w * 0.26, c * 0.3), 0x000000, 0.1)
            }

        case .banner:
            d.screen(radius: m.radius)
            let a = avatar(w, h)
            d.circle(R(w * 0.05, h - a / 2, a, a), stock)
            d.circle(R(w * 0.05 + a * 0.12, h - a / 2 + a * 0.12, a * 0.76, a * 0.76), 0x000000, 0.1)
            d.ring(R(w * 0.05, h - a / 2, a, a), Theme.table, width: max(1, a * 0.07))

        case .video:
            d.screen(radius: m.radius)
            let pw = w * 0.12, ph = h * 0.085
            d.rounded(R(w - pw - w * 0.03, h - ph - h * 0.045, pw, ph), radius: ph * 0.25, 0x000000, 0.62)

        case .post:
            d.screen(radius: m.radius)

        case .paper:
            let fold = mm * 0.13
            d.dogEared(R(sx, sy, w, h), fold: fold)
            d.corner(R(w - fold, 0, fold, fold))

        case .businessCard:
            d.rounded(R(sx, sy, w, h), radius: m.radius, fold, turn: -8, offset: (w * 0.07, -h * 0.04))
            d.screen(radius: m.radius)
            let c = h * 0.2
            d.circle(R(w * 0.1, h * 0.16, c, c), Theme.pencil, 0.35)
            d.capsule(R(w * 0.1, h * 0.66, w * 0.42, max(1, h * 0.05)), 0x000000, 0.14)
            d.capsule(R(w * 0.1, h * 0.77, w * 0.28, max(1, h * 0.04)), 0x000000, 0.09)

        case .postcard:
            d.screen(radius: 0)
            let sw = w * 0.17
            d.rounded(R(w - sw - w * 0.07, w * 0.07, sw, sw * 1.2), radius: 0, Theme.pencil, 0.16)
            d.outline(R(w - sw - w * 0.07, w * 0.07, sw, sw * 1.2), radius: 0, 0x000000, 0.22, width: 0.6, dashed: true)
            d.rounded(R(w * 0.5, h * 0.12, 0.6, h * 0.76), radius: 0, 0x000000, 0.08)
            for k in 0..<3 { d.rounded(R(w * 0.57, h * (0.5 + Double(k) * 0.1), w * 0.34, 0.6), radius: 0, 0x000000, 0.1) }

        case .slide:
            let rod = m.bezel
            d.screen(radius: 0)
            d.capsule(R(sx + w * 0.08, sy + h * 0.14, w * 0.42, h * 0.05), 0x000000, 0.15)
            d.capsule(R(sx + w * 0.08, sy + h * 0.23, w * 0.27, h * 0.035), 0x000000, 0.08)
            d.uneven(R(0, 0, Double(m.size.width), rod), (rod / 2, rod / 2, rod / 2, rod / 2), gradient: (graphite, graphiteDeep))
            let cord = Double(m.size.height) - Double(s.maxY), knob = max(2, cord * 0.36)
            d.rounded(R(smx - 0.4, Double(s.maxY), 0.8, cord - knob), radius: 0, graphite, 0.7)
            d.capsule(R(smx - knob * 0.4, Double(m.size.height) - knob, knob * 0.8, knob), graphite)
        }
        return (d.canvas, m)
    }

    /// The band's colour faded out, where it runs off.
    private static var band0: UInt32 { band }

    struct R {
        var x, y, w, h: Double
        init(_ x: Double, _ y: Double, _ w: Double, _ h: Double) { self.x = x; self.y = y; self.w = max(0, w); self.h = max(0, h) }
        func inset(_ d: Double) -> R { R(x + d, y + d, w - 2 * d, h - 2 * d) }
    }

    /// Puts shapes into a canvas the thing's size, each at its rectangle, as `.place` does.
    @MainActor
    final class Drawing {
        let canvas = Canvas()
        let m: Metrics

        init(_ m: Metrics) {
            self.m = m
            canvas.width = Double(m.size.width)
            canvas.height = Double(m.size.height)
            canvas.isHitTestVisible = false
        }

        private func place(_ e: FrameworkElement, _ r: R) {
            e.width = r.w
            e.height = r.h
            try? Canvas.setLeft(e, r.x)
            try? Canvas.setTop(e, r.y)
            canvas.children.append(e)
        }

        func rounded(_ r: R, radius: Double, _ rgb: UInt32, _ alpha: Double = 1, turn: Double = 0, offset: (Double, Double) = (0, 0)) {
            let shape = Rectangle()
            shape.radiusX = radius
            shape.radiusY = radius
            shape.fill = Theme.brush(rgb, alpha)
            if turn != 0 {
                let t = CompositeTransform()
                t.rotation = turn
                t.centerX = r.w / 2
                t.centerY = r.h / 2
                t.translateX = offset.0
                t.translateY = offset.1
                shape.renderTransform = t
            }
            place(shape, r)
        }

        func capsule(_ r: R, _ rgb: UInt32, _ alpha: Double = 1) { rounded(r, radius: min(r.w, r.h) / 2, rgb, alpha) }

        func circle(_ r: R, _ rgb: UInt32, _ alpha: Double = 1) {
            let shape = Ellipse()
            shape.fill = Theme.brush(rgb, alpha)
            place(shape, r)
        }

        func ring(_ r: R, _ rgb: UInt32, width: Double) {
            let shape = Ellipse()
            shape.stroke = Theme.brush(rgb)
            shape.strokeThickness = width
            place(shape, r)
        }

        func outline(_ r: R, radius: Double, _ rgb: UInt32, _ alpha: Double, width: Double, dashed: Bool = false) {
            let shape = Rectangle()
            shape.radiusX = radius
            shape.radiusY = radius
            shape.stroke = Theme.brush(rgb, alpha)
            shape.strokeThickness = width
            if dashed {
                let dashes = DoubleCollection()
                dashes.append(1 / width)
                dashes.append(1 / width)
                shape.strokeDashArray = dashes
            }
            place(shape, r)
        }

        /// A rectangle rounded corner by corner (top left, top right, bottom right, bottom left),
        /// in one colour or a gradient from top to bottom.
        func uneven(_ r: R, _ c: (Double, Double, Double, Double), _ rgb: UInt32 = 0, gradient: (UInt32, UInt32)? = nil,
                    stroke: (UInt32, Double, Double)? = nil, fadeTop: Bool = false, fadeBottom: Bool = false, filled: Bool = true) {
            var p = PathData()
            p.rect(0, 0, r.w, r.h, corners: c.0, c.1, c.2, c.3)
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(p.d)'/>"
            guard let shape = (try? XamlReader.load(xaml)) as? WinUI.Path else { return }
            if let gradient {
                shape.fill = Devices.vertical(gradient.0, gradient.1, fadeTop: fadeTop, fadeBottom: fadeBottom)
            } else if filled {
                shape.fill = Theme.brush(rgb)
            }
            if let stroke {
                shape.stroke = Theme.brush(stroke.0, stroke.1)
                shape.strokeThickness = stroke.2
            }
            place(shape, r)
        }

        /// A device's body in graphite, its edge catching the light.
        func device(_ r: R, radius: Double) { device(r, corners: (radius, radius, radius, radius)) }

        func device(_ r: R, corners c: (Double, Double, Double, Double)) {
            uneven(r, c, gradient: (Devices.graphite, Devices.graphiteDeep), stroke: (0xFFFFFF, 0.2, 0.6))
        }

        /// The Duo in polished titanium: a darker rim, a bright line inside it.
        func titanium(_ r: R, corners c: (Double, Double, Double, Double)) {
            uneven(r, c, gradient: (Devices.titanium, Devices.titaniumDeep), stroke: (Devices.titaniumRim, 1, 0.6))
            uneven(r.inset(0.6), (max(0, c.0 - 0.6), max(0, c.1 - 0.6), max(0, c.2 - 0.6), max(0, c.3 - 0.6)), stroke: (0xFFFFFF, 0.6, 0.5), filled: false)
        }

        /// The screen, or the page: white, as an artboard is.
        func screen(radius: Double) {
            let s = m.screen
            rounded(R(Double(s.minX), Double(s.minY), Double(s.width), Double(s.height)), radius: radius, Devices.stock)
        }

        /// The Duo's fold: a faint line where it catches the light.
        func fold(_ r: R) {
            let brush = LinearGradientBrush()
            brush.startPoint = WindowsFoundation.Point(x: 0, y: 0.5)
            brush.endPoint = WindowsFoundation.Point(x: 1, y: 0.5)
            for (offset, rgb, alpha) in [(0.0, UInt32(0), 0.0), (0.25, 0, 0.07), (0.5, 0xFFFFFF, 0.5), (0.75, 0, 0.07), (1, 0, 0)] {
                let stop = GradientStop()
                stop.offset = offset
                stop.color = Theme.color(rgb, alpha)
                brush.gradientStops.append(stop)
            }
            let shape = Rectangle()
            shape.fill = brush
            place(shape, r)
        }

        /// A page with its top right corner folded over.
        func dogEared(_ r: R, fold: Double) {
            var p = PathData()
            p.move(0, 0); p.line(r.w - fold, 0); p.line(r.w, fold); p.line(r.w, r.h); p.line(0, r.h); p.close()
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(p.d)'/>"
            guard let shape = (try? XamlReader.load(xaml)) as? WinUI.Path else { return }
            shape.fill = Theme.brush(Devices.stock)
            place(shape, r)
        }

        /// The folded corner itself, in the fold's colour.
        func corner(_ r: R) {
            var p = PathData()
            p.move(0, 0); p.line(0, r.h); p.line(r.w, r.h); p.close()
            let xaml = "<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='\(p.d)'/>"
            guard let shape = (try? XamlReader.load(xaml)) as? WinUI.Path else { return }
            shape.fill = Theme.brush(Devices.fold)
            place(shape, r)
        }
    }

    /// A gradient from top to bottom; faded, the band runs off into nothing.
    static func vertical(_ top: UInt32, _ bottom: UInt32, fadeTop: Bool = false, fadeBottom: Bool = false) -> LinearGradientBrush {
        let brush = LinearGradientBrush()
        brush.startPoint = WindowsFoundation.Point(x: 0.5, y: 0)
        brush.endPoint = WindowsFoundation.Point(x: 0.5, y: 1)
        for (offset, rgb, alpha) in [(0.0, top, fadeTop ? 0.0 : 1.0), (1.0, bottom, fadeBottom ? 0.0 : 1.0)] {
            let stop = GradientStop()
            stop.offset = offset
            stop.color = Theme.color(rgb, alpha)
            brush.gradientStops.append(stop)
        }
        return brush
    }
}
