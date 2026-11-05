import AppKit

/// An artboard's name typed into where it shows, over the artboard's top left corner: a double
/// click on the name puts a field there with the name picked out. Return, Tab or a click anywhere
/// else keeps what was typed; Escape leaves the name as it was. The canvas places the field where
/// the name is drawn as the view moves, and draws the name itself only while there is no field.
@MainActor
final class BoardNaming: NSObject, NSTextFieldDelegate {
    let store: DocumentStore
    var redraw: () -> Void = {}
    /// The artboard being renamed.
    private(set) var board: UUID?
    private var field: NSTextField?
    private weak var canvas: NSView?

    init(store: DocumentStore) {
        self.store = store
    }

    func begin(_ id: UUID, in canvas: NSView, font: NSFont) {
        guard !store.isReadOnly, let node = store.node(id), node.isArtboard else { return }
        end(keep: true)
        let field = NSTextField(string: node.name)
        field.font = font
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.textColor = CanvasInk.labelSelected
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.setAccessibilityLabel(String(localized: "Name"))
        canvas.addSubview(field)
        self.field = field
        self.canvas = canvas
        board = id
        store.selection = [id]
        // Taking the keys picks out the whole name, to be typed over.
        canvas.window?.makeFirstResponder(field)
        redraw()
    }

    /// Puts the field where the name is drawn, `title` being the name's place in the canvas: as
    /// wide as what is typed, and never narrower than the artboard, so the whole name shows.
    func place(_ title: CGRect, boardWidth: CGFloat) {
        guard let field, let font = field.font else { return }
        let typed = (field.stringValue as NSString).size(withAttributes: [.font: font]).width
        // Moved by the field's own margins, its words lie on the drawn name's.
        let frame = CGRect(x: title.minX - 2, y: title.minY + 1, width: max(typed + 12, boardWidth + 4, 60), height: title.height + 2)
        if field.frame != frame { field.frame = frame }
    }

    /// Takes the field away, giving the artboard what was typed in it, or not.
    func end(keep: Bool) {
        guard let field, let board else { return }
        self.field = nil
        self.board = nil
        field.delegate = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        // Still taking the keys, it hands them back to the canvas.
        if let window = field.window, let editor = field.currentEditor(), window.firstResponder === editor {
            window.makeFirstResponder(canvas)
        }
        field.removeFromSuperview()
        if keep, let node = store.node(board), !name.isEmpty, name != node.name {
            store.renameLayer(board, to: name)
        }
        redraw()
    }

    func controlTextDidChange(_ obj: Notification) {
        redraw()
    }

    /// The keys went elsewhere: to the canvas, the inspector or another window.
    func controlTextDidEndEditing(_ obj: Notification) {
        end(keep: true)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            end(keep: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            end(keep: false)
            return true
        default:
            return false
        }
    }
}
