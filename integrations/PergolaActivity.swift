import Foundation

/// Drop this file into any of your apps to show a task and its progress in Pergola's notch.
///
///     let export = PergolaActivity(id: "export-\(UUID())", app: "CamCam", title: "Exporting video",
///                                  symbol: "film", bundleID: Bundle.main.bundleIdentifier)
///     export.update(detail: "Rendering", progress: 0.4)
///     export.finish()                       // or export.finish(failed: true, detail: "Disk full")
///
/// Calls never block and never throw: if Pergola isn't running, nothing happens.
/// Sandboxed apps need the "Outgoing Connections (Client)" capability.
public final class PergolaActivity: @unchecked Sendable {
    public let id: String
    private let base: [String: Any]
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 2
        return URLSession(configuration: c)
    }()

    /// - Parameters:
    ///   - symbol: an SF Symbol name, used when `bundleID` is nil.
    ///   - bundleID: pass your app's bundle ID to show its icon instead of a symbol.
    ///   - tint: ring colour as hex, e.g. "#34C759".
    public init(id: String, app: String, title: String, symbol: String? = nil, bundleID: String? = nil, tint: String? = nil) {
        self.id = id
        var d: [String: Any] = ["id": id, "app": app, "title": title]
        d["symbol"] = symbol; d["bundle_id"] = bundleID; d["tint"] = tint
        base = d
        post(d)
    }

    /// `progress` is 0…1; leave it nil to keep the last value (or a spinner if none was ever sent).
    public func update(title: String? = nil, detail: String? = nil, progress: Double? = nil, waiting: Bool = false) {
        var d = base
        if let title { d["title"] = title }
        d["detail"] = detail; d["progress"] = progress
        d["state"] = waiting ? "waiting" : "running"
        post(d)
    }

    /// Shows a tick (or a cross) for a few seconds, then leaves the notch.
    public func finish(failed: Bool = false, detail: String? = nil) {
        var d: [String: Any] = ["id": id, "state": failed ? "failed" : "done"]
        d["detail"] = detail
        post(d)
    }

    private static var port: Int {
        // Pergola writes the port it's using here; 47600 unless that was taken. (A sandboxed app
        // can't read this file and simply uses the default.)
        let url = URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Pergola/api.json")
        let info = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        return info?["port"] as? Int ?? 47600
    }

    private func post(_ body: [String: Any]) {
        guard let url = URL(string: "http://127.0.0.1:\(Self.port)/activity"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        Self.session.dataTask(with: req).resume()
    }
}
