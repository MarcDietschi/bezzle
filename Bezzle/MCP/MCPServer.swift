import Foundation
import Network
import Observation

/// Lets an AI assistant work in Bezzle through the Model Context Protocol. It is a small web
/// server on this Mac only, at `http://127.0.0.1:7412/mcp`, which the assistant sends JSON-RPC
/// to (MCP's "Streamable HTTP" transport, answered in plain JSON). What it asks for is done to the
/// designs open in their windows, as if by hand: it shows straight away, and undoes the same way.
/// `MCPTools` has what it can do.
///
/// With Claude Code: `claude mcp add --transport http bezzle http://127.0.0.1:7412/mcp`.
@Observable
final class MCPServer {
    static let shared = MCPServer()
    static let defaultPort: UInt16 = 7412
    private static let enabledKey = "aiControl"
    private static let env = ProcessInfo.processInfo.environment

    /// BEZZLE_MCP_PORT moves it, for a second copy of the app beside the first.
    let port: UInt16 = env["BEZZLE_MCP_PORT"].flatMap(UInt16.init) ?? defaultPort
    var address: String { "http://127.0.0.1:\(port)/mcp" }

    /// Why it is not running, when it was meant to be.
    private(set) var failure: String?
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private var connections: [ObjectIdentifier: Connection] = [:]
    @ObservationIgnored private let tools = MCPTools()

    /// Whether assistants may work in the app; on unless turned off in the Bezzle menu.
    var isEnabled: Bool {
        didSet {
            Library.settings.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private init() {
        isEnabled = Library.settings.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    /// When the app starts. Test runs, and debug runs with a library of their own, leave the port
    /// to the copy of the app in use, unless they are given one of their own.
    func launch() {
        if BezzleApp.isTesting { return }
        if Self.env["BEZZLE_LIBRARY"] != nil && Self.env["BEZZLE_MCP_PORT"] == nil { return }
        if isEnabled { start() }
    }

    private func start() {
        guard listener == nil, let port = NWEndpoint.Port(rawValue: port) else { return }
        failure = nil
        do {
            let parameters = NWParameters.tcp
            // Nothing beyond this Mac can reach it.
            parameters.requiredInterfaceType = .loopback
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters, on: port)
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            fail(error)
        }
    }

    private func stop() {
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.close() }
        connections = [:]
        failure = nil
    }

    private func listenerChanged(_ state: NWListener.State) {
        if case .failed(let error) = state {
            listener?.cancel()
            listener = nil
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        if case NWError.posix(.EADDRINUSE) = error {
            failure = String(localized: "Port \(Int(port)) is in use")
        } else {
            failure = error.localizedDescription
        }
        NSLog("Bezzle could not start its AI server on port %d: %@", Int(port), failure ?? "")
    }

    private func accept(_ nw: NWConnection) {
        let connection = Connection(nw, server: self)
        connections[ObjectIdentifier(connection)] = connection
        connection.start()
    }

    fileprivate func closed(_ connection: Connection) {
        connections[ObjectIdentifier(connection)] = nil
    }

    // MARK: Answering

    fileprivate func respond(to request: HTTPRequest) async -> HTTPResponse {
        // A web page in a browser on this Mac could otherwise reach it, under a name of its own
        // that it points here (DNS rebinding).
        guard Self.isLocal(request.headers["host"]), request.headers["origin"].map({ Self.isLocal(URL(string: $0)?.host) }) ?? true else {
            let refusal: JSONValue = ["error": "Only apps on this Mac may use Bezzle's AI server."]
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

    /// Whether a host named in a request is this Mac.
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
        default:
            return Self.rpcError(id: id, code: -32601, "Bezzle does not know \(method).")
        }
        return ["jsonrpc": "2.0", "id": JSONValue(id), "result": result]
    }

    private static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    func initialize(_ params: [String: Any]) -> JSONValue {
        let asked = params["protocolVersion"] as? String
        let version = asked.flatMap { Self.protocolVersions.contains($0) ? $0 : nil } ?? Self.protocolVersions[0]
        let info = Bundle.main.infoDictionary
        return [
            "protocolVersion": .string(version),
            "capabilities": ["tools": ["listChanged": false]],
            "serverInfo": ["name": "bezzle", "title": "Bezzle", "version": .string(info?["CFBundleShortVersionString"] as? String ?? "0")],
            "instructions": .string(MCPTools.instructions),
        ]
    }

    private static func rpcError(id: Any?, code: Int, _ message: String) -> JSONValue {
        ["jsonrpc": "2.0", "id": JSONValue(id), "error": ["code": .number(code), "message": .string(message)]]
    }
}

// MARK: - HTTP

private struct HTTPRequest {
    var method: String
    var path: String
    /// Names in lower case.
    var headers: [String: String]
    var body: Data
}

private struct HTTPResponse {
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

/// One client's connection: its requests read and answered one after another.
private final class Connection {
    private let connection: NWConnection
    private weak var server: MCPServer?
    private var buffer = Data()
    private var answering = false
    private var closing = false
    /// A request holding a picture of a design to place is the largest there is.
    private static let largest = 64 << 20

    init(_ connection: NWConnection, server: MCPServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        connection.cancel()
    }

    private func finish() {
        connection.stateUpdateHandler = nil
        server?.closed(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if complete || error != nil { self.closing = true }
                self.next()
            }
        }
    }

    /// Answers the next request once it has all come in, or reads more.
    private func next() {
        guard !answering else { return }
        switch Self.parse(&buffer) {
        case .incomplete:
            if closing { close() } else { receive() }
        case .invalid(let status):
            send(HTTPResponse(status: status), keepAlive: false)
        case .request(let request):
            answering = true
            let keepAlive = request.headers["connection"]?.lowercased() != "close" && !closing
            Task {
                guard let response = await server?.respond(to: request) else { return close() }
                answering = false
                send(response, keepAlive: keepAlive)
            }
        }
    }

    private func send(_ response: HTTPResponse, keepAlive: Bool) {
        connection.send(content: response.encoded(keepAlive: keepAlive), completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if keepAlive { self.next() } else { self.close() }
            }
        })
    }

    private enum Parsed {
        case incomplete
        case invalid(Int)
        case request(HTTPRequest)
    }

    /// Takes one whole request off the front of `buffer`, if it has come in.
    private static func parse(_ buffer: inout Data) -> Parsed {
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
