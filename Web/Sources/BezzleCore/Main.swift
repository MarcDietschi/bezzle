import Foundation
import AppKit

// What the page calls. Every answer is JSON, left in `outbox` for the page to read from memory.

nonisolated(unsafe) private var outbox: [UInt8] = []
nonisolated(unsafe) private var design: BezzleDocument?
nonisolated(unsafe) private var assets = Assets(folder: nil)

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
    let data = Data(bytes: p, count: Int(n))
    if let families = try? JSONSerialization.jsonObject(with: data) as? [String: [String]] {
        NSFontManager.shared.families = families
    }
}

/// Opens a design from its document.json; answers its artboards.
@_expose(wasm, "bz_open")
nonisolated func bz_open(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let data = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated {
        do {
            var doc = try JSONDecoder().decode(BezzleDocument.self, from: data)
            doc.repairStyles()
            design = doc
            assets = Assets(folder: URL(fileURLWithPath: "/images"))
            let boards = doc.nodes.enumerated().filter { $0.element.isArtboard }.map { i, b in
                "{\"index\":\(i),\"name\":\(quoted(b.name)),\"frame\":[\(b.frame.minX),\(b.frame.minY),\(b.frame.width),\(b.frame.height)]}"
            }
            return answer("{\"boards\":[" + boards.joined(separator: ",") + "],\"layers\":\(BezzleDocument.layerCount(doc.nodes))}")
        } catch {
            return answer("{\"error\":\(quoted("\(error)"))}")
        }
    }
}

/// Draws one artboard at `scale` pixels to the point with the app's own renderer. Answers the
/// picture to show and every picture made for it since the last drawing, as `Images` lists them.
@_expose(wasm, "bz_render")
nonisolated func bz_render(_ index: Int32, _ scale: Double) -> Int32 {
    MainActor.assumeIsolated {
        guard let doc = design, Int(index) < doc.nodes.count else { return answer("{\"error\":\"no such artboard\"}") }
        let first = Images.shared.list.last.map { $0.id + 1 } ?? 0
        let started = Date()
        guard let image = Renderer.image(of: doc.nodes[Int(index)], scale: CGFloat(scale), assets: assets) else {
            return answer("{\"error\":\"nothing drawn\"}")
        }
        let ms = Date().timeIntervalSince(started) * 1000
        return answer("{\"root\":\(image.id),\"ms\":\(ms),\"images\":\(Images.shared.json(from: first))}")
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
                        + "\"lines\":[\(lines.joined(separator: ","))]}")
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

private func boardsAnswer(_ doc: BezzleDocument, extra: String = "") -> String {
    let boards = doc.nodes.enumerated().filter { $0.element.isArtboard }.map { i, b in
        "{\"index\":\(i),\"name\":\(quoted(b.name)),\"frame\":[\(b.frame.minX),\(b.frame.minY),\(b.frame.width),\(b.frame.height)]}"
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
        design = doc
        assets = Assets(folder: URL(fileURLWithPath: "/images"))
        return answer(boardsAnswer(doc, extra: ",\"unread\":\(unread),\"clock\":\(WebSharing.state.clock.time)"))
    }
}

/// Takes in others' change records, as `bz_shared_open` takes them.
@_expose(wasm, "bz_shared_receive")
nonisolated func bz_shared_receive(_ p: UnsafeRawPointer, _ n: Int32) -> Int32 {
    let json = Data(bytes: p, count: Int(n))
    return MainActor.assumeIsolated {
        guard let shown = design else { return answer("{\"error\":\"no design\"}") }
        let doc = WebSharing.receive(records(json).records, into: shown)
        design = doc
        return answer(boardsAnswer(doc))
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
        design = doc
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

