import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The designs open in Bezzle's one window, a tab each, after the home tab that is always first.
/// Opening or making a design gives it a tab and brings it to the front; closing its tab saves it,
/// lets it go and brings home back. The window stays as long as Bezzle runs: closing it closes the
/// designs in it, and only closing home as well quits Bezzle.
@MainActor @Observable
final class Tabs {
    static let shared = Tabs()

    /// The open designs, in the order of their tabs.
    private(set) var designs: [DesignTab] = []
    /// The tab in front; nil for home.
    private(set) var selectedID: DesignTab.ID?
    /// What the designs on the home tab are being looked through for, typed into the bar.
    var homeSearch = ""
    /// The window the tabs are in, while it is open.
    @ObservationIgnored weak var window: NSWindow? {
        didSet {
            undoResponder.install(in: window)
            focusWatch = window?.observe(\.firstResponder) { window, _ in
                MainActor.assumeIsolated { Tabs.shared.keepFocus(in: window) }
            }
            guard window !== oldValue else { return }
            windowWatch.forEach(NotificationCenter.default.removeObserver)
            windowWatch = []
            guard let window else { return }
            closeButton.hook(window)
            let center = NotificationCenter.default
            windowWatch = [
                // Back from full screen, home alone takes its own size again.
                center.addObserver(forName: NSWindow.didExitFullScreenNotification, object: window, queue: .main) { _ in
                    MainActor.assumeIsolated { Tabs.shared.fitWindow() }
                },
            ]
            // Designs opened from the Finder as Bezzle starts may already be in their tabs.
            fitWindow(animate: false)
        }
    }
    @ObservationIgnored private var focusWatch: NSKeyValueObservation?
    @ObservationIgnored private var windowWatch: [NSObjectProtocol] = []
    /// Answers the window's close button, which closes the designs rather than the window.
    @ObservationIgnored private let closeButton = CloseButton()
    /// Gives Edit › Undo and every text field the history of the design in front.
    @ObservationIgnored private let undoResponder = TabsUndoResponder()
    /// The design tabs as they were last in front, the latest first.
    @ObservationIgnored private var recency: [DesignTab.ID] = []
    /// What holds the window still while the pointer is over it, so a tab can be dragged.
    @ObservationIgnored private var holds: Set<DesignTab.ID> = []

    var selected: DesignTab? { selectedID.flatMap { id in designs.first { $0.id == id } } }

    func tab(of store: DocumentStore) -> DesignTab? { designs.first { $0.store === store } }

    /// The open designs, the one in front first, then as they were last looked at.
    var storesByRecency: [DocumentStore] {
        recency.compactMap { id in designs.first { $0.id == id }?.store }
    }

    /// Opens a design in a new tab after the others and brings it to the front. One open already
    /// comes to the front instead. A file from Adobe XD, Figma or Sketch is brought in again each
    /// time, as a new design.
    func open(_ url: URL, report: ImportReport? = nil) {
        let url = url.standardizedFileURL
        if !Importer.imports(url), let tab = designs.first(where: { $0.shows(url) }) {
            select(tab)
            return
        }
        if designs.isEmpty { fitWindow(forDesigns: true) }
        let tab = DesignTab(url: url)
        tab.load(report: report)
        designs.append(tab)
        show(tab.id)
    }

    /// How big the window is made for designing: nearly all of the screen, but never wider than
    /// an eye can take in on an ultrawide one.
    static func designSize(in visible: CGSize) -> CGSize {
        CGSize(width: min(visible.width - 48, 2560), height: visible.height - 48)
    }

    /// How big the window is with home alone in it: home's page at its full width, with the sizes
    /// on their table and a row of designs under them, the same every time, and no more than the
    /// screen has.
    static func homeSize(in visible: CGSize) -> CGSize {
        CGSize(width: min(HomeView.maxWidth + HomeView.margin * 2, visible.width - 48), height: min(880, visible.height - 48))
    }

    /// The one size the window has while home is alone in it, which can't be changed: more room
    /// would show nothing more. Nil while designs are open, or in full screen, when the window
    /// takes any size. It is the size under the title bar, which SwiftUI adds to it.
    private(set) var homeAlone: CGSize? = Tabs.homeSize(in: NSScreen.main?.visibleFrame.size ?? CGSize(width: 1440, height: 900))

    /// Home alone keeps the window at its one size. The first design opened makes room for
    /// itself: the window grows to the size for designing, in the middle of its screen, before
    /// the canvas is first laid out, and from then on takes any size. With the last design
    /// closed, it goes back to home's size. In full screen that waits until the window is back on
    /// the desktop.
    fileprivate func fitWindow(forDesigns: Bool? = nil, animate: Bool = true) {
        guard let window, !window.styleMask.contains(.fullScreen),
              let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let animate = animate && window.isVisible
        if forDesigns ?? !designs.isEmpty {
            homeAlone = nil
            let room = Self.designSize(in: visible.size)
            var frame = window.frame
            guard frame.width < room.width - 1 || frame.height < room.height - 1 else { return }
            frame.size = CGSize(width: min(max(frame.width, room.width), visible.width), height: min(max(frame.height, room.height), visible.height))
            frame.origin = CGPoint(x: (visible.midX - frame.width / 2).rounded(), y: (visible.midY - frame.height / 2).rounded())
            // Home's one size holds the window until SwiftUI next lays it out.
            window.contentMaxSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            window.setFrame(frame, display: true, animate: animate)
        } else {
            // Shrinks about its middle, kept on the screen.
            let size = Self.homeSize(in: visible.size)
            let x = min(max(window.frame.midX - size.width / 2, visible.minX), visible.maxX - size.width)
            let y = min(max(window.frame.midY - size.height / 2, visible.minY), visible.maxY - size.height)
            let frame = CGRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
            if frame != window.frame { window.setFrame(frame, display: true, animate: animate) }
            let titleBar = window.frame.height - window.contentLayoutRect.height
            homeAlone = CGSize(width: size.width, height: size.height - titleBar)
        }
    }

    /// Brings a tab to the front; nil is home.
    func select(_ tab: DesignTab?) {
        guard tab?.id != selectedID else { return }
        show(tab?.id)
    }

    /// The next tab along, or the one before, home included, going round.
    func step(by offset: Int) {
        let order: [DesignTab.ID?] = [nil] + designs.map(\.id)
        guard let at = order.firstIndex(of: selectedID) else { return }
        let next = order[((at + offset) % order.count + order.count) % order.count]
        show(next)
    }

    /// Closes a design's tab, saving it. Closing the one in front brings home to the front; with
    /// the last design closed, the window goes back to home's size.
    func close(_ tab: DesignTab) {
        guard let index = designs.firstIndex(where: { $0 === tab }) else { return }
        if selectedID == tab.id { show(nil) }
        tab.close()
        designs.remove(at: index)
        recency.removeAll { $0 == tab.id }
        hold(tab.id, false)
        if designs.isEmpty { fitWindow() }
    }

    func closeOthers(than tab: DesignTab) {
        for other in designs where other !== tab { close(other) }
        select(tab)
    }

    /// The window's close button, and Close Window: with a design in front, every design closes,
    /// each saved, and home stays. Closing home quits Bezzle, once everything is saved.
    func closeWindow() {
        if selectedID == nil {
            closeHome()
        } else {
            for tab in designs { close(tab) }
        }
    }

    /// Home is closed: Bezzle quits, saving every design still open first.
    func closeHome() {
        NSApp.terminate(nil)
    }

    /// Bezzle is quitting: what is being typed is kept, and every design saved.
    func saveAll() {
        for tab in designs {
            tab.store?.canvas?.endEditing()
            tab.store?.save()
        }
    }

    /// Moves a tab to another place along the bar.
    func move(_ tab: DesignTab, to index: Int) {
        guard let from = designs.firstIndex(where: { $0 === tab }) else { return }
        let to = min(max(index, 0), designs.count - 1)
        guard from != to else { return }
        designs.insert(designs.remove(at: from), at: to)
    }

    private func show(_ id: DesignTab.ID?) {
        selected?.leaveFront()
        selectedID = id
        undoResponder.install(in: window)
        if let id {
            recency.removeAll { $0 == id }
            recency.insert(id, at: 0)
        }
    }

    /// With nothing in a design taking the keyboard, such as after a click away from a field,
    /// its canvas takes it, as a click on it would: the window itself would answer Undo from the
    /// history all the tabs share, and the keys for the canvas would go nowhere.
    private func keepFocus(in window: NSWindow) {
        guard window.firstResponder === window, selected?.store?.canvas?.window === window else { return }
        DispatchQueue.main.async { [weak self] in
            guard window.firstResponder === window, let canvas = self?.selected?.store?.canvas, canvas.window === window else { return }
            window.makeFirstResponder(canvas)
        }
    }

    /// The window holds still while the pointer is over a tab: the title bar lies under the tabs,
    /// and the window server would otherwise move the window for a drag that means to move a tab.
    func hold(_ id: DesignTab.ID, _ on: Bool) {
        if on { holds.insert(id) } else { holds.remove(id) }
        guard let window else { return }
        if !holds.isEmpty {
            window.isMovable = false
        } else if !overCanvasStrip(window) {
            window.isMovable = true
        }
    }

    /// Whether the pointer is in the strip under the bar where the title bar reaches down over a
    /// design's canvas, which holds the window still there itself (see `CanvasView.holdWindow`).
    private func overCanvasStrip(_ window: NSWindow) -> Bool {
        guard selected?.store != nil, let content = window.contentView else { return false }
        let pointer = content.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let below = content.convert(window.contentLayoutRect, from: nil)
        // Both measured from the top.
        let y = content.isFlipped ? pointer.y : content.bounds.height - pointer.y
        let titleBar = content.isFlipped ? below.minY : content.bounds.height - below.maxY
        return y >= Theme.barHeight && y < titleBar
    }
}

/// One design's tab: the design, once open, or why it could not be, and what stays with it while
/// another tab is in front.
@MainActor @Observable
final class DesignTab: Identifiable {
    let id = UUID()
    /// The file asked for; the design's own once it is open.
    private(set) var url: URL
    private(set) var store: DocumentStore?
    private(set) var failure: String?
    /// Whether its name is being typed anew, in its tab.
    var renaming = false
    /// Its own history, so Undo in one design never reaches into another.
    let undo = UndoManager()
    /// Its menus, drawn over the whole window, the bar along the top included.
    let menus = MenuHost()
    /// Its canvas, held while another tab is in front, so coming back shows the design at once,
    /// with its tiles already drawn.
    @ObservationIgnored private var keptCanvas: CanvasView?

    init(url: URL) {
        self.url = url
    }

    var name: String { store?.name ?? url.deletingPathExtension().lastPathComponent }

    func shows(_ url: URL) -> Bool {
        store.map { $0.isAt(url) } ?? (self.url == url)
    }

    /// Opens the file. One from Adobe XD, Figma or Sketch is brought in as a new design in the
    /// library, which the tab then shows; the file itself is left as it is.
    /// A design just brought in from elsewhere, such as a web page, comes with what was said
    /// about bringing it in.
    fileprivate func load(report given: ImportReport? = nil) {
        do {
            var design = url
            var report: ImportReport? = given
            if Importer.imports(url) {
                (design, report) = try Importer.importFile(url, into: Library.shared.folder)
                url = design
            }
            let s = try DocumentStore(opening: design)
            s.undoManager = undo
            s.importReport = report
            store = s
            MCPTools.opened(s)
            Library.shared.touched(design)
            #if DEBUG
            DebugHooks.attach(s)
            #endif
        } catch {
            failure = "\(url.lastPathComponent): \(error.localizedDescription)"
        }
    }

    fileprivate func leaveFront() {
        menus.dismiss()
        renaming = false
        if let canvas = store?.canvas { keptCanvas = canvas }
    }

    fileprivate func close() {
        menus.dismiss()
        guard let store else { return }
        store.canvas?.endEditing()
        store.save()
        DocumentStore.finishSaving()
        store.sharing?.close()
        MCPTools.closed(store)
        undo.removeAllActions()
        keptCanvas = nil
    }
}

/// Opens designs from places without a SwiftUI environment, such as files opened from the
/// Finder, and brings the window forward for them.
@MainActor
final class WindowRouter {
    static let shared = WindowRouter()
    var openWindow: OpenWindowAction?
    /// Designs asked for before the window first showed, which open once it has.
    private var waiting: [URL] = []

    /// Opens a design in its own tab and brings it to the front.
    func open(_ url: URL, report: ImportReport? = nil) {
        guard openWindow != nil else { waiting.append(url); return }
        Tabs.shared.open(url, report: report)
        bringForward()
    }

    /// The home tab, where a new design is started.
    func showHome() {
        Tabs.shared.select(nil)
        bringForward()
    }

    /// Brings an open design's tab to the front.
    func show(_ store: DocumentStore) {
        if let tab = Tabs.shared.tab(of: store) { Tabs.shared.select(tab) }
        bringForward()
    }

    /// Closes the tab in front in Bezzle's window, home included, which quits Bezzle; or else
    /// the window in front.
    func closeFront() {
        let tabs = Tabs.shared
        if let window = tabs.window, NSApp.keyWindow === window || NSApp.keyWindow == nil {
            if let tab = tabs.selected { tabs.close(tab) } else { tabs.closeHome() }
        } else {
            NSApp.keyWindow?.performClose(nil)
        }
    }

    func flush() {
        let urls = waiting
        waiting = []
        urls.forEach { open($0) }
    }

    private func bringForward() {
        if let window = Tabs.shared.window, window.isVisible || window.isMiniaturized {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow?(id: BezzleApp.windowID)
        }
    }

    /// Asks for designs to open, or for files from other apps to bring in, each in a tab of its own.
    static func openPanel(only types: [UTType]? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types ?? DesignFile.openableTypes
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
        if types != nil { panel.message = String(localized: "Each file becomes a new design in your Bezzle folder. The file itself stays as it is.") }
        if panel.runModal() == .OK { panel.urls.forEach { shared.open($0) } }
    }
}

/// Each design keeps its own history, so Undo in one tab never reaches into another. Undo asks
/// the first responder for its undo manager, which asks the next responder up, and so on to the
/// window, whose one history all the tabs would share; SwiftUI's window answers Undo from it
/// itself. So this sits in the chain just under the window and answers instead, with the history
/// of the design in front. A text view with a history of its own, such as text being typed on the
/// canvas, keeps it. With home in front it stands aside.
final class TabsUndoResponder: NSResponder {
    /// Puts itself between the window's content and the window, if it is not there already.
    func install(in window: NSWindow?) {
        guard let controller = window?.contentViewController, controller.nextResponder !== self else { return }
        nextResponder = controller.nextResponder
        controller.nextResponder = self
    }

    private var front: UndoManager? { Tabs.shared.selected?.undo }

    override var undoManager: UndoManager? { front ?? nextResponder?.undoManager }

    /// The history Undo works on: the first responder's, which is the design's unless it keeps one
    /// of its own.
    private var active: UndoManager? {
        guard let front else { return nil }
        guard let responder = Tabs.shared.window?.firstResponder, !(responder is NSWindow) else { return front }
        return responder.undoManager ?? front
    }

    nonisolated override func responds(to selector: Selector!) -> Bool {
        if selector == #selector(undo(_:)) || selector == #selector(redo(_:)) {
            return Thread.isMainThread && MainActor.assumeIsolated { Tabs.shared.selectedID != nil }
        }
        return super.responds(to: selector)
    }

    @objc func undo(_ sender: Any?) {
        if let active, active.canUndo { active.undo() }
    }

    @objc func redo(_ sender: Any?) {
        if let active, active.canRedo { active.redo() }
    }
}

extension TabsUndoResponder: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let active else { return false }
        switch item.action {
        case #selector(undo(_:)):
            item.title = active.undoMenuItemTitle
            return active.canUndo
        case #selector(redo(_:)):
            item.title = active.redoMenuItemTitle
            return active.canRedo
        default:
            return false
        }
    }
}

/// The window's close button closes the designs in it, as Close Window does, and only quits
/// Bezzle from home; the window itself would otherwise close and leave Bezzle running without it.
final class CloseButton: NSObject {
    func hook(_ window: NSWindow) {
        guard let button = window.standardWindowButton(.closeButton) else { return }
        button.target = self
        button.action = #selector(press(_:))
    }

    @objc func press(_ sender: Any?) {
        Tabs.shared.closeWindow()
    }
}

/// Tells the tabs which window they are in.
struct TabsWindowReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { Tabs.shared.window = window }
        }
    }
}
