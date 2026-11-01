import SwiftUI
import AppKit

/// Bezzle's one window: the bar along the top, with home and a tab for each open design, and
/// under it home or the design in front.
struct MainWindow: View {
    @State private var tabs = Tabs.shared
    @State private var webImport = WebImporting.shared
    /// Menus opened from the bar while home is in front; a design's tab has menus of its own.
    @State private var homeMenus = MenuHost()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let selected = tabs.selected
        // Home and the designs fill the window, as each did its own, keeping the bar's height
        // free along their tops; the bar lies over that.
        ZStack(alignment: .top) {
            Group {
                if let tab = selected {
                    DesignTabView(tab: tab)
                        .id(tab.id)
                } else {
                    HomeView()
                }
            }
            // A tab comes in at once; only the bar moves.
            .transition(.identity)
            TabBar(tabs: tabs)
        }
        .background(Theme.paper)
        .ignoresSafeArea()
        // Home alone has one size; with designs open the window takes any.
        .frame(width: tabs.homeAlone?.width, height: tabs.homeAlone?.height)
        .frame(minWidth: tabs.homeAlone == nil ? 1000 : nil, maxWidth: tabs.homeAlone == nil ? .infinity : nil,
               minHeight: tabs.homeAlone == nil ? 640 : nil, maxHeight: tabs.homeAlone == nil ? .infinity : nil)
        .overlay {
            if let store = selected?.store, store.exporting {
                ExportSheet(store: store)
                    .environment(store)
                    .transition(.opacity)
            }
        }
        .animation(selected?.store?.exporting == true ? Theme.open : Theme.close, value: selected?.store?.exporting)
        .overlay {
            if webImport.showing {
                WebImportSheet(model: webImport)
                    .transition(.opacity)
            }
        }
        .animation(webImport.showing ? Theme.open : Theme.close, value: webImport.showing)
        .overlayPreferenceValue(MenuAnchorKey.self) { MenuLayer(anchors: $0) }
        .environment(selected?.menus ?? homeMenus)
        .background(TabsWindowReader())
        .navigationTitle(Text(verbatim: selected?.name ?? "Bezzle"))
        .onAppear {
            WindowRouter.shared.openWindow = openWindow
            WindowRouter.shared.flush()
        }
    }
}

/// A design's tab, in front: the design, or why it could not be opened.
private struct DesignTabView: View {
    let tab: DesignTab

    var body: some View {
        if let store = tab.store {
            Workspace(store: store, menus: tab.menus)
        } else if let failure = tab.failure {
            VStack(spacing: 10) {
                Text(Importer.source(of: tab.url).map { String(localized: "This \($0) file could not be brought in.") } ?? String(localized: "This design could not be opened."))
                    .font(Theme.serif(22, weight: .medium))
                    .foregroundStyle(Theme.ink)
                Text(failure)
                    .prose(12.5)
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.paper)
        } else {
            Theme.paper
        }
    }
}

// MARK: - The bar

/// The strip along the top, level with the traffic lights: home and the open designs on the left,
/// and on the right what there is to do with the one in front.
struct TabBar: View {
    let tabs: Tabs

    var body: some View {
        HStack(spacing: 14) {
            TabStrip(tabs: tabs)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let store = tabs.selected?.store {
                // Never squeezed: with longer words (German, French, Italian) the zoom pill lost its
                // number first. The tabs make room instead.
                DesignBarControls(store: store)
                    .fixedSize()
            } else if tabs.selected == nil {
                HStack(spacing: 10) {
                    if !Library.shared.entries.isEmpty {
                        SearchWell(text: Bindable(tabs).homeSearch)
                            .frame(width: 200)
                            .transition(.opacity)
                    }
                    CardButton(title: "From a Website…", symbol: "globe", height: 28) { WebImporting.shared.present() }
                        .help("Bring a web page in as a design  ⌥⇧⌘I")
                    CardButton(title: "Open…", height: 28) { WindowRouter.openPanel() }
                        .help("Open a design, or an XD, Figma or Sketch file  ⌘O")
                }
            }
        }
        // Clear of the traffic lights by a little more than they are apart, so that a tab's card,
        // pointed at or in front, stands off them.
        .padding(.leading, 90)
        .padding(.trailing, tabs.selected == nil ? HomeView.edge : 16)
        .frame(height: Theme.barHeight)
        .background(TitleBarDoubleClick())
    }
}

/// Home, then a tab for each open design, then a button to start another. Each tab is as wide
/// as its name; the one in front opens out to a full width and rests on a card of its own, which
/// slides along to whichever tab is picked. A tab dragged sideways takes another place, the others
/// making way.
private struct TabStrip: View {
    let tabs: Tabs
    @Environment(MenuHost.self) private var menus
    @Namespace private var space
    /// How wide each tab is, as laid out, for moving them about.
    @State private var widths: [DesignTab.ID: CGFloat] = [:]
    @State private var drag: Drag?

    private struct Drag {
        let id: DesignTab.ID
        let from: Int
        var offset: CGFloat
    }

    static let spacing: CGFloat = 4
    static let height: CGFloat = 30

    var body: some View {
        HStack(spacing: Self.spacing + 2) {
            HomeTab(selected: tabs.selectedID == nil, space: space) { tabs.select(nil) }
            row
        }
        .animation(Theme.spring, value: tabs.selectedID)
        .animation(Theme.spring, value: tabs.designs.map(\.id))
    }

    private var row: some View {
        let selected = tabs.designs.firstIndex { $0.id == tabs.selectedID }
        return TabRow(selected: selected, spacing: Self.spacing) {
            ForEach(Array(tabs.designs.enumerated()), id: \.element.id) { index, tab in
                let offset = offset(of: tab, at: index)
                TabButton(tab: tab, selected: tabs.selectedID == tab.id, space: space,
                          press: { tabs.select(tab) },
                          dragged: { dragged(tab, at: index, by: $0) },
                          dropped: dropped,
                          close: { tabs.close(tab) },
                          menu: { menus.show(at: $0, width: 220, entries: entries(for: tab)) },
                          hold: { tabs.hold(tab.id, $0) },
                          measured: { widths[tab.id] = $0 })
                    .offset(x: offset)
                    // The tab being dragged keeps up with the pointer; the others ease aside.
                    .animation(drag?.id == tab.id ? nil : Theme.spring, value: offset)
                    .zIndex(drag?.id == tab.id ? 1 : 0)
                    .transition(.asymmetric(insertion: .scale(scale: 0.6, anchor: .leading).combined(with: .opacity),
                                            removal: .scale(scale: 0.85).combined(with: .opacity)))
            }
            NewTabButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Moving a tab

    private func width(at index: Int) -> CGFloat { widths[tabs.designs[index].id] ?? 0 }

    /// Where a tab starts along the row, as laid out.
    private func start(at index: Int) -> CGFloat {
        (0..<index).reduce(0) { $0 + width(at: $1) + Self.spacing }
    }

    /// The tabs whose middle the dragged one's leading edge has passed, which step aside for it:
    /// its right edge going right, its left edge going left. Tabs differ in width, and its own
    /// middle may never reach a narrow tab's at the end of the row.
    private func passed(by drag: Drag) -> (right: Int, left: Int) {
        let left = start(at: drag.from) + drag.offset
        let right = left + width(at: drag.from)
        let count = tabs.designs.count
        let passedRight = drag.offset > 0 ? (drag.from + 1..<max(drag.from + 1, count)).filter { right > start(at: $0) + width(at: $0) / 2 }.count : 0
        let passedLeft = drag.offset < 0 ? (0..<drag.from).filter { left < start(at: $0) + width(at: $0) / 2 }.count : 0
        return (passedRight, passedLeft)
    }

    private func offset(of tab: DesignTab, at index: Int) -> CGFloat {
        guard let drag, drag.from < tabs.designs.count else { return 0 }
        if drag.id == tab.id { return drag.offset }
        let (right, left) = passed(by: drag)
        let step = width(at: drag.from) + Self.spacing
        if index > drag.from, index <= drag.from + right { return -step }
        if index < drag.from, index >= drag.from - left { return step }
        return 0
    }

    private func dragged(_ tab: DesignTab, at index: Int, by x: CGFloat) {
        // As far as the first tab's left edge and the last one's right, no further.
        let last = tabs.designs.count - 1
        let x = min(max(x, -start(at: index)), start(at: last) + width(at: last) - start(at: index) - width(at: index))
        if drag?.id == tab.id { drag?.offset = x } else { drag = Drag(id: tab.id, from: index, offset: x) }
    }

    /// The dragged tab settles into the place it was let go at.
    private func dropped() {
        guard let drag, let tab = tabs.designs.first(where: { $0.id == drag.id }) else { return }
        let (right, left) = passed(by: drag)
        withAnimation(Theme.spring) {
            tabs.move(tab, to: drag.from + right - left)
            self.drag = nil
        }
    }

    // MARK: Right click

    private func entries(for tab: DesignTab) -> [MenuEntry] {
        var entries: [MenuEntry] = []
        if let store = tab.store {
            entries.append(.item("Rename", enabled: !store.isReadOnly) {
                tabs.select(tab)
                tab.renaming = true
            })
            entries.append(.item("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([store.url]) })
            entries.append(.separator)
        }
        entries.append(.item("Close Tab", shortcut: tabs.selectedID == tab.id ? "⌘W" : nil) { tabs.close(tab) })
        entries.append(.item("Close Other Tabs", enabled: tabs.designs.count > 1) { tabs.closeOthers(than: tab) })
        return entries
    }
}

/// Lays the tabs side by side, each as wide as its name and the one in front at full width, then
/// the button after them. When they are too many for the room, the longest names give way first,
/// down to a few letters each, and only then the tab in front.
private struct TabRow: Layout {
    let selected: Int?
    let spacing: CGFloat

    static let widest: CGFloat = 196
    static let narrowest: CGFloat = 44

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(of: subviews, room: proposal.width)
        let height = subviews.map { $0.sizeThatFits(.unspecified).height }.max() ?? 0
        return CGSize(width: widths.reduce(0, +) + spacing * CGFloat(max(widths.count - 1, 0)), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(of: subviews, room: proposal.width ?? bounds.width)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: bounds.height))
            x += width + spacing
        }
    }

    /// The tabs' widths, then the button's.
    private func widths(of subviews: Subviews, room: CGFloat?) -> [CGFloat] {
        guard let button = subviews.last else { return [] }
        let buttonWidth = button.sizeThatFits(.unspecified).width
        var tabs = subviews.dropLast().map { min(Self.widest, $0.sizeThatFits(.unspecified).width.rounded(.up)) }
        if let selected, tabs.indices.contains(selected) { tabs[selected] = Self.widest }
        guard let room, room.isFinite else { return tabs + [buttonWidth] }
        let available = room - buttonWidth - spacing * CGFloat(tabs.count)
        guard tabs.reduce(0, +) > available else { return tabs + [buttonWidth] }
        let others = tabs.indices.filter { $0 != selected }
        let front = selected != nil ? Self.widest : 0
        let cap = max(Self.narrowest, level(others.map { tabs[$0] }, filling: available - front))
        for i in others { tabs[i] = min(tabs[i], cap) }
        if let selected, tabs.indices.contains(selected) {
            tabs[selected] = max(Self.narrowest, min(Self.widest, available - others.reduce(0) { $0 + tabs[$1] }))
        }
        return tabs + [buttonWidth]
    }

    /// How wide the widest may be for all of them to fill `room`, the narrower keeping their width.
    private func level(_ widths: [CGFloat], filling room: CGFloat) -> CGFloat {
        var remaining = room, left = CGFloat(widths.count)
        for width in widths.sorted() {
            if width * left <= remaining {
                remaining -= width
                left -= 1
            } else {
                return (remaining / left).rounded(.down)
            }
        }
        return .infinity
    }
}

/// The card the tab in front rests on.
private struct FrontCard: View {
    let space: Namespace.ID

    var body: some View {
        Color.clear
            .card(radius: 9)
            .matchedGeometryEffect(id: "front", in: space)
    }
}

/// Bezzle's name, first along the bar: home, where designs are started and found.
private struct HomeTab: View {
    let selected: Bool
    let space: Namespace.ID
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Text(verbatim: "Bezzle")
            .font(Theme.serif(15, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: TabStrip.height)
            .background {
                if selected {
                    FrontCard(space: space)
                } else {
                    RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.05 : 0))
                }
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .onTapGesture(perform: action)
            .help("Home")
            .animation(Theme.quick, value: hovering)
            .accessibilityLabel(Text("Home"))
            .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction(.default, action)
    }
}

/// A design's tab: its name, a mark when it is shared, and a cross to close it, which shows on
/// the tab in front and on the one pointed at. Pressed, it comes to the front; dragged sideways,
/// it moves along the bar; a double click renames the design.
private struct TabButton: View {
    let tab: DesignTab
    let selected: Bool
    let space: Namespace.ID
    let press: () -> Void
    let dragged: (CGFloat) -> Void
    let dropped: () -> Void
    let close: () -> Void
    let menu: (CGPoint) -> Void
    let hold: (Bool) -> Void
    let measured: (CGFloat) -> Void
    @State private var width: CGFloat = 0
    @State private var hovering = false
    @State private var moved = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    private var showsClose: Bool { (selected || hovering) && width >= 56 && !tab.renaming }
    /// Over a tab not in front, the cross lies over the end of the name, which fades under it.
    private var fadesForClose: Bool { showsClose && !selected }

    var body: some View {
        HStack(spacing: 5) {
            if let mark = tab.store?.sharing?.mark, !tab.renaming {
                Image(systemName: mark == .ended ? "lock.fill" : "person.2.fill")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(mark == .ended ? Theme.ink3 : Theme.pencil)
                    .help(mark == .ended ? "Read only: this design is no longer shared with you. Save a copy to keep working on it." : "Shared through iCloud")
            }
            if tab.renaming {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { tab.renaming = false }
                    .onChange(of: focused) { _, now in if !now { commit() } }
            } else {
                Text(verbatim: tab.name)
                    .font(.system(size: 12.5, weight: selected ? .medium : .regular))
                    .foregroundStyle(selected ? Theme.ink : hovering ? Theme.ink : Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .mask {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                                .frame(width: fadesForClose ? 10 : 0)
                            Color.clear
                                .frame(width: fadesForClose ? 12 : 0)
                        }
                    }
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 12)
        // The tab in front keeps room for its cross.
        .padding(.trailing, selected && !tab.renaming ? 26 : 12)
        .frame(height: TabStrip.height)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { new in
            width = new
            measured(new)
        }
        .background {
            if selected {
                FrontCard(space: space)
            } else {
                RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.ink.opacity(hovering ? 0.05 : 0))
            }
        }
        .contentShape(Rectangle())
        .gesture(pressing, including: tab.renaming ? .subviews : .all)
        .overlay(alignment: .trailing) {
            if showsClose {
                CloseCross(action: close)
                    .padding(.trailing, 6)
                    .transition(.opacity)
            }
        }
        .contextMenuReplacement(menu)
        .onContinuousHover { phase in
            switch phase {
            case .active:
                if !hovering { hovering = true }
                hold(true)
            case .ended:
                hovering = false
                hold(false)
            }
        }
        .onDisappear { hold(false) }
        .help(Text(verbatim: tab.name))
        .animation(Theme.quick, value: hovering)
        .animation(Theme.quick, value: selected)
        .onChange(of: tab.renaming, initial: true) { _, now in
            guard now else { return }
            draft = tab.name
            focused = true
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: tab.name))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, press)
        .accessibilityAction(named: Text("Close Tab"), close)
        .accessibilityAction(named: Text("Rename")) { if tab.store?.isReadOnly == false { tab.renaming = true } }
    }

    /// Down, the tab comes to the front at once; moved, it is dragged; a second click renames.
    private var pressing: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                if !moved, abs(value.translation.width) < 4 {
                    if !selected { press() }
                    return
                }
                moved = true
                dragged(value.translation.width)
            }
            .onEnded { _ in
                if moved {
                    dropped()
                } else if (NSApp.currentEvent?.clickCount ?? 1) >= 2, tab.store?.isReadOnly == false {
                    tab.renaming = true
                }
                moved = false
            }
    }

    private func commit() {
        guard tab.renaming else { return }
        tab.renaming = false
        tab.store?.rename(to: draft)
    }
}

/// The cross on a tab, drawn in the hand of the other marks.
private struct CloseCross: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            p.move(to: CGPoint(x: s.width * 0.34, y: s.height * 0.34))
            p.addLine(to: CGPoint(x: s.width * 0.66, y: s.height * 0.66))
            p.move(to: CGPoint(x: s.width * 0.66, y: s.height * 0.34))
            p.addLine(to: CGPoint(x: s.width * 0.34, y: s.height * 0.66))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
        }
        .foregroundStyle(hovering ? Theme.ink : Theme.ink3)
        .frame(width: 18, height: 18)
        .background(Circle().fill(Theme.ink.opacity(hovering ? 0.08 : 0)))
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .help("Close Tab  ⌘W")
        .animation(Theme.quick, value: hovering)
        .accessibilityLabel(Text("Close Tab"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, action)
    }
}

/// After the tabs: home, to start another design.
private struct NewTabButton: View {
    @State private var hovering = false

    var body: some View {
        Canvas { ctx, s in
            var p = Path()
            p.move(to: CGPoint(x: s.width * 0.5, y: s.height * 0.3))
            p.addLine(to: CGPoint(x: s.width * 0.5, y: s.height * 0.7))
            p.move(to: CGPoint(x: s.width * 0.3, y: s.height * 0.5))
            p.addLine(to: CGPoint(x: s.width * 0.7, y: s.height * 0.5))
            ctx.stroke(p, with: .foreground, style: StrokeStyle(lineWidth: 1.4, lineCap: .round))
        }
        .foregroundStyle(hovering ? Theme.ink : Theme.ink2)
        .frame(width: 26, height: 26)
        .background(Circle().fill(Theme.ink.opacity(hovering ? 0.07 : 0)))
        .contentShape(Circle())
        .onHover { hovering = $0 }
        .onTapGesture { WindowRouter.shared.showHome() }
        .help("New Design  ⌘N")
        .animation(Theme.quick, value: hovering)
        .accessibilityLabel(Text("New Design"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { WindowRouter.shared.showHome() }
    }
}
