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
