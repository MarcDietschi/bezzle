import Foundation
import WinUI
import UWP
import WindowsFoundation
import WinSDK

/// Bezzle's look, the Mac's own (Views/Theme.swift; the numbers are in DESIGN.md), light for now.
@MainActor
enum Theme {
    // MARK: Colours

    /// Dark, as Windows is set for apps (Settings › Personalization › Colors), read when a window's
    /// content is made; every colour below is the Mac's own for light or dark.
    static var dark = false

    static func readAppearance() {
        // BEZZLE_APPEARANCE=dark or light, for a test copy, whatever Windows is set to.
        if let asked = ProcessInfo.processInfo.environment["BEZZLE_APPEARANCE"], ["dark", "light"].contains(asked) {
            dark = asked == "dark"
            return
        }
        var value: DWORD = 1
        var size = DWORD(MemoryLayout<DWORD>.size)
        let read = "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize".withCString(encodedAs: UTF16.self) { key in
            "AppsUseLightTheme".withCString(encodedAs: UTF16.self) { name in
                RegGetValueW(HKEY_CURRENT_USER, key, name, DWORD(RRF_RT_REG_DWORD), nil, &value, &size)
            }
        }
        dark = read == ERROR_SUCCESS && value == 0
    }

    static var paper: UInt32 { dark ? 0x1B1A18 : 0xF0EDE7 }
    static var panel: UInt32 { dark ? 0x22211F : 0xF6F4EF }
    static var card: UInt32 { dark ? 0x2A2926 : 0xFCFBF8 }
    static var well: UInt32 { dark ? 0x141312 : 0xE5E1D9 }
    static var ink: UInt32 { dark ? 0xEDEAE4 : 0x1C1B19 }
    static var shadow: UInt32 { dark ? 0x000000 : 0x3A3226 }
    static var pencil: UInt32 { dark ? 0x8FA8F2 : 0x3559C7 }
    /// What warns, such as a card about to be torn off.
    static var warning: UInt32 { dark ? 0xE4705C : 0xB3402F }
    /// What is drawn on ink, such as a switch's knob when it is on.
    static var onInk: UInt32 { dark ? 0x1B1A18 : 0xF6F4EF }
    static var linked: UInt32 { dark ? 0xAE93F2 : 0x7650D8 }
    /// The canvas behind the artboards, and its selection's pencil (the same in both).
    static var table: UInt32 { dark ? 0x0F0E0D : 0xE5E1D9 }
    static let selection: UInt32 = 0x3A63D8
    /// A ruler beside the artboard it measures.
    static var rulerSheet: UInt32 { dark ? 0x161514 : 0xEAE7E0 }
    static var pencilWash: Double { dark ? 0.16 : 0.10 }

    static func color(_ rgb: UInt32, _ alpha: Double = 1) -> UWP.Color {
        UWP.Color(a: UInt8((min(max(alpha, 0), 1) * 255).rounded()), r: UInt8(rgb >> 16 & 0xFF), g: UInt8(rgb >> 8 & 0xFF), b: UInt8(rgb & 0xFF))
    }

    /// `b` laid over `a` at `t`, as one colour.
    static func mix(_ a: UInt32, _ b: UInt32, _ t: Double) -> UInt32 {
        func c(_ v: UInt32, _ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) }
        func m(_ shift: UInt32) -> UInt32 { UInt32((c(a, shift) * (1 - t) + c(b, shift) * t).rounded()) << shift }
        return m(16) | m(8) | m(0)
    }

    static func brush(_ rgb: UInt32, _ alpha: Double = 1) -> SolidColorBrush { SolidColorBrush(color(rgb, alpha)) }

    /// Ink at the Mac's four strengths: ink, ink2 64%, ink3 44%, ink4 22%; and the hairline, 9%.
    static func ink(_ level: Int = 1) -> SolidColorBrush { brush(ink, [1, 1, 0.64, 0.44, 0.22][min(max(level, 0), 4)]) }
    static var hairline: SolidColorBrush { brush(ink, 0.09) }
    static var clear: SolidColorBrush { brush(0, 0) }

    // MARK: Sizes

    static let barHeight = 52.0
    static let railWidth = 56.0
    static let layersWidth = 236.0
    static let inspectorWidth = 280.0
    static let cardWidth = 248.0

    // MARK: Type

    /// The system font's stand-in (SF on the Mac), as the designs use it: Inter, in fonts\ beside
    /// Bezzle.exe, which ms-appx:/// names for an app run from its folder.
    static let ui = FontFamily("ms-appx:///fonts/Inter-Variable.ttf#Inter")
    /// The serif (New York on the Mac): Gelasio.
    static let serif = FontFamily("ms-appx:///fonts/Gelasio-400.ttf#Gelasio")

    static func text(_ s: String, size: Double, weight: UInt16 = 400, ink level: Int = 1, serif: Bool = false) -> TextBlock {
        let t = TextBlock()
        t.text = s
        t.fontFamily = serif ? Theme.serif : ui
        t.fontSize = size
        t.fontWeight = FontWeight(weight: weight)
        t.foreground = ink(level)
        t.textTrimming = .characterEllipsis
        t.textWrapping = .noWrap
        t.verticalAlignment = .center
        return t
    }

    // MARK: Surfaces

    /// A card, as `.card()` makes one: the card's fill, a hairline round it.
    static func card(radius: Double = 12) -> Border {
        let b = Border()
        b.background = brush(card)
        b.borderBrush = brush(ink, 0.09)
        b.borderThickness = Thickness(left: 0.5, top: 0.5, right: 0.5, bottom: 0.5)
        b.cornerRadius = CornerRadius(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
        return b
    }

    /// A well, as `.well()` makes one: pressed into the paper.
    static func well(radius: Double) -> Border {
        let b = Border()
        b.background = brush(well)
        b.borderBrush = brush(shadow, 0.12)
        b.borderThickness = Thickness(left: 0, top: 1, right: 0, bottom: 0)
        b.cornerRadius = CornerRadius(topLeft: radius, topRight: radius, bottomRight: radius, bottomLeft: radius)
        return b
    }

    static func corners(_ r: Double) -> CornerRadius { CornerRadius(topLeft: r, topRight: r, bottomRight: r, bottomLeft: r) }
    static func inset(_ l: Double, _ t: Double, _ r: Double, _ b: Double) -> Thickness { Thickness(left: l, top: t, right: r, bottom: b) }
    static func inset(_ all: Double) -> Thickness { Thickness(left: all, top: all, right: all, bottom: all) }
}

/// Something to press, drawn as the Mac draws its own: no chrome but what it is given, a wash on
/// hover. Its content sits in `box`. It keeps working when nothing else holds this object: its
/// handlers hold only its state, which does not hold the box (the box holds the handlers).
@MainActor
final class Pressable {
    /// The keys held, and when, at the last tap: an action runs once the tap is over, when they
    /// may have been let go.
    static var tap: (control: Bool, shift: Bool, at: DWORD) = (false, false, 0)

    let box = Border()
    private let state: State

    @MainActor final class State {
        var action: () -> Void
        var hoverWash: Double = 0.05
        var isOn = false
        var onLook: (() -> Brush?)?
        var hovering = false
        /// Lit as if under the pointer, for what the pointer is on elsewhere.
        var pointed = false
        init(action: @escaping () -> Void) { self.action = action }

        func paint(_ box: Border) {
            if isOn, let on = onLook?() { box.background = on; return }
            box.background = hovering || pointed ? Theme.brush(Theme.ink, hoverWash) : Theme.clear
        }
    }

    var action: () -> Void { get { state.action } set { state.action = newValue } }
    var hoverWash: Double { get { state.hoverWash } set { state.hoverWash = newValue } }
    var onLook: (() -> Brush?)? { get { state.onLook } set { state.onLook = newValue } }
    var isOn: Bool { get { state.isOn } set { state.isOn = newValue; state.paint(box) } }

    init(radius: Double, action: @escaping () -> Void) {
        let state = State(action: action)
        self.state = state
        box.cornerRadius = Theme.corners(radius)
        box.background = Theme.clear
        box.pointerEntered.addHandler { sender, _ in
            state.hovering = true
            if let b = sender as? Border { state.paint(b) }
        }
        box.pointerExited.addHandler { sender, _ in
            state.hovering = false
            if let b = sender as? Border { state.paint(b) }
        }
        // Once the tap is over: what it does often makes the panel again, this very box with
        // it, which WinUI must not lose inside its own event.
        // The keys as they were when the press came, which it carries itself.
        box.pointerPressed.addHandler { _, args in
            // Windows' VirtualKeyModifiers: Control 1, Menu 2, Shift 4.
            let keys = UInt32(truncatingIfNeeded: args?.keyModifiers.rawValue ?? 0)
            Pressable.tap = (keys & 1 != 0, keys & 4 != 0, GetTickCount())
        }
        box.tapped.addHandler { _, _ in DispatchQueue.main.async { MainActor.assumeIsolated { state.action() } } }
    }

    func paint() { state.paint(box) }

    /// Lit as if under the pointer, or not.
    func point(_ on: Bool) {
        guard state.pointed != on else { return }
        state.pointed = on
        state.paint(box)
    }
}
