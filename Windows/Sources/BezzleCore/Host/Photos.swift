import Foundation
import CBezzleHost

// Developing photos on Windows, as the Mac's Photo card and its store do it (Views/PhotoCard.swift,
// Store/DevelopOperations.swift): each picture layer's `Develop`, shared, its settings and its
// colours' shifts set, all of it made stronger or weaker at once, or taken away.

extension WindowsCore {
    /// The Photo card of the selected layers, when every one is filled with a picture.
    public struct PhotoLook: Sendable {
        /// What the card says folded: "Original", what was done, or "Several".
        public let summary: String
        /// Whether none of them is developed at all.
        public let neutral: Bool
        /// Each setting's amount on the first, by its name, and whether they differ.
        public let amounts: [String: Double]
        public let mixed: Set<String>
        /// Each colour's shift on the first: hue, saturation, luminance.
        public let bands: [String: (hue: Double, saturation: Double, luminance: Double)]
        public let mixedBands: Set<String>
    }

    /// A setting, as the card shows it: its name, its title, how far it goes, which tab it is in,
    /// and how many decimals it is shown with.
    public struct PhotoSetting: Sendable {
        public let name: String
        public let title: String
        public let low: Double
        public let high: Double
        public let group: String
        public let decimals: Int
        public let isTone: Bool
    }

    public static var photoSettings: [PhotoSetting] {
        Develop.Setting.allCases.map { s in
            PhotoSetting(name: s.rawValue, title: String(localized: s.title), low: s.range.lowerBound, high: s.range.upperBound,
                         group: s.group.rawValue, decimals: s == .exposure ? 2 : 0, isTone: s.isTone)
        }
    }

    /// The tabs: their names and titles.
    public static var photoGroups: [(name: String, title: String)] {
        Develop.Group.allCases.map { ($0.rawValue, String(localized: $0.title)) }
    }

    /// The colours, by name: their titles and where each is most itself on the wheel, in degrees.
    public static var photoBands: [(name: String, title: String, hue: Double)] {
        Develop.Band.allCases.map { ($0.rawValue, String(localized: $0.title), $0.hue) }
    }

    private static func develops(_ n: Node) -> Bool { n.fill.on && n.fill.image != nil }

    public static func photoLook(_ ids: [UUID]) -> PhotoLook? {
        guard let doc = design else { return nil }
        let nodes = ids.compactMap { doc.node($0) }
        guard let first = nodes.first, nodes.count == ids.count, nodes.allSatisfy(develops) else { return nil }
        let developments = nodes.map { $0.fill.image?.develop }
        let d = first.fill.image?.develop ?? Develop()
        let alike = Set(developments).count == 1
        let summary = !alike ? say("Several") : d.isNeutral ? say("Original") : d.words.map { String(localized: $0) }.joined(separator: " · ")
        var amounts: [String: Double] = [:], mixed = Set<String>()
        for s in Develop.Setting.allCases {
            amounts[s.rawValue] = d[s]
            if Set(developments.map { ($0 ?? Develop())[s] }).count > 1 { mixed.insert(s.rawValue) }
        }
        var bands: [String: (Double, Double, Double)] = [:], mixedBands = Set<String>()
        for b in Develop.Band.allCases {
            let shift = d[b]
            bands[b.rawValue] = (shift.hue, shift.saturation, shift.luminance)
            if Set(developments.map { ($0 ?? Develop())[b] }).count > 1 { mixedBands.insert(b.rawValue) }
        }
        return PhotoLook(summary: summary, neutral: developments.allSatisfy { $0 == nil }, amounts: amounts, mixed: mixed,
                         bands: bands, mixedBands: mixedBands)
    }

    /// Each picture layer's development changed, as one step, or as the gesture stands.
    private static func develop(_ ids: [UUID], _ change: @escaping (inout Develop) -> Void) {
        edit { doc in
            for id in ids {
                guard let n = doc.node(id), develops(n) else { continue }
                doc.update(id) { n in
                    guard var image = n.fill.image else { return }
                    var d = image.develop ?? Develop()
                    change(&d)
                    image.develop = d.kept
                    n.fill.image = image
                }
            }
        }
    }

    /// A setting set, by its name.
    public static func setPhoto(_ ids: [UUID], _ name: String, _ value: Double) {
        guard let s = Develop.Setting(rawValue: name) else { return }
        develop(ids) { $0[s] = value }
    }

    /// A colour's hue, saturation or luminance set (`part`: "hue", "saturation", "luminance").
    public static func setPhotoBand(_ ids: [UUID], _ band: String, _ part: String, _ value: Double) {
        guard let b = Develop.Band(rawValue: band), let p = Develop.Shift.Part(rawValue: part) else { return }
        develop(ids) { $0[b][p] = value }
    }

    /// A colour's whole shift set at once: hue, saturation and luminance (the wheel's drag).
    public static func setPhotoShift(_ ids: [UUID], _ band: String, hue: Double, saturation: Double, luminance: Double) {
        guard let b = Develop.Band(rawValue: band) else { return }
        develop(ids) { $0[b] = Develop.Shift(hue: hue, saturation: saturation, luminance: luminance) }
    }

    /// An angle in degrees, brought to −180…180.
    public static func turn(_ degrees: Double) -> Double { Develop.turn(degrees) }

    /// Back to the photo as it was taken.
    public static func resetPhoto(_ ids: [UUID]) {
        develop(ids) { $0 = Develop() }
    }

    /// How much of the development there is, as a share of what there was as the drag began, from
    /// nothing to twice as much (the folded card's drag). A photo not yet developed starts from
    /// nothing and goes towards what would suit it best, as on the Mac.
    public static func photoStrength(_ ids: [UUID], _ k: Double) {
        let start = Editing.gestureStart ?? design
        var bases: [UUID: Develop] = [:]
        for id in ids {
            guard let n = start?.node(id), develops(n) else { continue }
            let was = n.fill.image?.develop ?? Develop()
            bases[id] = was.isNeutral ? autoDevelop(n) : was
        }
        edit { doc in
            for (id, base) in bases { doc.update(id) { $0.fill.image?.develop = base.scaled(by: k).kept } }
        }
    }

    /// Each picture developed as suits it best, as one step (the card's Auto).
    public static func autoPhoto(_ ids: [UUID]) {
        guard let doc = design else { return }
        var targets: [UUID: Develop] = [:]
        for id in ids { if let n = doc.node(id), develops(n) { targets[id] = autoDevelop(n) } }
        edit { doc in
            for (id, d) in targets { doc.update(id) { $0.fill.image?.develop = d.kept } }
        }
    }

    /// Each picture glides to what suits it best over a moment, the canvas drawn again at each
    /// step (`step`), all one step of the history, as the Mac's Auto glides.
    public static func glideAutoPhoto(_ ids: [UUID], step: @escaping @MainActor () -> Void) {
        guard let doc = design else { return }
        var from: [UUID: Develop] = [:], to: [UUID: Develop] = [:]
        for id in ids {
            guard let n = doc.node(id), develops(n) else { continue }
            from[id] = n.fill.image?.develop ?? Develop()
            to[id] = autoDevelop(n)
        }
        guard from.contains(where: { to[$0.key] != $0.value }) else { return }
        glides += 1
        let glide = glides
        // A glide cut short by another still ends as one step.
        if Editing.gestureStart != nil { endGesture() }
        beginGesture()
        let began = Date()
        // Its design's own, should another tab come to the front meanwhile.
        let slot = active
        func tick() {
            guard glide == glides else { return }
            if let slot, slot !== active {
                if slot.isOpen { using(slot) { tick() } }
                return
            }
            let t = min(Date().timeIntervalSince(began) / 0.42, 1)
            // Quick to start and gentle to land.
            let eased = 1 - pow(1 - t, 3)
            edit { doc in
                for (id, a) in from {
                    guard let b = to[id] else { continue }
                    doc.update(id) { $0.fill.image?.develop = (t >= 1 ? b : Develop.mix(a, b, eased)).kept }
                }
            }
            if t >= 1 { endGesture() }
            step()
            if t < 1 { DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { MainActor.assumeIsolated { tick() } } }
        }
        tick()
    }
    nonisolated(unsafe) private static var glides = 0

    /// The pictures shown as they were taken while `on` (the card's compare button held).
    public static func previewPhotoOriginal(_ ids: [UUID], _ on: Bool) {
        endPreview()
        guard on else { return }
        preview { doc in for id in ids { doc.update(id) { $0.fill.image?.develop = nil } } }
    }

    /// Only the part of the pictures a tone (by its setting's name) or a colour (by its band's
    /// name) works on, the rest grey, while Alt is held on it; nil for all of them again.
    public static func previewPhotoIsolated(_ ids: [UUID], tone: String? = nil, band: String? = nil) {
        endPreview()
        let isolation: Develop.Isolation? = if let tone, let s = Develop.Setting(rawValue: tone), s.isTone { .tone(s) }
            else if let band, let b = Develop.Band(rawValue: band) { .band(b) } else { nil }
        guard let isolation else { return }
        preview { doc in
            for id in ids {
                doc.update(id) { n in
                    guard n.fill.image != nil else { return }
                    var d = n.fill.image?.develop ?? Develop()
                    d.isolate = isolation
                    n.fill.image?.develop = d
                }
            }
        }
    }

    // MARK: Reading pictures

    nonisolated(unsafe) private static var autoKept: [String: Develop] = [:]
    nonisolated(unsafe) private static var looksKept: [String: PhotoTones] = [:]

    /// What would suit a layer's picture best, worked out once for each picture.
    static func autoDevelop(_ n: Node) -> Develop {
        guard let image = n.fill.image else { return Develop() }
        if let known = autoKept[image.asset] { return known }
        let d = pixels(of: { assets.image(image.asset, pixels: 256) }, longest: 160).map(Develop.auto(pixels:)) ?? Develop()
        autoKept[image.asset] = d
        return d
    }

    /// A picture read small, as the Mac's `Pixels` reads it with Core Graphics: drawn `longest`
    /// across into a recording, made by Skia, and its pixels read back. The picture is made here,
    /// so that Skia is given what it is made from, such as a photo developed just now.
    static func pixels(of made: () -> CGImage?, longest: Int) -> Pixels? {
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        guard let picture = made() else { return nil }
        let s = min(1, Double(longest) / Double(max(picture.width, picture.height, 1)))
        let w = max(1, Int((Double(picture.width) * s).rounded())), h = max(1, Int((Double(picture.height) * s).rounded()))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(picture, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let image = ctx.makeImage() else { return nil }
        for p in Images.shared.list where p.id >= first { send(p) }
        defer { forget(before: first) }
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let done = bytes.withUnsafeMutableBytes { bz_picture_read(Int32(image.id), Int32(w), Int32(h), 0, $0.baseAddress) }
        return done == 0 ? Pixels(width: w, height: h, bytes: bytes) : nil
    }

    /// The first picture's tones as the card's landscape shows them (the Mac's PictureLook): how
    /// much of it is at each tone, dark to light, and in red, green and blue alone, the fullest
    /// being 1, and how much is lost to black and to white.
    public struct PhotoTones: Sendable {
        public let tones: [Double]
        public let reds: [Double]
        public let greens: [Double]
        public let blues: [Double]
        public let crushed: Double
        public let blown: Double
        public let colors: [Double]
    }

    /// How much of the first picture is of each colour: `hueSteps` hues round the wheel from red,
    /// each `strengthSteps` strengths from grey out to full, the most being 1 (PictureLook.colors).
    public static func photoColours(_ ids: [UUID]) -> (colors: [Double], hues: Int, strengths: Int)? {
        photoTones(ids).map { ($0.colors, PictureLook.hueSteps, PictureLook.strengthSteps) }
    }

    /// The picture's own colours as the Mac's wheel shows them, a soft cloud inside a ring
    /// `ring` round: each hue round the wheel, stronger further out, blurred by 4. Into pixels a
    /// `size` box at `scale`.
    public static func colourCloud(_ colors: [Double], hues: Int, strengths: Int, size: CGSize, ring: Double, scale: Double,
                                   into fill: (_ width: Int, _ height: Int) -> UnsafeMutableRawPointer?) -> Bool {
        var dots: [Node] = []
        for i in 0..<hues {
            for j in 0..<strengths {
                let v = colors[i * strengths + j]
                guard v > 0.03 else { continue }
                let a = Double(i) / Double(hues) * 2 * .pi
                let r = (Double(j) + 0.6) / Double(strengths) * (ring - 12)
                let d = 5 + v * 9
                let p = CGPoint(x: size.width / 2 + CGFloat(sin(a) * r), y: size.height / 2 - CGFloat(cos(a) * r))
                var n = Node(kind: .ellipse, name: "", frame: CGRect(x: p.x - CGFloat(d) / 2, y: p.y - CGFloat(d) / 2, width: CGFloat(d), height: CGFloat(d)))
                n.fill.on = true
                n.fill.color = RGBA(h: Double(i) / Double(hues), s: (Double(j) + 0.5) / Double(strengths), b: 0.92, a: 0.25 + v * 0.7)
                n.border.on = false
                n.blur = Blur(radius: 4)
                dots.append(n)
            }
        }
        return drawGlyph(dots, size: size, scale: scale, into: fill)
    }

    public static func photoTones(_ ids: [UUID]) -> PhotoTones? {
        guard let id = ids.first, let n = design?.node(id), develops(n), let image = n.fill.image else { return nil }
        let key = image.shown + "|" + String(describing: image.develop)
        if let known = looksKept[key] { return known }
        let px = pixels(of: {
            (assets.image(image.shown, pixels: 256) ?? assets.image(image.asset, pixels: 256)).map { Developer.developed($0, image.develop) }
        }, longest: 200)
        guard let px, let look = PictureLook(pixels: px) else { return nil }
        let tones = PhotoTones(tones: look.tones, reds: look.reds, greens: look.greens, blues: look.blues, crushed: look.crushed, blown: look.blown,
                               colors: look.colors)
        if looksKept.count > 40 { looksKept.removeAll() }
        looksKept[key] = tones
        return tones
    }

    /// The landscape's zones: the setting a sideways drag moves in each, and where each lies across
    /// it, 0…1, as the Mac's ToneTerrain has them.
    public static let toneZones: [(setting: String, from: Double, to: Double)] = [
        ("blacks", 0, 0.12), ("shadows", 0.12, 0.38), ("exposure", 0.38, 0.62), ("highlights", 0.62, 0.88), ("whites", 0.88, 1),
    ]
}
