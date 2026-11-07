import Foundation
import WinUI
import UWP

/// The tools, one above the other, with the layers switch at the foot (the Mac's ToolRail):
/// buttons 38 square, radius 10, 4 apart; the chosen one in a well, a wash of ink on hover.
@MainActor
final class ToolRail {
    let root = Grid()
    private let session: DesignSession
    private var buttons: [(tool: Glyphs.Tool?, button: Pressable, glyph: [Glyphs.Part])] = []

    init(session: DesignSession) {
        self.session = session
        root.width = Theme.railWidth
        let top = StackPanel()
        top.spacing = 4
        top.margin = Theme.inset(0, 6, 0, 0)
        top.horizontalAlignment = .center
        for tool in Glyphs.Tool.allCases {
            let button = Pressable(radius: 10) { [weak session] in session?.tool = tool }
            button.hoverWash = 0.06
            button.box.width = 38
            button.box.height = 38
            buttons.append((tool, button, Glyphs.tool(tool)))
            try? ToolTipService.setToolTip(button.box, Words.t(tool.title) + "  " + tool.key)
            top.children.append(button.box)
        }
        root.children.append(top)

        let layers = Pressable(radius: 10) { [weak session] in session?.showsLayers.toggle() }
        layers.hoverWash = 0.06
        layers.box.width = 38
        layers.box.height = 38
        layers.box.verticalAlignment = .bottom
        layers.box.horizontalAlignment = .center
        // As far from the bottom as from the left, level with the canvas's bottom edge.
        layers.box.margin = Theme.inset(0, 0, 0, 9)
        try? ToolTipService.setToolTip(layers.box, Words.t("Layers") + "  Ctrl+Y")
        buttons.append((nil, layers, Glyphs.layers()))
        root.children.append(layers.box)

        session.listen { [weak self] in self?.show() }
        show()
    }

    private func show() {
        for b in buttons {
            let on = b.tool.map { $0 == session.tool } ?? session.showsLayers
            b.button.onLook = { Theme.brush(Theme.well) }
            b.button.isOn = on
            b.button.box.child = Glyphs.view(b.glyph, size: 18, brush: Theme.ink(on ? 1 : 2))
        }
    }
}
