import WinUI
import WinAppSDK

/// The pointer the canvas shows, as the Mac's canvas sets its cursors: Windows' own where the
/// Mac takes the system's, and the Mac's own drawings (Bezzle/Canvas/Cursors.swift, made into
/// cursor resources by Resources/make-cursors.sh) where it draws them.
enum Pointer: Hashable {
    case arrow, cross, iBeam, pointingHand
    /// The hand that moves the canvas around: open while Space is held, closed while dragging.
    /// Windows has none, so its four-way arrow.
    case grab
    /// Windows' own arrows across and up and down, for guides and layout grids, as the Mac's.
    case across, upDown
    /// A two-headed arrow at any angle, in degrees clockwise from across, following a turned
    /// layer's sides.
    case resize(Double)
    /// The curved arrow at a corner whose way from the middle is an angle, in degrees.
    case rotate(Double)
    /// Turning in depth.
    case turn
    case knife
    /// The pen, with what a click does marked beside it: 0 nothing, 1 add, 2 remove, 3 close,
    /// 4 convert, 5 carry on.
    case pen(Int)
    case build(erase: Bool)

    /// Its number among Bezzle.exe's cursors, for the Mac's drawings (see Resources/cursors.swift).
    var resource: UInt32? {
        switch self {
        case .resize(let degrees):
            // Both ends look the same, so half a turn is enough, in steps of 15°.
            return 100 + UInt32(Int(((degrees.truncatingRemainder(dividingBy: 180) + 180).truncatingRemainder(dividingBy: 180) / 15).rounded()) % 12)
        case .rotate(let degrees):
            return 200 + UInt32(Int(((degrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360) / 15).rounded()) % 24)
        case .turn: return 300
        case .pen(let mark): return 400 + UInt32(min(max(mark, 0), 5))
        case .knife: return 500
        case .build(let erase): return erase ? 601 : 600
        default: return nil
        }
    }

    private var shape: InputSystemCursorShape {
        switch self {
        case .cross: .cross
        case .iBeam: .ibeam
        case .pointingHand: .hand
        case .grab: .sizeAll
        case .across: .sizeWestEast
        case .upDown: .sizeNorthSouth
        // Should Bezzle.exe lack its cursors, the nearest of Windows' own.
        case .resize(let degrees):
            switch Int((((degrees.truncatingRemainder(dividingBy: 180)) + 180).truncatingRemainder(dividingBy: 180) / 45).rounded()) % 4 {
            case 0: .sizeWestEast
            case 1: .sizeNorthwestSoutheast
            case 2: .sizeNorthSouth
            default: .sizeNortheastSouthwest
            }
        case .knife, .pen, .build: .cross
        default: .arrow
        }
    }

    nonisolated(unsafe) private static var made: [UInt32: InputCursor] = [:]

    /// The cursor itself, made once.
    var cursor: InputCursor? {
        let key = resource ?? UInt32(shape.rawValue)
        if let c = Self.made[key] { return c }
        var c: InputCursor?
        // From Bezzle.exe by name: without it, the cursor is looked for in another module.
        if let id = resource { c = try? InputDesktopResourceCursor.createFromModule("Bezzle.exe", id) }
        if c == nil { c = try? InputSystemCursor.create(shape) }
        Self.made[key] = c
        return c
    }
}
