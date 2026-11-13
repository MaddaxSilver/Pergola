import Foundation
import Network
import Observation
import AppKit

/// Pergola's door for other apps: a tiny HTTP API on this Mac only (127.0.0.1), plus an MCP server on
/// the same port at /mcp. See INTEGRATIONS.md for the full reference.
///
///     POST   /activity        create or update   {"id": "export-1", "app": "CamCam", "title": "Exporting", "progress": 0.4}
///     DELETE /activity/<id>   remove
///     GET    /activities      list
///     GET    /health
///     POST   /mcp             Model Context Protocol (JSON-RPC)
@Observable @MainActor
final class PergolaAPI {
    nonisolated static let defaultPort = 47600
    /// Where the port in use is written, so clients can find it if the default was taken.
    nonisolated static var infoURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pergola/api.json")
    }

    private(set) var port: Int?
    /// Reports from the Safari extension about the video on the page; the reply goes back to it.
    @ObservationIgnored var onVideoReport: (([String: Any]) -> [String: Any])?
    @ObservationIgnored var onVideoDebug: (() -> [String: Any])?
    @ObservationIgnored var onVideoFrame: ((Data) -> [String: Any])?
    @ObservationIgnored private let activities: Activities
    @ObservationIgnored private var listener: NWListener?
    @ObservationIgnored private let queue = DispatchQueue(label: "pergola.api")

    init(activities: Activities) { self.activities = activities }

    func setEnabled(_ on: Bool) {
        if on {
            if listener == nil { listen(on: Self.defaultPort) }
        } else {
            listener?.cancel(); listener = nil; port = nil
            try? FileManager.default.removeItem(at: Self.infoURL)
            activities.removeAll()
        }
    }

    private func listen(on port: Int) {
        guard port < Self.defaultPort + 10, let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only: nothing off this Mac can reach it.
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: nwPort)
        guard let l = try? NWListener(using: params) else { listen(on: port + 1); return }
        listener = l
        l.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.listener === l else { return }
                    switch state {
                    case .ready:
                        self.port = port
                        let url = Self.infoURL
                        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try? JSONSerialization.data(withJSONObject: ["port": port, "pid": ProcessInfo.processInfo.processIdentifier])
                            .write(to: url, options: .atomic)
                    case .failed, .waiting:
                        // Port taken: try the next one.
                        l.cancel(); self.listener = nil
                        self.listen(on: port + 1)
                    default: break
                    }
                }
            }
        }
        l.newConnectionHandler = { [weak self] c in self?.accept(c) }
        l.start(queue: queue)
    }

    // MARK: HTTP

    private nonisolated func accept(_ c: NWConnection) {
        c.start(queue: queue)
        read(c, buffer: Data())
        // Never hold a half-sent request open.
        queue.asyncAfter(deadline: .now() + 10) { c.cancel() }
    }

    private nonisolated func read(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, done, error in
            guard let self else { c.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count <= 4_194_304 else { self.reply(c, 413, ["error": "Request too large"]); return }
            if let request = HTTPRequest(buffer) {
                DispatchQueue.main.async {
                    let (status, body, headers) = MainActor.assumeIsolated { self.route(request) }
                    self.reply(c, status, body, headers)
                }
            } else if done || error != nil {
                c.cancel()
            } else {
                self.read(c, buffer: buffer)
            }
        }
    }

    private nonisolated func reply(_ c: NWConnection, _ status: Int, _ body: Any?, _ headers: [String: String] = [:]) {
        let payload = body.flatMap { $0 as? Data ?? (try? JSONSerialization.data(withJSONObject: $0)) } ?? Data()
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      405: "Method Not Allowed", 413: "Payload Too Large"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(payload.count)\r\nConnection: close\r\n"
        if !payload.isEmpty { head += "Content-Type: application/json\r\n" }
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        c.send(content: Data((head + "\r\n").utf8) + payload, completion: .contentProcessed { _ in c.cancel() })
    }

    private func route(_ r: HTTPRequest) -> (Int, Any?, [String: String]) {
        // Web pages must not be able to poke this from a browser: they always send an Origin, and a
        // page that re-points its own domain at 127.0.0.1 still sends its own Host.
        // The one exception: Pergola's own Safari extension reporting where a video is (POST /video).
        if let origin = r.headers["origin"] {
            Log.media.info("api \(r.method, privacy: .public) \(r.path, privacy: .public) origin=\(origin, privacy: .public)")
            guard origin.hasPrefix("safari-web-extension://"), r.method == "POST" || r.method == "OPTIONS",
                  r.path == "/video" || r.path == "/video/frame" else {
                return (403, ["error": "Browser requests are not allowed"], [:])
            }
            // Answered with CORS headers, so the extension needs no extra site permission to reach us.
            let cors = ["Access-Control-Allow-Origin": origin, "Access-Control-Allow-Methods": "POST",
                        "Access-Control-Allow-Headers": "Content-Type"]
            if r.method == "OPTIONS" { return (200, nil, cors) }
            if r.path == "/video/frame" { return (200, onVideoFrame?(r.body) ?? [:], cors) }
            let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any] ?? [:]
            return (200, onVideoReport?(json) ?? [:], cors)
        }
        let host = (r.headers["host"] ?? "").split(separator: ":").first.map(String.init) ?? ""
        guard ["127.0.0.1", "localhost"].contains(host) else { return (403, ["error": "Bad Host"], [:]) }
        if r.method == "POST", !(r.headers["content-type"] ?? "").lowercased().contains("application/json") {
            return (400, ["error": "Send Content-Type: application/json"], [:])
        }
        if r.path == "/mcp" {
            guard r.method == "POST" else { return (405, ["error": "POST JSON-RPC here"], [:]) }
            let before = r.headers["mcp-session-id"]
            var session = before
            let answer = MCP.respond(to: r.body, session: &session) { method, path, body in self.call(method, path, body) }
            let extra = session != before ? session.map { ["Mcp-Session-Id": $0] } ?? [:] : [:]
            return answer.map { (200, $0 as Any?, extra) } ?? (202, nil, [:])
        }
        let json = (try? JSONSerialization.jsonObject(with: r.body)) as? [String: Any]
        if r.method == "POST", !r.body.isEmpty, json == nil { return (400, ["error": "Body must be a JSON object"], [:]) }
        let (status, body) = call(r.method, r.path, json)
        return (status, body, [:])
    }

    /// The API itself, shared by HTTP and the in-app MCP endpoint.
    func call(_ method: String, _ path: String, _ body: [String: Any]?) -> (Int, Any?) {
        let parts = path.split(separator: "?")[0].split(separator: "/").map { String($0).removingPercentEncoding ?? String($0) }
        switch (method, parts.first, parts.count) {
        case ("GET", "health", 1):
            return (200, ["app": "Pergola", "ok": true])
        case ("GET", "activities", 1):
            return (200, ["activities": activities.items.map(\.json)])
        case ("POST", "activity", 1):
            guard let a = activities.upsert(body ?? [:]) else { return (400, ["error": "\"id\" is required"]) }
            return (200, a.json)
        case ("GET", "video", 1):
            return (200, onVideoDebug?() ?? [:])
        case ("POST", "video", 1):
            return (200, onVideoReport?(body ?? [:]) ?? [:])
        case ("DELETE", "activity", 2):
            return activities.remove(id: parts[1]) ? (200, ["ok": true]) : (404, ["error": "No such activity"])
        default:
            return (404, ["error": "Unknown route"])
        }
    }
}

private struct HTTPRequest {
    var method = ""
    var path = ""
    var headers: [String: String] = [:]
    var body = Data()

    /// Nil until the whole request (headers and declared body) has arrived.
    init?(_ data: Data) {
        guard let split = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count >= 2 else { return nil }
        method = String(first[0]).uppercased()
        path = String(first[1])
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "") ?? 0
        let rest = data[split.upperBound...]
        guard rest.count >= length else { return nil }
        body = Data(rest.prefix(length))
    }
}

// MARK: - MCP

/// A small Model Context Protocol server: lets Claude (or any MCP client) put its task in the notch.
/// Runs inside the app at POST /mcp, and as a stdio server via `Pergola --mcp`.
enum MCP {
    typealias API = (_ method: String, _ path: String, _ body: [String: Any]?) -> (Int, Any?)

    static let tools: [[String: Any]] = [
        ["name": "show_activity",
         "description": "Show or update a live task in the Mac's notch (Pergola): a title, a short status line and a progress ring. Call it when you start a multi-step task, again whenever the step or progress changes (same id), and finish with end_activity. Omitted fields keep their previous values.",
         "inputSchema": ["type": "object", "required": ["id"], "properties": [
            "id": ["type": "string", "description": "Stable id for this task; reuse it for every update."],
            "title": ["type": "string", "description": "Short name of the task, e.g. \"Refactoring auth\"."],
            "detail": ["type": "string", "description": "What is happening right now, e.g. \"Running tests\"."],
            "progress": ["type": "number", "description": "How far along, 0 to 1. Leave out for a spinner."],
            "step": ["type": "number", "description": "Steps finished so far (use with total_steps instead of progress)."],
            "total_steps": ["type": "number", "description": "Total number of steps."],
            "state": ["type": "string", "enum": ["running", "waiting"], "description": "\"waiting\" when you need the user."],
            "app": ["type": "string", "description": "Your own product name, e.g. \"ChatGPT\", \"Codex\", \"Gemini\", \"Cursor\", \"Claude\". It picks the icon shown in the notch. Detected from the MCP client when left out."],
            "symbol": ["type": "string", "description": "SF Symbol name for the icon. Leave out to get your product's own mark."],
            "tint": ["type": "string", "description": "Ring colour as hex, e.g. \"#D97757\". Leave out for your product's colour."]] as [String: Any]] as [String: Any]],
        ["name": "start_timer",
         "description": "Start a countdown timer in the Mac's notch (Pergola). It shows the time left beside the notch, chimes and shows a tick when it ends. Cancel it with end_activity and the returned id.",
         "inputSchema": ["type": "object", "required": ["duration"], "properties": [
            "duration": ["type": "string", "description": "How long, e.g. \"5m\", \"90s\", \"1h30m\", \"2:30\" or a number of seconds."],
            "title": ["type": "string", "description": "What it is for, e.g. \"Tea\". Defaults to \"Timer\"."]] as [String: Any]] as [String: Any]],
        ["name": "end_activity",
         "description": "Finish a task shown with show_activity. It shows a tick (or a cross if failed) for a few seconds, then leaves the notch.",
         "inputSchema": ["type": "object", "required": ["id"], "properties": [
            "id": ["type": "string"],
            "state": ["type": "string", "enum": ["done", "failed"], "description": "Defaults to done."],
            "detail": ["type": "string", "description": "Optional closing line, e.g. \"12 files changed\"."]] as [String: Any]] as [String: Any]],
        ["name": "list_activities",
         "description": "List the live tasks currently shown in the notch, from every app.",
         "inputSchema": ["type": "object", "properties": [String: Any]()] as [String: Any]],
    ]

    /// Who is on the other end of each MCP session (from `initialize`), so their tasks carry their name.
    nonisolated(unsafe) private static var clients: [String: String] = [:]
    nonisolated(unsafe) private static var lastClient: String?

    /// Answers one JSON-RPC message. Nil for notifications, which get no reply.
    /// `session` is the caller's MCP session id; `initialize` starts a new one and writes it back.
    static func respond(to data: Data, session: inout String?, api: API) -> Data? {
        guard let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        guard let id = msg["id"], !(id is NSNull) else { return nil }
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]
        func ok(_ result: [String: Any]) -> Data? { encode(["jsonrpc": "2.0", "id": id, "result": result]) }

        switch method {
        case "initialize":
            let asked = params["protocolVersion"] as? String ?? ""
            let version = ["2025-06-18", "2025-03-26", "2024-11-05"].contains(asked) ? asked : "2025-06-18"
            let info = params["clientInfo"] as? [String: Any] ?? [:]
            let names = [info["title"] as? String, info["name"] as? String].compactMap { $0 }.filter { !$0.isEmpty }
            // A name Pergola knows ("codex-mcp-client" → ChatGPT) wins; otherwise the client's own name.
            let client = names.compactMap { AIBrand.match($0)?.name }.first ?? names.first.map { String($0.prefix(40)) }
            let sid = UUID().uuidString
            if clients.count > 200 { clients.removeAll() }
            clients[sid] = client
            lastClient = client
            session = sid
            return ok(["protocolVersion": version,
                       "capabilities": ["tools": [String: Any]()],
                       "serverInfo": ["name": "pergola", "title": "Pergola", "version": "1.0"],
                       "instructions": "Pergola shows live task progress in the Mac's notch. For any multi-step task, call show_activity at the start, update it as steps complete, and call end_activity when finished."])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": tools])
        case "tools/call":
            let client = session.flatMap { clients[$0] } ?? lastClient
            let (text, failed) = run(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:], client, api)
            return ok(["content": [["type": "text", "text": text]], "isError": failed])
        default:
            return encode(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found: \(method)"]])
        }
    }

    private static func run(_ tool: String, _ args: [String: Any], _ client: String?, _ api: API) -> (String, Bool) {
        func describe(_ status: Int, _ json: Any?, _ success: String) -> (String, Bool) {
            if status == 200 { return (success, false) }
            if status == 0 { return ("Pergola isn't running (or its app integrations are switched off in Settings).", true) }
            return ((json as? [String: Any])?["error"] as? String ?? "Pergola returned \(status)", true)
        }
        switch tool {
        case "show_activity":
            var body = args
            // Known AI tools get their own mark from their name; anything else gets a plain spark.
            let app = (body["app"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? client ?? "Claude"
            body["app"] = app
            if body["symbol"] == nil, AIBrand.match(app) == nil { body["symbol"] = "sparkle" }
            let (s, j) = api("POST", "/activity", body)
            return describe(s, j, "Shown in the notch.")
        case "start_timer":
            let text = (args["duration"] as? String) ?? (args["duration"] as? NSNumber).map { "\($0)" } ?? ""
            guard let body = PergolaCLI.timerBody(duration: text, title: args["title"] as? String) else {
                return ("Couldn't read that duration. Try \"5m\", \"90s\" or \"1h30m\".", true)
            }
            let (s, j) = api("POST", "/activity", body)
            return describe(s, j, "Timer started (id \(body["id"] ?? "")).")
        case "end_activity":
            var body: [String: Any] = ["id": args["id"] ?? "", "state": args["state"] as? String ?? "done"]
            if let d = args["detail"] { body["detail"] = d }
            let (s, j) = api("POST", "/activity", body)
            return describe(s, j, "Ended.")
        case "list_activities":
            let (s, j) = api("GET", "/activities", nil)
            let text = j.flatMap { try? JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
                .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            return describe(s, j, text)
        default:
            return ("Unknown tool: \(tool)", true)
        }
    }

    private static func encode(_ object: [String: Any]) -> Data? { try? JSONSerialization.data(withJSONObject: object) }
}

// MARK: - Command line

/// Ways to reach a running Pergola from a terminal, a script or Claude, using the app's own binary:
///
///     Pergola --mcp                         MCP server over stdio (for Claude Desktop and other clients)
///     Pergola --activity '{"id": …}'        create or update an activity
///     Pergola --end-activity <id>           remove one
///     Pergola --timer 5m [title]            start a countdown ("90s", "1h30m", "2:30" also work)
///     Pergola --claude-hook                 Claude Code hook: reads the hook's JSON on stdin
///
/// Each runs without starting the app's UI, and exits.
enum PergolaCLI {
    static func runIfNeeded(_ args: [String]) {
        if args.contains("--mcp") { mcp(); exit(0) }
        if args.contains("--claude-hook") { ClaudeHook.run(); exit(0) }
        if let i = args.firstIndex(of: "--activity"), i + 1 < args.count {
            let body = (try? JSONSerialization.jsonObject(with: Data(args[i + 1].utf8))) as? [String: Any]
            let (status, json) = http("POST", "/activity", body)
            if status != 200 { FileHandle.standardError.write(Data("\((json as? [String: Any])?["error"] ?? "Pergola isn't reachable")\n".utf8)) }
            exit(status == 200 ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--timer"), i + 1 < args.count {
            let title = args.count > i + 2 ? args[(i + 2)...].joined(separator: " ") : nil
            guard let body = timerBody(duration: args[i + 1], title: title) else {
                FileHandle.standardError.write(Data("Couldn't read that duration. Try 5m, 90s or 1h30m.\n".utf8))
                exit(2)
            }
            exit(http("POST", "/activity", body).0 == 200 ? 0 : 1)
        }
        if let i = args.firstIndex(of: "--end-activity"), i + 1 < args.count {
            let id = args[i + 1].addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? args[i + 1]
            exit(http("DELETE", "/activity/\(id)", nil).0 == 200 ? 0 : 1)
        }
    }

    /// The activity that is a Pergola timer: a countdown that chimes when it ends.
    static func timerBody(duration: String, title: String?) -> [String: Any]? {
        guard let seconds = DurationText.seconds(duration) else { return nil }
        let name = title.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Timer"
        return ["id": "timer-\(UUID().uuidString.prefix(8).lowercased())", "app": "Pergola", "title": name,
                "detail": DurationText.spoken(seconds), "symbol": "timer", "tint": "#FF9F0A", "timer": seconds, "chime": true]
    }

    static var port: Int {
        let info = (try? Data(contentsOf: PergolaAPI.infoURL)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return info?["port"] as? Int ?? PergolaAPI.defaultPort
    }

    /// A blocking request to the running app. Status 0 means it couldn't be reached.
    static func http(_ method: String, _ path: String, _ body: [String: Any]?, timeout: Double = 3) -> (Int, Any?) {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else { return (0, nil) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.httpMethod = method
        if method == "POST" {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body ?? [:])
        }
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: (Int, Any?) = (0, nil)
        URLSession.shared.dataTask(with: req) { data, response, _ in
            result = ((response as? HTTPURLResponse)?.statusCode ?? 0, data.flatMap { try? JSONSerialization.jsonObject(with: $0) })
            done.signal()
        }.resume()
        done.wait()
        return result
    }

    private static func mcp() {
        var session: String?
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty,
                  let answer = MCP.respond(to: Data(line.utf8), session: &session, api: { http($0, $1, $2) }) else { continue }
            FileHandle.standardOutput.write(answer + Data("\n".utf8))
        }
    }
}

/// Turns Claude Code's hook events into a live activity, so the notch shows what Claude is doing and
/// how far through its task list it is, with no effort from Claude itself.
enum ClaudeHook {
    static func run() {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        guard let hook = (try? JSONSerialization.jsonObject(with: input)) as? [String: Any],
              let session = hook["session_id"] as? String, !session.isEmpty else { return }
        let id = "claude-\(session.prefix(8))"
        let event = hook["hook_event_name"] as? String ?? ""
        let tool = hook["tool_name"] as? String ?? ""
        let toolInput = hook["tool_input"] as? [String: Any] ?? [:]
        let project = (hook["cwd"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""
        var plan = Plan.load(session)

        var body: [String: Any] = ["id": id, "app": "Claude", "symbol": "sparkle", "tint": "#D97757", "ttl": 660,
                                   "title": project.isEmpty || project.count > 28 ? "Claude" : "Claude · \(project)"]
        if let transcript = hook["transcript_path"] as? String { body["transcript"] = transcript }
        // The app this session lives in (Claude's desktop app, Terminal, an editor…): a click on the task opens it.
        if let host = ProcessInfo.processInfo.environment["__CFBundleIdentifier"], !host.isEmpty { body["opens"] = host }
        switch event {
        case "UserPromptSubmit":
            body["state"] = "running"
            body["detail"] = "Thinking…"
        case "PreToolUse":
            body["state"] = "running"
            body["detail"] = plan.note(tool: tool, input: toolInput) ?? describe(tool: tool, input: toolInput)
        case "Notification":
            // "Claude is waiting for your input" arrives a minute after a turn has already ended; it
            // would bring a finished session back into the notch. Only real questions count.
            let message = (hook["message"] as? String ?? "").lowercased()
            if hook["notification_type"] as? String == "idle_prompt" || message.contains("waiting for your input") { return }
            body["state"] = "waiting"
            body["ttl"] = 300
            body["detail"] = String((hook["message"] as? String ?? "Needs you").prefix(80))
        case "Stop":
            body["state"] = "done"
            body["detail"] = "Finished"
            plan = Plan()
        case "SessionEnd":
            _ = PergolaCLI.http("DELETE", "/activity/\(id)", nil, timeout: 1)
            Plan.forget(session)
            return
        default:
            return
        }
        if plan.total > 0, event != "Stop" {
            body["step"] = plan.done; body["total_steps"] = plan.total
            if event == "UserPromptSubmit" || !tool.contains("plan") && !tool.hasPrefix("Task") && tool != "TodoWrite",
               let current = plan.current, event != "Notification" { body["detail"] = body["detail"] ?? current }
        } else if event == "UserPromptSubmit" {
            body["progress"] = NSNull()
        }
        plan.save(session)
        _ = PergolaCLI.http("POST", "/activity", body, timeout: 1)
    }

    private static func describe(tool: String, input: [String: Any]) -> String {
        func file() -> String { ((input["file_path"] ?? input["path"] ?? input["notebook_path"]) as? String).map { URL(fileURLWithPath: $0).lastPathComponent } ?? "a file" }
        switch tool {
        case "Bash": return String((input["description"] as? String ?? "Running a command").prefix(80))
        case "Edit", "MultiEdit", "Write", "NotebookEdit": return "Editing \(file())"
        case "Read": return "Reading \(file())"
        case "Grep", "Glob": return "Searching the project"
        case "WebFetch", "WebSearch": return "Browsing the web"
        case "Task", "Agent": return String((input["description"] as? String ?? "Running a helper agent").prefix(80))
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.components(separatedBy: "__")
                return "Using \(parts.count > 2 ? parts[2].replacingOccurrences(of: "_", with: " ") : "a tool")"
            }
            return tool
        }
    }

    /// Claude's task list for this session, remembered between hook runs so progress can be a fraction.
    struct Plan: Codable {
        var done = 0
        var total = 0
        var current: String?
        var finished: Set<String> = []

        /// Updates the counts from a task-list tool call; returns the line to show, if this was one.
        mutating func note(tool: String, input: [String: Any]) -> String? {
            // TodoWrite sends "todos"; the desktop app's plan tool sends "items". Same shape.
            if let items = (input["todos"] ?? input["items"]) as? [[String: Any]], tool == "TodoWrite" || tool.hasSuffix("update_plan") {
                total = items.count
                done = items.filter { $0["status"] as? String == "completed" }.count
                let active = items.first { $0["status"] as? String == "in_progress" }
                current = (active?["activeForm"] ?? active?["content"]) as? String
                return current ?? "Planning"
            }
            if tool.hasSuffix("update_plan"), input["advance"] as? Bool == true, total > 0 {
                done = min(total, done + 1)
                return current
            }
            if tool == "TaskCreate" {
                total += 1
                return (input["subject"] as? String) ?? "Planning"
            }
            if tool == "TaskUpdate", let task = input["taskId"].map({ "\($0)" }) {
                if input["status"] as? String == "completed", finished.insert(task).inserted { done = min(max(total, 1), done + 1) }
                if input["status"] as? String == "in_progress" { current = (input["activeForm"] ?? input["subject"]) as? String ?? current }
                return current
            }
            return nil
        }

        private static func url(_ session: String) -> URL {
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pergola/claude")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let safe = session.filter { $0.isLetter || $0.isNumber || $0 == "-" }
            return dir.appendingPathComponent("\(safe.prefix(64)).json")
        }
        static func load(_ session: String) -> Plan {
            (try? Data(contentsOf: url(session))).flatMap { try? JSONDecoder().decode(Plan.self, from: $0) } ?? Plan()
        }
        func save(_ session: String) { try? JSONEncoder().encode(self).write(to: Self.url(session), options: .atomic) }
        static func forget(_ session: String) { try? FileManager.default.removeItem(at: url(session)) }
    }
}

// MARK: - Claude setup

/// Connects Claude Code to Pergola by adding hooks to its settings file (only when you click Connect).
@MainActor
enum ClaudeSetup {
    static let events = ["UserPromptSubmit", "PreToolUse", "Notification", "Stop", "SessionEnd"]
    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json") }
    static var binary: String { Bundle.main.executablePath ?? "/Applications/Pergola.app/Contents/MacOS/Pergola" }
    private static var command: String { "'\(binary)' --claude-hook" }

    private static func has(_ entries: Any?) -> Bool {
        ((entries as? [[String: Any]]) ?? []).contains { entry in
            ((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains("--claude-hook") == true }
        }
    }

    static var hooksInstalled: Bool {
        guard let data = try? Data(contentsOf: settingsURL),
              let hooks = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["hooks"] as? [String: Any] else { return false }
        return events.allSatisfy { has(hooks[$0]) }
    }

    /// Adds Pergola's hook to each event, leaving everything else in the file alone. A copy of the
    /// file as it was is kept beside it. Returns a line to show the user.
    static func installHooks() -> String {
        let fm = FileManager.default
        var root: [String: Any] = [:]
        if let data = try? Data(contentsOf: settingsURL) {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                return "Couldn't read ~/.claude/settings.json (it isn't valid JSON), so nothing was changed."
            }
            root = parsed
            let backup = settingsURL.deletingLastPathComponent().appendingPathComponent("settings.before-pergola.json")
            if !fm.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        var hooks = root["hooks"] as? [String: Any] ?? [:]
        for event in events where !has(hooks[event]) {
            var entries = hooks[event] as? [[String: Any]] ?? []
            var entry: [String: Any] = ["hooks": [["type": "command", "command": command, "timeout": 5]]]
            if event == "PreToolUse" { entry["matcher"] = "*" }
            entries.append(entry)
            hooks[event] = entries
        }
        root["hooks"] = hooks
        do {
            try fm.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                .write(to: settingsURL, options: .atomic)
            return "Connected. Claude Code sessions you start from now on show in the notch. (Your old settings are saved as settings.before-pergola.json.)"
        } catch {
            return "Couldn't write ~/.claude/settings.json: \(error.localizedDescription)"
        }
    }

    static var desktopConfig: String {
        let config: [String: Any] = ["mcpServers": ["pergola": ["command": binary, "args": ["--mcp"]]]]
        return (try? JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .withoutEscapingSlashes]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? ""
    }

    /// A pretend task that runs through five steps, to see how activities look. `app` picks whose
    /// mark it wears ("ChatGPT", "Gemini"…), exactly as a real task from that tool would.
    static func demo(_ activities: Activities, app: String = "Claude") {
        let steps = ["Reading the project", "Planning", "Editing files", "Running tests", "Wrapping up"]
        let id = "pergola-demo-\(app.lowercased())"
        for (i, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 1.6) {
                activities.upsert(["id": id, "app": app, "title": "\(app) · Demo", "detail": step,
                                   "state": "running", "step": i, "total_steps": steps.count])
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(steps.count) * 1.6) {
            activities.upsert(["id": id, "state": "done", "detail": "Finished"])
        }
    }
}
