import SwiftUI
import AppKit

/// In the Bezzle menu: whether AI assistants may work in the app, and how to connect one to it.
struct MCPCommands: Commands {
    private var server: MCPServer { .shared }

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Divider()
            Toggle("Allow AI Control", isOn: Binding(get: { server.isEnabled }, set: { server.isEnabled = $0 }))
            if server.isEnabled, let failure = server.failure {
                Text("AI control is off: \(failure)")
            }
            Menu("Connect an AI Assistant") {
                if ClaudeExtension.claude != nil {
                    Button("Add to Claude Desktop…") { ClaudeExtension.install() }
                }
                Button("Save Claude Desktop Extension…") { ClaudeExtension.save() }
                Divider()
                Button("Copy Claude Code Command") {
                    copy("claude mcp add --transport http --scope user bezzle \(server.address)")
                }
                // Codex in the terminal and in the ChatGPT app, which share their servers.
                Button("Copy Codex Command") { copy("codex mcp add bezzle --url \(server.address)") }
                Button("Copy Server Address") { copy(server.address) }
            }
            .disabled(!server.isEnabled)
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
