import Foundation
import WinSDK
import BezzleCore

/// A colour picked from anywhere on screen, as the Mac's NSColorSampler picks one for the colour
/// panel's dropper (Views/Fields.swift): the screen is held still as it was, a round magnifier
/// follows the pointer with the pixel under it marked in its middle, and a click takes that
/// pixel's colour. Escape or the right button lets it be; so does going to another window. The
/// arrow keys move the pointer a pixel at a time, and Enter takes the colour as a click does.
///
/// It is a window of its own over every screen, drawn with GDI from a picture of the screens
/// taken the moment it opens: the pixels are read from that picture, so nothing it draws itself
/// is ever picked.
@MainActor
final class Eyedropper {
    typealias Colour = WindowsCore.Colour

    /// The one picking now, which the window's messages go to.
    private static var current: Eyedropper?
    private static var registered = false
    private static let className: [WCHAR] = Array("BezzleEyedropper".utf16) + [0]

    private let done: (Colour?) -> Void
    private var window: HWND?
    /// The screens as they were, in a bitmap whose pixels can be read (BGRA, top row first).
    private var screenDC: HDC?
    private var screenBitmap: HBITMAP?
    private var screenBits: UnsafeMutablePointer<UInt8>?
    /// Where the screens start, and how big they are, in pixels.
    private var origin = (x: Int32(0), y: Int32(0))
    private var size = (w: Int32(0), h: Int32(0))
    /// The magnifier, drawn into a bitmap of its own each time it moves.
    private var loupeDC: HDC?
    private var loupeBitmap: HBITMAP?
    private var loupeBits: UnsafeMutablePointer<UInt8>?
    /// The pixel under the pointer, from the window's top left.
    private var at = (x: Int32(0), y: Int32(0))
    private var finished = false

    /// How many of the screen's pixels the magnifier is across, and how big each shows; its
    /// size, its rim and the shadow round it, at 100%.
    private var scale = 1.0
    private var cell: Int32 { Int32((9 * scale).rounded()) }
    private var diameter: Int32 { Int32((122 * scale).rounded()) }
    private var rim: Double { 3 * scale }
    private var pad: Int32 { Int32((10 * scale).rounded()) }
    private var box: Int32 { diameter + 2 * pad }

    private init(done: @escaping (Colour?) -> Void) {
        self.done = done
    }

    /// Picks a colour from the screen; `done` gets it, or nil when it was let be.
    static func pick(_ done: @escaping (Colour?) -> Void) {
        guard current == nil else { return }
        let dropper = Eyedropper(done: done)
        current = dropper
        if !dropper.open() {
            current = nil
            dropper.close()
            done(nil)
        }
    }

    // MARK: Opening and closing

    private func open() -> Bool {
        // In the screens' own pixels, whatever the scale the app itself is drawn at.
        let previous = SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT(bitPattern: -4))
        defer { if let previous { SetThreadDpiAwarenessContext(previous) } }
        origin = (GetSystemMetrics(76), GetSystemMetrics(77))
        size = (GetSystemMetrics(78), GetSystemMetrics(79))
        guard size.w > 0, size.h > 0, let screen = GetDC(nil) else { return false }
        defer { ReleaseDC(nil, screen) }
        scale = Double(GetDeviceCaps(screen, 88)) / 96
        guard let (dc, bitmap, bits) = Self.bitmap(like: screen, width: size.w, height: size.h) else { return false }
        screenDC = dc
        screenBitmap = bitmap
        screenBits = bits
        // The screens as they are now, windows drawn by the compositor and all.
        BitBlt(dc, 0, 0, size.w, size.h, screen, origin.x, origin.y, DWORD(0x00CC0020 | 0x40000000))
        guard let (ldc, lbitmap, lbits) = Self.bitmap(like: screen, width: box, height: box) else { return false }
        loupeDC = ldc
        loupeBitmap = lbitmap
        loupeBits = lbits

        let instance = GetModuleHandleW(nil)
        if !Self.registered {
            var wc = WNDCLASSEXW()
            wc.cbSize = UINT(MemoryLayout<WNDCLASSEXW>.size)
            wc.lpfnWndProc = eyedropperWindowProc
            wc.hInstance = instance
            Self.className.withUnsafeBufferPointer { name in
                wc.lpszClassName = name.baseAddress
                Self.registered = RegisterClassExW(&wc) != 0
            }
            guard Self.registered else { return false }
        }
        var cursor = POINT()
        GetCursorPos(&cursor)
        at = (cursor.x - origin.x, cursor.y - origin.y)
        let made = Self.className.withUnsafeBufferPointer { name in
            // A pop-up over everything, not on the taskbar.
            CreateWindowExW(DWORD(0x00000008 | 0x00000080), name.baseAddress, nil, DWORD(0x80000000 | 0x10000000),
                            origin.x, origin.y, size.w, size.h, nil, nil, instance, nil)
        }
        guard let made else { return false }
        window = made
        SetForegroundWindow(made)
        SetFocus(made)
        return true
    }

    /// A bitmap of 32-bit pixels, top row first, in a DC of its own; nil if Windows has no room.
    private static func bitmap(like screen: HDC, width: Int32, height: Int32) -> (HDC, HBITMAP, UnsafeMutablePointer<UInt8>)? {
        var info = BITMAPINFO()
        info.bmiHeader.biSize = DWORD(MemoryLayout<BITMAPINFOHEADER>.size)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = -height
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = DWORD(BI_RGB)
        var bits: UnsafeMutableRawPointer?
        guard let dc = CreateCompatibleDC(screen) else { return nil }
        guard let bitmap = CreateDIBSection(screen, &info, UINT(DIB_RGB_COLORS), &bits, nil, 0), let bits else {
            DeleteDC(dc)
            return nil
        }
        SelectObject(dc, UnsafeMutableRawPointer(bitmap))
        return (dc, bitmap, bits.assumingMemoryBound(to: UInt8.self))
    }

    /// Done: the window goes, the pictures with it, and `done` hears what was picked, once this
    /// message is over.
    private func finish(_ colour: Colour?) {
        guard !finished else { return }
        finished = true
        close()
        Self.current = nil
        let done = self.done
        DispatchQueue.main.async { MainActor.assumeIsolated { done(colour) } }
    }

    private func close() {
        if let window { DestroyWindow(window) }
        window = nil
        for (dc, bitmap) in [(screenDC, screenBitmap), (loupeDC, loupeBitmap)] {
            if let dc { DeleteDC(dc) }
            if let bitmap { DeleteObject(UnsafeMutableRawPointer(bitmap)) }
        }
        screenDC = nil; screenBitmap = nil; screenBits = nil
        loupeDC = nil; loupeBitmap = nil; loupeBits = nil
    }

    // MARK: The pixels

    /// The pixel at `x`, `y` of the screens as they were: blue, green, red; black off them.
    private func pixel(_ x: Int32, _ y: Int32) -> (b: Double, g: Double, r: Double) {
        guard let bits = screenBits, x >= 0, y >= 0, x < size.w, y < size.h else { return (0, 0, 0) }
        let k = (Int(y) * Int(size.w) + Int(x)) * 4
        return (Double(bits[k]), Double(bits[k + 1]), Double(bits[k + 2]))
    }

    private var picked: Colour {
        let p = pixel(at.x, at.y)
        return Colour(r: p.r / 255, g: p.g / 255, b: p.b / 255, a: 1)
    }

    /// Where the magnifier's box lies, from the window's top left: its middle on the pointer.
    private var loupeRect: RECT {
        let left = at.x - box / 2, top = at.y - box / 2
        return RECT(left: left, top: top, right: left + box, bottom: top + box)
    }

    /// The magnifier drawn into its bitmap, over the screens as they were under it: the pixels
    /// round the pointer, each `cell` across, a faint line between them, the one under the
    /// pointer outlined white and dark; a white rim with a dark edge, and a soft shadow under it.
    private func drawLoupe() {
        guard let out = loupeBits else { return }
        let r = loupeRect
        let n = Int(box), half = Double(box) / 2
        let outer = Double(diameter) / 2, inner = outer - rim
        let c = Double(cell), drop = 1.5 * scale, soft = Double(pad)
        for j in 0..<n {
            for i in 0..<n {
                let sx = r.left + Int32(i), sy = r.top + Int32(j)
                var (b, g, rr) = pixel(sx, sy)
                let x = Double(i) + 0.5 - half, y = Double(j) + 0.5 - half
                let d = (x * x + y * y).squareRoot()
                // The shadow, a little below, fading out past the rim.
                let ds = (x * x + (y - drop) * (y - drop)).squareRoot()
                if ds > outer - 1, d > outer - 1 {
                    let t = min(max((ds - outer) / soft, 0), 1)
                    let a = 0.26 * (1 - t) * (1 - t)
                    b *= 1 - a; g *= 1 - a; rr *= 1 - a
                }
                if d < outer + 1 {
                    // The pixels magnified, inside the rim.
                    let ci = Int32((x / c + 0.5).rounded(.down)), cj = Int32((y / c + 0.5).rounded(.down))
                    var (mb, mg, mr) = pixel(at.x + ci, at.y + cj)
                    let fx = x / c + 0.5 - Double(ci), fy = y / c + 0.5 - Double(cj)
                    if cell >= 6, fx * c < 1 || fy * c < 1 {
                        mb = mb * 0.86 + 128 * 0.14; mg = mg * 0.86 + 128 * 0.14; mr = mr * 0.86 + 128 * 0.14
                    }
                    // The pixel under the pointer, marked: white inside a dark line.
                    let m = max(abs(x), abs(y)), edge = c / 2
                    if m >= edge - 1, m < edge + 1, ci >= -1, ci <= 1, cj >= -1, cj <= 1 {
                        let v: Double = m < edge ? 255 : 20
                        mb = v; mg = v; mr = v
                    }
                    // The rim, white; its outer edge dark; each edge smoothed.
                    let inside = min(max(inner - d + 0.5, 0), 1)
                    let white = 247.0
                    var ob = white * (1 - inside) + mb * inside, og = white * (1 - inside) + mg * inside, orr = white * (1 - inside) + mr * inside
                    let line = min(max(1 - abs(d - (outer - 0.5)), 0), 1) * 0.35
                    ob *= 1 - line; og *= 1 - line; orr *= 1 - line
                    let cover = min(max(outer - d + 0.5, 0), 1)
                    b = b * (1 - cover) + ob * cover
                    g = g * (1 - cover) + og * cover
                    rr = rr * (1 - cover) + orr * cover
                }
                let k = (j * n + i) * 4
                out[k] = UInt8(min(max(b, 0), 255))
                out[k + 1] = UInt8(min(max(g, 0), 255))
                out[k + 2] = UInt8(min(max(rr, 0), 255))
                out[k + 3] = 255
            }
        }
    }

    // MARK: The window's messages

    fileprivate func handle(_ hwnd: HWND, _ message: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT? {
        switch message {
        case 0x000F: // paint
            var ps = PAINTSTRUCT()
            guard let dc = BeginPaint(hwnd, &ps) else { return 0 }
            let p = ps.rcPaint
            if let screenDC {
                BitBlt(dc, p.left, p.top, p.right - p.left, p.bottom - p.top, screenDC, p.left, p.top, DWORD(0x00CC0020))
            }
            if let loupeDC {
                drawLoupe()
                let r = loupeRect
                BitBlt(dc, r.left, r.top, box, box, loupeDC, 0, 0, DWORD(0x00CC0020))
            }
            EndPaint(hwnd, &ps)
            return 0
        case 0x0014: // erase background: the picture of the screens covers it
            return 1
        case 0x0020: // set cursor: none, the magnifier shows where it is
            SetCursor(nil)
            return 1
        case 0x0200: // mouse move
            let x = Int32(Int16(truncatingIfNeeded: l & 0xFFFF)), y = Int32(Int16(truncatingIfNeeded: (l >> 16) & 0xFFFF))
            move(to: (x, y), hwnd)
            return 0
        case 0x0201: // left button down
            let x = Int32(Int16(truncatingIfNeeded: l & 0xFFFF)), y = Int32(Int16(truncatingIfNeeded: (l >> 16) & 0xFFFF))
            at = (x, y)
            finish(picked)
            return 0
        case 0x0204: // right button down
            finish(nil)
            return 0
        case 0x0100: // key down
            switch Int32(truncatingIfNeeded: w) {
            case Int32(VK_ESCAPE): finish(nil)
            case Int32(VK_RETURN), Int32(VK_SPACE): finish(picked)
            case Int32(VK_LEFT): nudge(-1, 0)
            case Int32(VK_RIGHT): nudge(1, 0)
            case Int32(VK_UP): nudge(0, -1)
            case Int32(VK_DOWN): nudge(0, 1)
            default: break
            }
            return 0
        case 0x0006: // activate: another window coming forward lets it be
            if w & 0xFFFF == 0 { finish(nil) }
            return 0
        default:
            return nil
        }
    }

    private func move(to p: (x: Int32, y: Int32), _ hwnd: HWND) {
        guard p != at else { return }
        var old = loupeRect
        at = p
        var new = loupeRect
        InvalidateRect(hwnd, &old, false)
        InvalidateRect(hwnd, &new, false)
    }

    /// The pointer a pixel over, as the arrow keys move it.
    private func nudge(_ dx: Int32, _ dy: Int32) {
        let x = min(max(at.x + dx, 0), size.w - 1), y = min(max(at.y + dy, 0), size.h - 1)
        SetCursorPos(origin.x + x, origin.y + y)
        if let window { move(to: (x, y), window) }
    }

    fileprivate static func handle(_ hwnd: HWND?, _ message: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT {
        if let hwnd, let current, current.window == hwnd || current.window == nil, let answer = current.handle(hwnd, message, w, l) {
            return answer
        }
        return DefWindowProcW(hwnd, message, w, l)
    }
}

/// The eyedropper's window procedure: its messages come on the main thread, which runs the app.
nonisolated private func eyedropperWindowProc(_ hwnd: HWND?, _ message: UINT, _ w: WPARAM, _ l: LPARAM) -> LRESULT {
    MainActor.assumeIsolated { Eyedropper.handle(hwnd, message, w, l) }
}
