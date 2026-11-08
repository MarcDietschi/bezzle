import Foundation
import BezzleCore

// Draws every artboard of a design to PNG files with the core and Skia, as Bezzle for Windows
// draws them: for comparing with the Mac (Web/tools/WebTruthTests.swift makes the Mac's).
//
//   bezzle-render <open fonts folder> <design.bezzle> <out folder> [scale]

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("bezzle-render <open fonts folder> <design.bezzle> <out folder> [scale]")
    exit(2)
}
let scale = arguments.count > 4 ? Double(arguments[4]) ?? 1 : 1
do {
    try WindowsCore.loadFonts(from: URL(fileURLWithPath: arguments[1]))
    // With BEZZLE_FIRST (designs, separated by ;), each is opened and its first artboard drawn
    // small before, as home's thumbnails are.
    for path in (ProcessInfo.processInfo.environment["BEZZLE_FIRST"] ?? "").split(separator: ";") {
        var buffer: UnsafeMutableRawPointer?
        var size = (0, 0)
        let drawn = WindowsCore.thumbnail(of: URL(fileURLWithPath: String(path)), width: 300, height: 188, scale: 1) { w, h in
            let p = UnsafeMutableRawPointer.allocate(byteCount: w * h * 4, alignment: 16)
            p.initializeMemory(as: UInt8.self, repeating: 0, count: w * h * 4)
            buffer = p
            size = (w, h)
            return p
        }
        // Whether it drew, and how much of it, for trying home's thumbnails.
        var painted = 0
        if let b = buffer { painted = (0..<(size.0 * size.1)).filter { b.load(fromByteOffset: $0 * 4 + 3, as: UInt8.self) > 0 }.count }
        print("thumbnail \(path): \(drawn ? "drawn" : "not drawn"), \(painted) of \(size.0 * size.1) pixels painted")
    }
    // A file from Adobe XD, Figma, Sketch or Photoshop is brought in first, as a new design in
    // the out folder (or BEZZLE_IMPORT_TO), as Bezzle brings it in; what came across is said.
    var design = URL(fileURLWithPath: arguments[2])
    // A web page (http:, https: or file:) is brought in first as Bezzle brings a website in, read
    // at BEZZLE_WEB_WIDTHS (1440 otherwise, separated by commas), its cookie banners hidden unless
    // BEZZLE_WEB_BANNERS is set; BEZZLE_WEB_SCALE reads it at that many pixels to a CSS pixel.
    let typed = arguments[2].lowercased()
    if typed.hasPrefix("http://") || typed.hasPrefix("https://") || typed.hasPrefix("file:"), let page = WindowsCore.webAddress(arguments[2]) {
        let into = ProcessInfo.processInfo.environment["BEZZLE_IMPORT_TO"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: arguments[3])
        let widths = (ProcessInfo.processInfo.environment["BEZZLE_WEB_WIDTHS"] ?? "").split(separator: ",").compactMap { Double($0) }
        let started = Date()
        var said = ""
        let (made, summary) = try await WindowsCore.importWebsite(page, widths: widths.map(WindowsCore.WebWidth.init), hideBanners: ProcessInfo.processInfo.environment["BEZZLE_WEB_BANNERS"] == nil, into: into) { what, done in
            if what != said { print("  \(Int(done * 100))% \(what)"); said = what }
        }
        print("brought in from \(summary.source) in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(summary.artboards) artboards, \(summary.layers) layers → \(made.lastPathComponent)")
        for line in summary.lines { print("  \(line)") }
        if !summary.missingFonts.isEmpty { print("  fonts not here: \(summary.missingFonts.joined(separator: ", "))") }
        design = made
    } else if WindowsCore.imports(design) {
        let into = ProcessInfo.processInfo.environment["BEZZLE_IMPORT_TO"].map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: arguments[3])
        let started = Date()
        let (made, summary) = try WindowsCore.importDesign(design, into: into)
        print("brought in from \(summary.source) in \(Int(Date().timeIntervalSince(started) * 1000)) ms: \(summary.artboards) artboards, \(summary.layers) layers → \(made.lastPathComponent)")
        for line in summary.lines { print("  \(line)") }
        if !summary.missingFonts.isEmpty { print("  fonts not here: \(summary.missingFonts.joined(separator: ", "))") }
        design = made
    }
    var boards = try WindowsCore.open(design)
    // With BEZZLE_TEXTS (a file), how the core measures the design's texts and probe texts is
    // written there instead (TextReport.swift), for comparing with Text Kit; BEZZLE_TEXTS_PROBES=0
    // leaves the probes out.
    if let file = ProcessInfo.processInfo.environment["BEZZLE_TEXTS"] {
        let name = design.deletingPathExtension().lastPathComponent
        try Data(WindowsCore.textReport(design: name).utf8).write(to: URL(fileURLWithPath: file))
        print("texts measured → \(file)")
        exit(0)
    }
    // With BEZZLE_INK (a file), where letters are drawn against their baselines (TextReport.swift).
    if let file = ProcessInfo.processInfo.environment["BEZZLE_INK"] {
        try Data(WindowsCore.inkReport().utf8).write(to: URL(fileURLWithPath: file))
        print("ink measured → \(file)")
        exit(0)
    }
    // With BEZZLE_DROP (files separated by ;, then @x,y on the canvas), they are let go there
    // first, as when dragged onto the canvas; the design is saved with them.
    if let drop = ProcessInfo.processInfo.environment["BEZZLE_DROP"], let at = drop.split(separator: "@").last,
       let xy = Optional(at.split(separator: ",").compactMap { Double($0) }), xy.count == 2 {
        let files = drop.split(separator: "@").first.map { $0.split(separator: ";").map { URL(fileURLWithPath: String($0)) } } ?? []
        let p = BezzleCore.CGPoint(x: xy[0], y: xy[1])
        let made = WindowsCore.drop(files: files, text: nil, at: p, on: WindowsCore.dropTarget(at: p, zoom: 1))
        print("dropped: \(made.map { "\($0.count) layers" } ?? "nothing")")
        try WindowsCore.save()
        boards = WindowsCore.boards()
    }
    // With BEZZLE_TYPING (steps separated by |, TypingScript.swift), a text is typed into first,
    // as the canvas types; what happens is said, and the artboards drawn as it leaves them.
    if let script = ProcessInfo.processInfo.environment["BEZZLE_TYPING"] {
        print(WindowsCore.typingScript(script))
        boards = WindowsCore.boards()
    }
    let out = URL(fileURLWithPath: arguments[3])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    // With BEZZLE_CUT (x1,y1,x2,y2 on the canvas), the knife's line is drawn there first, and
    // what it cuts said.
    if let cut = ProcessInfo.processInfo.environment["BEZZLE_CUT"] {
        let v = cut.split(separator: ",").compactMap { Double($0) }
        if v.count == 4 { print(WindowsCore.debugCut(from: BezzleCore.CGPoint(x: v[0], y: v[1]), to: BezzleCore.CGPoint(x: v[2], y: v[3]))) }
        boards = WindowsCore.boards()
    }
    // With BEZZLE_OUTLINE (a file), every text is first made the outlines of its letters, as
    // Convert to Path makes them, and what each became written there (Host/Outlining.swift).
    if let file = ProcessInfo.processInfo.environment["BEZZLE_OUTLINE"] {
        try Data(WindowsCore.outlineEveryText().utf8).write(to: URL(fileURLWithPath: file))
        boards = WindowsCore.boards()
    }
    // With BEZZLE_EXPORT (png, jpeg, webp, avif, svg or pdf), every artboard is exported there as
    // the Export sheet exports them, at the scale given, at BEZZLE_QUALITY (0…1, 0.9 otherwise);
    // with BEZZLE_SCOPE=marked, what is marked for export instead, as each is marked.
    if let format = ProcessInfo.processInfo.environment["BEZZLE_EXPORT"] {
        let quality = ProcessInfo.processInfo.environment["BEZZLE_QUALITY"].flatMap { Double($0) } ?? 0.9
        let scope = ProcessInfo.processInfo.environment["BEZZLE_SCOPE"] ?? "all"
        let outcome = await WindowsCore.export(scope, format: format, scale: scale, quality: quality, selection: [], to: out, replacing: true) { _ in }
        print("exported: \(outcome.written) written, \(outcome.missed) missed → \(outcome.shown.lastPathComponent)")
        exit(0)
    }
    for (k, board) in boards.enumerated() {
        // With BEZZLE_TWICE, drawn once before: what a second drawing makes (the app draws over and over).
        if ProcessInfo.processInfo.environment["BEZZLE_TWICE"] != nil { _ = WindowsCore.render(board: board.index, scale: scale) }
        let started = Date()
        guard let picture = WindowsCore.render(board: board.index, scale: scale) else {
            print("\(board.name): nothing drawn")
            continue
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let file = out.appendingPathComponent(String(format: "%02d.png", k))
        try WindowsCore.writePNG(picture.pixels, width: picture.width, height: picture.height, to: file)
        print("\(board.name): \(picture.width)×\(picture.height) in \(ms) ms → \(file.lastPathComponent)")
    }
} catch {
    print("bezzle-render: \(error)")
    exit(1)
}
