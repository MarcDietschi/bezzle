import Foundation
import WinSDK

extension WindowsCore {
    /// Moves a file or a design's folder to the Recycle Bin, as Explorer's Delete does, without
    /// asking or showing progress: whether it went.
    static func recycle(_ url: URL) -> Bool {
        // The shell takes a list of paths, each ended by a nought and the list by another.
        var from = Array(url.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\").utf16)
        from += [0, 0]
        return from.withUnsafeBufferPointer { paths in
            var operation = SHFILEOPSTRUCTW()
            operation.wFunc = UINT(FO_DELETE)
            operation.pFrom = paths.baseAddress
            operation.fFlags = FILEOP_FLAGS(FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI)
            return SHFileOperationW(&operation) == 0 && !operation.fAnyOperationsAborted.boolValue
        } && !FileManager.default.fileExists(atPath: url.path)
    }
}
