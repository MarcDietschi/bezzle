import Foundation
import WinUI
import BezzleCore

/// The Path card, as the Mac's PathCard (Views/Inspector.swift): open or closed; with a fill,
/// whether where the outline overlaps itself is filled in or cut out; for one path, Edit Points
/// (Done while editing); and while its points are edited, where the picked ones are and whether
/// they are corners or smooth.
extension Inspector {
    func pathCard(_ layers: [WindowsCore.Layer], board: Int) -> UIElement {
        let pen = session.pen
        let ids = layers.map(\.id)
        let single = layers.count == 1 && !layers[0].locked ? layers[0] : nil
        let editing = single != nil && pen.editingPath == single?.id
        var summary = switch pen.closed {
        case true?: "Closed"
        case false?: "Open"
        case nil: "Several"
        }
        if editing { summary += " · Editing points" }
        @MainActor func edited() { self.session.edited(board: board) }
        return card("Path", summary, glyph: Glyphs.kind("path", size: 16), body: {
            var rows: [UIElement] = [
                Controls.segmented(pen.closed ?? false, [(false, "Open"), (true, "Closed")]) { closed in
                    pen.setClosed(closed)
                    edited()
                },
            ]
            // Where the outline crosses itself, or one part lies inside another: only a fill shows it.
            let fills = WindowsCore.pathFills(ids)
            if fills.filled {
                rows.append(Controls.row("Overlaps", Controls.glyphChoice(fills.cutOut, [false, true]) { cut, on in
                    Glyphs.overlap(cut: cut, brush: on ? Theme.ink(1) : Theme.ink(2))
                } choose: { cut in
                    WindowsCore.setCutOut(ids, cut)
                    edited()
                }))
            }
            if single != nil {
                rows.append(Controls.cardButton(editing ? "Done" : "Edit Points", height: 28) {
                    if editing { pen.editingPath = nil } else { pen.editSelectedPoints() }
                    edited()
                })
            }
            if editing {
                if !pen.picksPoints {
                    rows.append(Controls.caption("Drag a point or its handles. Click the outline to add a point, and double-click a point to make it smooth or sharp."))
                } else {
                    rows.append(self.pair(self.pointField(x: true, edited), self.pointField(x: false, edited)))
                    rows.append(Controls.segmented(pen.smoothPicked ?? false, [(false, "Corner"), (true, "Smooth")]) { smooth in
                        pen.setPickedSmooth(smooth)
                        edited()
                    })
                }
            }
            return rows
        })
    }

    /// Where the picked points are, across or down: typed, all go there; scrubbed or stepped
    /// while they differ, each moves by as much.
    private func pointField(x: Bool, _ edited: @escaping @MainActor () -> Void) -> FrameworkElement {
        let pen = session.pen
        return field(x ? "X" : "Y", pen.picked(x: x), each: { d in
            pen.movePicked(x: x, by: d)
            edited()
        }) { v in
            pen.movePicked(x: x, to: v)
            edited()
        }
    }
}
