// Draws the Mac's icons as Windows icon files, into Resources/Generated (git-ignored): make-icons.sh
// runs it on the Mac. Bezzle.ico is the app's (Bezzle/Assets.xcassets/AppIcon), which the installer
// puts into Bezzle.exe and shows in the Start menu and the list of installed apps;
// BezzleDocument.ico is a design's (Bezzle/App/BezzleDocument.icns), for Explorer.
//
// Each holds the sizes Windows asks for at 100 to 200 percent: plain 32-bit bitmaps up to 128
// pixels, as every part of Windows reads them, and PNG at 256, as icon files keep their largest.
//
//   swift icons.swift <AppIcon.appiconset> <BezzleDocument.icns> <out folder>

import AppKit

/// The picture at `px` pixels square, as straight (not premultiplied) BGRA rows from the top.
func pixels(_ image: NSImage, _ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: px * 4, bitsPerPixel: 32)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    image.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .copy, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

/// One image of an icon file: a bitmap (BITMAPINFOHEADER twice as high, rows from the bottom, then
/// an empty mask) or, at 256, a PNG.
func entry(_ image: NSImage, _ px: Int) -> Data {
    let rep = pixels(image, px)
    if px >= 256 { return rep.representation(using: .png, properties: [:])! }
    var dib = Data()
    func put16(_ v: Int) { dib.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func put32(_ v: Int) { put16(v & 0xFFFF); put16((v >> 16) & 0xFFFF) }
    let maskRow = (px + 31) / 32 * 4
    put32(40); put32(px); put32(px * 2); put16(1); put16(32); put32(0)
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
    return dib
}

func iconFile(_ image: NSImage) -> Data {
    let sizes = [16, 20, 24, 32, 40, 48, 64, 96, 128, 256]
    let images = sizes.map { ($0, entry(image, $0)) }
    var data = Data()
    func put16(_ v: Int) { data.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]) }
    func put32(_ v: Int) { put16(v & 0xFFFF); put16((v >> 16) & 0xFFFF) }
    put16(0); put16(1); put16(images.count)
    var offset = 6 + 16 * images.count
    for (px, bytes) in images {
        data.append(UInt8(px >= 256 ? 0 : px))
        data.append(UInt8(px >= 256 ? 0 : px))
        data.append(0); data.append(0)
        put16(1); put16(32)
        put32(bytes.count); put32(offset)
        offset += bytes.count
    }
    for (_, bytes) in images { data.append(bytes) }
    return data
}

let arguments = CommandLine.arguments
let appIcons = URL(fileURLWithPath: arguments[1], isDirectory: true)
let documentIcon = URL(fileURLWithPath: arguments[2])
let out = URL(fileURLWithPath: arguments[3], isDirectory: true)
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

// The app's icon from its largest drawing, as each size is drawn down from it.
let app = NSImage()
for name in ["icon_512x512@2x.png", "icon_512x512.png", "icon_256x256.png", "icon_128x128.png", "icon_32x32.png", "icon_16x16.png"] {
    if let rep = NSImageRep(contentsOf: appIcons.appendingPathComponent(name)) { app.addRepresentation(rep) }
}
app.size = NSSize(width: 1024, height: 1024)
try iconFile(app).write(to: out.appendingPathComponent("Bezzle.ico"))
guard let document = NSImage(contentsOf: documentIcon) else { fatalError("no \(documentIcon.path)") }
try iconFile(document).write(to: out.appendingPathComponent("BezzleDocument.ico"))

/// The installer's pictures (Installer/Bezzle.iss), at twice the size it shows them: the icon on
/// the top right of its pages, and the panel beside its last page, Bezzle's paper with the icon.
func picture(width: Int, height: Int, paper: Bool, icon side: Int, top: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: width * 4, bitsPerPixel: 32)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    context.imageInterpolation = .high
    NSGraphicsContext.current = context
    // The paper of Bezzle's home, lighter at the top, as the Mac's document icon is cut from.
    let gradient = NSGradient(starting: NSColor(srgbRed: 0.976, green: 0.965, blue: 0.941, alpha: 1),
                              ending: NSColor(srgbRed: 0.937, green: 0.922, blue: 0.890, alpha: 1))!
    if paper { gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90) }
    else { NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill() }
    app.draw(in: NSRect(x: (width - side) / 2, y: height - top - side, width: side, height: side), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
try picture(width: 110, height: 110, paper: false, icon: 110, top: 0).write(to: out.appendingPathComponent("SetupSmall.png"))
try picture(width: 328, height: 628, paper: true, icon: 200, top: 150).write(to: out.appendingPathComponent("SetupPanel.png"))
print("Bezzle.ico, BezzleDocument.ico and the installer's pictures in \(out.path)")
