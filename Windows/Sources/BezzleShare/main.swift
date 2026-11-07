import Foundation
@testable import BezzleCore

// Works on a shared design headless, as Bezzle for Windows does, for the Mac's own tests to check
// (BezzleTests/WindowsShareTests.swift): what Windows saw, what it changed, and what it wrote.
//
//   bezzle-share <open fonts folder> folder <design.bezzle> <out folder>
//
// `folder`: opens a design shared through its folder (written by the Mac as two people), writes
// what it opened as (opened.json), changes it and names a version, saves (stage1.json), then
// waits for <out>/go while the Mac changes its copy and the folder brings that here; looks,
// changes it again, saves, and writes the design as it has it then (final.json, board.png).
// BEZZLE_REPLICA names this computer among those sharing it.

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    print("bezzle-share <open fonts folder> folder <design.bezzle> <out folder>")
    exit(2)
}

func json(_ doc: BezzleDocument) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: (try? encoder.encode(doc)) ?? Data(), as: UTF8.self)
}

func write(_ object: [String: Any], _ name: String, in out: URL) throws {
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted]).write(to: out.appendingPathComponent(name))
}

/// What is shared of the open design, as this computer has it now.
@MainActor func report(_ url: URL) -> [String: Any] {
    let session = WindowsCore.sharing
    let mine = FolderShare.folder(of: WindowsCore.replica, in: url)
    return [
        "replica": WindowsCore.replica,
        "shared": session != nil,
        "design": session.map { json($0.state.flatDesign().document()) } ?? "",
        "shown": json(WindowsCore.design ?? BezzleDocument()),
        "people": (session?.folder?.people ?? []).map(\.replica),
        "versions": WindowsCore.versions.list.map { ["id": $0.id.uuidString, "name": $0.name ?? "", "replica": $0.replica ?? "", "shared": $0.shared] },
        "files": ((try? FileManager.default.contentsOfDirectory(atPath: mine.path)) ?? []).sorted(),
    ]
}

@MainActor func layer(_ name: String) -> UUID? { WindowsCore.design?.allNodes.first { $0.name == name }?.id }

do {
    try WindowsCore.loadFonts(from: URL(fileURLWithPath: arguments[1]))
    let url = URL(fileURLWithPath: arguments[3]), out = URL(fileURLWithPath: arguments[4])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    guard arguments[2] == "folder" else { print("unknown: \(arguments[2])"); exit(2) }

    _ = try WindowsCore.open(url)
    WindowsCore.versions.load()
    try write(report(url), "opened.json", in: out)
    print("opened as \(WindowsCore.replica): shared \(WindowsCore.sharing != nil), people \(WindowsCore.sharing?.folder?.people.map(\.replica) ?? [])")

    // What Windows does at first: the same layer as the Macs, another property; a layer the Macs
    // renamed, renamed again; a layer of its own.
    guard let r = layer("R"), let s = layer("S, renamed"), let board = WindowsCore.design?.nodes.first?.id else {
        print("FAIL: the Macs' changes are not in the design as it opened")
        exit(1)
    }
    WindowsCore.edit { d in d.update(r) { $0.opacity = 0.5 } }
    WindowsCore.edit { d in d.update(s) { $0.name = "S, from Windows" } }
    WindowsCore.edit { d in
        var w = Node(kind: .rectangle, name: "W", frame: CGRect(x: 20, y: 200, width: 80, height: 40))
        w.fill.color = RGBA(r: 0.2, g: 0.6, b: 0.3, a: 1)
        d.update(board) { $0.children.append(w) }
    }
    try WindowsCore.save()
    WindowsCore.versions.nameNow("From Windows")
    try write(report(url), "stage1.json", in: out)
    try Data().write(to: out.appendingPathComponent("stage1.done"))
    print("changed and saved; waiting for the Mac")

    // The Mac changes its copy meanwhile; the folder brings its files here.
    let go = out.appendingPathComponent("go")
    var waited = 0
    while !FileManager.default.fileExists(atPath: go.path) {
        guard waited < 1200 else { print("FAIL: no go"); exit(1) }
        Thread.sleep(forTimeInterval: 0.5)
        waited += 1
    }
    let changed = WindowsCore.lookAtShare()
    var look = report(url)
    look["changed"] = changed
    try write(look, "look.json", in: out)
    print("looked: the design shown changed \(changed)")

    guard let w = layer("W") else { print("FAIL: W is gone"); exit(1) }
    WindowsCore.edit { d in d.update(w) { $0.frame.origin.x += 40 } }
    try WindowsCore.save()
    try write(report(url), "final.json", in: out)
    if let picture = WindowsCore.render(board: 0, scale: 1) {
        try WindowsCore.writePNG(picture.pixels, width: picture.width, height: picture.height, to: out.appendingPathComponent("board.png"))
    }
    print("done")
} catch {
    print("FAIL: \(error)")
    exit(1)
}
