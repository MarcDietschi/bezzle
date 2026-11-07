import Foundation

// Making shapes one on Windows, as the Mac's Arrange card does (the shared ShapeCombine): the
// shapes at the back, less, with or only where what lies in front of them.

extension WindowsCore {
    /// The ways, in the Mac's order: union, subtract, intersect, exclude.
    public static let combines = ["union", "subtract", "intersect", "exclude"]

    private static func way(_ name: String) -> ShapeCombine? {
        switch name {
        case "union": .union
        case "subtract": .subtract
        case "intersect": .intersect
        case "exclude": .exclude
        default: nil
        }
    }

    /// What each way is called, with its key on the Mac (⌥⌘U and so on) as Windows writes it.
    public static func combineTitle(_ name: String) -> String {
        switch name {
        case "union": "Union: join the shapes into one  Ctrl+Alt+U"
        case "subtract": "Subtract: cut the front shapes out of the back one  Ctrl+Alt+S"
        case "intersect": "Intersect: keep only where the shapes overlap  Ctrl+Alt+I"
        default: "Exclude overlap: cut out where the shapes overlap  Ctrl+Alt+X"
        }
    }

    /// Whether the layers are two or more shapes and nothing else.
    public static func canCombine(_ ids: [UUID]) -> Bool { design?.canCombine(ids) ?? false }

    /// Makes the shapes one path, styled as the one at the back and lying where the frontmost
    /// was, as one step: the new path, or nil when nothing would be left of them.
    public static func combine(_ ids: [UUID], _ name: String) -> UUID? {
        guard let how = way(name), let doc = design, let made = doc.combined(ids, how) else { return nil }
        edit { $0.place(combined: made, replacing: ids) }
        return made.id
    }

    /// The picture of a way, 28 square, as the Mac's CombineButton draws it: two overlapping
    /// squares, what is left of them to shade and the outlines over it, as path data.
    public static func combineGlyph(_ name: String) -> (shade: String, outlines: [String]) {
        let side: CGFloat = 9, step: CGFloat = 5
        let x = ((28 - side - step) / 2).rounded(), y = ((28 - side - step) / 2).rounded()
        let back = CGPath(roundedRect: CGRect(x: x, y: y, width: side, height: side), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        let front = CGPath(roundedRect: CGRect(x: x + step, y: y + step, width: side, height: side), cornerWidth: 1.5, cornerHeight: 1.5, transform: nil)
        let left = switch way(name) ?? .union {
        case .union: back.union(front)
        case .subtract: back.subtracting(front)
        case .intersect: back.intersection(front)
        case .exclude: back.symmetricDifference(front)
        }
        let outlines = name == "union" ? [left] : [back, front]
        return (PathData.string(left), outlines.map(PathData.string))
    }
}
