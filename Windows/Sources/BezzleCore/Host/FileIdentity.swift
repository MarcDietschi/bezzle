import Foundation
import WinSDK

/// A file or folder as the file system knows it, whatever it is called and wherever it is on its
/// volume: NTFS keeps a file's number through renames and moves, as a bookmark leads to a file on
/// the Mac. An open design is found again by it when its package was renamed in Explorer.
nonisolated struct FileIdentity: Equatable, Sendable {
    let volume: UInt32
    let index: UInt64

    init?(of url: URL) {
        // A folder opens only with backup semantics; nothing is read or written.
        let handle = url.path.withCString(encodedAs: UTF16.self) {
            CreateFileW($0, 0, DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), nil, DWORD(OPEN_EXISTING),
                        DWORD(FILE_FLAG_BACKUP_SEMANTICS), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else { return nil }
        defer { CloseHandle(handle) }
        var info = BY_HANDLE_FILE_INFORMATION()
        guard GetFileInformationByHandle(handle, &info) else { return nil }
        volume = info.dwVolumeSerialNumber
        index = UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow)
    }
}
