import AppKit
import SwiftUI
@preconcurrency import ScreenCaptureKit
import CoreMedia
import QuartzCore
import SafariServices

/// Mirrors the video that's playing in a browser tab, live, by copying just the video's rectangle
/// out of the browser window with ScreenCaptureKit. The page is asked (through Apple Events
/// JavaScript) where its playing `<video>` sits, and that spot is re-checked every second so
/// scrolling or resizing follows along. Sound stays in the browser, so nothing drifts out of sync.
///
/// Needs Screen Recording permission, and the browser's "Allow JavaScript from Apple Events".
/// Protected video (Netflix, Apple TV+…) captures black; for that, `nativePictureInPicture()`
/// asks the browser for its own picture-in-picture instead.
@Observable @MainActor
final class VideoMirror {
    enum Status: Equatable, Error { case off, starting, live, noPermission, noJavaScript, noExtension, noVideo, protected }

    private(set) var status: Status = .off
    /// Width ÷ height of the video picture.
    private(set) var aspect: CGFloat = 16 / 9
    /// A frame has arrived since the mirror started (until then, show the artwork).
    private(set) var hasFrame = false

    @ObservationIgnored private var stream: SCStream?
    @ObservationIgnored private var output: Output?
    @ObservationIgnored private var poll: Timer?
    @ObservationIgnored private var spot: Spot?
    @ObservationIgnored private var bundleID: String?
    @ObservationIgnored private var users = Set<String>()
    @ObservationIgnored private let sinks = NSHashTable<CALayer>.weakObjects()
    @ObservationIgnored private var lastSurface: IOSurface?
    @ObservationIgnored private var askedPermission = false
    @ObservationIgnored private var checking = false
    /// What Pergola's Safari extension last said about each tab.
    @ObservationIgnored private var tabs: [Int: TabReport] = [:]
    @ObservationIgnored private var pendingCommand: (tab: Int, command: String)?
    /// Whether the Safari extension is switched on (nil until asked).
    @ObservationIgnored private(set) var extensionEnabled: Bool?

    static let extensionID = "com.pergola.Pergola.SafariExtension"

    private struct TabReport {
        var spot: Spot?
        var playing: Bool
        var visible: Bool
        var at: Date
    }

    /// Where the video is: in which browser window (CG coordinates) and where inside it (points).
    private struct Spot: Equatable {
        var window: CGRect
        var video: CGRect
        var protected: Bool
    }

    // MARK: Users

    /// Several parts of the app can want the mirror at once (the floating window, the open notch,
    /// a drag in progress); it runs while any of them does.
    func want(_ who: String, bundleID: String?) {
        guard let bundleID else { return }
        users.insert(who)
        if self.bundleID != bundleID { stop(); self.bundleID = bundleID }
        if status == .off { begin() }
    }

    func release(_ who: String) {
        users.remove(who)
        if users.isEmpty { stop() }
    }

    func attach(_ layer: CALayer) {
        sinks.add(layer)
        if let lastSurface { layer.contents = lastSurface }
    }

    // MARK: Start / stop

    private func begin() {
        status = .starting
        hasFrame = false
        if !CGPreflightScreenCaptureAccess() {
            if !askedPermission { askedPermission = true; CGRequestScreenCaptureAccess() }
            status = .noPermission
            // Keep checking: once it's granted the mirror starts by itself.
            startPolling()
            return
        }
        startPolling()
        refresh()
    }

    private func stop() {
        poll?.invalidate(); poll = nil
        if let stream { Task { try? await stream.stopCapture() } }
        stream = nil; output = nil; spot = nil
        lastSurface = nil
        status = .off
        hasFrame = false
    }

    private func startPolling() {
        poll?.invalidate()
        let t = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        poll = t
    }

    /// Finds the video again and starts, moves or stops the capture to match.
    private func refresh() {
        guard !users.isEmpty, let bundleID, !checking else { return }
        if status == .noPermission {
            guard CGPreflightScreenCaptureAccess() else { return }
            status = .starting
        }
        if Self.isSafari(bundleID) {
            checkExtension()
            if let best = bestTab() { apply(.success(best)); return }
            // No word from the extension: fall back to asking Safari directly, if that's allowed.
            if extensionEnabled == true { apply(.failure(.noVideo)); return }
        }
        checking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found = Self.locate(in: bundleID)
            if Self.isSafari(bundleID), case .failure(.noJavaScript) = found { found = .failure(.noExtension) }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.checking = false
                    guard !self.users.isEmpty else { return }
                    self.apply(found)
                }
            }
        }
    }

    private func apply(_ found: Result<Spot, Status>) {
        switch found {
        case .failure(let why):
            if stream != nil { Task { [stream] in try? await stream?.stopCapture() } }
            stream = nil; spot = nil; hasFrame = false
            status = why
        case .success(let new):
            if new.protected { status = .protected }
            aspect = max(0.5, min(3, new.video.width / max(new.video.height, 1)))
            if new == spot, stream != nil { return }
            let moved = spot.map { $0.window.size == new.window.size } ?? false
            spot = new
            if moved, let stream {
                Task { try? await stream.updateConfiguration(Self.configuration(for: new)) }
            } else {
                Task { await self.capture(new) }
            }
        }
    }

    private func capture(_ spot: Spot) async {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false),
              let bundleID else { return }
        // The browser window is the one of this app whose frame matches the one the browser reported.
        let candidates = content.windows.filter { $0.owningApplication?.bundleIdentifier == bundleID && $0.windowLayer == 0 }
        guard let window = candidates.min(by: { Self.distance($0.frame, spot.window) < Self.distance($1.frame, spot.window) }) else {
            status = .noVideo; return
        }
        if let old = stream { try? await old.stopCapture() }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let output = Output { [weak self] surface in
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.show(surface) } }
        }
        let stream = SCStream(filter: filter, configuration: Self.configuration(for: spot), delegate: nil)
        do {
            try stream.addStreamOutput(output, type: .screen, sampleHandlerQueue: output.queue)
            try await stream.startCapture()
            self.stream = stream
            self.output = output
            if status != .protected { status = .live }
        } catch {
            Log.media.error("video mirror: \(error.localizedDescription, privacy: .public)")
            status = .noPermission
        }
    }

    private static func distance(_ a: CGRect, _ b: CGRect) -> CGFloat {
        abs(a.minX - b.minX) + abs(a.minY - b.minY) + abs(a.width - b.width) + abs(a.height - b.height)
    }

    private static func configuration(for spot: Spot) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.sourceRect = spot.video
        // Full Retina resolution (up to a 2560-wide picture), so it stays sharp even made big.
        let scale = min(NSScreen.screens.map(\.backingScaleFactor).max() ?? 2, 2560 / max(spot.video.width, 1))
        c.width = max(2, Int(spot.video.width * scale))
        c.height = max(2, Int(spot.video.height * scale))
        c.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        c.pixelFormat = kCVPixelFormatType_32BGRA
        c.showsCursor = false
        c.queueDepth = 4
        c.capturesAudio = false
        c.ignoreShadowsSingleWindow = true
        return c
    }

    private func show(_ surface: IOSurface) {
        guard stream != nil else { return }
        lastSurface = surface
        if !hasFrame { hasFrame = true }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in sinks.allObjects { layer.contents = surface }
        CATransaction.commit()
    }

    // MARK: Safari extension

    nonisolated static func isSafari(_ id: String) -> Bool { id.hasPrefix("com.apple.Safari") }

    private func checkExtension() {
        SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.extensionID) { state, _ in
            let on = state?.isEnabled ?? false
            DispatchQueue.main.async { MainActor.assumeIsolated { self.extensionEnabled = on } }
        }
    }

    func openExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.extensionID) { _ in }
    }

    /// The tab to mirror: a visible one that's playing, else any visible one with a video.
    private func bestTab() -> Spot? {
        let fresh = tabs.values.filter { Date().timeIntervalSince($0.at) < 5 && $0.visible && $0.spot != nil }
        return (fresh.first { $0.playing } ?? fresh.max { $0.at < $1.at })?.spot
    }

    /// A report from the extension (through Pergola's local API). Returns its reply.
    func report(_ j: [String: Any]) -> [String: Any] {
        extensionEnabled = true
        let tab = (j["tab"] as? Int) ?? -1
        func num(_ k: String) -> CGFloat? { (j[k] as? NSNumber).map { CGFloat($0.doubleValue) } }
        var spot: Spot?
        if j["gone"] == nil, let x = num("x"), let y = num("y"), let w = num("w"), let h = num("h"),
           let iw = num("innerWidth"), let ih = num("innerHeight"), let ow = num("outerWidth"), let oh = num("outerHeight"),
           let sx = num("screenX"), let sy = num("screenY") {
            // CSS pixels → points: page zoom is the device pixel ratio over the screen's own scale.
            let primary = NSScreen.screens.first?.frame.height ?? 0
            let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: sx + 5, y: primary - sy - 5)) } ?? NSScreen.main
            let backing = screen?.backingScaleFactor ?? 2
            let zoom = max(0.25, (num("dpr") ?? backing) / backing)
            let x0 = max(0, x), y0 = max(0, y), x1 = min(iw, x + w), y1 = min(ih, y + h)
            if x1 - x0 > 20, y1 - y0 > 20 {
                let left = max(0, ow - iw * zoom), top = max(0, oh - ih * zoom)
                spot = Spot(window: CGRect(x: sx, y: sy, width: ow, height: oh),
                            video: CGRect(x: left + x0 * zoom, y: top + y0 * zoom, width: (x1 - x0) * zoom, height: (y1 - y0) * zoom),
                            protected: (j["protected"] as? Bool) ?? false)
            }
        }
        if j["gone"] != nil { tabs[tab] = nil } else {
            tabs[tab] = TabReport(spot: spot, playing: (j["playing"] as? Bool) ?? false,
                                  visible: (j["visible"] as? Bool) ?? true, at: Date())
        }
        tabs = tabs.filter { Date().timeIntervalSince($0.value.at) < 30 }
        // Follow scrolling and resizing right away rather than at the next check.
        if !users.isEmpty, let bundleID, Self.isSafari(bundleID), status != .noPermission {
            if let best = bestTab() { apply(.success(best)) } else if stream != nil { apply(.failure(.noVideo)) }
        }
        if let p = pendingCommand, p.tab == tab || tabs[p.tab] == nil {
            pendingCommand = nil
            return ["command": p.command]
        }
        return [:]
    }

    // MARK: Native picture-in-picture (protected video)

    /// Asks the browser to pop its own video out into macOS picture-in-picture.
    func nativePictureInPicture() {
        guard let bundleID else { return }
        if Self.isSafari(bundleID), extensionEnabled == true {
            let tab = tabs.first { $0.value.visible && $0.value.playing }?.key ?? tabs.keys.first ?? -1
            pendingCommand = (tab, "pip")
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let js = "(function(){var v=[].slice.call(document.querySelectorAll('video')).filter(function(x){return !x.paused})[0];if(!v)return '';if(v.webkitSetPresentationMode){v.webkitSetPresentationMode('picture-in-picture')}else if(v.requestPictureInPicture){v.requestPictureInPicture()}return 'ok'})()"
            _ = Self.runJavaScript(js, in: bundleID)
        }
    }

    // MARK: Finding the video

    /// Picks the playing video (or else the biggest one) in the front tab of each browser window
    /// and returns the part of its picture that's on screen, in window points.
    nonisolated private static let locateJS = """
    (function(){var vs=[].slice.call(document.querySelectorAll('video'));if(!vs.length)return '';\
    var v=vs.filter(function(x){return !x.paused&&x.readyState>1})[0]||vs.sort(function(a,b){return b.clientWidth*b.clientHeight-a.clientWidth*a.clientHeight})[0];\
    var r=v.getBoundingClientRect();if(r.width<40||r.height<30)return '';\
    var vw=v.videoWidth||r.width,vh=v.videoHeight||r.height,s=Math.min(r.width/vw,r.height/vh),w=vw*s,h=vh*s;\
    var x=r.left+(r.width-w)/2,y=r.top+(r.height-h)/2;\
    var x0=Math.max(0,x),y0=Math.max(0,y),x1=Math.min(innerWidth,x+w),y1=Math.min(innerHeight,y+h);if(x1-x0<20||y1-y0<20)return '';\
    var p=(v.mediaKeys||v.webkitKeys)?1:0;\
    return [x0,y0,x1-x0,y1-y0,outerWidth-innerWidth,outerHeight-innerHeight,p,v.paused?0:1].join(',')})()
    """

    nonisolated private static func locate(in bundleID: String) -> Result<Spot, Status> {
        let js = locateJS.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        if bundleID == "com.apple.Safari" || bundleID.hasPrefix("com.apple.Safari") {
            script = """
            tell application id "\(bundleID)"
              set out to ""
              repeat with w in windows
                try
                  set r to do JavaScript "\(js)" in current tab of w
                  if r is not missing value and r is not "" then
                    set b to bounds of w
                    set out to out & r & "|" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & linefeed
                  end if
                on error e number n
                  if n is 8 or e contains "JavaScript" then return "NOJS"
                end try
              end repeat
              return out
            end tell
            """
        } else {
            script = """
            tell application id "\(bundleID)"
              set out to ""
              repeat with w in windows
                try
                  set r to execute (active tab of w) javascript "\(js)"
                  if r is not missing value and r is not "" then
                    set b to bounds of w
                    set out to out & r & "|" & (item 1 of b) & "," & (item 2 of b) & "," & (item 3 of b) & "," & (item 4 of b) & linefeed
                  end if
                on error e number n
                  if e contains "JavaScript" or e contains "javascript" then return "NOJS"
                end try
              end repeat
              return out
            end tell
            """
        }
        guard let text = runScript(script) else { return .failure(.noJavaScript) }
        if text.hasPrefix("NOJS") { return .failure(.noJavaScript) }
        var best: (Spot, Bool)?
        for line in text.split(separator: "\n") {
            let halves = line.split(separator: "|")
            guard halves.count == 2 else { continue }
            let v = halves[0].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            let b = halves[1].split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
            guard v.count >= 8, b.count == 4 else { continue }
            // The page's left/top chrome: toolbars above it, a sidebar (if open) to its left.
            let video = CGRect(x: v[0] + v[4], y: v[1] + v[5], width: v[2], height: v[3])
            let window = CGRect(x: b[0], y: b[1], width: b[2] - b[0], height: b[3] - b[1])
            let spot = Spot(window: window, video: video, protected: v[6] > 0)
            let playing = v[7] > 0
            if best == nil || (playing && !best!.1) { best = (spot, playing) }
        }
        guard let best else { return .failure(.noVideo) }
        return .success(best.0)
    }

    @discardableResult
    nonisolated private static func runJavaScript(_ js: String, in bundleID: String) -> String? {
        let js = js.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = bundleID.hasPrefix("com.apple.Safari")
            ? "tell application id \"\(bundleID)\" to do JavaScript \"\(js)\" in current tab of front window"
            : "tell application id \"\(bundleID)\" to execute (active tab of front window) javascript \"\(js)\""
        return runScript(script)
    }

    /// Runs AppleScript out of process, with a time limit, so a busy browser can't hang Pergola.
    nonisolated private static func runScript(_ source: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(2.5)
        while p.isRunning, Date() < deadline { usleep(20_000) }
        if p.isRunning { p.terminate(); return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let error = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if p.terminationStatus != 0 {
            if error.contains("JavaScript") || error.contains("javascript") { return "NOJS" }
            return nil
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Stream output

    private final class Output: NSObject, SCStreamOutput, @unchecked Sendable {
        let queue = DispatchQueue(label: "pergola.video", qos: .userInteractive)
        private let deliver: (IOSurface) -> Void
        init(deliver: @escaping (IOSurface) -> Void) { self.deliver = deliver }

        func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
            guard type == .screen, sample.isValid,
                  let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete,
                  let pixels = sample.imageBuffer,
                  let surface = CVPixelBufferGetIOSurface(pixels)?.takeUnretainedValue() else { return }
            deliver(surface)
        }
    }
}

/// A view that shows the mirrored video, filling its frame (cropped to fit).
struct VideoSurface: NSViewRepresentable {
    let mirror: VideoMirror

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        let layer = CALayer()
        layer.contentsGravity = .resizeAspectFill
        layer.masksToBounds = true
        layer.magnificationFilter = .linear
        layer.minificationFilter = .trilinear
        v.layer = layer
        v.wantsLayer = true
        mirror.attach(layer)
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
