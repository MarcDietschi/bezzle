import Foundation
import AppKit

// What the page calls. Every answer is JSON, left in `outbox` for the page to read from memory.

nonisolated(unsafe) private var outbox: [UInt8] = []
nonisolated(unsafe) private var design: BezzleDocument?
nonisolated(unsafe) private var assets = Assets(folder: nil)
/// The film the page is showing, of one artboard of the design (Film/WebFilm.swift).
nonisolated(unsafe) private var film: WebFilm?
/// The artboard last drawn as the design, held until the next is drawn or another design is
/// opened: what the page made for it is the page's to keep that long (`PageKeeps`).
nonisolated(unsafe) private var lastDrawn: CGImage?
/// How many texts the core keeps laid out before it forgets the ones longest not asked for
/// (`TextLayout.trim`): more than the design's own can come to, so that only texts set anew
/// again and again (one growing in a film, a shared design being changed) are ever forgotten.
nonisolated(unsafe) private var mostTexts = 1200

/// The design the page now shows.
private func show(_ doc: BezzleDocument, anew: Bool) {
    design = doc
    film = nil
    if anew {
        lastDrawn = nil
        assets = Assets(folder: URL(fileURLWithPath: "/images"))
    }
    mostTexts = max(1200, BezzleDocument.layerCount(doc.nodes) * 3)
    WebLive.designChanged()
}

private func answer(_ s: String) -> Int32 {
    outbox = Array(s.utf8)
    return Int32(outbox.count)
}

@_expose(wasm, "bz_alloc")
nonisolated func bz_alloc(_ n: Int32) -> UnsafeMutableRawPointer {
    UnsafeMutableRawPointer.allocate(byteCount: Int(max(n, 1)), alignment: 16)
}

@_expose(wasm, "bz_free")
nonisolated func bz_free(_ p: UnsafeMutableRawPointer) { p.deallocate() }

/// Where the last answer is.
@_expose(wasm, "bz_outbox")
nonisolated func bz_outbox() -> UnsafeRawPointer {
    outbox.withUnsafeBytes { UnsafeRawPointer($0.baseAddress!) }
}

/// The families and faces of the fonts the page has: {"Avenir Next": ["Regular", "Medium"], …}.
@_expose(wasm, "bz_fonts")
nonisolated func bz_fonts(_ p: UnsafeRawPointer, _ n: Int32) {
    // The page's first call: from here on it is told what it may let go.
    PageKeeps.listen()
    let data = Data(bytes: p, count: Int(n))
    if let families = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
        NSFontManager.shared.families = families
        film = nil
    }
}

/// The Mac's families the page draws in fonts that stand in for them (the open fonts' manifest),
/// whose letters are spaced to the Mac's widths (MacFonts.spacing): ["System", "Avenir Next", …].
@_expose(wasm, "bz_stand_ins")
nonisolated func bz_stand_ins(_ p: UnsafeRawPointer, _ n: Int32) {
    let data = Data(bytes: p, count: Int(n))
    let families = (try? JSONSerialization.jsonObject(with: data) as? [String]) ?? []
    MainActor.assumeIsolated {
        MacFonts.standIns = Set(families)
        TextLayout.forget()
        film = nil
    }
}

/// The page has fonts it had not: texts are set again with them.
@_expose(wasm, "bz_forget_text")
nonisolated func bz_forget_text() {
    MainActor.assumeIsolated {
        TextLayout.forget()
        film = nil
    }
}

/// Opens a design from its document.json; answers its artboards, and what the page may let go
/// of the design shown before.
@_expose(wasm, "bz_open")
nonisolated func bz_open(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let data = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated {
        do {
            var doc = try JSONDecoder().decode(BezzleDocument.self, from: data)
            doc.repairStyles()
            show(doc, anew: true)
            return answer(boardsAnswer(doc, extra: "," + PageKeeps.gone()))
        } catch {
            return answer("{\"error\":\(quoted("\(error)"))}")
        }
    }
}

/// Draws one artboard at `scale` pixels to the point with the app's own renderer. Answers the
/// picture to show and every picture made for it, as `Images` lists them, with the pictures and
/// texts the page may let go (`PageKeeps`): the picture drawn before this one is among them, and
/// what only it drew. So the picture answered is the page's until the next is drawn.
@_expose(wasm, "bz_render")
nonisolated func bz_render(_ index: Int32, _ scale: Double) -> Int32 {
    MainActor.assumeIsolated {
        guard let doc = design, Int(index) < doc.nodes.count else { return answer("{\"error\":\"no such artboard\"}") }
        lastDrawn = nil
        TextLayout.trim(over: mostTexts)
        let started = Date()
        let (image, images) = PageKeeps.listing { Renderer.image(of: doc.nodes[Int(index)], scale: CGFloat(scale), assets: assets) }
        guard let image else { return answer("{\"error\":\"nothing drawn\"," + PageKeeps.gone() + "}") }
        lastDrawn = image
        let ms = Date().timeIntervalSince(started) * 1000
        return answer("{\"root\":\(image.id),\"ms\":\(ms),\"images\":\(images)," + PageKeeps.gone() + "}")
    }
}

/// Every straight text of the design as laid out here, in the shape the Mac's truth has.
@_expose(wasm, "bz_texts")
nonisolated func bz_texts() -> Int32 {
    MainActor.assumeIsolated {
        guard let doc = design else { return answer("[]") }
        var out: [String] = []
        func walk(_ nodes: [Node]) {
            for n in nodes {
                if n.kind == .text, n.curve == nil {
                    let laid = TextLayout.layout(n)
                    let lines = laid.lines.map { "[\($0.start),\($0.end),\($0.top),\($0.height),\($0.width),\($0.baseline)]" }
                    let f = TextLayout.fittedFrame(n)
                    out.append("{\"id\":\(quoted(n.id.uuidString)),\"text\":\(quoted(laid.string)),\"used\":[\(laid.usedSize.width),\(laid.usedSize.height)],"
                        + "\"natural\":\(TextLayout.naturalWidth(n)),\"firstBaseline\":\(TextLayout.firstBaseline(n)),\"fitted\":[\(f.width),\(f.height)],"
                        + "\"lines\":[\(lines.joined(separator: ","))],\"laid\":\(laid.id)}")
                }
                walk(n.children)
            }
        }
        walk(doc.nodes)
        return answer("[" + out.joined(separator: ",") + "]")
    }
}

nonisolated private func quoted(_ s: String) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: [s])) ?? Data("[\"\"]".utf8)
    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
}

// MARK: Shared designs

/// The design's artboards, as the page lists them. One with a film says so, with how long it
/// runs and whether it plays once: the page then offers to play it.
private func boardsAnswer(_ doc: BezzleDocument, extra: String = "") -> String {
    let boards = doc.nodes.enumerated().filter { $0.element.isArtboard }.map { i, b in
        "{\"index\":\(i),\"name\":\(quoted(b.name)),\"frame\":[\(b.frame.minX),\(b.frame.minY),\(b.frame.width),\(b.frame.height)]"
            + (b.hasFilm ? ",\"film\":{\"length\":\(b.filmLength),\"once\":\(b.film?.once == true)}" : "") + "}"
    }
    return "{\"boards\":[" + boards.joined(separator: ",") + "],\"layers\":\(BezzleDocument.layerCount(doc.nodes))\(extra)}"
}

private func records(_ json: Data) -> (records: [Data], replica: String) {
    let o = (try? JSONSerialization.jsonObject(with: json)) as? [String: Any] ?? [:]
    let list = (o["records"] as? [String] ?? []).compactMap { Data(base64Encoded: $0) }
    return (list, o["replica"] as? String ?? "web")
}

/// Opens a shared design from its zone's records: {"records": [base64 of each record's data], "replica": "…"}.
@_expose(wasm, "bz_shared_open")
nonisolated func bz_shared_open(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let json = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated {
        let (list, replica) = records(json)
        let (doc, unread) = WebSharing.open(list, replica: replica)
        show(doc, anew: true)
        return answer(boardsAnswer(doc, extra: ",\"unread\":\(unread),\"clock\":\(WebSharing.state.clock.time)," + PageKeeps.gone()))
    }
}

/// Takes in others' change records, as `bz_shared_open` takes them. `same` says that the design
/// is as it was (records that held nothing new, as when a change came through the live room
/// first): the page need not draw it again.
@_expose(wasm, "bz_shared_receive")
nonisolated func bz_shared_receive(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let json = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated {
        guard let shown = design else { return answer("{\"error\":\"no design\"}") }
        let doc = WebSharing.receive(records(json).records, into: shown)
        let same = doc == shown
        if !same { show(doc, anew: false) }
        return answer(boardsAnswer(doc, extra: ",\"same\":\(same)," + PageKeeps.gone()))
    }
}

/// What was changed here since it was last sent, packed: {"data": base64} or {} for nothing.
@_expose(wasm, "bz_shared_changes")
nonisolated func bz_shared_changes() -> Int32 {
    MainActor.assumeIsolated {
        guard let shown = design, let packed = WebSharing.changes(in: shown) else { return answer("{}") }
        return answer("{\"data\":\"\(packed.base64EncodedString())\",\"upTo\":\(WebSharing.sentUpTo)}")
    }
}

/// The whole shared design as this browser has it, packed: {"data": base64}.
@_expose(wasm, "bz_shared_whole")
nonisolated func bz_shared_whole() -> Int32 {
    MainActor.assumeIsolated {
        guard let shown = design, let packed = WebSharing.whole(of: shown) else { return answer("{}") }
        return answer("{\"data\":\"\(packed.base64EncodedString())\",\"upTo\":\(WebSharing.state.clock.time)}")
    }
}

/// The open design packed as an owner's first snapshot: {"data": base64}. For testing without iCloud.
@_expose(wasm, "bz_shared_snapshot")
nonisolated func bz_shared_snapshot() -> Int32 {
    MainActor.assumeIsolated {
        guard let doc = design, let packed = WebSharing.snapshot(of: doc, by: "owner-test") else { return answer("{}") }
        return answer("{\"data\":\"\(packed.base64EncodedString())\"}")
    }
}

/// For testing an edit without an editor: renames the first text found and moves it by 10 points.
@_expose(wasm, "bz_test_edit")
nonisolated func bz_test_edit() -> Int32 {
    MainActor.assumeIsolated {
        guard var doc = design else { return answer("{}") }
        func first(_ nodes: [Node]) -> UUID? {
            for n in nodes { if n.kind == .text { return n.id }; if let id = first(n.children) { return id } }
            return nil
        }
        guard let id = first(doc.nodes) else { return answer("{}") }
        doc.update(id) { $0.text = "Edited in a browser"; $0.refit(); $0.frame.origin.x += 10 }
        // As every edit in the app does: groups fit what they hold again.
        doc.fitGroups()
        show(doc, anew: false)
        return answer("{\"id\":\"\(id.uuidString)\"}")
    }
}

/// The open design as JSON, for comparing two copies.
@_expose(wasm, "bz_document")
nonisolated func bz_document() -> Int32 {
    MainActor.assumeIsolated {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let doc = design, let data = try? encoder.encode(doc) else { return answer("{}") }
        return answer(String(decoding: data, as: UTF8.self))
    }
}

// MARK: The live room

/// What someone in the design's live room said, its seal opened by the page (`plain`, as
/// `LiveMessage.packed` makes it), with their place in the room. Answers what it was, and what the
/// page shows of it (`WebLive.take`).
@_expose(wasm, "bz_live_message")
nonisolated func bz_live_message(_ peer: Int32, _ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let plain = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated { answer(WebLive.take(plain, from: UInt32(bitPattern: peer), in: design)) }
}

/// Everyone in the room who said who they are, as the page shows them: their name, their pencil,
/// where their hand is and what they hold on the design as it is now.
@_expose(wasm, "bz_live_people")
nonisolated func bz_live_people() -> Int32 {
    MainActor.assumeIsolated { answer(WebLive.people(in: design)) }
}

/// Someone left the room; answers who is there now.
@_expose(wasm, "bz_live_left")
nonisolated func bz_live_left(_ peer: Int32) -> Int32 {
    MainActor.assumeIsolated {
        WebLive.left(UInt32(bitPattern: peer))
        return answer(WebLive.people(in: design))
    }
}

/// The room was left, or its connection lost: nobody is there.
@_expose(wasm, "bz_live_clear")
nonisolated func bz_live_clear() {
    MainActor.assumeIsolated { WebLive.clear() }
}

/// For testing the live room without a Mac in it (`WebLive.test`).
@_expose(wasm, "bz_test_live")
nonisolated func bz_test_live(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let json = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated { answer(WebLive.test(json, in: design)) }
}

// MARK: The icon library

/// The icon sets, which the page fetched and unpacked (`WebIcons`). Answers the sets the core has.
@_expose(wasm, "bz_icons")
nonisolated func bz_icons(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    // Not copied: they are read here and now, and the page keeps them until this answers.
    let unpacked = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: p), count: Int(n), deallocator: .none)
    return MainActor.assumeIsolated { answer(WebIcons.take(unpacked)) }
}

/// For comparing the icon library with the Mac's (`WebIcons.test`). A sheet of icons asked for
/// becomes the design shown, to be drawn like any other.
@_expose(wasm, "bz_test_icons")
nonisolated func bz_test_icons(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let json = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated {
        let (said, sheet) = WebIcons.test(json)
        guard let sheet else { return answer(said) }
        show(sheet, anew: true)
        return answer(String(said.dropLast()) + "," + PageKeeps.gone() + "}")
    }
}

// MARK: Films

/// Opens the film of one artboard, for showing its frames (`bz_film_frame`). Answers how long it
/// runs, whether it plays once, its backdrop and the artboard's size, with what the page may let
/// go of a film shown before (`PageKeeps`); or an error for an artboard without a film.
@_expose(wasm, "bz_film")
nonisolated func bz_film(_ index: Int32) -> Int32 {
    MainActor.assumeIsolated {
        film = nil
        guard let doc = design, doc.nodes.indices.contains(Int(index)), doc.nodes[Int(index)].isArtboard, doc.nodes[Int(index)].hasFilm else {
            return answer("{\"error\":\"no film\"," + PageKeeps.gone() + "}")
        }
        let reel = WebFilm(doc.nodes[Int(index)], assets: assets)
        film = reel
        return answer(String(reel.described.dropLast()) + "," + PageKeeps.gone() + "}")
    }
}

/// What the open film's frame at `t` seconds is made from, `width` by `height` pixels: its
/// pieces, the lowest first, each a picture drawn through a 3 by 3 map, with the pictures drawn
/// for it since the last frame and the pictures and texts the page may let go. `playing` (not 0)
/// leaves parts sharper than a piece's whole picture for when the film rests.
@_expose(wasm, "bz_film_frame")
nonisolated func bz_film_frame(_ t: Double, _ width: Int32, _ height: Int32, _ playing: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let film else { return answer("{\"error\":\"no film\"}") }
        let started = Date()
        TextLayout.trim(over: mostTexts)
        let (frame, images) = PageKeeps.listing { film.frame(at: t, width: Int(width), height: Int(height), playing: playing != 0) }
        let ms = Date().timeIntervalSince(started) * 1000
        return answer(String(frame.dropLast()) + ",\"ms\":\(ms),\"images\":\(images)," + PageKeeps.gone() + "}")
    }
}

/// Draws one more of the open film's pieces ahead of its playing, for a frame `width` by `height`
/// pixels: answers its picture, how many pieces are left to draw, and the pictures made for it.
@_expose(wasm, "bz_film_warm")
nonisolated func bz_film_warm(_ width: Int32, _ height: Int32) -> Int32 {
    MainActor.assumeIsolated {
        guard let film else { return answer("{\"error\":\"no film\"}") }
        TextLayout.trim(over: mostTexts)
        let (made, images) = PageKeeps.listing { film.warm(width: Int(width), height: Int(height)) }
        return answer(String(made.dropLast()) + ",\"images\":\(images)," + PageKeeps.gone() + "}")
    }
}

/// Where the open film's arithmetic has each piece at `t` seconds, for comparing with the Mac's.
@_expose(wasm, "bz_film_placements")
nonisolated func bz_film_placements(_ t: Double) -> Int32 {
    MainActor.assumeIsolated {
        guard let film else { return answer("{\"error\":\"no film\"}") }
        return answer(film.placements(at: t))
    }
}

/// Lets the open film go; answers the pictures and texts the page may let go with it.
@_expose(wasm, "bz_film_close")
nonisolated func bz_film_close() -> Int32 {
    MainActor.assumeIsolated {
        film = nil
        return answer("{" + PageKeeps.gone() + "}")
    }
}

