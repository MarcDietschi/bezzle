import Foundation
import WinSDK
import CWinAppSDK
import WinUI
import WinAppSDK
import WindowsFoundation
import BezzleCore
import UWP

/// Starts Bezzle: the Windows App Runtime, then WinUI with Bezzle's application.
///
/// Not SwiftApplication's own `main`, which finds the application class by name (that fails for a
/// class in an executable), nor WindowsAppRuntimeInitializer, which looks for the runtime's
/// bootstrapper in a resource folder Foundation no longer finds: the bootstrapper sits beside
/// Bezzle.exe (build.ps1 puts it there), as in an installed copy.
@main
enum Main {
    static func main() {
        Trace.time("main")
        do {
            try startRuntime()
            Trace.time("Windows App Runtime started")
            var application: BezzleApp?
            let exitCode = try Application.startWithCustomRunLoop(BezzleApp.runLoop) { _ in
                application = BezzleApp()
            }
            application?.onShutdown(exitCode: exitCode)
        } catch {
            fatalError("Bezzle could not start WinUI: \(error)")
        }
    }

    private typealias Initialize = @convention(c) (UInt32, PCWSTR?, PACKAGE_VERSION, MddBootstrapInitializeOptions) -> HRESULT

    /// The Windows App Runtime that the bindings were made for (an unpackaged app finds it through
    /// the bootstrapper), on a single-threaded Windows Runtime apartment.
    private static func startRuntime() throws {
        let initialized = RoInitialize(RO_INIT_SINGLETHREADED)
        guard initialized >= 0 else { throw RuntimeError(step: "RoInitialize", result: initialized) }
        // OLE as well, as an app's own main would start it (C#'s [STAThread] does): without it,
        // nothing dragged in from Explorer reaches the window.
        _ = OleInitialize(nil)
        let folder = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let path = folder.appendingPathComponent("Microsoft.WindowsAppRuntime.Bootstrap.dll").path
        guard let dll = path.withCString(encodedAs: UTF16.self, LoadLibraryW),
              let function = GetProcAddress(dll, "MddBootstrapInitialize2") else {
            throw RuntimeError(step: "loading \(path)", result: HRESULT(bitPattern: GetLastError()))
        }
        let result = unsafeBitCast(function, to: Initialize.self)(
            UInt32(WINDOWSAPPSDK_RELEASE_MAJORMINOR), WINDOWSAPPSDK_RELEASE_VERSION_TAG_SWIFT, PACKAGE_VERSION(),
            MddBootstrapInitializeOptions(MddBootstrapInitializeOptions_OnNoMatch_ShowUI.rawValue))
        guard result >= 0 else { throw RuntimeError(step: "MddBootstrapInitialize2", result: result) }
    }

    struct RuntimeError: Swift.Error, CustomStringConvertible {
        let step: String
        let result: HRESULT
        var description: String { "\(step) failed: 0x" + String(UInt32(bitPattern: result), radix: 16) }
    }
}

/// Whether AI assistants may work in the app (the AI server); on unless turned off in the
/// Bezzle menu, as on the Mac, under the Mac's own key.
@MainActor enum AIControl {
    static var allowed: Bool {
        get { UserDefaults.standard.object(forKey: "aiControl") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "aiControl")
            if newValue { MCPServer.shared.start() } else { MCPServer.shared.stop() }
        }
    }
}

/// Bezzle on Windows: one window, home or a design in it, as the Mac's tabs show one or the other.
final class BezzleApp: SwiftApplication {
    var window: Window?
    var home: HomeView?
    var design: DesignWindow?

    /// Where designs are kept: the folder chosen in the Bezzle menu (Designs Folder…), or, as the
    /// Mac's standard one, Documents › Bezzle.
    static var designsFolder: URL {
        if let chosen = UserDefaults.standard.string(forKey: "designsFolderPath"), FileManager.default.fileExists(atPath: chosen) {
            return URL(fileURLWithPath: chosen, isDirectory: true)
        }
        return (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Bezzle", isDirectory: true)
    }

    /// Another folder chosen to keep designs in, as the Mac's Designs Folder…; home shows it.
    @MainActor func chooseDesignsFolder() {
        guard let folder = FileDialogs.chooseFolder(title: Words.t("Designs Folder…"), button: Words.t("Choose"), startingIn: Self.designsFolder) else { return }
        UserDefaults.standard.set(folder.path, forKey: "designsFolderPath")
        if design == nil { showHome() }
    }

    required init() {
        super.init()
    }

    override func onLaunched(_ args: WinUI.LaunchActivatedEventArgs) {
        Trace.time("launched")
        // The core's own words (what a drag measures) in the user's language too.
        WindowsCore.say = { key, args in Words.t(key, arguments: args) }
        // The shared code's own words too, such as the names new layers are given.
        Localization.lookup = { key, args in Words.lookup(key, args) }
        // What Foundation does on the Mac that the host does here (the icon library's unpacking).
        MainActor.assumeIsolated { WindowsCore.start() }
        MainActor.assumeIsolated { Theme.readAppearance() }
        let window = Window()
        window.title = "Bezzle"
        self.window = window
        // Bezzle draws its own bar, as on the Mac; Windows keeps its caption buttons at its right.
        window.extendsContentIntoTitleBar = true
        if let appWindow = window.appWindow {
            // As the Mac sizes its window: never larger than the screen less 48, centred.
            let screen = (w: Int32(GetSystemMetrics(SM_CXSCREEN)), h: Int32(GetSystemMetrics(SM_CYSCREEN)))
            let size = SizeInt32(width: min(1440, screen.w - 48), height: min(900, screen.h - 48))
            try? appWindow.resize(size)
            try? appWindow.move(PointInt32(x: (screen.w - size.width) / 2, y: max(0, (screen.h - size.height) / 2 - 12)))
            if let bar = appWindow.titleBar {
                bar.preferredHeightOption = .tall
                bar.buttonBackgroundColor = UWP.Color(a: 0, r: 0, g: 0, b: 0)
                bar.buttonInactiveBackgroundColor = UWP.Color(a: 0, r: 0, g: 0, b: 0)
                MainActor.assumeIsolated {
                    bar.buttonForegroundColor = Theme.color(Theme.ink)
                    bar.buttonInactiveForegroundColor = Theme.color(Theme.ink, 0.44)
                    bar.buttonHoverBackgroundColor = Theme.color(Theme.ink, 0.06)
                }
            }
        }
        window.closed.addHandler { [weak self] _, _ in
            MainActor.assumeIsolated {
                guard let self, let design = self.design else { return }
                design.session.save()
                WindowsCore.versions.saved(closing: true)
            }
        }
        // WinUI calls this on the main thread, where the core lives.
        MainActor.assumeIsolated {
            let fonts = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fonts")
            do {
                try WindowsCore.loadFonts(from: fonts)
                Trace.time("fonts loaded")
            } catch {
                window.content = message("Bezzle could not read its fonts", detail: "\(error)")
                return
            }
            if CommandLine.arguments.count > 1 { openDesign(URL(fileURLWithPath: CommandLine.arguments[1])) } else { showHome() }
            Trace.time("first view made")
            startAIServer()
        }
        try? window.activate()
        Trace.time("window activated")
    }

    /// The AI server (Model Context Protocol) at 127.0.0.1:7412, as on the Mac: what it asks of
    /// the window, and it started. BEZZLE_NO_MCP leaves it off, for a copy beside the one in use.
    @MainActor private func startAIServer() {
        guard ProcessInfo.processInfo.environment["BEZZLE_NO_MCP"] == nil else { return }
        let host = MCPHost.shared
        host.designsFolder = { Self.designsFolder }
        host.open = { [weak self] url in
            self?.openDesign(url)
            return self?.design != nil
        }
        host.close = { [weak self] in self?.showHome() }
        host.selection = { [weak self] in self?.design?.session.selection ?? [] }
        host.select = { [weak self] ids in
            guard let session = self?.design?.session else { return }
            session.select(ids, on: ids.first.flatMap(WindowsCore.board(of:)) ?? session.board)
        }
        host.edited = { [weak self] in self?.design?.session.edited(board: nil) }
        host.visible = { [weak self] in self?.design?.canvas.visibleRect ?? .zero }
        host.zoom = { [weak self] in self?.design?.session.zoom ?? 1 }
        host.zoomToFit = { [weak self] in self?.design?.canvas.fit() }
        host.show = { [weak self] r in self?.design?.canvas.show(r) }
        host.setZoom = { [weak self] z in self?.design?.canvas.zoom(to: z) }
        host.focusedBoard = { [weak self] in self?.design?.session.board }
        host.endEditing = { [weak self] in self?.design?.canvas.finishTyping() }
        Bar.chooseDesignsFolder = { [weak self] in self?.chooseDesignsFolder() }
        MCPServer.shared.failed = { why in Trace.say("AI server: \(why)") }
        if AIControl.allowed { MCPServer.shared.start() }
        Trace.time("AI server at \(MCPServer.shared.address)")
    }

    @MainActor func showHome() {
        guard let window else { return }
        Theme.readAppearance()
        design?.session.save()
        // Closed after a change, it is kept as a version at once.
        if design != nil { WindowsCore.versions.saved(closing: true) }
        design = nil
        WindowsCore.close()
        let home = HomeView(folder: Self.designsFolder) { [weak self] url in self?.openDesign(url) }
        home.root.requestedTheme = Theme.dark ? .dark : .light
        home.root.loaded.addHandler { _, _ in Trace.time("home on screen") }
        window.content = home.root
        try? window.setTitleBar(home.dragArea)
        window.title = "Bezzle"
        self.home = home
    }

    @MainActor func openDesign(_ url: URL) {
        guard let window else { return }
        Theme.readAppearance()
        design?.session.save()
        do {
            _ = try WindowsCore.open(url)
        } catch {
            window.content = message("Bezzle could not open the design", detail: "\(error)")
            return
        }
        let name = url.deletingPathExtension().lastPathComponent
        let view = DesignWindow(name: name) { [weak self] in self?.showHome() }
        view.session.onOpen = { [weak self] in
            if let url = FileDialogs.chooseDesign(startingIn: Self.designsFolder) { self?.openDesign(url) }
        }
        view.session.onHome = { [weak self] in self?.showHome() }
        view.session.onSaveCopy = { [weak self, weak view] in
            guard let self, let view else { return }
            view.session.save()
            guard let copy = try? WindowsCore.saveCopy(named: Words.t("%@ copy", name), in: Self.designsFolder) else { MessageBeep(0); return }
            self.openDesign(copy)
        }
        view.root.requestedTheme = Theme.dark ? .dark : .light
        window.content = view.root
        try? window.setTitleBar(view.bar.dragArea)
        window.title = name + " — Bezzle"
        design = view
        home = nil
    }

    @MainActor private func message(_ title: String, detail: String) -> UIElement {
        let stack = StackPanel()
        stack.spacing = 8
        stack.horizontalAlignment = .center
        stack.verticalAlignment = .center
        stack.children.append(Theme.text(title, size: 28, serif: true))
        let body = Theme.text(detail, size: 13, ink: 3)
        body.textWrapping = .wrap
        body.maxWidth = 640
        stack.children.append(body)
        return stack
    }
}
