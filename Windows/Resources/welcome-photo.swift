// The welcome tour's pictures for Windows: the Mac's own lake photo (Bezzle/Store/WelcomePhoto.swift)
// and its logo to trace (Bezzle/Store/WelcomeLogo.swift), painted here on the Mac as the Mac paints
// them for each new tour, and written where the Windows build puts them beside Bezzle.exe
// (Resources/Generated/welcome-lake.jpg and welcome-logo.png). make-welcome-photo.sh compiles the
// three together, this as main.swift.
import Foundation

let folder = URL(fileURLWithPath: CommandLine.arguments[1])
guard let jpeg = WelcomePhoto.jpeg(), let png = WelcomeLogo.png() else {
    FileHandle.standardError.write(Data("The welcome tour's pictures could not be painted.\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for (name, data) in [("welcome-lake.jpg", jpeg), ("welcome-logo.png", png)] {
    let out = folder.appendingPathComponent(name)
    try data.write(to: out, options: .atomic)
    print("welcome picture:", data.count, "bytes ->", out.path)
}
