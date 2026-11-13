import AppKit

/// What a browser (or any app other than Music and Spotify) says it is playing.
struct WebTrack {
    var bundleID: String
    var title: String
    var artist: String
    var album: String
    var duration: Double
    /// Position at `stamp`.
    var elapsed: Double
    var stamp: Date
    var playing: Bool
    var artwork: CGImage?
    var artworkID: Int
}

/// Streams the system's now-playing information through MediaRemote Adapter (bundled in
/// Resources), so YouTube, SoundCloud and other web players show up in the notch too. Music and
/// Spotify keep their own, richer connection and are ignored here.
///
/// MediaRemote only answers Apple's own programs, so the adapter runs inside /usr/bin/perl. If a
/// future macOS closes that door, the stream simply stays quiet and nothing else changes.
@MainActor
final class WebMedia {
    var onChange: ((WebTrack?) -> Void)?

    private var process: Process?
    private var restarts = 0
    private var wanted = false
    private var observingQuit = false

    /// Helpers still running from an earlier Pergola that didn't get to stop them.
    private static func killStrays() {
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("mediaremote-adapter.pl").path else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", res + " "]
        try? p.run()
        p.waitUntilExit()
    }
    nonisolated private static let parseQueue = DispatchQueue(label: "com.pergola.webmedia", qos: .utility)
    /// Merged state of the stream (it sends only what changed); touched only on `parseQueue`.
    nonisolated(unsafe) private static var state: [String: Any] = [:]
    nonisolated(unsafe) private static var buffer = Data()
    nonisolated(unsafe) private static var artworkID = 0
    nonisolated(unsafe) private static var artworkImage: CGImage?
    nonisolated(unsafe) private static var artworkSource: String?

    nonisolated private static let ignored: Set<String> = ["com.apple.Music", "com.spotify.client"]

    func setEnabled(_ on: Bool) {
        if !observingQuit {
            observingQuit = true
            // The helper is a separate process: stop it with Pergola, and clear any left by a crash.
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.process?.terminationHandler = nil
                    self?.process?.terminate()
                }
            }
            Self.killStrays()
        }
        wanted = on
        if on { start() } else { stop() }
    }

    private func start() {
        guard process == nil, wanted,
              let res = Bundle.main.resourceURL,
              FileManager.default.fileExists(atPath: res.appendingPathComponent("mediaremote-adapter.pl").path) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res.appendingPathComponent("mediaremote-adapter.pl").path,
                       res.appendingPathComponent("MediaRemoteAdapter.framework").path,
                       "stream", "--debounce=120", "--micros"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        out.fileHandleForReading.readabilityHandler = { [weak self] fh in
            let chunk = fh.availableData
            guard !chunk.isEmpty else { fh.readabilityHandler = nil; return }
            Self.parseQueue.async {
                let tracks = Self.consume(chunk)
                guard !tracks.isEmpty else { return }
                let latest = tracks.last!
                Log.media.debug("web: \(latest?.title ?? "nothing", privacy: .private) playing=\(latest?.playing ?? false)")
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.onChange?(latest) } }
            }
        }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.ended() } }
        }
        do { try p.run(); process = p } catch { process = nil; Log.media.error("web stream failed to start: \(error.localizedDescription, privacy: .public)") }
    }

    private func stop() {
        process?.terminationHandler = nil
        process?.terminate()
        process = nil
        Self.parseQueue.async { Self.state = [:]; Self.buffer = Data() }
        onChange?(nil)
    }

    private func ended() {
        process = nil
        guard wanted, restarts < 5 else { return }
        restarts += 1
        // Back off, so a broken adapter can't spin.
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(restarts) * 3) { [weak self] in self?.start() }
    }

    // MARK: Commands

    /// MediaRemote command IDs (see ThirdParty/mediaremote-adapter's README).
    enum Command: Int { case play = 0, pause = 1, toggle = 2, next = 4, previous = 5 }

    func send(_ command: Command) { run(["send", String(command.rawValue)]) }

    func seek(to seconds: Double) { run(["seek", String(Int(max(0, seconds) * 1_000_000))]) }

    private func run(_ args: [String]) {
        guard let res = Bundle.main.resourceURL else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = [res.appendingPathComponent("mediaremote-adapter.pl").path,
                       res.appendingPathComponent("MediaRemoteAdapter.framework").path] + args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }

    // MARK: Parsing (on parseQueue)

    nonisolated private static func consume(_ chunk: Data) -> [WebTrack?] {
        buffer.append(chunk)
        var results: [WebTrack?] = []
        while let nl = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            if obj["diff"] as? Bool == true {
                for (k, v) in payload { if v is NSNull { state[k] = nil } else { state[k] = v } }
            } else {
                state = payload
            }
            results.append(track())
        }
        return results
    }

    nonisolated private static func track() -> WebTrack? {
        guard let bundle = state["bundleIdentifier"] as? String,
              let title = state["title"] as? String, !title.isEmpty else { return nil }
        let parent = state["parentApplicationBundleIdentifier"] as? String
        guard !ignored.contains(bundle), !(parent.map(ignored.contains) ?? false) else { return nil }
        if let b64 = state["artworkData"] as? String {
            if b64 != artworkSource {
                artworkSource = b64
                artworkID += 1
                artworkImage = Data(base64Encoded: b64).flatMap { NowPlaying.decode($0) }
            }
        } else if artworkSource != nil {
            artworkSource = nil
            artworkImage = nil
            artworkID += 1
        }
        func micros(_ key: String) -> Double? { (state[key] as? NSNumber).map { $0.doubleValue / 1_000_000 } }
        let stamp = micros("timestampEpochMicros").map { Date(timeIntervalSince1970: $0) } ?? Date()
        return WebTrack(bundleID: parent ?? bundle, title: title,
                        artist: state["artist"] as? String ?? "", album: state["album"] as? String ?? "",
                        duration: micros("durationMicros") ?? 0, elapsed: micros("elapsedTimeMicros") ?? 0,
                        stamp: stamp, playing: state["playing"] as? Bool ?? false,
                        artwork: artworkImage, artworkID: artworkID)
    }
}
