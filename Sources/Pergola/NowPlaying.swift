import AppKit
import SwiftUI

enum PlayerApp: String {
    case music = "com.apple.Music"
    case spotify = "com.spotify.client"
    /// A browser or another app, through the system's now-playing information (see WebMedia).
    case web = "web"

    var scriptName: String {
        switch self { case .music: "Music"; case .spotify: "Spotify"; case .web: "your browser" }
    }

    var isRunning: Bool {
        self == .web || !NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).isEmpty
    }
    var pid: pid_t? {
        self == .web ? nil : NSRunningApplication.runningApplications(withBundleIdentifier: rawValue).first?.processIdentifier
    }
}

/// Tracks what's playing in Apple Music or Spotify.
///
/// State comes from the players' own distributed notifications (posted on every play,
/// pause and track change), so there is no polling and no private framework. Commands go
/// through AppleScript, and are only ever sent to an app that is already running.
@Observable @MainActor
final class NowPlaying {
    var source: PlayerApp?
    var title = ""
    var artist = ""
    var album = ""
    var artwork: NSImage?
    var accent: Color = .white
    var isPlaying = false
    var duration: Double = 0
    var shuffle = false
    var repeatMode = 0 // 0 off, 1 one, 2 all
    var favorited = false

    /// Position at `positionDate`; the UI extrapolates while playing.
    private(set) var position: Double = 0
    private(set) var positionDate = Date()

    var onTrackChange: (() -> Void)?
    private var trackKey = ""
    /// The track the current `artwork` belongs to.
    private var artworkKey = ""

    var hasTrack: Bool { source != nil && !title.isEmpty }
    /// The browser (or other app) behind a `.web` source.
    private(set) var webBundleID: String?
    /// Shuffle, repeat and favourite only work with Music and Spotify.
    var hasModes: Bool { source != .web }
    @ObservationIgnored let web = WebMedia()
    @ObservationIgnored private var webArtworkID = -1
    var pid: pid_t? { source?.pid }

    func currentPosition(at date: Date = .now) -> Double {
        guard isPlaying else { return position }
        let raw = position + date.timeIntervalSince(positionDate)
        guard duration > 0 else { return raw }
        // Repeat One: the song starts over without the player saying anything, so wrap around.
        if repeatMode == 1, raw >= duration { return raw.truncatingRemainder(dividingBy: duration) }
        return min(duration, raw)
    }

    @ObservationIgnored private var lastEndCheck = Date.distantPast

    /// Called a few times a second. When the clock reaches the end of the song, ask the player where it
    /// really is: a song that repeats (or a playlist that loops back to the same song) restarts without
    /// a new "track changed" notification, which used to leave the progress bar and lyrics stuck at the end.
    func checkForRestart() {
        guard isPlaying else { return }
        let sinceSync = Date().timeIntervalSince(positionDate)
        let atEnd = duration > 0 && position + sinceSync >= duration - 0.3
        // Also re-check every 8 s: streaming hiccups or scrubbing inside the player app otherwise let
        // Pergola's clock drift ahead of the music, and the lyrics with it.
        let sinceCheck = Date().timeIntervalSince(lastEndCheck)
        guard (atEnd && sinceCheck > 1) || (sinceSync > 8 && sinceCheck > 8) else { return }
        lastEndCheck = Date()
        syncPosition()
    }

    // MARK: Lifecycle

    func start() {
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(.music, info) }
        }
        dnc.addObserver(forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main) { [weak self] n in
            let info = n.userInfo ?? [:]
            MainActor.assumeIsolated { self?.handle(.spotify, info) }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let id = (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated {
                guard let self, let id, id == self.source?.rawValue || (self.source == .web && id == self.webBundleID) else { return }
                self.clear()
            }
        }
        loadInitialState()
        web.onChange = { [weak self] track in self?.handleWeb(track) }
        web.setEnabled(Prefs.d.bool(forKey: Prefs.webMedia))
    }

    /// Browser music (and other players) from the system's now-playing information.
    private func handleWeb(_ track: WebTrack?) {
        guard let track, allowed(.web) else {
            if source == .web { clear() }
            return
        }
        // Don't let a paused browser steal the notch from Music or Spotify playing.
        if let source, source != .web, isPlaying, !track.playing { return }
        if source != .web { source = .web }
        webBundleID = track.bundleID
        if title != track.title { title = track.title }
        if artist != track.artist { artist = track.artist }
        if album != track.album { album = track.album }
        let settling = Date().timeIntervalSince(commandedAt) < 1.2
        if !settling, isPlaying != track.playing { isPlaying = track.playing }
        duration = track.duration
        position = track.elapsed
        positionDate = track.stamp
        shuffle = false; repeatMode = 0; favorited = false

        let key = "web|\(track.bundleID)|\(title)|\(artist)"
        if key != trackKey {
            trackKey = key
            webArtworkID = -1
            if track.playing { onTrackChange?() }
        }
        if track.artworkID != webArtworkID {
            webArtworkID = track.artworkID
            if let image = track.artwork { setArtwork(image, for: key) }
            else if artworkKey != key {
                withAnimation(.spring(duration: 0.5)) { artwork = nil; accent = .white }
            }
        }
    }

    private func allowed(_ app: PlayerApp) -> Bool {
        switch Prefs.d.string(forKey: Prefs.playerSource) {
        case "music": app == .music
        case "spotify": app == .spotify
        default: app != .web || Prefs.d.bool(forKey: Prefs.webMedia)
        }
    }

    private func handle(_ app: PlayerApp, _ info: [AnyHashable: Any]) {
        guard allowed(app) else { return }
        let state = info["Player State"] as? String ?? ""
        let playing = state == "Playing"

        // Don't let a paused player steal the notch from one that's playing.
        if let source, source != app, isPlaying, !playing { return }

        if state == "Stopped" {
            if source == app { clear() }
            return
        }

        let sameSource = source == app
        if source != app { source = app }
        let newTitle = info["Name"] as? String ?? "", newArtist = info["Artist"] as? String ?? "", newAlbum = info["Album"] as? String ?? ""
        if title != newTitle { title = newTitle }
        if artist != newArtist { artist = newArtist }
        if album != newAlbum { album = newAlbum }
        // Right after you press play/pause, Music posts a burst of notifications and some still carry
        // the old state. Trust the button for a moment (then `confirmPlayState` checks for real), so
        // the play/pause icon doesn't flash back and forth.
        let settling = sameSource && Date().timeIntervalSince(commandedAt) < 1.2
        if !settling, isPlaying != playing { isPlaying = playing }
        switch app {
        case .music:
            duration = ((info["Total Time"] as? NSNumber)?.doubleValue ?? 0) / 1000
        case .spotify:
            duration = ((info["Duration"] as? NSNumber)?.doubleValue ?? 0) / 1000
            if let pos = (info["Playback Position"] as? NSNumber)?.doubleValue { setPosition(pos) }
        case .web:
            break
        }

        let key = "\(app.rawValue)|\(title)|\(artist)|\(album)"
        if key != trackKey {
            trackKey = key
            // Keep the old cover until the new one arrives, so the change animates cover-to-cover.
            if playing { onTrackChange?() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                // No artwork found for this track: fall back to the placeholder.
                guard let self, self.trackKey == key, self.artworkKey != key else { return }
                withAnimation(.spring(duration: 0.5)) { self.artwork = nil; self.accent = .white }
            }
            loadArtwork() // runs in the background, so it can start straight away
        }
        syncPosition()
        syncModes()
    }

    private func clear() {
        source = nil; title = ""; artist = ""; album = ""; artwork = nil; webBundleID = nil
        isPlaying = false; duration = 0; position = 0; trackKey = ""
    }

    private func setPosition(_ p: Double) {
        position = p
        positionDate = Date()
    }

    private func loadInitialState() {
        for app in [PlayerApp.music, .spotify] where app.isRunning && allowed(app) {
            let script = """
            tell application "\(app.scriptName)"
                if player state is stopped then return {}
                set t to current track
                return {name of t, artist of t, album of t, duration of t, player state is playing}
            end tell
            """
            guard let d = AppleScript.run(script), d.numberOfItems == 5 else { continue }
            source = app
            title = d.atIndex(1)?.stringValue ?? ""
            artist = d.atIndex(2)?.stringValue ?? ""
            album = d.atIndex(3)?.stringValue ?? ""
            let dur = d.atIndex(4)?.doubleValue ?? 0
            duration = app == .spotify ? dur / 1000 : dur
            isPlaying = d.atIndex(5)?.booleanValue ?? false
            trackKey = "\(app.rawValue)|\(title)|\(artist)|\(album)"
            loadArtwork()
            syncPosition()
            syncModes()
            if isPlaying { break }
        }
    }

    // MARK: Sync

    /// Reads the playback position in the background. The time is stamped the moment the player
    /// answers, so the progress bar stays exact however long the answer takes to come back.
    func syncPosition() {
        guard let app = source, app != .web, app.isRunning else { return }
        let key = trackKey
        AppleScript.fetch("tell application \"\(app.scriptName)\" to player position",
                          { ($0.doubleValue, Date()) }) { [weak self] result in
            guard let self, let (pos, at) = result, self.trackKey == key else { return }
            self.position = pos
            self.positionDate = at
        }
    }

    /// Shuffle, repeat and favourite in a single round trip.
    private func syncModes() {
        guard let app = source, app != .web, app.isRunning else { return }
        let key = trackKey
        switch app {
        case .music:
            let script = """
            tell application "Music"
                set s to shuffle enabled
                set f to false
                try
                    set f to favorited of current track
                end try
                set r to 0
                if song repeat is one then set r to 1
                if song repeat is all then set r to 2
                return {s, f, r}
            end tell
            """
            AppleScript.fetch(script, { d -> (Bool, Bool, Int)? in
                guard d.numberOfItems == 3 else { return nil }
                return (d.atIndex(1)?.booleanValue ?? false, d.atIndex(2)?.booleanValue ?? false, Int(d.atIndex(3)?.int32Value ?? 0))
            }) { [weak self] r in
                guard let self, let (sh, fav, rep) = r, self.trackKey == key else { return }
                self.shuffle = sh; self.favorited = fav; self.repeatMode = rep
            }
        case .spotify:
            AppleScript.fetch("tell application \"Spotify\" to return {shuffling, repeating}", { d -> (Bool, Bool)? in
                guard d.numberOfItems == 2 else { return nil }
                return (d.atIndex(1)?.booleanValue ?? false, d.atIndex(2)?.booleanValue ?? false)
            }) { [weak self] r in
                guard let self, let (sh, rep) = r, self.trackKey == key else { return }
                self.shuffle = sh; self.repeatMode = rep ? 2 : 0
            }
        case .web:
            break
        }
    }

    // MARK: Commands

    /// Commands are sent in the background (in order), so a button press never waits on the player.
    private func send(_ command: String) {
        guard let app = source, app.isRunning else { return }
        if app == .web {
            let map: [String: WebMedia.Command] = ["play": .play, "pause": .pause, "next track": .next, "previous track": .previous]
            if let c = map[command] { web.send(c) }
            return
        }
        AppleScript.send("tell application \"\(app.scriptName)\" to \(command)")
    }

    func playPause() {
        guard source?.isRunning == true else { return }
        // Update immediately so the UI and waveform respond without waiting for the player.
        if isPlaying { position = currentPosition() }
        positionDate = Date()
        isPlaying.toggle()
        commandedAt = Date()
        // Say exactly which one we mean: a bare "playpause" sent twice in a row can cancel itself out.
        send(isPlaying ? "play" : "pause")
        confirmPlayState()
    }

    @ObservationIgnored private var commandedAt = Date.distantPast
    @ObservationIgnored private var confirmToken = 0

    /// Once the player has had time to act on the last play/pause, ask it what it's really doing.
    private func confirmPlayState() {
        confirmToken += 1
        let token = confirmToken
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25) { [weak self] in
            guard let self, self.confirmToken == token, let app = self.source, app != .web, app.isRunning else { return }
            AppleScript.fetch("tell application \"\(app.scriptName)\" to return (player state is playing)",
                              { $0.booleanValue }) { [weak self] playing in
                guard let self, self.confirmToken == token, let playing, playing != self.isPlaying else { return }
                self.isPlaying = playing
                self.syncPosition()
            }
        }
    }

    func next() { send("next track") }
    func previous() { send("previous track") }

    func seek(to seconds: Double) {
        setPosition(seconds)
        if source == .web { web.seek(to: seconds); return }
        send("set player position to \(seconds)")
    }

    func toggleShuffle() {
        guard let app = source, app != .web else { return }
        shuffle.toggle()
        send(app == .music ? "set shuffle enabled to \(shuffle)" : "set shuffling to \(shuffle)")
    }

    /// Favorite (love) the current song. Apple Music only; Spotify has no scripting for it.
    func toggleFavorite() {
        guard source == .music else { return }
        favorited.toggle()
        send("set favorited of current track to \(favorited)")
    }

    func cycleRepeat() {
        guard let app = source, app != .web else { return }
        switch app {
        case .music:
            // Same order as Apple Music's own button: off → repeat all → repeat one → off.
            repeatMode = [0: 2, 2: 1, 1: 0][repeatMode] ?? 0
            send("set song repeat to \(["off", "one", "all"][repeatMode])")
        case .spotify:
            repeatMode = repeatMode == 0 ? 2 : 0
            send("set repeating to \(repeatMode != 0)")
        case .web:
            break
        }
    }

    func openPlayer() {
        guard let app = source,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: app == .web ? (webBundleID ?? "") : app.rawValue) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init())
    }

    // MARK: Artwork

    private func loadArtwork() {
        guard let app = source else { return }
        let key = trackKey
        switch app {
        case .music:
            let script = "tell application \"Music\" to try\nreturn raw data of artwork 1 of current track\nend try"
            AppleScript.fetch(script, { d -> CGImage? in Self.decode(d.data) }) { [weak self] image in
                guard let self, self.trackKey == key else { return }
                if let image { self.setArtwork(image, for: key) }
                else { Task { await self.fetchArtworkFromStore(for: key) } }
            }
        case .spotify:
            AppleScript.fetch("tell application \"Spotify\" to artwork url of current track", { $0.stringValue }) { [weak self] s in
                guard let self, let s, let url = URL(string: s) else { return }
                Task { await self.downloadArtwork(url, for: key) }
            }
        case .web:
            break // arrives with the stream
        }
    }

    /// Decodes artwork fully (off the main thread), so the first frame that draws it doesn't have to.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    private func downloadArtwork(_ url: URL, for key: String) async {
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let image = await Task.detached(operation: { Self.decode(data) }).value else { return }
        setArtwork(image, for: key)
    }

    /// Streaming tracks sometimes have no local artwork; fall back to the iTunes Search API.
    private func fetchArtworkFromStore(for key: String) async {
        var comps = URLComponents(string: "https://itunes.apple.com/search")!
        comps.queryItems = [.init(name: "term", value: "\(artist) \(title)"),
                            .init(name: "entity", value: "song"), .init(name: "limit", value: "1")]
        struct Result: Decodable { struct Item: Decodable { let artworkUrl100: String? }; let results: [Item] }
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let r = try? JSONDecoder().decode(Result.self, from: data),
              let small = r.results.first?.artworkUrl100,
              let big = URL(string: small.replacingOccurrences(of: "100x100", with: "1000x1000")) else { return }
        await downloadArtwork(big, for: key)
    }

    private func setArtwork(_ cg: CGImage, for key: String) {
        guard key == trackKey else { return }
        artworkKey = key
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        withAnimation(.spring(duration: 0.7, bounce: 0.14)) {
            artwork = img
            accent = img.accentColor
        }
    }
}

/// Runs AppleScript on one background queue, never on the main thread: a player can take a few
/// hundred milliseconds to answer, and on the main thread that freezes every animation meanwhile.
/// Scripts are compiled once and reused. Everything runs in order, so commands never overtake each other.
enum AppleScript {
    private static let queue = DispatchQueue(label: "com.pergola.applescript", qos: .userInitiated)
    nonisolated(unsafe) private static var compiled: [String: NSAppleScript] = [:] // only touched on `queue`

    nonisolated private static func execute(_ source: String) -> NSAppleEventDescriptor? {
        let script: NSAppleScript
        if let cached = compiled[source] {
            script = cached
        } else {
            guard let fresh = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            fresh.compileAndReturnError(&compileError)
            if compiled.count > 48 { compiled.removeAll() } // one-off scripts (seeks) shouldn't pile up
            compiled[source] = fresh
            script = fresh
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        return error == nil ? result : nil
    }

    /// Waits for the answer. Only for launch, before anything is on screen.
    @MainActor @discardableResult
    static func run(_ source: String) -> NSAppleEventDescriptor? {
        queue.sync { execute(source) }
    }

    /// Fire and forget.
    static func send(_ source: String) {
        queue.async { _ = execute(source) }
    }

    /// Runs `source`, converts the answer on the background queue, and delivers it on the main thread.
    static func fetch<T>(_ source: String, _ transform: @escaping (NSAppleEventDescriptor) -> T?,
                         completion: @escaping @MainActor (T?) -> Void) {
        queue.async {
            let value = execute(source).flatMap(transform)
            nonisolated(unsafe) let boxed = value
            DispatchQueue.main.async { MainActor.assumeIsolated { completion(boxed) } }
        }
    }
}

extension NSImage {
    /// A bright, saturated version of the image's average color, for tinting controls.
    var accentColor: Color {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else { return .white }
        var px = [UInt8](repeating: 0, count: 4)
        guard let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return .white }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        let c = NSColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.usingColorSpace(.deviceRGB)?.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        if s < 0.12 { return .white } // greyscale art: stay neutral
        return Color(hue: h, saturation: min(1, s * 1.2 + 0.1), brightness: max(0.8, b))
    }
}
