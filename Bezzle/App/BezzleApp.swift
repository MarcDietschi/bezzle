import SwiftUI
import AppKit
import UniformTypeIdentifiers

@main
struct BezzleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // One window: home and every open design in tabs along its top.
        Window(Text(verbatim: "Bezzle"), id: BezzleApp.windowID) {
            MainWindow()
                .background(TallTitleBar())
                .onAppear {
                    #if DEBUG
                    DebugHooks.runOnce()
                    #endif
                }
        }
        // Test runs host the app without showing it, so they cannot take the keyboard.
        .defaultLaunchBehavior(BezzleApp.isTesting ? .suppressed : .presented)
        .windowStyle(.hiddenTitleBar)
        .defaultWindowPlacement { _, context in
            WindowPlacement(.center, size: Tabs.homeSize(in: context.defaultDisplay.visibleRect.size))
        }
        .restorationBehavior(.disabled)
        // Home alone keeps the window at one size; designs let it take any (see `Tabs.homeAlone`).
        .windowResizability(.contentSize)
        .commands {
            BezzleCommands()
            MCPCommands()
            UpdateCommands()
        }
    }
}

extension BezzleApp {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    static let windowID = "main"
}

/// Files opened from the Finder or dropped on the Dock icon open in tabs of their own.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Library.moveInFromVellum()
        FileAccess.reopen()
        if BezzleApp.isTesting { NSApp.setActivationPolicy(.prohibited) }
        // Bezzle keeps its designs in tabs of its own; the system's window tabs would only
        // add menu items for a second kind.
        NSWindow.allowsAutomaticWindowTabbing = false
        #if DEBUG
        // AppKit otherwise swallows an exception on the main thread and carries on, half done.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        #endif
        ClickAway.watch()
        PlainTyping.watch()
        HandOver.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Not in a copy that is about to hand over to one already running, which has these.
        HandOver.whenRunningAlone {
            MCPServer.shared.launch()
            Welcome.makeOnFirstLaunch()
            Updates.start()
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        // A design renamed or moved in the Finder meanwhile goes on where it is now.
        for store in Tabs.shared.designs.compactMap(\.store) { store.follow() }
        Sharing.shared.lookNow()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // A shared design's link, passed on by Bezzle's page on the web.
        for link in urls where Sharing.secret(from: link) != nil {
            Sharing.log.notice("A shared design's link came")
            if !HandOver.pass(invitation: link) { Sharing.shared.accept(link: link) }
        }
        let designs = urls.filter { BezzleDocument.fileExtensions.contains($0.pathExtension.lowercased()) || Importer.imports($0) }
        if HandOver.pass(designs: designs) { return }
        designs.forEach { WindowRouter.shared.open($0) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Bezzle only goes once every open design is on disk. One that could not be written keeps it
    /// open, unless told to go all the same.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Tabs.shared.saveAll()
        let unsaved = DocumentStore.unsaved(among: Tabs.shared.designs.compactMap { $0.store?.url })
        if !unsaved.isEmpty, !BezzleApp.isTesting {
            let alert = NSAlert()
            alert.alertStyle = .critical
            if unsaved.count == 1, let design = unsaved.first {
                alert.messageText = String(localized: "“\(design.url.deletingPathExtension().lastPathComponent)” could not be saved.")
                alert.informativeText = design.reason
            } else {
                alert.messageText = String(localized: "\(unsaved.count) designs could not be saved.")
                alert.informativeText = unsaved.map { "\($0.url.deletingPathExtension().lastPathComponent): \($0.reason)" }.joined(separator: "\n")
            }
            alert.addButton(withTitle: String(localized: "Keep Bezzle Open"))
            alert.addButton(withTitle: String(localized: "Quit Anyway"))
            alert.buttons[1].hasDestructiveAction = true
            NSApp.activate()
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        AppDelegate.terminating = true
        return .terminateNow
    }
}

/// The menu bar: File, Edit, Object and View, all working on the design in front.
struct BezzleCommands: Commands {
    @FocusedValue(\.store) private var store
    /// Whether misspelt words are underlined while typing into text, and grammar checked with them.
    @AppStorage("BezzleChecksSpelling") private var checksSpelling = true
    @AppStorage("BezzleChecksGrammar") private var checksGrammar = false

    var body: some Commands {
        // In the Bezzle menu, where settings go.
        CommandGroup(replacing: .appSettings) {
            Button("Designs Folder…") { Library.shared.chooseFolder() }
        }
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .newItem) {
            Button("New…") { WindowRouter.shared.showHome() }
                .keyboardShortcut("n")
            Button("Open…") { WindowRouter.openPanel() }
                .keyboardShortcut("o")
            Button("Import from XD, Figma, Sketch or Photoshop…") { WindowRouter.openPanel(only: DesignFile.importableTypes) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Button("Import from a Website…") { WebImporting.shared.present() }
                .keyboardShortcut("i", modifiers: [.command, .shift, .option])
        }
        CommandGroup(replacing: .saveItem) {
            Button(store != nil ? "Close Tab" : "Close") { WindowRouter.shared.closeFront() }
                .keyboardShortcut("w")
            Button("Close Window") {
                if let window = Tabs.shared.window, NSApp.keyWindow === window || NSApp.keyWindow == nil {
                    Tabs.shared.closeWindow()
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
                .keyboardShortcut("w", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Save a Copy") { store?.saveCopy() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(store == nil)
            Button("Export…") { store?.exporting = true }
                .keyboardShortcut("e")
                .disabled(store == nil)
            Button("Versions") {
                guard let versions = store?.versions else { return }
                if versions.browsing { versions.leave() } else { versions.browse() }
            }
                .keyboardShortcut("t", modifiers: [.command, .option])
                .disabled(store == nil)
            Divider()
            Button("Show in Finder") { if let url = store?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                .disabled(store == nil)
        }
        CommandGroup(after: .pasteboard) {
            // In Animate, the keys picked in the timeline while there are any.
            Button("Duplicate") { store?.duplicate() }
                .keyboardShortcut("d")
                .disabled(store?.canDuplicate != true)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                Button("Find…") { store?.openFind() }
                    .keyboardShortcut("f")
                Button("Find Next") { store?.findNext() }
                    .disabled(store?.finder == nil)
                Button("Find Previous") { store?.findNext(forward: false) }
                    .disabled(store?.finder == nil)
            }
            .disabled(store == nil)
            Menu("Spelling and Grammar") {
                Button("Check Spelling…") { store?.openFind(spelling: true) }
                    .keyboardShortcut(";")
                    .disabled(store == nil)
                Divider()
                Toggle("Check Spelling While Typing", isOn: $checksSpelling)
                Toggle("Check Grammar With Spelling", isOn: $checksGrammar)
            }
        }
        CommandMenu("Format") {
            Group {
                Button("Bold") { store?.toggleBold() }
                    .keyboardShortcut("b")
                Button("Italic") { store?.toggleItalic() }
                    .keyboardShortcut("i")
                Button("Underline") { store?.toggleUnderline() }
                    .keyboardShortcut("u")
                Button("Strikethrough") { store?.toggleStrikethrough() }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("Bigger") { store?.growLetters(by: 1) }
                    .keyboardShortcut(".", modifiers: [.command, .shift])
                Button("Smaller") { store?.growLetters(by: -1) }
                    .keyboardShortcut(",", modifiers: [.command, .shift])
                Divider()
                Button("Bulleted List") { store?.toggleList(.bullet) }
                    .keyboardShortcut("8", modifiers: [.command, .shift])
                Button("Numbered List") { store?.toggleList(.number) }
                    .keyboardShortcut("7", modifiers: [.command, .shift])
            }
            .disabled(store?.canStyleText != true)
        }
        CommandMenu("Object") {
            Button { store?.group() } label: { Text(DocumentStore.grouping) }
                .keyboardShortcut("g")
                .disabled(store?.canGroup != true)
            Button("Ungroup") { store?.ungroup() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(store?.canUngroup != true)
            Button { store?.maskSelection() } label: { Text(DocumentStore.masking) }
                .keyboardShortcut("m", modifiers: [.command, .control])
                .disabled(store?.canMask != true)
            Button { if let store, let mask = store.selectedMask { store.releaseMask(mask.id) } } label: { Text(DocumentStore.unmasking) }
                .keyboardShortcut("m", modifiers: [.command, .control, .shift])
                .disabled(store?.canReleaseMask != true)
            Button { store?.rideSelection() } label: { Text(DocumentStore.riding) }
                .disabled(store?.ridePair == nil)
            Button { store?.straightenSelection() } label: { Text(DocumentStore.straightening) }
                .disabled(store?.canStraighten != true)
            Divider()
            Button("Bring to Front") { store?.arrange(.front) }.keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Bring Forward") { store?.arrange(.forward) }.keyboardShortcut("]")
            Button("Send Backward") { store?.arrange(.backward) }.keyboardShortcut("[")
            Button("Send to Back") { store?.arrange(.back) }.keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            Menu("Align") {
                Button("Left") { store?.align(.left) }
                Button("Centre") { store?.align(.centerX) }
                Button("Right") { store?.align(.right) }
                Divider()
                Button("Top") { store?.align(.top) }
                Button("Middle") { store?.align(.centerY) }
                Button("Bottom") { store?.align(.bottom) }
            }
            Menu("Distribute") {
                Button("Across") { store?.distribute(horizontally: true) }
                Button("Down") { store?.distribute(horizontally: false) }
            }
            Button("Flip Horizontally") { store?.flip(horizontally: true) }
                .disabled(store?.canFlip != true)
            Button("Flip Vertically") { store?.flip(horizontally: false) }
                .disabled(store?.canFlip != true)
            Divider()
            Button(store?.selectedNodes.allSatisfy(\.locked) == true && store?.selection.isEmpty == false ? "Unlock" : "Lock") {
                guard let store else { return }
                store.setLocked(!store.selectedNodes.allSatisfy(\.locked), store.selection)
            }
            .keyboardShortcut("l")
            Button("Hide") { if let store { store.setHidden(true, store.selection) } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
            Button("Show All") {
                guard let store else { return }
                store.update(store.doc.allNodes.filter(\.hidden).map(\.id), "Show All") { $0.hidden = false }
            }
            Divider()
            Button("Make Repeat Grid") { store?.makeRepeatGrid() }
                .keyboardShortcut("r")
                .disabled(store?.canMakeRepeatGrid != true)
            Button("Ungroup Grid") { if let store, let grid = store.selectedGrid { store.ungroupGrid(grid.id) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(store?.selectedGrid == nil)
            Divider()
            Button("Make Component") { store?.makeComponent() }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(store?.canMakeComponent != true)
            Button("New Variant") { if let store, let copy = store.selectedCopy { store.addVariant(from: copy.id) } }
                .disabled(store?.selectedCopy == nil || store?.isReadOnly == true)
            Button("Look Like the Others") { if let store, let copy = store.selectedCopy { store.resetCopy(copy.id) } }
                .disabled(store?.selectedCopy.map { store?.hasOwnLooks($0) == true } != true)
            Button("Unlink Copy") { store?.unlinkComponent() }
                .disabled(store?.canUnlink != true)
            Divider()
            Button("Add Post") {
                if let store, let board = store.postableBoard { store.addPost(to: board.id) }
            }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(store?.postableBoard == nil)
            Button("Previous Post") { store?.turnPage(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                .disabled(store?.turnableDeck == nil)
            Button("Next Post") { store?.turnPage(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                .disabled(store?.turnableDeck == nil)
            Button("Show All Posts") { if let store, let deck = store.turnableDeck { store.canvas?.deckTool.openSpread(deck) } }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(store?.turnableDeck == nil)
            Button("Remove Post") {
                if let store, let deck = store.turnableDeck, let front = store.front(of: deck) { store.removePost(front, from: deck.id) }
            }
            .disabled((store?.turnableDeck?.posts.count ?? 0) < 2)
            Divider()
            Button("Convert to Path") { store?.convertToPath() }
                .keyboardShortcut("8")
                .disabled(store?.canConvertToPath != true)
            Divider()
            Button("Union") { store?.combine(.union) }
                .keyboardShortcut("u", modifiers: [.command, .option])
                .disabled(store?.canCombine != true)
            Button("Subtract") { store?.combine(.subtract) }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(store?.canCombine != true)
            Button("Intersect") { store?.combine(.intersect) }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .disabled(store?.canCombine != true)
            Button("Exclude Overlap") { store?.combine(.exclude) }
                .keyboardShortcut("x", modifiers: [.command, .option])
                .disabled(store?.canCombine != true)
            Button(store?.building != nil ? "Done Building" : "Build with Pieces") {
                guard let store else { return }
                if store.building != nil { store.building = nil } else { store.startBuilding() }
            }
            .keyboardShortcut("b", modifiers: [.command, .option])
            .disabled(store?.canCombine != true)
            Divider()
            Button("Remove Background") { store?.removeBackground() }
                .disabled(store?.canRemoveBackground != true)
            Button("Restore Background") { store?.restoreBackground() }
                .disabled(store?.canRestoreBackground != true)
            Button(DocumentStore.vectorizing) { store?.vectorize() }
                .disabled(store?.canVectorize != true)
            Divider()
            Button("Outline Border") { store?.outlineBorders() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(store?.canOutlineBorders != true)
        }
        CommandGroup(after: .windowArrangement) {
            Divider()
            Button("Show Previous Tab") { Tabs.shared.step(by: -1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            Button("Show Next Tab") { Tabs.shared.step(by: 1) }
                .keyboardShortcut(.tab, modifiers: .control)
        }
        CommandGroup(replacing: .help) {
            Button("Welcome to Bezzle") { Welcome.open() }
        }
        CommandGroup(before: .windowSize) {
            Button("Zoom In") { store?.zoomStep(in: true) }.keyboardShortcut("=")
            Button("Zoom Out") { store?.zoomStep(in: false) }.keyboardShortcut("-")
            Button("Zoom to Fit") { store?.zoomToFit() }.keyboardShortcut("0")
            Button("Actual Size") { store?.zoom(to: 1) }.keyboardShortcut("1")
            Button("Zoom to Selection") { store?.zoomToSelection() }.keyboardShortcut("2")
            Divider()
            Button(store?.showsLayers == false ? "Show Layers" : "Hide Layers") { store?.showsLayers.toggle() }
                .keyboardShortcut("y")
            Button(store?.showsResources == true ? "Hide Resources" : "Show Resources") { store?.toggleResources() }
                .keyboardShortcut("y", modifiers: [.command, .shift])
            Divider()
            Toggle("Rulers", isOn: Binding(get: { Helpers.shared.rulers }, set: { Helpers.shared.rulers = $0 }))
                .keyboardShortcut("r", modifiers: .control)
            // The comma has a key of its own on nearly every keyboard, where ";" often takes Shift
            // (on a Swiss or German one it is ⇧,). Kept on that key: left to itself, macOS may
            // move a shortcut elsewhere, and the ⌃, the menus and the tour name would do nothing.
            Toggle("Guides", isOn: Binding(get: { Helpers.shared.guides }, set: { Helpers.shared.guides = $0 }))
                .keyboardShortcut(",", modifiers: .control, localization: .custom)
            Toggle("Layout Grids", isOn: Binding(get: { Helpers.shared.grids }, set: { Helpers.shared.grids = $0 }))
                .keyboardShortcut("g", modifiers: .control)
            Toggle("Lock Guides", isOn: Binding(get: { Helpers.shared.guidesLocked }, set: { Helpers.shared.guidesLocked = $0 }))
            Divider()
            Toggle(LocalizedStringResource("mode.prototype", defaultValue: "Prototype"), isOn: Binding(get: { store?.prototyping == true }, set: { store?.prototyping = $0 }))
                .keyboardShortcut("p", modifiers: .control)
                .disabled(store == nil)
            Toggle(LocalizedStringResource("mode.inspect", defaultValue: "Inspect"), isOn: Binding(get: { store?.inspecting == true }, set: { on in store?.show(on ? .inspect : .prototype) }))
                .keyboardShortcut("i", modifiers: .control)
                .disabled(store == nil)
            Toggle(LocalizedStringResource("mode.animate", defaultValue: "Animate"), isOn: Binding(get: { store?.animating == true }, set: { on in store?.show(on ? .animate : .design) }))
                .keyboardShortcut("a", modifiers: .control)
                .disabled(store == nil)
            if store?.animating == true {
                Button("Play Film") { store?.playFilm(fromStart: true) }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store?.filmBoard == nil)
            } else {
                Button("Play Prototype") { store?.play() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(store == nil || store?.doc.artboards.isEmpty == true || store?.player != nil)
            }
            Divider()
        }
    }
}

/// Gives the window an empty toolbar, which makes the title bar 52 points tall and centres the
/// traffic lights in it, level with the top bar's own text.
struct TallTitleBar: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, window.toolbar == nil else { return }
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unified
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        }
    }
}

/// Behind a window's bar along the top: a double click there does what a double click on a title
/// bar does, as set in System Settings. The bar lies over the hidden title bar, and SwiftUI's
/// window takes every click there for itself, so the title bar never hears of it; handing it on
/// only comes back here. Dragging the window by the bar needs nothing: the window server does that.
struct TitleBarDoubleClick: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Catcher() }
    func updateNSView(_ view: NSView, context: Context) {}

    final class Catcher: NSView {
        override func mouseDown(with event: NSEvent) {
            guard event.clickCount == 2, let window else {
                super.mouseDown(with: event)
                return
            }
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            // Home alone keeps its one size.
            case _ where !window.styleMask.contains(.resizable): break
            // Zoom, and Fill, which AppKit offers no way to ask for, and the system's own choice
            // while none is made: the window takes the screen, and a second double click gives
            // it back its size.
            default: window.performZoom(nil)
            }
        }
    }
}
