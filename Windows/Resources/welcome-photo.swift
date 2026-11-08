// The welcome tour's photo for Windows: the Mac's own (Bezzle/Store/WelcomePhoto.swift), painted
// here on the Mac as the Mac paints it for each new tour, and written where the Windows build puts
// it beside Bezzle.exe (Resources/Generated/welcome-lake.jpg). make-welcome-photo.sh compiles the
// two together, this as main.swift.
import Foundation

let out = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("welcome-lake.jpg")
guard let jpeg = WelcomePhoto.jpeg() else {
    FileHandle.standardError.write(Data("The welcome photo could not be painted.\n".utf8))
    exit(1)
}
try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
try jpeg.write(to: out, options: .atomic)
print("welcome photo:", jpeg.count, "bytes ->", out.path)
