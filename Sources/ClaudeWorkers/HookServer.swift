import Foundation
import Network
import ClaudeWorkersCore

/// Minimal loopback-only HTTP server the hook shim POSTs to.
/// Runs on the main queue so it can talk to the @MainActor store directly.
final class HookServer {
    private let store: SessionStore
    private let token: String
    private var listener: NWListener?
    private(set) var port: UInt16?
    /// Control API: POST /jump?session=<id>
    var onJump: ((String) -> Bool)?
    /// Dev aid: renders the panel to `HiveWarden/snapshot.png` (POST /snapshot).
    var onSnapshot: (([String: String]) -> Void)?

    init(store: SessionStore, token: String) {
        self.store = store
        self.token = token
    }

    func start() throws {
        // Bind the socket itself to 127.0.0.1 (ephemeral port). `requiredInterfaceType`
        // alone still listens on the wildcard address.
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        l.stateUpdateHandler = { [weak self, weak l] state in
            guard let self, let l else { return }
            switch state {
            case .ready:
                if let p = l.port?.rawValue {
                    self.port = p
                    AppPaths.writePort(p)
                }
            case .failed(let err):
                NSLog("HiveWarden: listener failed: \(err)")
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn) }
        l.start(queue: .main)
        listener = l
    }

    func stop() {
        listener?.cancel()
        AppPaths.removePort()
    }

    // MARK: - Connection handling

    private func accept(_ conn: NWConnection) {
        conn.start(queue: .main)
        read(conn, buffer: Data())
    }

    private func read(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isDone, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if error != nil { conn.cancel(); return }

            switch Self.parse(buf) {
            case .incomplete:
                if isDone { conn.cancel() } else { self.read(conn, buffer: buf) }
            case .bad:
                self.respond(conn, status: "400 Bad Request", body: "")
            case .request(let req):
                self.dispatch(req, on: conn)
            }
        }
    }

    private func dispatch(_ req: Request, on conn: NWConnection) {
        guard req.method == "POST", ["/event", "/snapshot", "/decide", "/jump"].contains(req.path) else {
            return respond(conn, status: "404 Not Found", body: "")
        }
        guard req.token == token else {
            return respond(conn, status: "401 Unauthorized", body: "")
        }
        if req.path == "/decide" {
            // Control API: POST /decide?session=<id>&choice=allow|deny|terminal
            let choice: PermissionChoice? = ["allow": .allow, "deny": .deny, "terminal": .terminal][req.query["choice"] ?? ""]
            // We're on the main queue (the listener's queue), so this is already the main actor.
            let ok = MainActor.assumeIsolated { () -> Bool in
                guard let id = req.query["session"], let choice else { return false }
                return store.decidePermission(sessionID: id, choice: choice)
            }
            return respond(conn, status: ok ? "200 OK" : "404 Not Found", body: "")
        }
        if req.path == "/jump" {
            let ok = onJump?(req.query["session"] ?? "") ?? false
            return respond(conn, status: ok ? "200 OK" : "404 Not Found", body: "")
        }
        if req.path == "/snapshot" {
            onSnapshot?(req.query)
            return respond(conn, status: "200 OK", body: "")
        }
        guard let ev = HookEvent(data: req.body) else {
            return respond(conn, status: "422 Unprocessable Entity", body: "")
        }
        let meta = HookMeta(ppid: req.query["ppid"].flatMap { Int32($0) }, tty: req.query["tty"])
        let handle = RequestHandle()

        // Detect the shim hanging up (Claude killed the hook because you answered
        // in the terminal) so we can clear the card instead of leaving it stale.
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isDone, error in
            if isDone || error != nil { handle.cancel() }
        }

        let tag = "\(ev.sessionID.prefix(8)) \(ev.name)\(ev.toolName.map { " \($0)" } ?? "")"
        AppPaths.log("→ \(tag)")
        // The task tools' shapes are inferred, so keep evidence for when they show up.
        if ev.name == "PostToolUse", let t = ev.toolName, ["TodoWrite", "TaskCreate", "TaskUpdate"].contains(t) {
            let dump = HookReply.compact(["input": ev.toolInput, "response": ev.toolResponse ?? NSNull()])
            AppPaths.log("  \(t) payload: \(dump.prefix(600))")
        }
        Task { @MainActor in
            let body = await self.store.handle(ev, meta: meta, request: handle)
            if !body.isEmpty || ev.name == "PermissionRequest" || ev.toolName == "AskUserQuestion" {
                AppPaths.log("← \(tag) reply=\(body.isEmpty ? "(passthrough)" : String(body.prefix(160)))")
            }
            self.respond(conn, status: "200 OK", body: body)
        }
    }

    private func respond(_ conn: NWConnection, status: String, body: String) {
        let payload = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Tiny HTTP parser

    struct Request {
        var method: String
        var path: String
        var query: [String: String]
        var token: String?
        var body: Data
    }

    enum Parsed { case incomplete, bad, request(Request) }

    static func parse(_ data: Data) -> Parsed {
        let sep = Data("\r\n\r\n".utf8)
        guard let r = data.range(of: sep) else { return data.count > 64 * 1024 ? .bad : .incomplete }
        guard let head = String(data: data[..<r.lowerBound], encoding: .utf8) else { return .bad }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return .bad }

        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let i = l.firstIndex(of: ":") else { continue }
            headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[r.upperBound...]
        if body.count < length { return .incomplete }

        let comps = URLComponents(string: String(first[1]))
        var query: [String: String] = [:]
        for item in comps?.queryItems ?? [] { query[item.name] = item.value }
        return .request(Request(method: String(first[0]), path: comps?.path ?? "/",
                                query: query, token: headers["x-hivewarden-token"],
                                body: Data(body.prefix(length))))
    }
}
