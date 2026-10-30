import SwiftUI
import AppKit
import CloudKit
import UniformTypeIdentifiers

@main
struct BezzleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Bezzle", id: "home") {
            HomeView()
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
        .defaultSize(width: 1100, height: 760)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .commands {
            BezzleCommands()
            MCPCommands()
        }

        WindowGroup("Design", id: "design", for: URL.self) { $url in
            if let current = url {
                DesignWindow(url: current) { url = $0 }
                    .background(TallTitleBar())
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
    }
}

extension BezzleApp {
    static let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

/// One design in its own window. It opens the file, and gives the window back its new name when
/// the design is renamed.
struct DesignWindow: View {
    let url: URL
    let renamed: (URL) -> Void
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.undoManager) private var undoManager
    @State private var store: DocumentStore?
    @State private var failure: String?

    var body: some View {
        Group {
            if let store {
                Workspace(store: store)
                    .onChange(of: store.url) { _, new in renamed(new) }
                    .navigationTitle(store.name)
            } else if let failure {
                VStack(spacing: 10) {
                    Text(url.pathExtension.lowercased() == XDImporter.fileExtension ? "This XD file could not be brought in." : "This design could not be opened.")
                        .font(Theme.serif(22, weight: .medium))
                        .foregroundStyle(Theme.ink)
                    Text(failure)
                        .font(.system(size: 12.5))
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
        .frame(minWidth: 1000, minHeight: 640)
        .onAppear {
            WindowRouter.shared.openWindow = openWindow
            WindowRouter.shared.dismissWindow = dismissWindow
            WindowRouter.shared.openDesigns += 1
            load()
        }
        .onDisappear {
            store?.canvas?.endEditing()
            store?.save()
            DocumentStore.finishSaving()
            store?.sharing?.close()
            if let store { MCPTools.closed(store) }
            WindowRouter.shared.openDesigns -= 1
            // With the last design closed, the home screen comes back.
            if WindowRouter.shared.openDesigns == 0 && !AppDelegate.terminating { openWindow(id: "home") }
        }
    }

    private func load() {
        guard store == nil else { return }
        do {
            var design = url
            var report: XDReport?
            // An Adobe XD file is brought in as a new design in the library, which this window
            // then shows; the XD file itself is left as it is.
            if url.pathExtension.lowercased() == XDImporter.fileExtension {
                (design, report) = try XDImporter.importFile(url, into: Library.shared.folder)
                renamed(design)
            }
            let s = try DocumentStore(opening: design)
            s.undoManager = undoManager
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
}

/// Files opened from the Finder or dropped on the Dock icon open in their own windows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    static var terminating = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        Library.moveInFromVellum()
        if BezzleApp.isTesting { NSApp.setActivationPolicy(.prohibited) }
        #if DEBUG
        // AppKit otherwise swallows an exception on the main thread and carries on, half done.
        UserDefaults.standard.register(defaults: ["NSApplicationCrashOnExceptions": true])
        #endif
        ClickAway.watch()
        PlainTyping.watch()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MCPServer.shared.launch()
        CloudSync.shared.start()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        CloudSync.shared.fetchNow()
    }

    /// An invitation to a shared design was clicked.
    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        CloudSync.shared.accept(metadata)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where (BezzleDocument.fileExtensions + [XDImporter.fileExtension]).contains(url.pathExtension.lowercased()) {
            WindowRouter.shared.open(url)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        AppDelegate.terminating = true
        DocumentStore.finishSaving()
        return .terminateNow
    }
}

/// The menu bar: File, Edit, Object and View, all working on the design in front.
struct BezzleCommands: Commands {
    @FocusedValue(\.store) private var store
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .toolbar) {}
        CommandGroup(replacing: .newItem) {
            Button("New…") { openWindow(id: "home") }
                .keyboardShortcut("n")
            Button("Open…") { open() }
                .keyboardShortcut("o")
            Button("Import from Adobe XD…") { open(only: UTType(filenameExtension: XDImporter.fileExtension)) }
                .keyboardShortcut("i", modifiers: [.command, .shift])
        }
        CommandGroup(after: .saveItem) {
            Button("Export…") { store?.exporting = true }
                .keyboardShortcut("e")
                .disabled(store == nil)
            Divider()
            Button("Show in Finder") { if let url = store?.url { NSWorkspace.shared.activateFileViewerSelecting([url]) } }
                .disabled(store == nil)
        }
        CommandGroup(after: .pasteboard) {
            Button("Duplicate") { store?.duplicateSelection() }
                .keyboardShortcut("d")
                .disabled(store?.selection.isEmpty ?? true)
        }
        CommandMenu("Object") {
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
            Button("Outline Border") { store?.outlineBorders() }
                .keyboardShortcut("o", modifiers: [.command, .option])
                .disabled(store?.canOutlineBorders != true)
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
            Divider()
        }
    }

    private func open(only type: UTType? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = type.map { [$0] } ?? DesignFile.openableTypes
        panel.allowsMultipleSelection = true
        if type != nil { panel.message = "Each XD file becomes a new design in your Bezzle folder. The XD file stays as it is." }
        if panel.runModal() == .OK { panel.urls.forEach { openWindow(id: "design", value: $0.standardizedFileURL) } }
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
