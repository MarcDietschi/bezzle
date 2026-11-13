import Foundation

// From Bezzle/MCP/MCPBrowse.swift, for Windows: Bezzle's browser through the AI server (`WebBrowser`).

/// Bezzle's browser through the AI server: an assistant opens a page, clicks, types and scrolls
/// in it, and looks at what it shows, so that import_website with shown can bring in the
/// screens of a web app behind a sign-in or a few clicks (`WebBrowser`).
extension MCPTools {
    func browse(_ args: Arguments) async throws -> [Content] {
        let browser = WebBrowser.shared
        let action = (try args.string("action") ?? "look").lowercased()
        let target: Any? = args["target"]
        let selector = try args.string("selector")
        var said: String?
        do {
            switch action {
            case "open":
                guard let address = try args.string("url"), let url = WebCapture.address(address) else {
                    throw MCPError("Give the page's address to open, such as https://example.com.")
                }
                if let width = try args.number("width") { browser.resize(to: Self.webSize(width)) }
                try await browser.open(url)
            case "look":
                break
            case "pages":
                guard browser.url != nil else { throw WebBrowser.Failure.nothingOpen }
                let pages = await browser.offered()
                let list: [JSONValue] = pages.map { p in
                    let kind = switch p.kind { case .open: "open"; case .visited: "visited"; case .linked: "linked" }
                    return .object([("url", .string(p.url.absoluteString)), ("name", .string(p.name)), ("kind", .string(kind))])
                }
                return [.text(JSONValue.object([("pages", .array(list)), ("note", "Bring several in together with import_website urls (and shown for the one open as it is).")]).text)]
            case "click":
                said = try await browser.click(target, selector: selector)
            case "hover":
                said = try await browser.hover(target, selector: selector)
            case "type":
                guard let text = try args.string("text") else { throw MCPError("Give the words to type as text.") }
                said = try await browser.type(text, into: target, selector: selector, submit: try args.bool("submit") ?? false, add: try args.bool("add") ?? false)
            case "press":
                guard let key = try args.string("key") else { throw MCPError("Give the key to press, such as Enter or Escape.") }
                said = try await browser.press(key)
            case "scroll":
                said = try await browser.scroll(target, selector: selector, to: args["to"], by: try args.number("by"))
            case "back", "forward", "reload":
                guard browser.url != nil else { throw WebBrowser.Failure.nothingOpen }
                if action == "back" { browser.back() } else if action == "forward" { browser.forward() } else { browser.reload() }
                try await browser.settle()
            case "show":
                let into = try args.string("design") != nil ? try await store(args) : Self.stores.first { !$0.isReadOnly }
                let size = try args.number("width").map(Self.webSize)
                browser.show(nil, size: size, into: into?.slot, activate: false)
                said = "The browser is on screen for the person, its pages going into \(into?.name ?? "a new design")."
                guard browser.url != nil else { return [.text(said! + " It has no page open yet: open one.")] }
            case "hide":
                browser.hide()
                said = "The browser's window is off the screen; its page is still open out of sight."
            case "close":
                browser.close()
                return [.text("The browser let its page go. Its sign-ins stay.")]
            default:
                throw MCPError("action is one of open, look, pages, click, type, press, hover, scroll, back, forward, reload, show, hide or close.")
            }
        } catch let error as WebBrowser.Failure {
            if case .nothingOpen = error { throw MCPError("Bezzle's browser has no page open: browse with action open and a url first.") }
            throw MCPError(error.localizedDescription)
        } catch let error as WebCapture.Failure {
            throw MCPError(error.localizedDescription)
        }
        do {
            var text = try await browser.look(words: try args.int("words"))
            if let said { text = said + "\n" + text }
            var out: [Content] = [.text(text)]
            if try args.bool("picture") == true, let png = try await browser.picture() { out.append(.png(png)) }
            return out
        } catch let error as WebBrowser.Failure {
            if case .nothingOpen = error { throw MCPError("Bezzle's browser has no page open: browse with action open and a url first.") }
            throw MCPError(error.localizedDescription)
        } catch let error as WebCapture.Failure {
            throw MCPError(error.localizedDescription)
        }
    }
}
