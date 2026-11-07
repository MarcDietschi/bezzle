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

/// Bezzle on Windows: one window, home or a design in it, as the Mac's tabs show one or the other.
final class BezzleApp: SwiftApplication {
    var window: Window?
    var home: HomeView?
    var design: DesignWindow?

    /// Where designs are kept, as the Mac's standard Designs folder: Documents › Bezzle.
    static var designsFolder: URL {
        (FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser)
            .appendingPathComponent("Bezzle", isDirectory: true)
    }

    required init() {
        super.init()
    }

    override func onLaunched(_ args: WinUI.LaunchActivatedEventArgs) {
        Trace.time("launched")
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
        window.closed.addHandler { [weak self] _, _ in MainActor.assumeIsolated { self?.design?.session.save() } }
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
        }
        try? window.activate()
        Trace.time("window activated")
    }

    @MainActor func showHome() {
        guard let window else { return }
        Theme.readAppearance()
        design?.session.save()
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
