import Foundation
import CBezzleHost

// From Bezzle/Store/CutoutOperations.swift: a picture cut out into a new picture beside it, named as
// the Mac names it, so a cutout made on either is found by the other in a shared design.

extension WindowsCore {
    /// What the cutout of a picture is called: the same each time it is cut out with the same
    /// picks, so taking the background away again finds it made, however often it was given back.
    /// Cut out with the learned matte, it is named for the model's version, so one cut without it
    /// (on a Mac, by Vision alone) is never taken for one cut with it.
    nonisolated static func cutoutName(of asset: String, picks: [CGPoint]?, learned: Bool = true) -> String {
        let stem = (asset as NSString).deletingPathExtension + (learned ? "-cutout-m\(SubjectMatte.version)" : "-cutout")
        guard let picks, !picks.isEmpty else { return "\(stem).png" }
        // FNV-1a over the picks to a ten-thousandth, the same on every computer and every run.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in picks.map({ String(format: "%.4f,%.4f", Double($0.x), Double($0.y)) }).joined(separator: ";").utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100_0000_01b3
        }
        return "\(stem)-\(String(hash, radix: 16)).png"
    }

    /// The outline of a cutout, from how solid it is as it was kept: the same however it came to be
    /// there, made here, made before, or made by someone sharing the design.
    nonisolated static func cutoutOutline(of cutout: URL) throws -> String {
        guard let data = try? Data(contentsOf: cutout), let image = CutoutMaker.Pixels(file: data, longest: 1024) else {
            throw CutoutMaker.Failure.unreadable
        }
        return CutoutMaker.outline(of: image)
    }

    /// The picture at `source` cut out, and kept as a PNG at `target`: written beside it first, so a
    /// cutout cut short is never taken for one made. Returns the outline of what it leaves.
    nonisolated static func makeCutout(of source: URL, picks: [CGPoint]?, to target: URL, matting: any CutoutMaker.Matting,
                                       told: (CutoutMaker.Progress) -> Void = { _ in }) throws -> String {
        // At its own size, turned upright as it is drawn.
        guard let data = try? Data(contentsOf: source), let picture = CutoutMaker.Pixels(file: data) else { throw CutoutMaker.Failure.unreadable }
        let cut = try CutoutMaker.cut(picture, picks: picks, matting: matting, told: told)
        let writing = target.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: writing) }
        guard let png = encodePNG(cut) else { throw CutoutMaker.Failure.unreadable }
        do { try png.write(to: writing) } catch { throw CutoutMaker.Failure.unreadable }
        // Another cutting out of the same picture may have put it there meanwhile: it is the same.
        if !FileManager.default.fileExists(atPath: target.path) {
            do { try FileManager.default.moveItem(at: writing, to: target) } catch { throw CutoutMaker.Failure.unreadable }
        }
        let outline = try cutoutOutline(of: target)
        told(CutoutMaker.Progress(done: 1))
        return outline
    }

    /// Pixels as a PNG file's bytes.
    nonisolated static func encodePNG(_ p: CutoutMaker.Pixels) -> Data? {
        var capacity = Int64(p.w * p.h * 4 + 65536)
        for _ in 0..<2 {
            var out = Data(count: Int(capacity))
            let written = p.bytes.withUnsafeBytes { from in
                out.withUnsafeMutableBytes { bz_png_encode(Int32(p.w), Int32(p.h), from.baseAddress, 0, $0.baseAddress, capacity) }
            }
            if written > 0 { return out.prefix(Int(written)) }
            guard written < -1 else { return nil }
            capacity = -written
        }
        return nil
    }
}

// MARK: - Taking backgrounds away in the open design

extension WindowsCore {
    /// A picture being cut out, as the canvas and the inspector show it while it is (the Mac's
    /// CutoutWork).
    public struct CutoutWork {
        /// How far along, 0…1.
        public var done: Double = 0
        /// Roughly where the subject is, once it has been found.
        public var found: CutoutFound?
        /// When it began, on the clock animations run by (`now`).
        public let began = WindowsCore.now
    }

    /// Where the subject was found, as the canvas draws the work going on (the Mac's CutoutTool
    /// makes the same of the grey picture it is given): each mask 0…255 a pixel, at most 900
    /// across, rows top first.
    public struct CutoutFound: Sendable {
        public let width: Int, height: Int
        /// White where the subject is not: the rest sinks into the table.
        public let background: [UInt8]
        /// A narrow line just outside the subject, for tracing it in pencil.
        public let edge: [UInt8]
        /// Where the subject is on the whole, across and down from the top left, 0…1.
        public let middle: CGPoint
    }

    /// The layers whose pictures are being cut out in the open design (the Mac's store.cuttingOut).
    nonisolated(unsafe) public internal(set) static var cuttingOut: [UUID: CutoutWork] = [:]
    /// Why the background could not be taken away, said in the inspector for a moment (the Mac's
    /// cutoutTrouble), in Bezzle's English words for the app to say in its language.
    nonisolated(unsafe) public internal(set) static var cutoutTrouble: String?
    /// Told, on the main thread, when a design's cutting out moved on (`edited` when the design
    /// changed): the window of that design draws it again.
    nonisolated(unsafe) public static var cutoutsChanged: (@MainActor (_ slot: Slot?, _ edited: Bool) -> Void)?

    /// Why a background could not be taken away, in the Mac's words (and Windows' own).
    enum CutoutTrouble: Swift.Error, CustomStringConvertible {
        case noPictures, readOnly, noMatte, failed(CutoutMaker.Failure)

        /// As the inspector says it, in English (the app translates).
        var description: String {
            switch self {
            case .noPictures: "Only a layer filled with a picture has a background to take away."
            case .readOnly: "This design can only be looked at."
            case .noMatte: "Bezzle cannot find subjects on this PC: what finds them did not load."
            case .failed(.noSubject): "Nothing in the picture stands out from its background."
            case .failed(.nothingPicked): "Nothing stands out where the picture was picked."
            case .failed(.unreadable): "The picture could not be read."
            }
        }
    }

    /// Whether Bezzle takes backgrounds away here: its subject matte and ONNX Runtime are beside it.
    public static var removesBackground: Bool {
        if let known = knowsMatte { return known }
        let known = SubjectModel.isAvailable
        knowsMatte = known
        return known
    }
    nonisolated(unsafe) private static var knowsMatte: Bool?

    /// The layers among `ids` filled with a picture, that are not locked.
    private static func pictures(_ ids: [UUID]) -> [Node] {
        guard let doc = design else { return [] }
        return ids.compactMap { doc.node($0) }.filter { !$0.isArtboard && !$0.locked && $0.fill.on && $0.fill.image != nil }
    }

    /// Whether every one of `ids` is filled with a picture a subject can be cut out of: not text,
    /// whose letters it would leave little of (the Mac's Fill card asks the same).
    public static func cutsOut(_ ids: [UUID]) -> Bool {
        guard let doc = design, !ids.isEmpty else { return false }
        return ids.allSatisfy { id in doc.node(id).map { $0.fill.on && $0.fill.image != nil && $0.kind != .text } ?? false }
    }

    public static func canRemoveBackground(_ ids: [UUID]) -> Bool {
        removesBackground && !isReadOnly && cuttingOut.isEmpty && pictures(ids).contains { $0.fill.image?.cutout == nil }
    }

    public static func canRestoreBackground(_ ids: [UUID]) -> Bool {
        !isReadOnly && pictures(ids).contains { $0.fill.image?.cutout != nil }
    }

    /// Whether the pictures filling `ids` show their subject alone: cut out, or being cut out;
    /// nil when some do and some do not, or none is a picture.
    public static func showsSubjectAlone(_ ids: [UUID]) -> Bool? {
        let those = pictures(ids)
        guard !those.isEmpty else { return nil }
        if ids.contains(where: { cuttingOut[$0] != nil }) { return true }
        let cut = those.map { $0.fill.image?.cutout != nil }
        if cut.allSatisfy({ $0 }) { return true }
        return cut.allSatisfy { !$0 } ? false : nil
    }

    /// How far the cutting out of the pictures filling `ids` has come, the least of them; nil when
    /// none is being cut out.
    public static func cutoutProgress(_ ids: [UUID]) -> Double? {
        ids.compactMap { cuttingOut[$0]?.done }.min()
    }

    /// Takes the background away from the pictures filling `ids`, saying in the inspector why
    /// when it could not.
    public static func removeBackground(_ ids: [UUID]) {
        let ids = pictures(ids).filter { $0.fill.image?.cutout == nil }.map(\.id)
        guard !ids.isEmpty else { return }
        cutoutTrouble = nil
        let slot = active
        Task {
            do {
                try await cutOut(ids, picks: nil)
            } catch {
                trouble(error, in: slot)
            }
        }
    }

    /// Says in the inspector, for a moment, why a background could not be taken away.
    public static func trouble(_ error: Swift.Error, in slot: Slot?) {
        let said = (error as? CutoutTrouble)?.description ?? "The picture could not be cut out."
        within(slot) { cutoutTrouble = said }
        cutoutsChanged?(slot, false)
        Task {
            try? await Task.sleep(for: .seconds(6))
            var gone = false
            within(slot) {
                if cutoutTrouble == said {
                    cutoutTrouble = nil
                    gone = true
                }
            }
            if gone { cutoutsChanged?(slot, false) }
        }
    }

    /// Shows the pictures filling `ids` whole again.
    public static func restoreBackground(_ ids: [UUID]) {
        let cut = pictures(ids).filter { $0.fill.image?.cutout != nil }.map(\.id)
        guard !cut.isEmpty else { return }
        edit { d in for id in cut { d.update(id) { $0.fill.image?.cutout = nil } } }
    }

    /// `body` with `slot`'s design as the one worked on, if it is still open; with no slots (a
    /// tool without tabs), as it is.
    private static func within(_ slot: Slot?, _ body: () -> Void) {
        guard let slot else { body(); return }
        guard slot.isOpen else { return }
        using(slot, body)
    }

    /// Cuts out the pictures filling `ids`: the subjects at `picks`, 0…1 across and down each
    /// picture, or all that stand out. A picture filling several layers is cut out once. Returns
    /// the layers that show a cutout now: those still showing the picture they had once it is made.
    /// The design is the one in front as it is asked; it may go behind meanwhile.
    @discardableResult
    public static func cutOut(_ ids: [UUID], picks: [CGPoint]? = nil) async throws -> [UUID] {
        guard !isReadOnly else { throw CutoutTrouble.readOnly }
        let slot = active
        var layers: [String: [UUID]] = [:]
        for id in ids {
            guard let n = design?.node(id), n.fill.on, let image = n.fill.image else { continue }
            layers[image.asset, default: []].append(id)
        }
        guard let folder = assets.folder, !layers.isEmpty else { throw CutoutTrouble.noPictures }
        for id in ids { cuttingOut[id] = CutoutWork() }
        cutoutsChanged?(slot, false)
        defer {
            within(slot) { for id in ids { cuttingOut[id] = nil } }
            cutoutsChanged?(slot, false)
        }

        // The learned matte, unless every picture was cut out with it before.
        let fine = { (asset: String) in folder.appendingPathComponent(cutoutName(of: asset, picks: picks, learned: true)) }
        let matte = layers.keys.allSatisfy({ FileManager.default.fileExists(atPath: fine($0).path) }) ? nil : await SubjectModel.shared.matte()

        var made: [String: Cutout] = [:], problem: CutoutTrouble?
        for asset in layers.keys.sorted() {
            let learned = matte != nil || FileManager.default.fileExists(atPath: fine(asset).path)
            let name = cutoutName(of: asset, picks: picks, learned: learned)
            let source = folder.appendingPathComponent(asset), target = folder.appendingPathComponent(name)
            // Without the matte, only a cutout made before (here, or on a Mac) can be shown again.
            guard matte != nil || FileManager.default.fileExists(atPath: target.path) else {
                problem = problem ?? .noMatte
                continue
            }
            // Each step told to the layers it fills, as it is taken.
            let showing = layers[asset] ?? []
            let told: @Sendable (CutoutMaker.Progress) -> Void = { progress in
                let found = progress.found.map { Self.found($0) }
                Task { @MainActor in
                    within(slot) {
                        for id in showing {
                            cuttingOut[id]?.done = progress.done
                            if let found { cuttingOut[id]?.found = found }
                        }
                    }
                    cutoutsChanged?(slot, false)
                }
            }
            do {
                // Cut out before, and given back since, it is shown again as it was.
                let outline = try await Task.detached(priority: .userInitiated) {
                    if FileManager.default.fileExists(atPath: target.path) { return try cutoutOutline(of: target) }
                    guard let matte else { throw CutoutMaker.Failure.unreadable }
                    return try makeCutout(of: source, picks: picks, to: target, matting: RememberedMatte(matting: matte, key: source.path), told: told)
                }.value
                // Skia is given it by its name, as the design's other pictures.
                if let data = try? Data(contentsOf: target) { giveSkia(name, data) }
                made[asset] = Cutout(asset: name, picks: picks, outline: outline)
            } catch {
                problem = problem ?? .failed(error as? CutoutMaker.Failure ?? .unreadable)
            }
        }
        if made.isEmpty, let problem { throw problem }

        // Made after the click that asked for it is over, and after any drag going on meanwhile:
        // a step of the undo history of its own.
        while slot?.isOpen ?? true, inGesture(slot) { try? await Task.sleep(for: .milliseconds(200)) }
        var shown: [UUID] = []
        within(slot) {
            guard design != nil else { return }
            edit { d in
                for (asset, ids) in layers {
                    guard let cutout = made[asset] else { continue }
                    for id in ids {
                        d.update(id) { n in
                            guard n.fill.image?.asset == asset else { return }
                            n.fill.image?.cutout = cutout
                            shown.append(id)
                        }
                    }
                }
            }
        }
        cutoutsChanged?(slot, true)
        return shown
    }

    /// Whether a drag is going on in `slot`'s design, whose steps a change made now would be lost in.
    private static func inGesture(_ slot: Slot?) -> Bool {
        var dragging = false
        within(slot) { dragging = Editing.gestureStart != nil }
        return dragging
    }

    /// What the canvas draws of where the subject was found (the Mac's CutoutTool.inverted, edge
    /// and middle), from the subject at the size it was worked on.
    nonisolated static func found(_ subject: CutoutMaker.Plane) -> CutoutFound {
        let shrink = min(1, 900 / Double(max(subject.w, subject.h)))
        let w = max(1, Int(Double(subject.w) * shrink)), h = max(1, Int(Double(subject.h) * shrink))
        let small = CutoutMaker.resample(subject, w, h)
        let inside = (0..<(w * h)).map { UInt8(min(max(small.p[$0], 0), 1) * 255 + 0.5) }
        // The most solid within reach, across and then down; less what was there.
        let reach = 2
        var across = inside, edge = inside
        for y in 0..<h {
            for x in 0..<w {
                var most: UInt8 = 0
                for d in -reach...reach where x + d >= 0 && x + d < w { most = max(most, inside[y * w + x + d]) }
                across[y * w + x] = most
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var most: UInt8 = 0
                for d in -reach...reach where y + d >= 0 && y + d < h { most = max(most, across[(y + d) * w + x]) }
                edge[y * w + x] = most > inside[y * w + x] ? most - inside[y * w + x] : 0
            }
        }
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in stride(from: 0, to: h, by: 2) {
            for x in stride(from: 0, to: w, by: 2) where inside[y * w + x] > 127 {
                sx += Double(x)
                sy += Double(y)
                n += 1
            }
        }
        let middle = n > 0 ? CGPoint(x: (sx / n + 0.5) / Double(w), y: (sy / n + 0.5) / Double(h)) : CGPoint(x: 0.5, y: 0.5)
        return CutoutFound(width: w, height: h, background: inside.map { 255 - $0 }, edge: edge, middle: middle)
    }
}

// MARK: - Trying it without the app

extension WindowsCore {
    /// What `bezzle-render <fonts> cutout <out>` does with the photos BEZZLE_PHOTOS names (separated
    /// by ;): each cut out as Bezzle cuts it out, into `out` as <name>-cutout.png with its outline
    /// (<name>-outline.txt), the matte as the model made it (<name>-matte.png, and with
    /// BEZZLE_MATTE_RAW its 2,048 × 2,048 floats, <name>-matte.f32, and what the model was given,
    /// <name>-input.f32), and the parts a click keeps or drops (<name>-parts.txt); BEZZLE_PICKS
    /// ("x,y;x,y") keeps only some. Says how long each step took and where the model ran;
    /// BEZZLE_MATTE_TWICE runs the model twice, the second time as it runs once warm.
    public static func tryCutouts(_ photos: [URL], into out: URL) async -> [String] {
        var said: [String] = []
        let started = Date()
        guard let matte = await SubjectModel.shared.matte() else {
            return ["no subject matte: \(SubjectModel.shared.trouble ?? "none at BEZZLE_MATTE_MODEL or beside Bezzle")"]
        }
        said.append("model loaded on \(matte.device) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
        let environment = ProcessInfo.processInfo.environment
        let picks: [CGPoint]? = environment["BEZZLE_PICKS"].map { text in
            text.split(separator: ";").compactMap { pair in
                let xy = pair.split(separator: ",").compactMap { Double($0) }
                return xy.count == 2 ? CGPoint(x: xy[0], y: xy[1]) : nil
            }
        }
        let raw = environment["BEZZLE_MATTE_RAW"] != nil, twice = environment["BEZZLE_MATTE_TWICE"] != nil
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for photo in photos {
            let name = photo.deletingPathExtension().lastPathComponent
            let lines = await Task.detached(priority: .userInitiated) { () -> [String] in
                var lines: [String] = []
                func time<T>(_ what: String, _ body: () throws -> T) rethrows -> T {
                    let t0 = Date()
                    let made = try body()
                    lines.append("\(name): \(what) \(String(format: "%.3f", Date().timeIntervalSince(t0))) s")
                    return made
                }
                guard let data = try? Data(contentsOf: photo), let picture = time("read", { CutoutMaker.Pixels(file: data) }) else {
                    return ["\(name): could not be read"]
                }
                // The matte alone, of the picture as it is worked on, timed (twice, asked: the first run
                // after loading is slower on a graphics card).
                let shrink = min(1, 2048 / Double(max(picture.w, picture.h)))
                let ww = max(1, Int((Double(picture.w) * shrink).rounded())), wh = max(1, Int((Double(picture.h) * shrink).rounded()))
                guard let work = (shrink < 1 ? picture.scaled(ww, wh) : picture)?.overWhite() else { return ["\(name): could not be scaled"] }
                do {
                    let learned = try time("matte", { try matte.matte(of: work, remembered: name) })
                    lines.append("\(name): matte made on \(matte.device)")
                    if twice { _ = try time("matte again", { try matte.matte(of: work) }) }
                    if raw {
                        let floats = Data(bytes: learned.p, count: learned.count * 4)
                        try? floats.write(to: out.appendingPathComponent("\(name)-matte.f32"))
                        // And what the model was given: red, green and blue planes, 2,048 square.
                        if let input = try? SubjectMatte.square(work) {
                            try? input.withUnsafeBytes { Data($0) }.write(to: out.appendingPathComponent("\(name)-input.f32"))
                        }
                    }
                    let small = CutoutMaker.resample(learned, ww, wh)
                    var grey = [UInt8](repeating: 255, count: ww * wh * 4)
                    for i in 0..<(ww * wh) {
                        let v = UInt8(min(max(small.p[i], 0), 1) * 255 + 0.5)
                        grey[i * 4] = v; grey[i * 4 + 1] = v; grey[i * 4 + 2] = v
                    }
                    if let png = encodePNG(CutoutMaker.Pixels(w: ww, h: wh, bytes: grey)) { try? png.write(to: out.appendingPathComponent("\(name)-matte.png")) }
                    let subjects = time("parts", { CutoutMaker.subjects(of: small, ww, wh) })
                    let parts = subjects.parts.map { p in
                        String(format: "%.4f,%.4f %.0f%%", Double(p.point.x), Double(p.point.y),
                               Double(p.outline.boundingBoxOfPath.width * p.outline.boundingBoxOfPath.height) * 100)
                    }
                    try? parts.joined(separator: "\n").write(to: out.appendingPathComponent("\(name)-parts.txt"), atomically: true, encoding: .utf8)
                    lines.append("\(name): \(subjects.parts.count) part(s): \(parts.joined(separator: " | "))")
                    let target = out.appendingPathComponent("\(name)-cutout.png")
                    try? FileManager.default.removeItem(at: target)
                    let outline = try time("cutout", {
                        try makeCutout(of: photo, picks: picks, to: target, matting: RememberedMatte(matting: matte, key: name))
                    })
                    try? outline.write(to: out.appendingPathComponent("\(name)-outline.txt"), atomically: true, encoding: .utf8)
                    lines.append("\(name): \(picture.w)x\(picture.h), outline \(outline.count) characters")
                } catch {
                    lines.append("\(name): \(error)")
                }
                return lines
            }.value
            said += lines
        }
        return said
    }
}
