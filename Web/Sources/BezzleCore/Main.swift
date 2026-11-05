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
