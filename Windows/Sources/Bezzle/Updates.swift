import Foundation
import WinSDK
import BezzleCore

/// Updates for the copy of Bezzle installed from bezzle.ch, as the Mac's (Bezzle/App/Updates.swift)
/// are with Sparkle: WinSparkle (MIT), which reads the same kind of feed and checks the same EdDSA
/// signature, by the key the Mac's updates are signed with.
///
/// Only an installed copy has it: Installer/make-installer.ps1 puts WinSparkle.dll beside
/// Bezzle.exe and the feed and the public key into Bezzle.exe's resources (FeedURL APPCAST,
/// EdDSAPub EDDSA, where WinSparkle reads them). So builds from build.ps1 and test copies made
/// without them never look for updates. It is loaded when Bezzle starts rather than linked.
///
/// As on the Mac, every launch looks for a new version in the background, and WinSparkle once a
/// day after that. A new version shows WinSparkle's window with its notes, to install now or later;
/// installing runs the new installer quietly (its arguments come with the feed) while Bezzle saves
/// everything and quits, and the installer opens Bezzle again.
@MainActor
enum Updates {
    /// Whether this copy updates itself: WinSparkle beside it, and a feed to read.
    static var isAvailable: Bool { sparkle != nil }

    /// The version people see and the build number updates are compared by, from Bezzle.exe's
    /// version resource (the installer writes them there); nil for a copy built here.
    static let version: (short: String, build: String)? = {
        guard let short = versionString("ProductVersion"), let build = versionString("Build") else { return nil }
        return (short, build)
    }()

    /// Starts the updater, once, once Bezzle is on screen.
    static func start() {
        guard !started, let s = sparkle, let version else { return }
        started = true
        "Bezzle".withCString(encodedAs: UTF16.self) { company in
            version.short.withCString(encodedAs: UTF16.self) { s.setAppDetails(company, company, $0) }
        }
        version.build.withCString(encodedAs: UTF16.self) { s.setBuildVersion($0) }
        // Its own words in Bezzle's language (it has German, French and Italian of its own).
        Words.language.withCString { s.setLanguage($0) }
        // Where it keeps when it last looked and a version skipped; the uninstaller takes it away.
        "Software\\Bezzle\\Updates".withCString { s.setRegistryPath($0) }
        // Looking without asking first, as the Mac's release sets SUEnableAutomaticChecks; once a
        // day, as Sparkle does.
        s.setAutomatic(1)
        s.setInterval(24 * 60 * 60)
        // Bezzle may always quit for an update: it saves every design first, as when it quits.
        s.setCanShutdown { 1 }
        s.setShutdownRequest {
            DispatchQueue.main.async { MainActor.assumeIsolated { Tabs.shared.quit() } }
        }
        s.initialize()
        // On every launch too, as the Mac's does; a window shows only when there is something new.
        s.checkQuietly()
    }

    /// Bezzle › Check for Updates…: WinSparkle's window, with what it finds.
    static func check() {
        start()
        sparkle?.checkWithWindow()
    }

    /// As Bezzle quits: WinSparkle's thread and window let go.
    static func stop() {
        guard started else { return }
        sparkle?.cleanup()
    }

    private static var started = false

    /// WinSparkle's functions, from the DLL beside Bezzle.exe, when Bezzle.exe also names a feed.
    private static let sparkle: WinSparkle? = {
        let feed = "FeedURL".withCString(encodedAs: UTF16.self) { name in
            "APPCAST".withCString(encodedAs: UTF16.self) { type in FindResourceW(nil, name, type) }
        }
        guard feed != nil else { return nil }
        let path = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("WinSparkle.dll").path
        guard FileManager.default.fileExists(atPath: path),
              let dll = path.withCString(encodedAs: UTF16.self, LoadLibraryW) else { return nil }
        return WinSparkle(dll)
    }()

    /// One value of Bezzle.exe's version resource (StringFileInfo, US English, Unicode).
    private static func versionString(_ name: String) -> String? {
        typealias Size = @convention(c) (UnsafePointer<UInt16>?, UnsafeMutablePointer<DWORD>?) -> DWORD
        typealias Info = @convention(c) (UnsafePointer<UInt16>?, DWORD, DWORD, UnsafeMutableRawPointer?) -> Int32
        typealias Query = @convention(c) (UnsafeRawPointer?, UnsafePointer<UInt16>?, UnsafeMutablePointer<UnsafeMutableRawPointer?>?, UnsafeMutablePointer<UINT>?) -> Int32
        guard let dll = "version.dll".withCString(encodedAs: UTF16.self, LoadLibraryW),
              let sizeOf = GetProcAddress(dll, "GetFileVersionInfoSizeW"), let infoOf = GetProcAddress(dll, "GetFileVersionInfoW"),
              let query = GetProcAddress(dll, "VerQueryValueW") else { return nil }
        let exe = CommandLine.arguments[0]
        var ignored: DWORD = 0
        let size = exe.withCString(encodedAs: UTF16.self) { unsafeBitCast(sizeOf, to: Size.self)($0, &ignored) }
        guard size > 0 else { return nil }
        var block = [UInt8](repeating: 0, count: Int(size))
        let read = exe.withCString(encodedAs: UTF16.self) { path in
            block.withUnsafeMutableBytes { unsafeBitCast(infoOf, to: Info.self)(path, 0, size, $0.baseAddress) }
        }
        guard read != 0 else { return nil }
        return block.withUnsafeBytes { bytes -> String? in
            var value: UnsafeMutableRawPointer?
            var length: UINT = 0
            let found = "\\StringFileInfo\\040904B0\\\(name)".withCString(encodedAs: UTF16.self) {
                unsafeBitCast(query, to: Query.self)(bytes.baseAddress, $0, &value, &length)
            }
            guard found != 0, let value, length > 0 else { return nil }
            let text = String(decodingCString: value.assumingMemoryBound(to: UInt16.self), as: UTF16.self)
            return text.isEmpty ? nil : text
        }
    }
}

/// The part of WinSparkle's C API (winsparkle.h) that Bezzle calls, found by name in the DLL.
private struct WinSparkle {
    typealias Callback = @convention(c) () -> Void
    typealias Answer = @convention(c) () -> Int32

    let setAppDetails: @convention(c) (UnsafePointer<UInt16>?, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?) -> Void
    let setBuildVersion: @convention(c) (UnsafePointer<UInt16>?) -> Void
    let setLanguage: @convention(c) (UnsafePointer<CChar>?) -> Void
    let setRegistryPath: @convention(c) (UnsafePointer<CChar>?) -> Void
    let setAutomatic: @convention(c) (Int32) -> Void
    let setInterval: @convention(c) (Int32) -> Void
    let setCanShutdown: @convention(c) (Answer?) -> Void
    let setShutdownRequest: @convention(c) (Callback?) -> Void
    let initialize: Callback
    let cleanup: Callback
    let checkQuietly: Callback
    let checkWithWindow: Callback

    init?(_ dll: HMODULE) {
        func find<T>(_ name: String, as type: T.Type) -> T? {
            GetProcAddress(dll, name).map { unsafeBitCast($0, to: type) }
        }
        guard let setAppDetails = find("win_sparkle_set_app_details", as: (@convention(c) (UnsafePointer<UInt16>?, UnsafePointer<UInt16>?, UnsafePointer<UInt16>?) -> Void).self),
              let setBuildVersion = find("win_sparkle_set_app_build_version", as: (@convention(c) (UnsafePointer<UInt16>?) -> Void).self),
              let setLanguage = find("win_sparkle_set_lang", as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self),
              let setRegistryPath = find("win_sparkle_set_registry_path", as: (@convention(c) (UnsafePointer<CChar>?) -> Void).self),
              let setAutomatic = find("win_sparkle_set_automatic_check_for_updates", as: (@convention(c) (Int32) -> Void).self),
              let setInterval = find("win_sparkle_set_update_check_interval", as: (@convention(c) (Int32) -> Void).self),
              let setCanShutdown = find("win_sparkle_set_can_shutdown_callback", as: (@convention(c) (Answer?) -> Void).self),
              let setShutdownRequest = find("win_sparkle_set_shutdown_request_callback", as: (@convention(c) (Callback?) -> Void).self),
              let initialize = find("win_sparkle_init", as: Callback.self),
              let cleanup = find("win_sparkle_cleanup", as: Callback.self),
              let checkQuietly = find("win_sparkle_check_update_without_ui", as: Callback.self),
              let checkWithWindow = find("win_sparkle_check_update_with_ui", as: Callback.self) else { return nil }
        self.setAppDetails = setAppDetails
        self.setBuildVersion = setBuildVersion
        self.setLanguage = setLanguage
        self.setRegistryPath = setRegistryPath
        self.setAutomatic = setAutomatic
        self.setInterval = setInterval
        self.setCanShutdown = setCanShutdown
        self.setShutdownRequest = setShutdownRequest
        self.initialize = initialize
        self.cleanup = cleanup
        self.checkQuietly = checkQuietly
        self.checkWithWindow = checkWithWindow
    }
}
