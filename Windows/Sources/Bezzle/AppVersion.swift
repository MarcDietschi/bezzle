import Foundation
import WinSDK

/// Bezzle's version on Windows, which is the Mac's: Xcode's MARKETING_VERSION in
/// Bezzle.xcodeproj, one number for both, as the release notes are one for both.
///
/// - A released copy has it in Bezzle.exe's version resource, with the build number its updates
///   are compared by (Scripts/release-windows.sh reads the project; Installer/make-installer.ps1
///   writes them in). The installer, the feed and the file's Details in Explorer say the same.
/// - A copy built here has version.txt beside it (VM/sync.sh writes it from the project, build.ps1
///   puts it there), and no build number.
/// About Bezzle shows it, the AI server says it, and the updater compares by it.
enum AppVersion {
    /// The version people see: "1.4.2", or "0" when nothing says.
    static let short: String = resource("ProductVersion") ?? builtHere ?? "0"
    /// The build number updates are compared by ("20261108.1200"); a released copy's alone.
    static let build: String? = resource("Build")
    /// Whether this copy was released (it carries a build number), rather than built here.
    static var isRelease: Bool { build != nil }

    private static let builtHere: String? = {
        let file = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("version.txt")
        let text = (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }()

    /// One value of Bezzle.exe's version resource (StringFileInfo, US English, Unicode), read
    /// through version.dll, loaded when asked rather than linked.
    private static func resource(_ name: String) -> String? {
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
