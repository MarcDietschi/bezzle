import SwiftUI
import AppKit

/// Menus and small panels drawn in the paper style instead of the system's. A control marks
/// itself with `menuAnchor(id)`; `MenuHost` opens a menu under it, or at a point for a right
/// click, drawn by `MenuLayer` at the top of the window so nothing can clip it.
struct MenuEntry: Identifiable {
    enum Kind { case item, separator, note }
    let id = UUID()
    var kind: Kind = .item
    var title = ""
    var detail: String?
    var shortcut: String?
    var checked = false
    var enabled = true
    /// Drawn in the entry's own font, for the font menu.
    var font: Font?
    /// Shows on the canvas what choosing the entry would do, while it is highlighted; false when it
    /// no longer is.
    var preview: ((Bool) -> Void)?
    var action: () -> Void = {}

    static func item(_ title: LocalizedStringResource, detail: LocalizedStringResource? = nil, shortcut: String? = nil, checked: Bool = false,
                     enabled: Bool = true, font: Font? = nil, preview: ((Bool) -> Void)? = nil, action: @escaping () -> Void) -> MenuEntry {
        MenuEntry(title: String(localized: title), detail: detail.map { String(localized: $0) }, shortcut: shortcut, checked: checked,
                  enabled: enabled, font: font, preview: preview, action: action)
    }

    static var separator: MenuEntry { MenuEntry(kind: .separator) }
    static func note(_ text: LocalizedStringResource) -> MenuEntry { MenuEntry(kind: .note, title: String(localized: text), enabled: false) }
}

@Observable
final class MenuHost {
    enum Place: Equatable {
        /// Under (or over) the control marked with this id.
        case anchor(String)
        /// At a point in the window, y measured from the top.
        case point(CGPoint)
    }

    enum Content {
        case entries([MenuEntry])
        case panel(AnyView, CGSize)
    }

    struct Open {
        let id: String
        let place: Place
        var content: Content
        let width: CGFloat
        /// Scrolls the menu so this entry shows, for long lists such as fonts.
        var reveal: Int?
        /// Each time a menu opens it is a new one, so one opening in place of another, such as a
        /// second right click, goes and comes rather than jumping.
        let token = UUID()
    }

    var open: Open?
    /// The entry under the pointer or picked out with the arrow keys; see `highlight`.
    private(set) var highlighted: Int?
    private var monitor: Any?
    private var clickMonitor: Any?
    /// Where the open menu and the control it hangs from are, in the window from its top left,
    /// to tell a click outside them. The layer notes them as it draws, so they are not observed.
    @ObservationIgnored private var menuFrame: CGRect = .zero
    @ObservationIgnored private var anchorFrame: CGRect?
    @ObservationIgnored private weak var window: NSWindow?
    /// Somewhere outside the menu a click leaves it open, such as the handles that shape on the
    /// canvas what the menu shows; at a point in the window from its top left.
    @ObservationIgnored var spares: ((CGPoint) -> Bool)?

    func track(menu: CGRect, anchor: CGRect?) {
        menuFrame = menu
        anchorFrame = anchor
    }

    func toggle(_ anchor: String, width: CGFloat = 240, reveal: Int? = nil, entries: [MenuEntry]) {
        if open?.id == anchor { dismiss(); return }
        present(Open(id: anchor, place: .anchor(anchor), content: .entries(entries), width: width, reveal: reveal))
    }

    static let contextID = "point"

    func show(at point: CGPoint, width: CGFloat = 220, entries: [MenuEntry]) {
        present(Open(id: Self.contextID, place: .point(point), content: .entries(entries), width: width))
    }

    /// A panel of any content under a control, such as the colour picker.
    func panel<Content: View>(_ anchor: String, size: CGSize, @ViewBuilder content: () -> Content) {
        if open?.id == anchor { dismiss(); return }
        present(Open(id: anchor, place: .anchor(anchor), content: .panel(AnyView(content()), size), width: size.width))
    }

    /// Makes the open panel this size, as what it shows changes.
    func resize(_ id: String, to size: CGSize) {
        guard let open, open.id == id, case .panel(let view, let old) = open.content, old != size else { return }
        self.open?.content = .panel(view, size)
    }

    /// Highlights an entry, or none, and shows on the canvas what it would do.
    func highlight(_ index: Int?) {
        guard index != highlighted else { return }
        if case .entries(let entries)? = open?.content {
            if let h = highlighted, entries.indices.contains(h) { entries[h].preview?(false) }
            if let index, entries.indices.contains(index) { entries[index].preview?(true) }
        }
        highlighted = index
    }

    private func present(_ next: Open) {
        highlight(nil)
        withAnimation(Theme.menu) { open = next }
        window = NSApp.keyWindow
        watchKeys()
        watchClicks()
    }

    func dismiss() {
        guard open != nil else { return }
        highlight(nil)
        withAnimation(Theme.close) { open = nil }
        for m in [monitor, clickMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(m) }
        monitor = nil
        clickMonitor = nil
    }

    /// A click outside the menu closes it and still does what it would have done: picks or drags
    /// on the canvas, presses another control. A click on the menu's own control is left to it,
    /// which closes it. Scrolling moves what a right-click menu was about, so that closes it too.
    private func watchClicks() {
        if clickMonitor != nil { return }
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self, self.open != nil else { return event }
            if let window = self.window, event.window !== window {
                if event.type != .scrollWheel { self.dismiss() }
            } else if let content = event.window?.contentView {
                self.passing(event.type, at: CGPoint(x: event.locationInWindow.x, y: content.bounds.height - event.locationInWindow.y))
            }
            return event
        }
    }

    /// A click or a scroll on its way past the open menu, at a point in the window from its top left.
    func passing(_ type: NSEvent.EventType, at p: CGPoint) {
        guard let open, !menuFrame.contains(p) else { return }
        if type == .scrollWheel {
            if case .point = open.place { dismiss() }
        } else if !(anchorFrame?.contains(p) ?? false), !(spares?(p) ?? false) {
            dismiss()
        }
    }

    func choose(_ entry: MenuEntry) {
        guard entry.kind == .item, entry.enabled else { return }
        dismiss()
        entry.action()
    }

    /// Arrow keys move through the menu, Return chooses, Escape closes.
    private func watchKeys() {
        if monitor != nil { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let open = self.open else { return event }
            if event.keyCode == 53 { self.dismiss(); return nil }
            guard case .entries(let entries) = open.content else { return event }
            let choosable = entries.indices.filter { entries[$0].kind == .item && entries[$0].enabled }
            switch event.keyCode {
            case 125, 126:
                guard !choosable.isEmpty else { return nil }
                let current = self.highlighted.flatMap { choosable.firstIndex(of: $0) }
                let next = event.keyCode == 125
                    ? (current.map { min($0 + 1, choosable.count - 1) } ?? 0)
                    : (current.map { max($0 - 1, 0) } ?? choosable.count - 1)
                self.highlight(choosable[next])
                return nil
            case 36, 76:
                if let h = self.highlighted { self.choose(entries[h]) }
                return nil
            default: return event
            }
        }
    }
}

struct MenuAnchorKey: PreferenceKey {
    static var defaultValue: [String: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func menuAnchor(_ id: String) -> some View {
        anchorPreference(key: MenuAnchorKey.self, value: .bounds) { [id: $0] }
    }
}

/// Draws the open menu under its control, or above it when there is no room below. A menu too
/// long for either side takes the roomier one and scrolls.
struct MenuLayer: View {
    @Environment(MenuHost.self) private var host
    let anchors: [String: Anchor<CGRect>]

    var body: some View {
        GeometryReader { geo in
            // Nothing here takes clicks but the menu: they reach the canvas and controls below,
            // and the host closes the menu as they pass. The clear sheet is only to place it on.
            ZStack(alignment: .topLeading) {
                Color.clear
                    .allowsHitTesting(false)
                if let open = host.open, let rect = rect(for: open, in: geo) {
                    let gap: CGFloat = rect.height > 0 ? 6 : 2
                    let full = contentHeight(open)
                    let roomBelow = geo.size.height - 12 - rect.maxY - gap
                    let roomAbove = rect.minY - gap - 12
                    let below = full <= roomBelow || roomBelow >= roomAbove
                    let height = min(full, below ? roomBelow : roomAbove)
                    let x = min(max(rect.minX, 12), geo.size.width - open.width - 12)
                    let y = below ? rect.maxY + gap : rect.minY - gap - height
                    let window = geo.frame(in: .global).origin
                    let _ = host.track(menu: CGRect(x: window.x + x, y: window.y + y, width: open.width, height: height),
                                       anchor: rect.isEmpty ? nil : rect.offsetBy(dx: window.x, dy: window.y))
                    let pop = MenuPop(origin: UnitPoint(x: min(max((rect.midX - x) / open.width, 0), 1), y: below ? 0 : 1))
                    Group {
                        switch open.content {
                        case .entries: MenuPanel(open: open, scrolls: height < full)
                        case .panel(let view, _): view.card(radius: 14, lifted: true)
                        }
                    }
                    .frame(width: open.width, height: height)
                    // Placed by its guides rather than offset, so it grows from where it really is.
                    .alignmentGuide(.leading) { _ in -x }
                    .alignmentGuide(.top) { _ in -y }
                    .id(open.token)
                    .transition(AsymmetricTransition(insertion: pop.animation(Theme.menu), removal: pop.animation(Theme.close)))
                }
            }
        }
    }

    private func rect(for open: MenuHost.Open, in geo: GeometryProxy) -> CGRect? {
        switch open.place {
        case .anchor(let id): anchors[id].map { geo[$0] }
        case .point(let p):
            // The point is in the window, from its top left; this layer starts below the title bar.
            CGRect(origin: CGPoint(x: p.x - geo.frame(in: .global).minX, y: p.y - geo.frame(in: .global).minY), size: .zero)
        }
    }

    private func contentHeight(_ open: MenuHost.Open) -> CGFloat {
        switch open.content {
        case .entries(let entries): MenuPanel.height(of: entries)
        case .panel(_, let size): size.height
        }
    }
}

/// How a menu comes and goes. It grows out of the control or the point it hangs from and settles
/// with a little give; it goes quicker than it came, sinking back a touch as it fades.
private struct MenuPop: Transition {
    let origin: UnitPoint

    func body(content: Content, phase: TransitionPhase) -> some View {
        content
            .scaleEffect(phase == .willAppear ? 0.9 : phase == .didDisappear ? 0.96 : 1, anchor: origin)
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

private struct MenuPanel: View {
    @Environment(MenuHost.self) private var host
    let open: MenuHost.Open
    /// Only a menu too long for the window scrolls. A scroll view near the title bar reaches up
    /// under it, over the bar's own controls, and takes the clicks meant for them, such as the
    /// one on the zoom button that shuts its menu.
    let scrolls: Bool

    static func height(of entries: [MenuEntry]) -> CGFloat {
        entries.reduce(CGFloat(12)) { total, e in
            total + (e.kind == .separator ? 9 : e.kind == .note ? 30 : e.detail == nil ? 28 : 40)
        }
    }

    var body: some View {
        if case .entries(let entries) = open.content {
            Group {
                if scrolls {
                    ScrollViewReader { reader in
                        ScrollView { list(entries) }
                            .scrollIndicators(.never)
                            .onAppear { if let reveal = open.reveal { reader.scrollTo(reveal, anchor: .center) } }
                    }
                } else {
                    list(entries)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .card(radius: 12, lifted: true)
        }
    }

    private func list(_ entries: [MenuEntry]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                switch entry.kind {
                case .separator:
                    Hairline().padding(.vertical, 4).padding(.horizontal, 8)
                case .note:
                    Text(entry.title)
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .padding(.horizontal, 12)
                        .frame(height: 30, alignment: .leading)
                case .item:
                    MenuRow(entry: entry, highlighted: host.highlighted == index)
                        .id(index)
                        .onHover { if $0 && entry.enabled { host.highlight(index) } }
                        .onTapGesture { host.choose(entry) }
                }
            }
        }
        .padding(6)
        // Off the menu, nothing is highlighted and nothing shown for it.
        .onHover { if !$0 { host.highlight(nil) } }
    }
}

private struct MenuRow: View {
    let entry: MenuEntry
    let highlighted: Bool

    var body: some View {
        HStack(alignment: entry.detail == nil ? .center : .firstTextBaseline, spacing: 8) {
            ZStack {
                if entry.checked { CheckMark(size: 10, color: Theme.ink) }
            }
            .frame(width: 12)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title)
                    .font(entry.font ?? .system(size: 13))
                    .foregroundStyle(entry.enabled ? Theme.ink : Theme.ink4)
                    .lineLimit(1)
                if let detail = entry.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(entry.enabled ? Theme.ink3 : Theme.ink4)
                }
            }
            Spacer(minLength: 0)
            if let shortcut = entry.shortcut {
                Text(shortcut)
                    .font(.system(size: 12))
                    .foregroundStyle(entry.enabled ? Theme.ink3 : Theme.ink4)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: entry.detail == nil ? 28 : 40)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(highlighted ? Theme.ink.opacity(0.07) : .clear)
        }
        .contentShape(Rectangle())
    }
}
