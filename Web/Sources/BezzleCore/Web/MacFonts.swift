import Foundation
import AppKit

// The Mac's own fonts as Text Kit sets them, for the system font and the families the open fonts
// stand in for (Web/tools/openfonts.py): numbers measured on the Mac (macOS 27, Text Kit), nothing
// of Apple's fonts themselves. With them a text's lines are as tall here, and its baselines where,
// as on the Mac, whatever the stand-in's own measures are (TextLayout.place in WebText.swift); and
// the letters of a stand-in are set a little apart or together, by as much as makes it about as
// wide as the face it stands in for, as Apple's own fonts are tracked by size (`spacing`).
//
// Measured by Web/tools/TextMeasureTests.swift on the Mac and Windows/Sources/BezzleCore/Host/
// TextReport.swift here, compared by Web/tools/text-compare.py; Web/tools/text-table.py makes the
// tables below again. Text Kit sets a line `round(ascent) + round(descent) + leading` tall, its
// baseline `round(ascent)` down, plus, for the faces marked `fifth`, a fifth of `round(ascent) +
// round(descent)` more above when the leading is under half a point. That held for every face
// and size measured, 4 to 132 points.

nonisolated enum MacFonts {
    /// A face's ascent, descent and leading in ems, as Core Text gives them, and whether Text Kit
    /// puts a fifth more room above its letters (Helvetica, Times and Courier always; Didot and
    /// Futura Bold while their leading is under half a point).
    struct Face {
        let ascent: Double, descent: Double, leading: Double
        var fifth = false

        init(_ ascent: Double, _ descent: Double, _ leading: Double, fifth: Bool = false) {
            self.ascent = ascent
            self.descent = descent
            self.leading = leading
            self.fifth = fifth
        }

        init(_ ascent: Int, _ descent: Int, _ leading: Int, of unitsPerEm: Double, fifth: Bool = false) {
            self.init(Double(ascent) / unitsPerEm, Double(descent) / unitsPerEm, Double(leading) / unitsPerEm, fifth: fifth)
        }

        /// What a run of this face at `size` takes of its line, as Text Kit counts it: the part above
        /// the baseline, and below it the descent with the leading, and the descent alone.
        func rise(at size: CGFloat) -> (above: CGFloat, below: CGFloat, descent: CGFloat) {
            let a = (CGFloat(ascent) * size).rounded(), d = (CGFloat(descent) * size).rounded(), l = CGFloat(leading) * size
            let extra = fifth && l < 0.5 ? (0.2 * (a + d)).rounded() : 0
            return (a + extra, d + l, d)
        }

        /// The font's own line height, which a text has until one is set: as Fonts.naturalLineHeight on the Mac.
        func naturalLineHeight(at size: CGFloat) -> CGFloat {
            (CGFloat(ascent + descent + leading) * max(size, 1)).rounded(.up)
        }
    }

    /// The Mac's face, by the family and face a design names; any face of the system font, which
    /// all measure alike, by its regular one.
    static func face(family: String, face: String) -> Face? {
        if let known = faces["\(family)/\(face)"] { return known }
        return family == TextStyle.system ? faces["System/Regular"] : nil
    }

    /// The families drawn here with stand-ins, which are spaced to the Mac's widths: set by the host
    /// from the open fonts' manifest. None where the page has the Mac's own fonts.
    nonisolated(unsafe) static var standIns: Set<String> = []

    /// The letter spacing, in points, that makes a face's stand-in about as wide as the Mac's face
    /// at `size`; none for the families drawn in their own fonts. Fitted on words in every face at
    /// sizes from 9 to 132 points; held to three hundredths of an em, beyond which the stand-in's
    /// letters would look crowded or apart, so that a stand-in much wider or narrower than its face
    /// (Baskerville, Bodoni, the condensed faces) still measures differently.
    static func spacing(family: String, face: String, size: CGFloat) -> CGFloat {
        guard standIns.contains(family) else { return 0 }
        if family == TextStyle.system {
            guard let known = systemSpacings[face] else { return 0 }
            return CGFloat(along(known, at: size)) / 10_000 * size
        }
        return CGFloat(spacings["\(family)/\(face)"] ?? 0) / 10_000 * size
    }

    /// The sizes the system font's spacings are given at; between them they go from one to the next.
    static let systemSizes: [CGFloat] = [9, 11, 12, 13, 14, 15, 16, 17, 18, 20, 22, 24, 28, 32, 40, 48, 64, 72, 96, 132]

    private static func along(_ values: [Int], at size: CGFloat) -> Double {
        guard let last = systemSizes.indices.last, values.count == systemSizes.count else { return 0 }
        if size <= systemSizes[0] { return Double(values[0]) }
        if size >= systemSizes[last] { return Double(values[last]) }
        let k = systemSizes.firstIndex { $0 >= size } ?? last
        let s0 = systemSizes[k - 1], s1 = systemSizes[k]
        let t = Double((size - s0) / (s1 - s0))
        return Double(values[k - 1]) + (Double(values[k]) - Double(values[k - 1])) * t
    }

    // MARK: Measured on the Mac

    /// Each face by "family/face".
    static let faces: [String: Face] = [
        "Arial/Bold": Face(1854, 434, 67, of: 2048),
        "Arial/Bold Italic": Face(1854, 434, 67, of: 2048),
        "Arial/Italic": Face(1854, 434, 67, of: 2048),
        "Arial/Regular": Face(1854, 434, 67, of: 2048),
        "Avenir Next/Bold": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Bold Italic": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Demi Bold": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Demi Bold Italic": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Heavy": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Heavy Italic": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Italic": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Medium": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Medium Italic": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Regular": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Ultra Light": Face(1.0, 0.365997314453125, 0),
        "Avenir Next/Ultra Light Italic": Face(1.0, 0.365997314453125, 0),
        "Avenir/Black": Face(1.0, 0.365997314453125, 0),
        "Avenir/Black Oblique": Face(1.0, 0.365997314453125, 0),
        "Avenir/Book": Face(1.0, 0.365997314453125, 0),
        "Avenir/Book Oblique": Face(1.0, 0.365997314453125, 0),
        "Avenir/Heavy": Face(1.0, 0.365997314453125, 0),
        "Avenir/Heavy Oblique": Face(1.0, 0.365997314453125, 0),
        "Avenir/Light": Face(1.0, 0.365997314453125, 0),
        "Avenir/Light Oblique": Face(1.0, 0.365997314453125, 0),
        "Avenir/Medium": Face(1.0, 0.365997314453125, 0),
        "Avenir/Medium Oblique": Face(1.0, 0.365997314453125, 0),
        "Avenir/Oblique": Face(1.0, 0.365997314453125, 0),
        "Avenir/Roman": Face(1.0, 0.365997314453125, 0),
        "Baskerville/Bold": Face(1836, 522, 0, of: 2048),
        "Baskerville/Bold Italic": Face(1802, 511, 0, of: 2048),
        "Baskerville/Italic": Face(1804, 504, 0, of: 2048),
        "Baskerville/Regular": Face(1839, 504, 0, of: 2048),
        "Baskerville/SemiBold": Face(1835, 506, 0, of: 2048),
        "Baskerville/SemiBold Italic": Face(1849, 504, 0, of: 2048),
        "Bodoni 72/Bold": Face(0.923004150390625, 0.272003173828125, 0),
        "Bodoni 72/Book": Face(0.936004638671875, 0.2660064697265625, 0),
        "Bodoni 72/Book Italic": Face(0.9470062255859375, 0.2920074462890625, 0),
        "Courier New/Bold": Face(1705, 615, 0, of: 2048),
        "Courier New/Bold Italic": Face(1705, 615, 0, of: 2048),
        "Courier New/Italic": Face(1705, 615, 0, of: 2048),
        "Courier New/Regular": Face(1705, 615, 0, of: 2048),
        "Courier/Bold": Face(1544, 504, 0, of: 2048, fifth: true),
        "Courier/Bold Oblique": Face(1544, 504, 0, of: 2048, fifth: true),
        "Courier/Oblique": Face(1544, 504, 0, of: 2048, fifth: true),
        "Courier/Regular": Face(1544, 504, 0, of: 2048, fifth: true),
        "Didot/Bold": Face(0.968994140625, 0.29400634765625, 0.0260009765625, fifth: true),
        "Didot/Italic": Face(0.9420013427734375, 0.2899932861328125, 0.024993896484375),
        "Didot/Regular": Face(0.9409942626953125, 0.2989959716796875, 0.0240020751953125, fifth: true),
        "Futura/Bold": Face(1.03900146484375, 0.2599945068359375, 0.029998779296875, fifth: true),
        "Futura/Condensed ExtraBold": Face(2055, 553, 56, of: 2048),
        "Futura/Condensed Medium": Face(2014, 448, 60, of: 2048),
        "Futura/Medium": Face(2127, 532, 61, of: 2048),
        "Futura/Medium Italic": Face(2126, 539, 60, of: 2048),
        "Georgia/Bold": Face(1878, 449, 0, of: 2048),
        "Georgia/Bold Italic": Face(1878, 449, 0, of: 2048),
        "Georgia/Italic": Face(1878, 449, 0, of: 2048),
        "Georgia/Regular": Face(1878, 449, 0, of: 2048),
        "Helvetica Neue/Bold": Face(0.975006103515625, 0.2169952392578125, 0.0290069580078125),
        "Helvetica Neue/Bold Italic": Face(0.975006103515625, 0.2169952392578125, 0.0290069580078125),
        "Helvetica Neue/Condensed Black": Face(0.9720001220703125, 0.2270050048828125, 0.0279998779296875),
        "Helvetica Neue/Condensed Bold": Face(0.96099853515625, 0.2209930419921875, 0.0279998779296875),
        "Helvetica Neue/Italic": Face(0.957000732421875, 0.2129974365234375, 0.0279998779296875),
        "Helvetica Neue/Light": Face(0.9669952392578125, 0.2129974365234375, 0.0290069580078125),
        "Helvetica Neue/Light Italic": Face(0.9510040283203125, 0.2129974365234375, 0.0279998779296875),
        "Helvetica Neue/Medium": Face(0.975006103515625, 0.2169952392578125, 0.0290069580078125),
        "Helvetica Neue/Medium Italic": Face(0.975006103515625, 0.2169952392578125, 0.0290069580078125),
        "Helvetica Neue/Regular": Face(0.951995849609375, 0.2129974365234375, 0.0279998779296875),
        "Helvetica Neue/Thin": Face(0.9669952392578125, 0.2129974365234375, 0.0290069580078125),
        "Helvetica Neue/Thin Italic": Face(0.9669952392578125, 0.2129974365234375, 0.0290069580078125),
        "Helvetica Neue/UltraLight": Face(0.930999755859375, 0.2129974365234375, 0.0269927978515625),
        "Helvetica Neue/UltraLight Italic": Face(0.930999755859375, 0.2129974365234375, 0.0269927978515625),
        "Helvetica/Bold": Face(1577, 471, 0, of: 2048, fifth: true),
        "Helvetica/Bold Oblique": Face(1577, 471, 0, of: 2048, fifth: true),
        "Helvetica/Light": Face(0.7700042724609375, 0.2299957275390625, 0, fifth: true),
        "Helvetica/Light Oblique": Face(0.7700042724609375, 0.2299957275390625, 0, fifth: true),
        "Helvetica/Oblique": Face(1577, 471, 0, of: 2048, fifth: true),
        "Helvetica/Regular": Face(1577, 471, 0, of: 2048, fifth: true),
        "Menlo/Bold": Face(1901, 483, 0, of: 2048),
        "Menlo/Bold Italic": Face(1901, 483, 0, of: 2048),
        "Menlo/Italic": Face(1901, 483, 0, of: 2048),
        "Menlo/Regular": Face(1901, 483, 0, of: 2048),
        "System/Black": Face(1980, 432, 0, of: 2048),
        "System/Black Italic": Face(1980, 432, 0, of: 2048),
        "System/Bold": Face(1980, 432, 0, of: 2048),
        "System/Bold Italic": Face(1980, 432, 0, of: 2048),
        "System/Heavy": Face(1980, 432, 0, of: 2048),
        "System/Heavy Italic": Face(1980, 432, 0, of: 2048),
        "System/Light": Face(1980, 432, 0, of: 2048),
        "System/Light Italic": Face(1980, 432, 0, of: 2048),
        "System/Medium": Face(1980, 432, 0, of: 2048),
        "System/Medium Italic": Face(1980, 432, 0, of: 2048),
        "System/Regular": Face(1980, 432, 0, of: 2048),
        "System/Regular Italic": Face(1980, 432, 0, of: 2048),
        "System/Semibold": Face(1980, 432, 0, of: 2048),
        "System/Semibold Italic": Face(1980, 432, 0, of: 2048),
        "System/Thin": Face(1980, 432, 0, of: 2048),
        "System/Thin Italic": Face(1980, 432, 0, of: 2048),
        "System/Ultralight": Face(1980, 432, 0, of: 2048),
        "System/Ultralight Italic": Face(1980, 432, 0, of: 2048),
        "Times New Roman/Bold": Face(1825, 443, 87, of: 2048),
        "Times New Roman/Bold Italic": Face(1825, 443, 87, of: 2048),
        "Times New Roman/Italic": Face(1825, 443, 87, of: 2048),
        "Times New Roman/Regular": Face(1825, 443, 87, of: 2048),
        "Times/Bold": Face(1536, 512, 0, of: 2048, fifth: true),
        "Times/Bold Italic": Face(1536, 512, 0, of: 2048, fifth: true),
        "Times/Italic": Face(1536, 512, 0, of: 2048, fifth: true),
        "Times/Regular": Face(1536, 512, 0, of: 2048, fifth: true),
    ]

    /// The system font's spacings by face, in ten-thousandths of an em, at each of `systemSizes`:
    /// as SF Pro is tracked by size, and Inter, which stands in for it, is not.
    static let systemSpacings: [String: [Int]] = [
        "Black": [400, 393, 334, 276, 227, 190, 162, 115, 113, 64, 53, 83, 148, 183, 149, 130, 91, 71, 56, 56],
        "Black Italic": [400, 400, 365, 306, 257, 220, 193, 145, 147, 108, 116, 163, 239, 275, 241, 221, 182, 163, 148, 148],
        "Bold": [330, 203, 145, 86, 37, 5, -18, -59, -57, -105, -118, -91, -13, 44, 10, -10, -49, -69, -83, -83],
        "Bold Italic": [349, 222, 164, 105, 56, 24, 1, -40, -34, -68, -59, -10, 82, 138, 104, 85, 46, 26, 11, 11],
        "Heavy": [400, 311, 252, 194, 145, 110, 85, 40, 42, -6, -17, 12, 84, 130, 96, 76, 37, 18, 3, 3],
        "Heavy Italic": [400, 335, 276, 217, 168, 134, 108, 64, 69, 33, 42, 90, 175, 221, 187, 167, 128, 109, 94, 94],
        "Light": [164, 37, -21, -80, -129, -152, -166, -199, -191, -236, -252, -231, -131, -39, -73, -92, -131, -151, -166, -166],
        "Light Italic": [183, 56, -3, -62, -110, -134, -148, -181, -169, -200, -194, -151, -37, 55, 21, 1, -38, -57, -72, -72],
        "Medium": [228, 101, 42, -17, -65, -94, -111, -149, -144, -189, -202, -174, -85, -12, -46, -65, -105, -124, -139, -139],
        "Medium Italic": [238, 111, 52, -7, -55, -84, -101, -139, -130, -159, -147, -95, 9, 82, 48, 29, -10, -30, -45, -45],
        "Regular": [161, 34, -24, -83, -132, -158, -174, -209, -203, -247, -260, -234, -138, -57, -91, -111, -150, -169, -184, -184],
        "Regular Italic": [169, 42, -16, -75, -124, -149, -166, -201, -191, -218, -205, -152, -41, 41, 6, -13, -52, -72, -86, -86],
        "Semibold": [263, 136, 78, 19, -30, -60, -81, -120, -116, -163, -176, -150, -67, -2, -36, -55, -95, -114, -129, -129],
        "Semibold Italic": [279, 152, 94, 35, -14, -44, -65, -104, -96, -128, -117, -68, 30, 95, 61, 41, 2, -17, -32, -32],
        "Thin": [144, 18, -41, -100, -148, -170, -181, -211, -203, -249, -274, -257, -154, -52, -86, -106, -145, -164, -179, -179],
        "Thin Italic": [175, 48, -10, -69, -118, -139, -150, -181, -169, -205, -214, -181, -68, 34, 0, -20, -59, -78, -93, -93],
        "Ultralight": [176, 49, -10, -69, -117, -136, -144, -173, -163, -207, -231, -216, -106, 6, -29, -48, -87, -107, -121, -121],
        "Ultralight Italic": [210, 83, 25, -34, -83, -101, -110, -139, -127, -162, -173, -145, -27, 85, 50, 31, -8, -28, -42, -42],
    ]

    /// The other faces' spacings, in ten-thousandths of an em, the same at every size; none where
    /// the stand-in is as wide (those made to the same widths: Arimo, Tinos, Cousine, Gelasio).
    static let spacings: [String: Int] = [
        "Avenir Next/Bold": 216,
        "Avenir Next/Bold Italic": 155,
        "Avenir Next/Demi Bold": 56,
        "Avenir Next/Heavy": 300,
        "Avenir Next/Heavy Italic": 300,
        "Avenir Next/Italic": -27,
        "Avenir Next/Medium": 44,
        "Avenir Next/Medium Italic": -13,
        "Avenir Next/Regular": 24,
        "Avenir Next/Ultra Light": -40,
        "Avenir Next/Ultra Light Italic": -92,
        "Avenir/Book": -61,
        "Avenir/Book Oblique": -61,
        "Avenir/Heavy": -161,
        "Avenir/Heavy Oblique": -160,
        "Avenir/Light": -52,
        "Avenir/Light Oblique": -52,
        "Avenir/Medium": -14,
        "Avenir/Medium Oblique": -14,
        "Avenir/Oblique": -22,
        "Avenir/Roman": -23,
        "Baskerville/Bold": -300,
        "Baskerville/Bold Italic": -300,
        "Baskerville/Italic": -300,
        "Baskerville/Regular": -300,
        "Baskerville/SemiBold": -300,
        "Baskerville/SemiBold Italic": -300,
        "Bodoni 72/Bold": -300,
        "Bodoni 72/Book": -300,
        "Bodoni 72/Book Italic": -300,
        "Didot/Bold": 121,
        "Didot/Italic": -26,
        "Didot/Regular": 152,
        "Futura/Bold": 300,
        "Futura/Condensed ExtraBold": -300,
        "Futura/Condensed Medium": -300,
        "Futura/Medium": 179,
        "Futura/Medium Italic": 279,
        "Helvetica Neue/Condensed Black": -300,
        "Helvetica Neue/Condensed Bold": -300,
        "Helvetica Neue/Italic": -12,
        "Helvetica Neue/Light": -156,
        "Helvetica Neue/Light Italic": -165,
        "Helvetica Neue/Medium": 54,
        "Helvetica Neue/Medium Italic": 49,
        "Helvetica Neue/Regular": 17,
        "Helvetica Neue/Thin": -300,
        "Helvetica Neue/Thin Italic": -300,
        "Helvetica Neue/UltraLight": -300,
        "Helvetica Neue/UltraLight Italic": -300,
        "Menlo/Bold": 20,
        "Menlo/Bold Italic": 20,
        "Menlo/Italic": 20,
        "Menlo/Regular": 20,
    ]
}
