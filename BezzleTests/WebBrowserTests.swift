import Testing
import AppKit
@testable import Bezzle

/// Bezzle's browser, and pages brought into a design that is open: a web app's screens behind a
/// sign-in or a click, read as they are shown and gathered beside the artboards there are.
@MainActor
@Suite(.serialized)
struct WebBrowserTests {
    /// A page laid out as a web app is: a bar on top, a list that scrolls in a box of its own,
    /// a menu that opens on a click, and a cookie banner along the bottom.
    static let shell = """
    <!doctype html><html><head><meta charset="utf-8"><title>Shell</title><style>
    html, body { height: 100%; margin: 0; overflow: hidden; font-family: Helvetica; }
    body { display: flex; flex-direction: column; }
    header { height: 60px; flex: none; background: rgb(20, 20, 20); }
    main { flex: 1; overflow: auto; }
    .row { height: 100px; border-bottom: 1px solid rgb(200, 200, 200); }
    #banner { position: fixed; bottom: 0; left: 0; right: 0; height: 80px; background: rgb(250, 240, 200); }
    </style></head><body>
    <header><button id="open">Open menu</button></header>
    <main id="list">\((1...30).map { "<div class=\"row\">Row \($0)</div>" }.joined())</main>
    <div id="banner">We use cookies. <button>Accept cookies</button></div>
    <script>
    document.getElementById('open').addEventListener('click', () => {
      const m = document.createElement('div');
      m.setAttribute('role', 'menu');
      m.textContent = 'Menu item one';
      m.style.cssText = 'position:absolute;top:60px;left:10px;width:200px;height:40px;background:white;';
      document.body.appendChild(m);
    });
    </script></body></html>
    """

    /// A search form, and a password beside it.
    static let form = """
    <!doctype html><html><head><meta charset="utf-8"><title>Form</title></head><body style="font-family: Helvetica">
    <form id="f"><input name="q" placeholder="Search"><input type="password" name="pw" placeholder="Password"><button>Go</button></form>
    <div id="out">Nothing yet</div>
    <script>
    const q = document.querySelector('[name=q]'), out = document.getElementById('out');
    q.addEventListener('input', () => { out.textContent = 'You typed ' + q.value; });
    document.getElementById('f').addEventListener('submit', (e) => { e.preventDefault(); out.textContent = 'Sent ' + q.value; });
    </script></body></html>
    """

    /// The page written into a folder of its own, to be opened as a file.
    static func site(_ html: String) throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("web-browser-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let page = folder.appendingPathComponent("index.html")
        try html.write(to: page, atomically: true, encoding: .utf8)
        return page
    }

    static func browser() -> WebBrowser {
        let browser = WebBrowser()
        browser.showsStash = false
        return browser
    }

    static func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    static func everything(_ n: Node) -> [Node] { [n] + n.children.flatMap(everything) }

    // MARK: Pictures behind a sign-in

    @Test func sendsCookiesOnlyToTheirSite() throws {
        func cookie(_ domain: String, path: String = "/", secure: Bool = false, expires: Date? = nil) -> HTTPCookie {
            var p: [HTTPCookiePropertyKey: Any] = [.name: "c\(domain)\(path)\(secure)\(expires != nil)", .value: "1", .domain: domain, .path: path]
            if secure { p[.secure] = "TRUE" }
            if let expires { p[.expires] = expires }
            return HTTPCookie(properties: p)!
        }
        let host = cookie("search.weblaw.ch"), wide = cookie(".weblaw.ch"), other = cookie("example.com")
        let deep = cookie("search.weblaw.ch", path: "/api"), safe = cookie("search.weblaw.ch", path: "/", secure: true)
        let old = cookie("search.weblaw.ch", expires: Date(timeIntervalSinceNow: -60))
        let all = [host, wide, other, deep, safe, old]
        let page = URL(string: "https://search.weblaw.ch/img/logo.png")!
        #expect(Set(WebCapture.cookies(for: page, among: all).map(\.name)) == Set([host, wide, safe].map(\.name)))
        // Only the domain's own cookie goes to a host beside it, and none marked secure over HTTP.
        #expect(WebCapture.cookies(for: URL(string: "https://www.weblaw.ch/a.png")!, among: all).map(\.name) == [wide.name])
        #expect(!WebCapture.cookies(for: URL(string: "http://search.weblaw.ch/api/x")!, among: all).contains { $0.name == safe.name })
        #expect(WebCapture.cookies(for: URL(string: "https://search.weblaw.ch/api/x")!, among: all).contains { $0.name == deep.name })
        #expect(!WebCapture.cookies(for: URL(string: "https://search.weblaw.ch/apix")!, among: all).contains { $0.name == deep.name })
    }

    // MARK: Into an open design

    @Test func laysPagesInARowRightOfWhatIsThere() {
        let made = [Node(kind: .artboard, name: "One", frame: CGRect(x: 0, y: 0, width: 1440, height: 900)),
                    Node(kind: .artboard, name: "Two", frame: CGRect(x: 1840, y: 0, width: 390, height: 844))]
        let there = [Node(kind: .artboard, name: "A", frame: CGRect(x: 100, y: 80, width: 400, height: 300)),
                     Node(kind: .rectangle, name: "Loose", frame: CGRect(x: 700, y: -40, width: 50, height: 50))]
        let placed = WebImport.placed(made, beside: there)
        #expect(placed.map(\.frame.origin) == [CGPoint(x: 1150, y: 80), CGPoint(x: 2990, y: 80)])
        #expect(WebImport.placed(made, beside: []).map(\.frame) == made.map(\.frame))
    }

    @Test func namesPagesByTitleSizeAndWhatIsTaken() throws {
        let page = try WebTest.page(WebTest.html())
        let taken = [Node(kind: .artboard, name: "Test page", frame: .zero), Node(kind: .artboard, name: "Test page 2", frame: .zero)]
        #expect(WebImport.boardName(of: page, size: .desktop, among: []) == "Test page")
        #expect(WebImport.boardName(of: page, size: .desktop, among: taken) == "Test page 3")
        #expect(WebImport.boardName(of: page, size: .mobile, among: taken) == "Test page (\(WebCapture.Size.mobile.name))")
    }

    /// The list of pages as the Mac and Windows make it from what their browsers say: the page
    /// open first, then those visited on its site that are safe to load again, then its links,
    /// each once, the part after # left off.
    @Test func offersPagesFromWhatTheBrowserSays() {
        let here = URL(string: "https://app.example.ch/search#results")!
        let visited: [(url: URL, title: String?)] = [
            (URL(string: "https://app.example.ch/account")!, "Account"),
            (URL(string: "https://app.example.ch/search")!, "Search again"),
            (URL(string: "https://app.example.ch/logout")!, "Signed out"),
            (URL(string: "https://elsewhere.ch/")!, "Elsewhere"),
            (URL(string: "https://app.example.ch/saved")!, ""),
        ]
        let links = #"[{"url":"https://app.example.ch/account#top","name":"Account again"},{"url":"https://app.example.ch/help","name":"Help"},{"url":"https://app.example.ch/news"}]"#
        let pages = WebSitePage.offered(open: here, title: "Search", visited: visited, links: links)
        #expect(pages.map(\.url.absoluteString) == ["https://app.example.ch/search", "https://app.example.ch/account", "https://app.example.ch/saved",
                                                    "https://app.example.ch/help", "https://app.example.ch/news"])
        #expect(pages.map(\.kind) == [.open, .visited, .visited, .linked, .linked])
        #expect(pages.map(\.name) == ["Search", "Account", "/saved", "Help", "/news"])
        // A page with no title is named for its host; links that cannot be read are no pages.
        let bare = WebSitePage.offered(open: URL(string: "https://app.example.ch/")!, title: "", visited: [], links: "not JSON")
        #expect(bare.map(\.name) == ["app.example.ch"] && bare.map(\.kind) == [.open])
    }

    @Test(.timeLimit(.minutes(5))) func bringsAPageIntoADesignAsOneStep() async throws {
        let bench = Bench()
        let picture = "data:image/png;base64," + WebTest.png(8, 8, CGColor(srgbRed: 0, green: 0.5, blue: 1, alpha: 1)).base64EncodedString()
        let (read, held) = try await WebTest.read("<div style=\"width: 200px; height: 80px; background: rgb(255, 0, 0)\"></div><img src=\"\(picture)\" width=\"40\" height=\"40\">")
        #expect(!held.isEmpty)
        let (ids, _) = try bench.store.bringIn([read], held: held, source: "test")
        #expect(ids.count == 1 && bench.store.doc.nodes.count == 3)
        let board = try #require(bench.store.doc.node(ids[0]))
        // Beside B, the rightmost artboard, level with the top of both.
        #expect(board.frame.origin == CGPoint(x: 1400, y: 100) && board.frame.width == WebTest.size.width)
        #expect(bench.store.selection == ids)
        let images = bench.store.url.appendingPathComponent(DesignFile.imagesFolder)
        let files = Set(try FileManager.default.contentsOfDirectory(atPath: images.path))
        let used = Set(Self.everything(board).compactMap { $0.fill.image?.asset })
        #expect(!used.isEmpty && used.isSubset(of: files))
        bench.undo.undo()
        #expect(bench.store.doc.nodes.map(\.name) == ["A", "B"])
    }

    // MARK: The browser

    @Test(.timeLimit(.minutes(5))) func readsAPageAsShownAndLeavesItSo() async throws {
        let bench = Bench()
        MCPTools.opened(bench.store)
        defer { MCPTools.closed(bench.store) }
        let browser = Self.browser()
        defer { browser.close() }
        try await browser.open(try Self.site(Self.shell))
        #expect(browser.title == "Shell")
        let first = Self.json(try await browser.look())
        let names = (first["things"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        #expect(names.contains("Open menu") && names.contains("Accept cookies"))
        #expect((first["words"] as? String)?.contains("Menu item one") == false)

        _ = try await browser.click("Open menu")
        let opened = Self.json(try await browser.look())
        #expect((opened["words"] as? String)?.contains("Menu item one") == true)
        #expect((opened["menus"] as? [String])?.first == "Menu item one")
        // The list scrolls in a box of its own, the page not at all.
        let scrolled = try await browser.scroll(nil, to: 450)
        #expect(scrolled.hasPrefix("Scrolled to 450 of"))

        let brought = try await browser.importShown(into: bench.store)
        #expect(brought.store === bench.store && brought.ids.count == 1)
        let board = try #require(bench.store.doc.node(brought.ids[0]))
        let words = Self.everything(board).compactMap(\.text)
        // The menu as it was open, the list in its box scrolled where it was, and the banner away.
        #expect(words.contains("Menu item one"))
        #expect(words.contains("Row 6") && !words.contains("Row 30"))
        #expect(board.frame.height == WebCapture.Size.desktop.height)
        #expect(!words.contains { $0.contains("cookies") })
        #expect(board.name == "Shell")

        // The page is as it was left: the menu open, the list in its box scrolled where it was,
        // the page no taller than its window, and the banner back.
        let after = Self.json(try await browser.look())
        #expect((after["words"] as? String)?.contains("Menu item one") == true)
        #expect((after["words"] as? String)?.contains("Accept cookies") == true)
        #expect((after["scroll"] as? [String: Any])?["height"] as? Int == Int(WebCapture.Size.desktop.height))
        #expect(try await browser.scroll(nil, by: 0).hasPrefix("Scrolled to 450 of"))

        // A second page goes beside the first, under a name of its own.
        let again = try await browser.importShown()
        #expect(again.store === bench.store)
        #expect(bench.store.doc.node(again.ids[0])?.name == "Shell 2")
        #expect((bench.store.doc.node(again.ids[0])?.frame.minX ?? 0) > board.frame.maxX)
    }

    @Test(.timeLimit(.minutes(5))) func typesIntoFieldsButLeavesPasswordsToThePerson() async throws {
        let browser = Self.browser()
        defer { browser.close() }
        try await browser.open(try Self.site(Self.form))
        _ = try await browser.type("hello", into: "Search")
        #expect((Self.json(try await browser.look())["words"] as? String)?.contains("You typed hello") == true)
        _ = try await browser.type("there", into: "Search", submit: true, add: true)
        let sent = Self.json(try await browser.look())
        #expect((sent["words"] as? String)?.contains("Sent hellothere") == true)
        let things = sent["things"] as? [[String: Any]] ?? []
        #expect(things.contains { $0["role"] as? String == "password" && $0["value"] == nil })
        await #expect(throws: (any Error).self) { _ = try await browser.type("secret", into: "Password") }
        await #expect(throws: (any Error).self) { _ = try await browser.click("Nothing like this at all") }
    }

    /// Three pages of one site side by side in a folder, the first linking to the others, to a
    /// sign-out, a file and another site.
    static func pagesOfASite() throws -> URL {
        let first = try site("""
        <!doctype html><html><head><meta charset="utf-8"><title>Home</title></head><body style="font-family: Helvetica">
        <nav><a href="b.html">Second</a> <a href="c.html#top">Third</a> <a href="c.html">Third again</a>
        <a href="logout.html">Sign out</a> <a href="report.pdf">Report</a> <a href="https://example.com/">Elsewhere</a>
        <a href="mailto:a@example.com">Write</a></nav><h1>Home page</h1></body></html>
        """)
        let folder = first.deletingLastPathComponent()
        for (file, title) in [("b.html", "Second"), ("c.html", "Third"), ("logout.html", "Signed out")] {
            try "<!doctype html><html><head><title>\(title)</title></head><body><h1>\(title) page</h1><a href=\"index.html\">Home</a></body></html>"
                .write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return first
    }

    @Test(.timeLimit(.minutes(5))) func offersTheSitesPagesButNeverSigningOut() async throws {
        let browser = Self.browser()
        defer { browser.close() }
        let home = try Self.pagesOfASite()
        try await browser.open(home)
        let pages = await browser.findPages()
        #expect(pages.map(\.url.lastPathComponent) == ["index.html", "b.html", "c.html"])
        #expect(pages.map(\.kind) == [.open, .linked, .linked])
        #expect(pages[1].name == "Second" && pages[2].name == "Third")
        #expect(browser.chosen == [pages[0].id])
        // A page gone to and come back from is among those visited.
        _ = try await browser.click("Second")
        browser.back()
        try await browser.settle()
        #expect(await browser.findPages().map(\.kind) == [.open, .visited, .linked])
        #expect(WebSitePage.doesSomething(URL(string: "https://search.weblaw.ch/signout")!))
        #expect(WebSitePage.doesSomething(URL(string: "https://a.ch/de/abmelden?x=1")!))
        #expect(!WebSitePage.doesSomething(URL(string: "https://a.ch/account/searches")!))
    }

    @Test(.timeLimit(.minutes(5))) func bringsSeveralPagesInTogetherAsOneStep() async throws {
        let bench = Bench()
        MCPTools.opened(bench.store)
        defer { MCPTools.closed(bench.store) }
        let browser = Self.browser()
        defer { browser.close() }
        try await browser.open(try Self.pagesOfASite())
        let pages = await browser.findPages()
        let brought = try await browser.importPages(pages, into: bench.store)
        #expect(brought.store === bench.store && brought.ids.count == 3 && brought.missed.isEmpty)
        let boards = brought.ids.compactMap { bench.store.doc.node($0) }
        #expect(boards.map(\.name) == ["Home", "Second", "Third"])
        #expect(boards.map(\.frame.minY) == [100, 100, 100])
        #expect(zip(boards, boards.dropFirst()).allSatisfy { $0.frame.maxX < $1.frame.minX })
        #expect(boards.contains { Self.everything($0).compactMap(\.text).contains("Third page") })
        // The page open stays open as it was.
        #expect(browser.url?.lastPathComponent == "index.html")
        bench.undo.undo()
        #expect(bench.store.doc.nodes.map(\.name) == ["A", "B"])
    }

    @Test(.timeLimit(.minutes(5))) func theAssistantBrowsesAndBringsInWhatItSees() async throws {
        let bench = Bench()
        MCPTools.opened(bench.store)
        defer { MCPTools.closed(bench.store) }
        let tools = MCPTools()
        WebBrowser.shared.showsStash = false
        defer { WebBrowser.shared.close() }
        func call(_ name: String, _ arguments: [String: Any]) async -> (text: String, failed: Bool) {
            let result = await tools.call(name, arguments)
            let object = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let content = object?["content"] as? [[String: Any]] ?? []
            return (content.compactMap { $0["text"] as? String }.joined(separator: "\n"), object?["isError"] as? Bool == true)
        }
        #expect(tools.has("browse"))
        let nothing = await call("import_website", ["shown": true, "design": bench.store.name])
        #expect(nothing.failed && nothing.text.contains("no page open"))
        let page = try Self.site(Self.shell)
        let opened = await call("browse", ["action": "open", "url": page.absoluteString])
        #expect(!opened.failed && opened.text.contains("Open menu"))
        let clicked = await call("browse", ["action": "click", "target": "Open menu"])
        #expect(!clicked.failed && clicked.text.hasPrefix("Clicked button \"Open menu\"") && clicked.text.contains("Menu item one"))
        let brought = await call("import_website", ["shown": true, "design": bench.store.name, "name": "Menu open"])
        #expect(!brought.failed)
        let answer = Self.json(brought.text)
        let boards = answer["artboards"] as? [[String: Any]] ?? []
        #expect(boards.count == 1 && boards.first?["name"] as? String == "Menu open")
        #expect(bench.store.doc.nodes.count == 3)
        let password = await call("browse", ["action": "type", "target": 99, "text": "x"])
        #expect(password.failed)
        // Several pages at once, side by side in the design.
        let site = try Self.pagesOfASite().deletingLastPathComponent()
        let many = await call("import_website", ["urls": [site.appendingPathComponent("b.html").absoluteString, site.appendingPathComponent("c.html").absoluteString],
                                                 "design": bench.store.name])
        #expect(!many.failed)
        #expect((Self.json(many.text)["artboards"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["Second", "Third"])
        #expect(bench.store.doc.nodes.count == 5)
    }
}
