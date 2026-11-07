import Foundation
import WinSDK

/// Windows' own Open dialog, through its COM interface (IFileOpenDialog). A design is a folder
/// named "….bezzle", as a package is on the Mac, so the dialog picks folders.
@MainActor
enum FileDialogs {
    static func chooseDesign(startingIn folder: URL?) -> URL? {
        chooseFolder(title: "Open a Design", button: "Open", startingIn: folder)
    }

    /// A folder chosen in Windows' own dialog, as the Mac's NSOpenPanel for folders.
    static func chooseFolder(title: String, button: String, startingIn folder: URL?) -> URL? {
        var clsid = CLSID_FileOpenDialog
        var iid = IID_IFileOpenDialog
        var raw: UnsafeMutableRawPointer?
        guard CoCreateInstance(&clsid, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &iid, &raw) >= 0, let raw else { return nil }
        let dialog = raw.assumingMemoryBound(to: IFileOpenDialog.self)
        let calls = dialog.pointee.lpVtbl.pointee
        defer { _ = calls.Release(dialog) }

        var options: FILEOPENDIALOGOPTIONS = 0
        _ = calls.GetOptions(dialog, &options)
        _ = calls.SetOptions(dialog, options | FILEOPENDIALOGOPTIONS(FOS_PICKFOLDERS.rawValue) | FILEOPENDIALOGOPTIONS(FOS_FORCEFILESYSTEM.rawValue))
        _ = title.withCString(encodedAs: UTF16.self) { calls.SetTitle(dialog, $0) }
        _ = button.withCString(encodedAs: UTF16.self) { calls.SetOkButtonLabel(dialog, $0) }
        if let folder {
            var item: UnsafeMutableRawPointer?
            var shellItem = IID_IShellItem
            let made = folder.path.withCString(encodedAs: UTF16.self) { SHCreateItemFromParsingName($0, nil, &shellItem, &item) }
            if made >= 0, let item {
                let shell = item.assumingMemoryBound(to: IShellItem.self)
                _ = calls.SetFolder(dialog, shell)
                _ = shell.pointee.lpVtbl.pointee.Release(shell)
            }
        }
        guard calls.Show(dialog, GetActiveWindow()) >= 0 else { return nil }
        var result: UnsafeMutablePointer<IShellItem>?
        guard calls.GetResult(dialog, &result) >= 0, let result else { return nil }
        defer { _ = result.pointee.lpVtbl.pointee.Release(result) }
        var name: PWSTR?
        guard result.pointee.lpVtbl.pointee.GetDisplayName(result, SIGDN_FILESYSPATH, &name) >= 0, let name else { return nil }
        defer { CoTaskMemFree(name) }
        return URL(fileURLWithPath: String(decodingCString: name, as: UTF16.self))
    }

    /// Files chosen in Windows' own dialog: of the kinds `filters` names (a name and patterns such
    /// as "*.png;*.jpg"), one or, with `several`, as many as are picked.
    static func chooseFiles(title: String, button: String, filters: [(name: String, patterns: String)], several: Bool) -> [URL] {
        var clsid = CLSID_FileOpenDialog
        var iid = IID_IFileOpenDialog
        var raw: UnsafeMutableRawPointer?
        guard CoCreateInstance(&clsid, nil, DWORD(CLSCTX_INPROC_SERVER.rawValue), &iid, &raw) >= 0, let raw else { return [] }
        let dialog = raw.assumingMemoryBound(to: IFileOpenDialog.self)
        let calls = dialog.pointee.lpVtbl.pointee
        defer { _ = calls.Release(dialog) }

        var options: FILEOPENDIALOGOPTIONS = 0
        _ = calls.GetOptions(dialog, &options)
        options |= FILEOPENDIALOGOPTIONS(FOS_FORCEFILESYSTEM.rawValue) | FILEOPENDIALOGOPTIONS(FOS_FILEMUSTEXIST.rawValue)
        if several { options |= FILEOPENDIALOGOPTIONS(FOS_ALLOWMULTISELECT.rawValue) }
        _ = calls.SetOptions(dialog, options)
        _ = title.withCString(encodedAs: UTF16.self) { calls.SetTitle(dialog, $0) }
        _ = button.withCString(encodedAs: UTF16.self) { calls.SetOkButtonLabel(dialog, $0) }
        func wide(_ s: String) -> UnsafeMutablePointer<WCHAR> {
            let u = Array(s.utf16) + [0]
            let p = UnsafeMutablePointer<WCHAR>.allocate(capacity: u.count)
            p.initialize(from: u, count: u.count)
            return p
        }
        let names = filters.map { (wide($0.name), wide($0.patterns)) }
        defer { for (a, b) in names { a.deallocate(); b.deallocate() } }
        var specs = names.map { COMDLG_FILTERSPEC(pszName: UnsafePointer($0.0), pszSpec: UnsafePointer($0.1)) }
        if !specs.isEmpty { _ = calls.SetFileTypes(dialog, UINT(specs.count), &specs) }
        guard calls.Show(dialog, GetActiveWindow()) >= 0 else { return [] }
        var results: UnsafeMutablePointer<IShellItemArray>?
        guard calls.GetResults(dialog, &results) >= 0, let results else { return [] }
        defer { _ = results.pointee.lpVtbl.pointee.Release(results) }
        var count: DWORD = 0
        _ = results.pointee.lpVtbl.pointee.GetCount(results, &count)
        var urls: [URL] = []
        for i in 0..<count {
            var item: UnsafeMutablePointer<IShellItem>?
            guard results.pointee.lpVtbl.pointee.GetItemAt(results, i, &item) >= 0, let item else { continue }
            defer { _ = item.pointee.lpVtbl.pointee.Release(item) }
            var name: PWSTR?
            guard item.pointee.lpVtbl.pointee.GetDisplayName(item, SIGDN_FILESYSPATH, &name) >= 0, let name else { continue }
            urls.append(URL(fileURLWithPath: String(decodingCString: name, as: UTF16.self)))
            CoTaskMemFree(name)
        }
        return urls
    }
}
