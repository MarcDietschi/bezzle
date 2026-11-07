import Foundation
import WinSDK
import BezzleCore

/// Layers on Windows' clipboard, under the format the Mac's pasteboard type names
/// (`com.erik.bezzle.layers`, a registered clipboard format), as the clip's JSON; text layers'
/// words go along as plain text, for pasting elsewhere. Words from elsewhere paste as a text.
@MainActor
enum Clipboard {
    private static let format: UINT = WindowsCore.clipType.withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) }

    /// Whether there is something to paste: layers from Bezzle, or words.
    static var canPaste: Bool { IsClipboardFormatAvailable(format) || IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)) }

    static func copy(_ ids: [UUID]) {
        guard let (json, words) = WindowsCore.copy(ids), OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        put(Array(json.utf8) + [0], as: format)
        if let words {
            let wide = Array(words.utf16) + [0]
            wide.withUnsafeBytes { put(Array($0), as: UINT(CF_UNICODETEXT)) }
        }
    }

    /// Words put on the clipboard, as a value copied from what is inspected.
    static func copyText(_ words: String) {
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        let wide = Array(words.utf16) + [0]
        wide.withUnsafeBytes { put(Array($0), as: UINT(CF_UNICODETEXT)) }
    }

    /// A file put on the clipboard, as Explorer copies one, to paste as a file; and for a PNG,
    /// its picture too, as a PNG (which browsers, Office and design apps read) and as a bitmap
    /// (which the rest read), from `pixels`: premultiplied RGBA, rows top first.
    static func copyFile(_ url: URL, png pixels: (width: Int, height: Int, pixels: [UInt8])? = nil) {
        guard OpenClipboard(nil) else { return }
        defer { CloseClipboard() }
        EmptyClipboard()
        // CF_HDROP: a DROPFILES head (where the names start, wide), then the names, ending twice.
        var drop: [UInt8] = []
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { drop.append(contentsOf: $0) } }
        u32(20); u32(0); u32(0); u32(0); u32(1)
        let native = url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path
        let wide = Array(native.replacingOccurrences(of: "/", with: "\\").utf16) + [0, 0]
        wide.withUnsafeBytes { drop.append(contentsOf: $0) }
        put(drop, as: UINT(CF_HDROP))
        guard let pixels else { return }
        if let data = try? Data(contentsOf: url) {
            let png: UINT = "PNG".withCString(encodedAs: UTF16.self) { RegisterClipboardFormatW($0) }
            put([UInt8](data), as: png)
        }
        // CF_DIBV5: a BITMAPV5HEADER, 32 bits a pixel, BGRA from the bottom row up, not premultiplied.
        var dib: [UInt8] = []
        func d32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { dib.append(contentsOf: $0) } }
        func d16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { dib.append(contentsOf: $0) } }
        let w = pixels.width, h = pixels.height
        d32(124); d32(UInt32(w)); d32(UInt32(h)); d16(1); d16(32); d32(3); d32(UInt32(w * h * 4)); d32(2835); d32(2835); d32(0); d32(0)
        d32(0x00FF_0000); d32(0x0000_FF00); d32(0x0000_00FF); d32(0xFF00_0000)
        d32(0x7352_4742)
        dib.append(contentsOf: [UInt8](repeating: 0, count: 36))
        d32(0); d32(0); d32(0)
        d32(4); d32(0); d32(0); d32(0)
        dib.reserveCapacity(dib.count + w * h * 4)
        for y in stride(from: h - 1, through: 0, by: -1) {
            for x in 0..<w {
                let k = (y * w + x) * 4
                let a = pixels.pixels[k + 3]
                func un(_ c: UInt8) -> UInt8 { a == 0 ? 0 : UInt8(min(255, (Int(c) * 255 + Int(a) / 2) / Int(a))) }
                dib.append(un(pixels.pixels[k + 2])); dib.append(un(pixels.pixels[k + 1])); dib.append(un(pixels.pixels[k])); dib.append(a)
            }
        }
        put(dib, as: UINT(CF_DIBV5))
    }

    /// The layers pasted (where they were copied from when that is in `visible`, else in its
    /// middle), or a text made of the words there; nil when there is nothing to paste.
    static func paste(visible: CGRect, board: Int?) -> [UUID]? {
        guard OpenClipboard(nil) else { return nil }
        var json: String?, words: String?
        if IsClipboardFormatAvailable(format), let h = GetClipboardData(format), let p = GlobalLock(h) {
            json = String(cString: p.assumingMemoryBound(to: CChar.self))
            GlobalUnlock(h)
        } else if IsClipboardFormatAvailable(UINT(CF_UNICODETEXT)), let h = GetClipboardData(UINT(CF_UNICODETEXT)), let p = GlobalLock(h) {
            words = String(decodingCString: p.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
            GlobalUnlock(h)
        }
        CloseClipboard()
        if let json { return WindowsCore.paste(json: json, visible: visible, board: board) }
        if let words, !words.isEmpty { return WindowsCore.paste(text: words, visible: visible, board: board).map { [$0] } }
        return nil
    }

    private static func put(_ bytes: [UInt8], as format: UINT) {
        guard let h = GlobalAlloc(UINT(GMEM_MOVEABLE), SIZE_T(bytes.count)), let p = GlobalLock(h) else { return }
        bytes.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: bytes.count) }
        GlobalUnlock(h)
        // The clipboard owns it from here.
        _ = SetClipboardData(format, h)
    }
}

/// Explorer, opened on a file, picked in its folder.
@MainActor
enum Explorer {
    static func show(_ url: URL) {
        let native = (url.withUnsafeFileSystemRepresentation { $0.map { String(cString: $0) } } ?? url.path).replacingOccurrences(of: "/", with: "\\")
        let arguments = "/select,\"" + native + "\""
        _ = "explorer.exe".withCString(encodedAs: UTF16.self) { file in
            arguments.withCString(encodedAs: UTF16.self) { args in
                ShellExecuteW(nil, nil, file, args, nil, Int32(SW_SHOWNORMAL))
            }
        }
    }
}
