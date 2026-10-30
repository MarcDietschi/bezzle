import AppKit
import UniformTypeIdentifiers

/// Bezzle as an extension for Claude Desktop. Claude Desktop starts the tools it uses as
/// programs and can't be pointed at a server by its address, so the extension is a small
/// script (ClaudeBridge.js) that passes what Claude says on to the server in Bezzle. It is
/// made here, when asked for, so it lists the tools this copy of Bezzle has.
enum ClaudeExtension {
    static let claudeBundleID = "com.anthropic.claudefordesktop"

    /// Where Claude Desktop is, if it is on this Mac.
    static var claude: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: claudeBundleID) }

    static let fileName = "Bezzle.mcpb"

    /// Makes the extension and opens it in Claude Desktop, which asks whether to install it.
    static func install() {
        guard let claude else { return save() }
        do {
            let file = FileManager.default.temporaryDirectory.appending(path: fileName)
            try write(to: file)
            NSWorkspace.shared.open([file], withApplicationAt: claude, configuration: NSWorkspace.OpenConfiguration())
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Asks where to save the extension, saves it there and shows it in the Finder.
    static func save() {
        let panel = NSSavePanel()
        panel.title = String(localized: "Save Claude Desktop Extension")
        panel.message = String(localized: "Open the file, or drag it into Claude Desktop's Settings ▸ Extensions, to install it.")
        panel.nameFieldStringValue = fileName
        panel.allowedContentTypes = [UTType(filenameExtension: "mcpb") ?? .zip]
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try write(to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Writes the extension, a zip of a manifest, the script, the tools it lists while Bezzle is
    /// closed, and the icon, to `url`.
    static func write(to url: URL) throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appending(path: "Bezzle extension \(UUID().uuidString)")
        defer { try? files.removeItem(at: folder) }
        try files.createDirectory(at: folder.appending(path: "server"), withIntermediateDirectories: true)

        guard let bridge = Bundle.main.url(forResource: "ClaudeBridge", withExtension: "js") else {
            throw MCPError(String(localized: "The bridge script is missing from Bezzle."))
        }
        try files.copyItem(at: bridge, to: folder.appending(path: "server/index.js"))
        let tools = MCPTools()
        let snapshot: JSONValue = ["initialize": MCPServer.shared.initialize([:]), "tools": .array(tools.list)]
        try snapshot.data.write(to: folder.appending(path: "server/snapshot.json"))
        try manifest(tools).data.write(to: folder.appending(path: "manifest.json"))
        try icon().write(to: folder.appending(path: "icon.png"))

        try? files.removeItem(at: url)
        let zip = Process()
        zip.executableURL = URL(filePath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--noqtn", folder.path, url.path]
        try zip.run()
        zip.waitUntilExit()
        guard zip.terminationStatus == 0 else { throw MCPError(String(localized: "Bezzle couldn't make the extension file.")) }
    }

    private static func manifest(_ tools: MCPTools) -> JSONValue {
        let info = Bundle.main.infoDictionary
        // Claude Desktop wants versions with three parts.
        var version = (info?["CFBundleShortVersionString"] as? String ?? "0").split(separator: ".").map(String.init)
        while version.count < 3 { version.append("0") }
        let server = MCPServer.shared
        let env: JSONValue = .compact([
            ("BEZZLE_BUNDLE_ID", Bundle.main.bundleIdentifier.map { .string($0) }),
            ("BEZZLE_MCP_PORT", server.port == MCPServer.defaultPort ? nil : .string(String(server.port))),
        ])
        return [
            "manifest_version": "0.3",
            "name": "bezzle",
            "display_name": "Bezzle",
            "version": .string(version.joined(separator: ".")),
            "description": "Design in Bezzle: build screens and posts, style and arrange layers, render and export.",
            "long_description": """
                Lets Claude work in your Bezzle designs the way you would: make artboards and layers, \
                change their fills, borders, text and shadows, arrange and combine them, look at a picture \
                of the result and export it. Every change is one step you can undo with Command-Z. Bezzle \
                opens by itself when Claude needs it. Turn this off in Bezzle with Bezzle ▸ Allow AI Control.
                """,
            "author": ["name": "Erik Vetsch"],
            "icon": "icon.png",
            "server": [
                "type": "node",
                "entry_point": "server/index.js",
                "mcp_config": .compact([("command", "node"), ("args", ["${__dirname}/server/index.js"]), ("env", env)]),
            ],
            "tools": .array(tools.summaries.map { ["name": .string($0.name), "description": .string($0.summary)] }),
            "tools_generated": true,
            "keywords": ["design", "bezzle", "mac"],
            "compatibility": ["platforms": ["darwin"], "runtimes": ["node": ">=18.0.0"]],
        ]
    }

    /// The app's icon, 512 pixels square, as Claude Desktop shows it best.
    private static func icon() throws -> Data {
        let size = 512
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { throw MCPError(String(localized: "Bezzle couldn't draw its icon.")) }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSApp.applicationIconImage.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else { throw MCPError(String(localized: "Bezzle couldn't draw its icon.")) }
        return png
    }
}
