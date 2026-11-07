import Foundation
@testable import BezzleCore

// Works on a shared design headless, as Bezzle for Windows does, for the Mac's own tests to check
// (BezzleTests/WindowsShareTests.swift): what Windows saw, what it changed, and what it wrote.
//
//   bezzle-share <open fonts folder> folder <design.bezzle> <out folder>
//   bezzle-share <open fonts folder> link <link.json> <out folder>
//   bezzle-share <open fonts folder> live <link.json> <out folder>
//
// `folder`: opens a design shared through its folder (written by the Mac as two people), writes
// what it opened as (opened.json), changes it and names a version, saves (stage1.json), then
// waits for <out>/go while the Mac changes its copy and the folder brings that here; looks,
// changes it again, saves, and writes the design as it has it then (final.json, board.png).
//
// `link`: first checks the keys a link makes against the Mac's (keys.json, with something sealed
// here for the Mac to open), then opens the link in link.json through the relay (BEZZLE_RELAY)
// into a designs folder beside it, and works on it as above, sending and taking in through the
// relay; after <out>/go2, the Mac has stopped sharing it: it is kept read only (ended.json).
//
// `live`: opens the link and stays in the design's live room until <out>/go, saying where it
// points; what it heard of the Mac there goes to live.json.
// BEZZLE_REPLICA names this computer among those sharing it.

let arguments = CommandLine.arguments
guard arguments.count >= 5 else {
    print("bezzle-share <open fonts folder> folder|link <design.bezzle|link.json> <out folder>")
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
    let images = url.appendingPathComponent("images")
    return [
        "replica": WindowsCore.replica,
        "shared": session != nil,
        "design": session.map { json($0.state.flatDesign().document()) } ?? "",
        "shown": json(WindowsCore.design ?? BezzleDocument()),
        "people": (session?.folder?.people ?? []).map(\.replica),
        "roomPeople": (session?.cloud?.people.keys.sorted() ?? []),
        "mark": WindowsCore.shareMark.map { "\($0)" } ?? "",
        "readOnly": WindowsCore.isReadOnly,
        "problem": WindowsCore.shareProblem ?? "",
        "linkEnded": Linking.link(of: url)?.ended ?? false,
        "versions": WindowsCore.versions.list.map { ["id": $0.id.uuidString, "name": $0.name ?? "", "replica": $0.replica ?? "", "shared": $0.shared] },
        "files": ((try? FileManager.default.contentsOfDirectory(atPath: mine.path)) ?? []).sorted(),
        "pictures": ((try? FileManager.default.contentsOfDirectory(atPath: images.path)) ?? []).sorted().map { name -> [String: Any] in
            let data = (try? Data(contentsOf: images.appendingPathComponent(name))) ?? Data()
            return ["name": name, "sha256": Data(SHA256.hash(data: data)).hex]
        },
    ]
}

@MainActor func layer(_ name: String) -> UUID? { WindowsCore.design?.allNodes.first { $0.name == name }?.id }

/// Waits for the Mac, as long as it takes it to say go.
func wait(for file: URL) {
    var waited = 0
    while !FileManager.default.fileExists(atPath: file.path) {
        guard waited < 2400 else { print("FAIL: no \(file.lastPathComponent)"); exit(1) }
        Thread.sleep(forTimeInterval: 0.5)
        waited += 1
    }
}

/// What Windows does at first: the same layer as the Macs, another property; a layer the Macs
/// renamed, renamed again; a layer of its own.
@MainActor func firstChanges() -> Bool {
    guard let r = layer("R"), let s = layer("S, renamed"), let board = WindowsCore.design?.nodes.first?.id else {
        print("FAIL: the Macs' changes are not in the design as it opened")
        return false
    }
    WindowsCore.edit { d in d.update(r) { $0.opacity = 0.5 } }
    WindowsCore.edit { d in d.update(s) { $0.name = "S, from Windows" } }
    WindowsCore.edit { d in
        var w = Node(kind: .rectangle, name: "W", frame: CGRect(x: 20, y: 200, width: 80, height: 40))
        w.fill.color = RGBA(r: 0.2, g: 0.6, b: 0.3, a: 1)
        d.update(board) { $0.children.append(w) }
    }
    return true
}

@MainActor func render(into out: URL) throws {
    if let picture = WindowsCore.render(board: 0, scale: 1) {
        try WindowsCore.writePNG(picture.pixels, width: picture.width, height: picture.height, to: out.appendingPathComponent("board.png"))
    }
}

@MainActor func folderRun(_ url: URL, _ out: URL) throws {
    _ = try WindowsCore.open(url)
    WindowsCore.versions.load()
    try write(report(url), "opened.json", in: out)
    print("opened as \(WindowsCore.replica): shared \(WindowsCore.sharing != nil), people \(WindowsCore.sharing?.folder?.people.map(\.replica) ?? [])")
    guard firstChanges() else { exit(1) }
    try WindowsCore.save()
    WindowsCore.versions.nameNow("From Windows")
    try write(report(url), "stage1.json", in: out)
    try Data().write(to: out.appendingPathComponent("stage1.done"))
    print("changed and saved; waiting for the Mac")

    // The Mac changes its copy meanwhile; the folder brings its files here.
    wait(for: out.appendingPathComponent("go"))
    let changed = WindowsCore.lookAtShare()
    var look = report(url)
    look["changed"] = changed
    try write(look, "look.json", in: out)
    print("looked: the design shown changed \(changed)")

    guard let w = layer("W") else { print("FAIL: W is gone"); exit(1) }
    WindowsCore.edit { d in d.update(w) { $0.frame.origin.x += 40 } }
    try WindowsCore.save()
    try write(report(url), "final.json", in: out)
    try render(into: out)
}

@MainActor func linkRun(_ file: URL, _ out: URL) async throws {
    let given = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    guard let link = given["link"] as? String, let vector = given["vector"] as? [String: String] else { print("FAIL: no link"); exit(1) }

    // The keys a link makes, as the Mac makes them, and sealing either way.
    guard let secret = vector["secret"], let keys = ShareKeys(link: secret) else { print("FAIL: no keys"); exit(1) }
    let sealed = vector["sealed"].flatMap { Data(base64Encoded: $0) } ?? Data()
    let opened = keys.open(sealed, about: vector["about"] ?? "").map { String(decoding: $0, as: UTF8.self) } ?? ""
    let mine = keys.seal(Data("Sealed on Windows".utf8), about: "probe").map { $0.base64EncodedString() } ?? ""
    try write(["room": keys.room == vector["room"], "read": keys.readToken == vector["read"], "write": keys.writeToken == vector["write"],
               "picture": keys.pictureName("photo.png") == vector["picture"], "hash": CloudRoom.hash(keys.writeToken) == vector["hash"],
               "opened": opened, "sealed": mine, "secretFromLink": CloudRoom.secret(from: URL(string: link)!) == secret,
               "isLink": WindowsCore.isShareLink(link)], "keys.json", in: out)
    print("keys: room \(keys.room == vector["room"]), opened \(opened)")

    // The link opened, as a click on it would: the design comes into the designs folder.
    let designs = file.deletingLastPathComponent().appendingPathComponent("designs", isDirectory: true)
    let url = try await WindowsCore.acceptLink(link, into: designs) { title, owner in print("arriving: \(title) by \(owner ?? "-")") }
    _ = try WindowsCore.open(url)
    WindowsCore.versions.load()
    await WindowsCore.syncShareNow()
    try write(report(url), "opened.json", in: out)
    print("opened \(url.lastPathComponent) as \(WindowsCore.replica): \(WindowsCore.shareMark.map { "\($0)" } ?? "-")")
    guard firstChanges() else { exit(1) }
    try WindowsCore.save()
    WindowsCore.versions.nameNow("From Windows")
    // As Copy Link does: everything sent, named versions too.
    let page = try await WindowsCore.shareLink()
    await WindowsCore.syncShareNow()
    var stage1 = report(url)
    stage1["page"] = page
    try write(stage1, "stage1.json", in: out)
    try Data().write(to: out.appendingPathComponent("stage1.done"))
    print("changed and sent; waiting for the Mac")

    wait(for: out.appendingPathComponent("go"))
    let changed = await WindowsCore.syncShareNow()
    var look = report(url)
    look["changed"] = changed
    try write(look, "look.json", in: out)
    print("took in: the design shown changed \(changed)")
    guard let w = layer("W") else { print("FAIL: W is gone"); exit(1) }
    WindowsCore.edit { d in d.update(w) { $0.frame.origin.x += 40 } }
    try WindowsCore.save()
    await WindowsCore.syncShareNow()
    try write(report(url), "final.json", in: out)
    try render(into: out)
    try Data().write(to: out.appendingPathComponent("final.done"))
    print("changed again and sent; waiting for the Mac to stop sharing")

    wait(for: out.appendingPathComponent("go2"))
    await WindowsCore.syncShareNow()
    let before = WindowsCore.design
    if let r = layer("R") { WindowsCore.edit { d in d.update(r) { $0.name = "Changed anyway" } } }
    try WindowsCore.save()
    var ended = report(url)
    ended["unchanged"] = WindowsCore.design == before
    try write(ended, "ended.json", in: out)
    print("ended: read only \(WindowsCore.isReadOnly)")
}

/// The live room: Windows says where it is, hears Anna come in, sees where she points and her
/// wink, takes in her change the moment she makes it, answers with one of its own, and hears the
/// relay say a record came; until <out>/go.
@MainActor func liveRun(_ file: URL, _ out: URL) async throws {
    let given = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any] ?? [:]
    guard let link = given["link"] as? String else { print("FAIL: no link"); exit(1) }
    let designs = file.deletingLastPathComponent().appendingPathComponent("designs", isDirectory: true)
    let url = try await WindowsCore.acceptLink(link, into: designs)
    _ = try WindowsCore.open(url)
    await WindowsCore.syncShareNow()
    guard let live = WindowsCore.live else { print("FAIL: no live room"); exit(1) }
    live.say(pointer: CGPoint(x: 123, y: 45), view: CGRect(x: 0, y: 0, width: 400, height: 300), selection: [], tool: "select", doing: "looking")
    print("in the live room as \(WindowsCore.replica)")
    var answered = false, events: [String] = []
    // Anna as Windows saw her while she was in the room.
    var seen: [String: Any] = [:]
    let go = out.appendingPathComponent("go"), started = Date()
    while !FileManager.default.fileExists(atPath: go.path) {
        guard Date().timeIntervalSince(started) < 600 else { print("FAIL: no go"); exit(1) }
        live.tick()
        try await Task.sleep(for: .milliseconds(50))
        let anna = live.people.first { $0.replica == "anna" }
        if let anna, !events.contains("hello") { events.append("hello") }
        if let anna, let p = live.presence[anna.id], p.pointer == CGPoint(x: 200, y: 150), !events.contains("presence") {
            events.append("presence")
            seen = ["replica": anna.replica, "name": anna.name, "pencil": String(format: "%06x", anna.pencil),
                    "pointer": [p.pointer?.x ?? 0, p.pointer?.y ?? 0], "tool": p.tool, "link": "\(live.link)"]
        }
        if live.winks.contains(where: { $0.at == CGPoint(x: 77, y: 88) }), !events.contains("wink") { events.append("wink") }
        if live.recordsHeard > 0, !events.contains("records") { events.append("records") }
        // Anna's change came live: shown once nothing holds it back, as the app's look does.
        WindowsCore.showOthersIfIdle()
        if WindowsCore.design?.allNodes.contains(where: { $0.name == "R, renamed live" }) == true, !answered {
            events.append("changes")
            answered = true
            if let s = layer("S") {
                WindowsCore.edit { d in d.update(s) { $0.name = "S, from Windows live" } }
                // Taken in as the app's save does, which sends it to the room at once.
                try WindowsCore.save()
                events.append("answered")
            }
        }
    }
    try write(["events": events, "anna": seen, "peopleAtTheEnd": live.people.map(\.replica),
               "recordsHeard": live.recordsHeard, "design": json(WindowsCore.sharing?.state.flatDesign().document() ?? BezzleDocument())],
              "live.json", in: out)
    print("live: \(events)")
}

do {
    try WindowsCore.loadFonts(from: URL(fileURLWithPath: arguments[1]))
    let given = URL(fileURLWithPath: arguments[3]), out = URL(fileURLWithPath: arguments[4])
    try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
    switch arguments[2] {
    case "folder": try folderRun(given, out)
    case "link": try await linkRun(given, out)
    case "live": try await liveRun(given, out)
    default: print("unknown: \(arguments[2])"); exit(2)
    }
    print("done")
} catch {
    print("FAIL: \(error)")
    exit(1)
}
