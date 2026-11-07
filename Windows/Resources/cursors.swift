// Draws the Mac's own pointers (Bezzle/Canvas/Cursors.swift) as Windows cursor files, and the
// resource script that puts them into Bezzle.exe: make-cursors.sh compiles it with Cursors.swift
// and runs it on the Mac, into Resources/Generated (git-ignored). Each .cur holds the pointer at
// 32, 48 and 64 pixels, for displays at 100, 150 and 200 percent; Windows picks the nearest.
// They are plain bitmaps: the resource compiler takes no PNG in a cursor.
//
// The ids, which Sources/Bezzle/Pointers.swift asks for: 100 + k a resize arrow k·15° from
// across, 200 + k the turning arrow at the corner k·15° from across, 300 turning in depth,
// 400 + mark the pen (none, add, remove, close, convert, carry on), 500 the knife, 600 and 601
// building (join, erase).

import AppKit

extension CGRect {
    init(center: CGPoint, size: CGSize) {
        self.init(x: center.x - size.width / 2, y: center.y - size.height / 2, width: size.width, height: size.height)
    }
}

/// The pointer drawn into a square of `cell` points at `scale` pixels a point, its image at the
/// top left as Windows takes it: a 32-bit bitmap as cursor files hold it (rows from the bottom,
/// colours not multiplied by their alpha, then an empty mask), and its hot spot in pixels.
func image(_ cursor: NSCursor, cell: CGFloat, scale: CGFloat) -> (dib: Data, size: Int, hot: (Int, Int)) {
    let px = Int((cell * scale).rounded())
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: px * 4, bitsPerPixel: 32)!
    rep.size = NSSize(width: cell, height: cell)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let picture = cursor.image
    picture.draw(in: NSRect(x: 0, y: cell - picture.size.height, width: picture.size.width, height: picture.size.height))
    NSGraphicsContext.restoreGraphicsState()
    var dib = Data()
    func put16(_ v: Int) { dib.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func put32(_ v: Int) { put16(v & 0xFFFF); put16((v >> 16) & 0xFFFF) }
    // BITMAPINFOHEADER: twice as high, for the colours and the mask under them.
    put32(40); put32(px); put32(px * 2); put16(1); put16(32); put32(0)
    let maskRow = (px + 31) / 32 * 4
    put32(px * px * 4 + maskRow * px); put32(0); put32(0); put32(0); put32(0)
    let bytes = rep.bitmapData!
    for y in (0..<px).reversed() {
        for x in 0..<px {
            let i = y * px * 4 + x * 4
            let r = Int(bytes[i]), g = Int(bytes[i + 1]), b = Int(bytes[i + 2]), a = Int(bytes[i + 3])
            func straight(_ c: Int) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (c * 255 + a / 2) / a)) }
            dib.append(contentsOf: [straight(b), straight(g), straight(r), UInt8(a)])
        }
    }
    dib.append(Data(count: maskRow * px))
    let hot = cursor.hotSpot
    return (dib, px, (Int((hot.x * scale).rounded()), Int((hot.y * scale).rounded())))
}

/// A cursor file: its images, each with its hot spot.
func cursorFile(_ cursor: NSCursor) -> Data {
    let images = [1.0, 1.5, 2.0].map { image(cursor, cell: 32, scale: $0) }
    var data = Data()
    func put16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func put32(_ v: Int) { put16(v & 0xFFFF); put16((v >> 16) & 0xFFFF) }
    put16(0); put16(2); put16(images.count)
    var offset = 6 + 16 * images.count
    for i in images {
        data.append(UInt8(i.size >= 256 ? 0 : i.size))
        data.append(UInt8(i.size >= 256 ? 0 : i.size))
        data.append(0); data.append(0)
        put16(i.hot.0); put16(i.hot.1)
        put32(i.dib.count); put32(offset)
        offset += i.dib.count
    }
    for i in images { data.append(i.dib) }
    return data
}

let out = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

var cursors: [(id: Int, name: String, cursor: NSCursor)] = []
for k in 0..<12 { cursors.append((100 + k, "resize-\(k * 15)", Cursors.resize(Double(k * 15)))) }
for k in 0..<24 { cursors.append((200 + k, "rotate-\(k * 15)", Cursors.rotate(Double(k * 15)))) }
cursors.append((300, "turn", Cursors.turn))
let marks: [(Cursors.PenMark, String)] = [(.none, "none"), (.add, "add"), (.remove, "remove"), (.close, "close"), (.convert, "convert"), (.carryOn, "carry-on")]
for (i, m) in marks.enumerated() { cursors.append((400 + i, "pen-\(m.1)", Cursors.pen(m.0))) }
cursors.append((500, "knife", Cursors.knife))
cursors.append((600, "build", Cursors.build(erase: false)))
cursors.append((601, "build-erase", Cursors.build(erase: true)))

var script = "// Made by Resources/make-cursors.sh from Bezzle/Canvas/Cursors.swift; do not edit.\n"
for c in cursors {
    try cursorFile(c.cursor).write(to: out.appendingPathComponent("\(c.name).cur"))
    script += "\(c.id) CURSOR \"\(c.name).cur\"\n"
}
try script.write(to: out.appendingPathComponent("Bezzle.rc"), atomically: true, encoding: .utf8)
print("\(cursors.count) cursors in \(out.path)")
