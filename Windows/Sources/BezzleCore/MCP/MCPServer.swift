import Foundation
import Synchronization
import WinSDK

// From Bezzle/MCP/MCPServer.swift, for Windows: lets an AI assistant work in Bezzle through the
// Model Context Protocol. It is a small web server on this PC only, at http://127.0.0.1:7412/mcp,
// which the assistant sends JSON-RPC to (MCP's "Streamable HTTP" transport, answered in plain
// JSON). What it asks for is done to the design open in the window, as if by hand: it shows
// straight away, and undoes the same way. Each connection is read on a thread of its own; what
// it asks is answered on the main thread, where the design is.
//
// With Claude Code: `claude mcp add --transport http bezzle http://127.0.0.1:7412/mcp`.

@MainActor public final class MCPServer {
    public static let shared = MCPServer()
    public static let defaultPort: UInt16 = 7412

    /// BEZZLE_MCP_PORT moves it, for a second copy of the app beside the first.
    public let port: UInt16 = ProcessInfo.processInfo.environment["BEZZLE_MCP_PORT"].flatMap(UInt16.init) ?? defaultPort
    public var address: String { "http://127.0.0.1:\(port)/mcp" }
    /// The app's version, as it says it when an assistant connects.
    public var version = "0"
    /// Why it is not running, when it was meant to be.
    public private(set) var failure: String?
    /// Told when it stops for good, as its port is taken.
    public var failed: ((String) -> Void)?
    private lazy var tools = MCPTools()
    private var started = false

    /// Starts listening, unless it is.
    public func start() {
        guard !started else { return }
        started = true
        failure = nil
        let port = port
        Thread.detachNewThread { Self.run(port: port) }
    }

    /// Stops listening: assistants can no longer reach Bezzle until it starts again.
    public func stop() {
        guard started else { return }
        started = false
        failure = nil
        Self.stopListening()
    }

    public var isRunning: Bool { started }

    fileprivate func fail(_ why: String) {
        failure = why
        failed?(why)
    }

    // MARK: Answering

    fileprivate func respond(to request: HTTPRequest) async -> HTTPResponse {
        // A web page in a browser on this PC could otherwise reach it, under a name of its own
        // that it points here (DNS rebinding).
        guard Self.isLocal(request.headers["host"]), request.headers["origin"].map({ Self.isLocal(URL(string: $0)?.host) }) ?? true else {
            let refusal: JSONValue = ["error": "Only apps on this PC may use Bezzle's AI server."]
            return HTTPResponse(status: 403, body: refusal.data)
        }
        let path = request.path.split(separator: "?").first.map(String.init) ?? request.path
        guard path == "/mcp" || path == "/" else { return HTTPResponse(status: 404) }
        switch request.method {
        case "POST":
            guard let answer = await answer(request.body) else { return HTTPResponse(status: 202) }
            return HTTPResponse(status: 200, body: answer.data)
        default:
            // Nothing is ever sent unasked, so there is no stream to listen to, and no session to end.
            return HTTPResponse(status: 405, headers: ["Allow": "POST"])
        }
    }

    /// Whether a host named in a request is this PC.
    private static func isLocal(_ host: String?) -> Bool {
        guard var host = host?.lowercased() else { return false }
        if host.hasPrefix("[") {
            host = String(host.dropFirst().prefix { $0 != "]" })
        } else if host.filter({ $0 == ":" }).count == 1 {
            host = String(host.prefix { $0 != ":" })
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// The answer to a JSON-RPC message, or to a list of them; nil when nothing needs one.
    private func answer(_ body: Data) async -> JSONValue? {
        guard let message = try? JSONSerialization.jsonObject(with: body) else {
            return Self.rpcError(id: nil, code: -32700, "That was not JSON.")
        }
        if let batch = message as? [Any] {
            var answers: [JSONValue] = []
            for item in batch { if let a = await answerOne(item) { answers.append(a) } }
            return answers.isEmpty ? nil : .array(answers)
        }
        return await answerOne(message)
    }

    private func answerOne(_ message: Any) async -> JSONValue? {
        guard let message = message as? [String: Any] else { return Self.rpcError(id: nil, code: -32600, "Expected a JSON-RPC message.") }
        let id = message["id"].flatMap { $0 is NSNull ? nil : $0 }
        // A notification, or an answer to something never asked: nothing to say back.
        guard let method = message["method"] as? String else { return nil }
        guard let id else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: JSONValue
        switch method {
        case "initialize":
            result = initialize(params)
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": .array(tools.list)]
        case "tools/call":
            guard let name = params["name"] as? String else { return Self.rpcError(id: id, code: -32602, "tools/call needs a tool name.") }
            guard tools.has(name) else { return Self.rpcError(id: id, code: -32602, "There is no tool called \(name).") }
            result = await tools.call(name, params["arguments"] as? [String: Any] ?? [:])
        case "prompts/list":
            result = ["prompts": .array(tools.promptList)]
        case "prompts/get":
            guard let name = params["name"] as? String else { return Self.rpcError(id: id, code: -32602, "prompts/get needs a prompt name.") }
            guard MCPTools.prompts.contains(where: { $0.name == name }) else { return Self.rpcError(id: id, code: -32602, "There is no prompt called \(name).") }
            do {
                result = try await tools.prompt(name, params["arguments"] as? [String: Any] ?? [:])
            } catch let error as MCPError {
                return Self.rpcError(id: id, code: -32603, error.message)
            } catch {
                return Self.rpcError(id: id, code: -32603, "\(error)")
            }
        default:
            return Self.rpcError(id: id, code: -32601, "Bezzle does not know \(method).")
        }
        return ["jsonrpc": "2.0", "id": JSONValue(id), "result": result]
    }

    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    func initialize(_ params: [String: Any]) -> JSONValue {
        let asked = params["protocolVersion"] as? String
        let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false], "prompts": ["listChanged": false]],
            "serverInfo": ["name": "bezzle", "title": "Bezzle", "version": .string(self.version)],
            "instructions": .string(MCPTools.instructions),
        ]
    }

    private static func rpcError(id: Any?, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": JSONValue(id), "error": ["code": .number(code), "message": .string(message)]]
    }

    /// The tools' names, for trying the server.
    public var toolNames: [String] { tools.names }

    // MARK: Listening

    /// Listens on this PC's own address for good, a thread for each connection.
    nonisolated private static func run(port: UInt16) {
        var startup = WSADATA()
        guard WSAStartup(0x0202, &startup) == 0 else { return failed("Windows' sockets could not be started.") }
        let listener = socket(AF_INET, Int32(SOCK_STREAM), Int32(IPPROTO_TCP.rawValue))
        guard listener != INVALID_SOCKET else { return failed("No socket could be made.") }
        // Nothing beyond this PC can reach it, and no other program may share the port
        // (SO_EXCLUSIVEADDRUSE, which is ~SO_REUSEADDR).
        var exclusive: Int32 = 1
        _ = withUnsafeBytes(of: &exclusive) { setsockopt(listener, SOL_SOCKET, ~SO_REUSEADDR, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count)) }
        var address = sockaddr_in()
        address.sin_family = ADDRESS_FAMILY(AF_INET)
        address.sin_port = htons(port)
        address.sin_addr.S_un.S_addr = htonl(0x7F00_0001)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, Int32(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, WinSDK.listen(listener, SOMAXCONN) == 0 else {
            closesocket(listener)
            return failed("Port \(port) is in use")
        }
        listening.withLock { $0 = listener }
        while true {
            let client = accept(listener, nil, nil)
            guard client != INVALID_SOCKET else {
                // Stopped: the socket listened on was closed under it.
                if listening.withLock({ $0 }) != listener { return }
                continue
            }
            Thread.detachNewThread { serve(client) }
        }
    }

    /// The socket listened on, while it is.
    nonisolated private static let listening = Mutex<SOCKET>(INVALID_SOCKET)

    nonisolated private static func stopListening() {
        let socket = listening.withLock { s -> SOCKET in
            let was = s
            s = INVALID_SOCKET
            return was
        }
        if socket != INVALID_SOCKET { closesocket(socket) }
    }

    nonisolated private static func failed(_ why: String) {
        DispatchQueue.main.async { MainActor.assumeIsolated { MCPServer.shared.fail(why) } }
    }

    /// One client's connection: its requests read and answered one after another.
    nonisolated private static func serve(_ client: SOCKET) {
        defer { closesocket(client) }
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            switch HTTPRequest.parse(&buffer) {
            case .incomplete:
                let n = chunk.withUnsafeMutableBytes { recv(client, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count), 0) }
                guard n > 0 else { return }
                buffer.append(contentsOf: chunk[0..<Int(n)])
            case .invalid(let status):
                send(HTTPResponse(status: status).encoded(keepAlive: false), to: client)
                return
            case .request(let request):
                let keepAlive = request.headers["connection"]?.lowercased() != "close"
                let response = answered(request)
                guard send(response.encoded(keepAlive: keepAlive), to: client), keepAlive else { return }
            }
        }
    }

    /// The answer to a request, worked out on the main thread while this one waits.
    nonisolated private static func answered(_ request: HTTPRequest) -> HTTPResponse {
        final class Box: @unchecked Sendable { var response = HTTPResponse(status: 500) }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            Task { @MainActor in
                box.response = await MCPServer.shared.respond(to: request)
                done.signal()
            }
        }
        done.wait()
        return box.response
    }

    @discardableResult
    nonisolated private static func send(_ data: Data, to client: SOCKET) -> Bool {
        var sent = 0
        let bytes = [UInt8](data)
        while sent < bytes.count {
            let n = bytes[sent...].withUnsafeBytes { WinSDK.send(client, $0.baseAddress?.assumingMemoryBound(to: CChar.self), Int32($0.count), 0) }
            guard n > 0 else { return false }
            sent += Int(n)
        }
        return true
    }
}

// MARK: - HTTP

nonisolated fileprivate struct HTTPRequest: Sendable {
    var method: String
    var path: String
    /// Names in lower case.
    var headers: [String: String]
    var body: Data

    enum Parsed {
        case incomplete
        case invalid(Int)
        case request(HTTPRequest)
    }

    /// A request holding a picture of a design to place is the largest there is.
    static let largest = 64 << 20

    /// Takes one whole request off the front of `buffer`, if it has come in.
    static func parse(_ buffer: inout Data) -> Parsed {
        guard let end = buffer.firstRange(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 << 10 ? .invalid(400) : .incomplete
        }
        guard let head = String(data: buffer[buffer.startIndex..<end.lowerBound], encoding: .utf8) else { return .invalid(400) }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .invalid(400) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let start = end.upperBound
        var body = Data()
        var consumed: Data.Index
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            guard let (decoded, after) = dechunk(buffer, from: start) else { return .incomplete }
            body = decoded
            consumed = after
        } else {
            let length = Int(headers["content-length"] ?? "0") ?? -1
            guard length >= 0 else { return .invalid(400) }
            guard length <= largest else { return .invalid(413) }
            guard buffer.endIndex - start >= length else { return .incomplete }
            body = buffer[start..<start + length]
            consumed = start + length
        }
        let request = HTTPRequest(method: String(first[0]), path: String(first[1]), headers: headers, body: Data(body))
        buffer = Data(buffer[consumed...])
        return .request(request)
    }

    /// A body sent in chunks, put back together, and where the request ends; nil until it has all come.
    private static func dechunk(_ buffer: Data, from start: Data.Index) -> (Data, Data.Index)? {
        var body = Data(), at = start
        let crlf = Data("\r\n".utf8)
        while true {
            guard let lineEnd = buffer[at...].firstRange(of: crlf),
                  let sizeLine = String(data: buffer[at..<lineEnd.lowerBound], encoding: .utf8),
                  let size = Int(sizeLine.split(separator: ";").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "", radix: 16)
            else { return nil }
            let chunk = lineEnd.upperBound
            guard buffer.endIndex - chunk >= size + 2 else { return nil }
            if size == 0 {
                // No trailers are sent in practice: the last chunk ends with an empty line.
                guard let close = buffer[chunk...].firstRange(of: crlf) else { return nil }
                return (body, close.upperBound)
            }
            body += buffer[chunk..<chunk + size]
            at = chunk + size + 2
        }
    }
}

nonisolated fileprivate struct HTTPResponse: Sendable {
    var status: Int
    var headers: [String: String] = [:]
    var body = Data()

    func encoded(keepAlive: Bool) -> Data {
        let reasons = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 413: "Content Too Large"]
        var head = "HTTP/1.1 \(status) \(reasons[status] ?? "Error")\r\n"
        var all = headers
        if !body.isEmpty { all["Content-Type"] = "application/json" }
        all["Content-Length"] = String(body.count)
        all["Connection"] = keepAlive ? "keep-alive" : "close"
        for (name, value) in all.sorted(by: { $0.key < $1.key }) { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}
