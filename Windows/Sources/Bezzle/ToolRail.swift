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
    private var resourcesButton: Pressable?

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

        // Above the layers switch, the resources switch, as on the Mac.
        let resources = Pressable(radius: 10) { [weak session] in session?.toggleResources() }
        resources.hoverWash = 0.06
        resources.box.width = 38
        resources.box.height = 38
        resources.box.verticalAlignment = .bottom
        resources.box.horizontalAlignment = .center
        resources.box.margin = Theme.inset(0, 0, 0, 9 + 38 + 4)
        try? ToolTipService.setToolTip(resources.box, Words.t("Resources") + "  Ctrl+Shift+Y")
        resourcesButton = resources
        root.children.append(resources.box)

        let layers = Pressable(radius: 10) { [weak session] in
            guard let session else { return }
            // From the resources, back to the layers.
            if session.showsResources { session.showsResources = false; session.showsLayers = true } else { session.showsLayers.toggle() }
        }
        layers.hoverWash = 0.06
        layers.box.width = 38
        layers.box.height = 38
        layers.box.verticalAlignment = .bottom
        layers.box.horizontalAlignment = .center
        // As far from the bottom as from the left, level with the canvas's bottom edge.
        layers.box.margin = Theme.inset(0, 0, 0, 9)
        // Alt+Y, as the Mac's ⌘Y: Ctrl+Y is Redo on Windows.
        try? ToolTipService.setToolTip(layers.box, Words.t("Layers") + "  Alt+Y")
        buttons.append((nil, layers, Glyphs.layers()))
        root.children.append(layers.box)

        session.listen { [weak self] in self?.show() }
        show()
    }

    /// What the rail last showed: it is made again only when that changes, not at every step of a
    /// drag, where nothing on it does.
    private var shown = ""

    private func show() {
        let state = "\(session.tool.rawValue) \(session.showsResources) \(session.showsLayers) \(Theme.ink)"
        guard state != shown else { return }
        shown = state
        if let r = resourcesButton {
            r.onLook = { Theme.brush(Theme.well) }
            r.isOn = session.showsResources
            r.box.child = Glyphs.view(Glyphs.resources(), size: 18, brush: Theme.ink(session.showsResources ? 1 : 2))
        }
        for b in buttons {
            let on = b.tool.map { $0 == session.tool } ?? (session.showsLayers && !session.showsResources)
            b.button.onLook = { Theme.brush(Theme.well) }
            b.button.isOn = on
            b.button.box.child = Glyphs.view(b.glyph, size: 18, brush: Theme.ink(on ? 1 : 2))
        }
    }
}
