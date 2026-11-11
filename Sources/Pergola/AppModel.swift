import SwiftUI
import AppKit

enum Peek: Equatable {
    case charging(percent: Int, charging: Bool)
    case track
    case accessory(Accessory)
    case sensory(Sensory.Kind, level: Float, muted: Bool)
    case output(name: String, symbol: String)
    case focus(name: String, symbol: String, on: Bool)
    /// Another app's task started, finished or needs you.
    case activity(title: String, status: String, state: LiveActivity.State)

    /// Every overlay drops a line down from under the notch. (Apple-style volume/brightness floats
    /// in its own capsule instead.)
    func dropsDown(apple: Bool) -> Bool {
        if case .sensory = self { !apple } else { true }
    }

    var isSensory: Bool { if case .sensory = self { true } else { false } }
}

/// Pages left to right: Calendar ← Files ← Media → Weather. Swipe left from Media for Weather, right for Files.
enum NotchTab: String, CaseIterable {
    case calendar, tray, player, weather, activity, rings

    var symbol: String {
        switch self { case .activity: "bolt.fill"; case .rings: "target"; case .player: "music.note"; case .weather: "cloud.sun.fill"; case .tray: "tray.fill"; case .calendar: "calendar" }
    }
}

@Observable @MainActor
final class NotchUI {
    var expanded = false
    var hidden = false
    var notchSize = CGSize(width: 185, height: 32)
    var hasNotch = true
    var peek: Peek?
    var tab: NotchTab = .player
    var hovering = false
    var locked = false
    /// Settings' glass slider is being dragged: keep the notch open as a live preview.
    var previewingGlass = false
    /// Another app has a live activity up, so the Activity page exists.
    var hasActivities = false
    /// An app is sharing goal rings, so the Rings page exists.
    var hasRings = false
    /// The enlarged album-art view (opened by clicking the artwork).
    var bigArt = false
    var bigArtLyrics = Prefs.d.bool(forKey: Prefs.bigArtLyrics) {
        didSet { Prefs.d.set(bigArtLyrics, forKey: Prefs.bigArtLyrics) }
    }
    /// The lock screen's enlarged album-art view.
    var lockBig = false
    /// Files are being dragged over the open notch.
    var dropTargeted = false
    /// Live horizontal offset while a swipe is in progress.
    var dragOffset: CGFloat = 0

    static let pagerWidth: CGFloat = 348
    /// Width of the lyrics column in the big-art view (fixed, so lines never re-wrap mid-animation).
    static let lyricsWidth: CGFloat = 306
    static let dropHeight: CGFloat = 26  // the line an overlay adds under the notch
    /// Tasks from other apps (Claude sessions and so on) currently listed.
    var taskCount = 0
    @ObservationIgnored var trayIsEmpty: () -> Bool = { true }
    static let maxTaskRows = 6
    static let taskRowHeight: CGFloat = 31

    /// Rows of tasks that fit on the page as it is; any more make the open notch taller.
    var freeTaskRows: Int {
        if !Prefs.d.bool(forKey: Prefs.trayEnabled) { return 3 }
        return trayIsEmpty() ? 2 : 1
    }
    private var extraTaskHeight: CGFloat {
        guard tab == .tray || tab == .activity else { return 0 }
        return CGFloat(max(0, min(taskCount, Self.maxTaskRows) - freeTaskRows)) * Self.taskRowHeight
    }

    var appleStyleSensory: Bool { Prefs.d.string(forKey: Prefs.sensoryStyle) == "apple" }

    /// The pages currently switched on, in left-to-right order.
    var pages: [NotchTab] {
        NotchTab.allCases.filter {
            ($0 != .weather || Prefs.d.bool(forKey: Prefs.weatherEnabled))
                && ($0 != .tray || Prefs.d.bool(forKey: Prefs.trayEnabled))
                && ($0 != .calendar || Prefs.d.bool(forKey: Prefs.calendarEnabled))
                // Tasks from other apps share the Files page; they only get a page of their own without it.
                && ($0 != .activity || (hasActivities && !Prefs.d.bool(forKey: Prefs.trayEnabled)))
                && ($0 != .rings || (hasRings && Prefs.d.bool(forKey: Prefs.ringsPage)))
        }
    }

    /// Size of the expanded panel, not counting the flared top corners.
    var expandedSize: CGSize {
        if bigArt { return CGSize(width: bigArtLyrics ? 620 : 420, height: notchSize.height + 270) }
        return CGSize(width: Self.pagerWidth, height: notchSize.height + 118 + extraTaskHeight)
    }
    /// The largest the open notch ever gets (sizes the window once, so it never has to resize).
    var maxExpandedSize: CGSize { CGSize(width: 620, height: notchSize.height + 270) }
    /// Width of each "wing" beside the notch when something is shown collapsed.
    var wingWidth: CGFloat { notchSize.height - 5 }  // art + ~2.5 pt each side: hugs the notch
}

@Observable @MainActor
final class AppModel {
    let ui = NotchUI()
    let player = NowPlaying()
    let weather = Weather()
    let battery = Battery()
    let waveform = Waveform()
    let tray = FileTray()
    let accessories = Accessories()
    let lyrics = Lyrics()
    let agenda = Agenda()
    let sensory = Sensory()
    let focus = FocusWatcher()
    let output = OutputWatcher()
    let activities = Activities()
    @ObservationIgnored private(set) lazy var api = PergolaAPI(activities: activities)
    @ObservationIgnored private lazy var live = LiveWatcher(activities: activities)

    private var reconcileTimer: Timer?
    private var peekTask: Task<Void, Never>?

    func start() {
        player.onTrackChange = { [weak self] in
            self?.reconcileLyrics() // start the next song's lyrics lookup right away
            guard Prefs.d.bool(forKey: Prefs.trackOverlay) else { return }
            self?.showPeek(.track)
        }
        battery.onPlugChange = { [weak self] _ in
            guard let self, Prefs.d.bool(forKey: Prefs.chargingOverlay), self.allowedDuringFocus(Prefs.focusShowsBattery) else { return }
            self.showPeek(.charging(percent: self.battery.percent, charging: self.battery.charging))
        }
        accessories.onConnect = { [weak self] acc in
            guard let self, Prefs.d.bool(forKey: Prefs.accessoryOverlay), self.allowedDuringFocus(Prefs.focusShowsAccessories) else { return }
            self.showPeek(.accessory(acc))
        }
        sensory.onChange = { [weak self] kind, level, muted in
            guard let self, self.allowedDuringFocus(Prefs.focusShowsSensory) else { return }
            self.showPeek(.sensory(kind, level: level, muted: muted), seconds: Prefs.d.double(forKey: Prefs.sensorySeconds))
        }
        output.onChange = { [weak self] device in
            guard let self, Prefs.d.bool(forKey: Prefs.outputOverlay), self.allowedDuringFocus(Prefs.focusShowsAccessories) else { return }
            self.showPeek(.output(name: device.name, symbol: device.symbol))
        }
        focus.onChange = { [weak self] mode, previous in
            guard let self, Prefs.d.bool(forKey: Prefs.focusOverlay), let shown = mode ?? previous else { return }
            self.showPeek(.focus(name: shown.name, symbol: shown.symbol, on: mode != nil))
        }
        activities.onAnnounce = { [weak self] a in
            guard let self, Prefs.d.bool(forKey: Prefs.activityOverlay) else { return }
            let status: String = switch a.state {
            case .done: "Done"
            case .failed: "Failed"
            case .waiting: a.detail.isEmpty ? "Needs you" : a.detail
            case .running: a.detail.isEmpty ? "Started" : a.detail
            }
            self.showPeek(.activity(title: a.title, status: status, state: a.state))
        }
        activities.onCountChange = { [weak self] count in
            guard let self else { return }
            // Goal rings live on their own page; everything else shares the Activity page.
            let rings = self.activities.items.contains(where: \.ambient)
            let taskCount = self.activities.items.count { !$0.ambient }
            let tasks = taskCount > 0
            if taskCount != self.ui.taskCount { withAnimation(Motion.content) { self.ui.taskCount = taskCount } }
            guard rings != self.ui.hasRings || tasks != self.ui.hasActivities else { return }
            withAnimation(Motion.content) {
                self.ui.hasActivities = tasks
                self.ui.hasRings = rings
                if !tasks, self.ui.tab == .activity { self.ui.tab = .player }
                if !rings, self.ui.tab == .rings { self.ui.tab = .player }
            }
        }
        // After the notch has had its first layout: changing its content while the window is still being
        // set up makes AppKit throw.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.activities.restore() }
        ui.trayIsEmpty = { [weak self] in self?.tray.items.isEmpty ?? true }
        api.setEnabled(Prefs.d.bool(forKey: Prefs.activitiesEnabled))
        sensory.start()
        focus.start()
        output.start()
        if Prefs.d.bool(forKey: Prefs.calendarEnabled) { agenda.start() }

        // Debug: PERGOLA_PEEK=volume|brightness|focus|output|airpods|charging shows that overlay for 60 s.
        if let which = ProcessInfo.processInfo.environment["PERGOLA_PEEK"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                let peek: Peek = switch which {
                case "brightness": .sensory(.brightness, level: 0.62, muted: false)
                case "focus": .focus(name: "Do Not Disturb", symbol: "moon.fill", on: true)
                case "output": .output(name: "AirPods Pro", symbol: "airpodspro")
                case "airpods": .accessory(Accessory(id: "x", name: "Alex’s AirPods Pro", symbol: "airpodspro", left: 82, right: 79, caseLevel: 55))
                case "charging": .charging(percent: 66, charging: true)
                default: .sensory(.volume, level: 0.44, muted: false)
                }
                self?.showPeek(peek, seconds: 60)
            }
        }
        player.start()
        accessories.start()
        weather.start()
        battery.start()

        // The waveform controller decides for itself whether anything should change;
        // calling it often is cheap and never restarts a capture that is already right.
        reconcileTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reconcileWaveform()
                self?.reconcileLyrics()
                self?.player.checkForRestart()
                self?.activities.prune()
                self?.live.tick()
            }
        }
    }

    /// Whether the collapsed notch should show the music wings.
    var showsMusicWings: Bool {
        Prefs.d.bool(forKey: Prefs.mediaPlayer) && player.hasTrack
            && (player.isPlaying || !Prefs.d.bool(forKey: Prefs.collapseOnPause))
    }

    /// Whether the closed notch has wings at all (music, or another app's activity).
    var showsWings: Bool { showsMusicWings || activities.current != nil }

    /// Width of each wing beside the closed notch: wider while one holds a running clock.
    var closedWingWidth: CGFloat { activities.current?.hasClock == true ? 46 : ui.wingWidth }

    private func reconcileWaveform() {
        waveform.update(
            enabled: Prefs.d.bool(forKey: Prefs.liveWaveform),
            playing: player.isPlaying,
            visible: !ui.hidden,
            pid: player.pid
        )
    }

    /// While a Focus is on, overlays switched off under Settings › Focus stay hidden.
    private func allowedDuringFocus(_ key: String) -> Bool {
        focus.active == nil || Prefs.d.bool(forKey: key)
    }

    private func reconcileLyrics() {
        guard player.hasTrack else { return }
        lyrics.load(title: player.title, artist: player.artist, album: player.album, duration: player.duration)
    }

    func showPeek(_ peek: Peek, seconds customSeconds: Double? = nil) {
        guard !ui.expanded else { return }
        peekTask?.cancel()
        // Repeated volume presses update the level in place instead of re-animating the whole overlay.
        if ui.peek?.isSensory == true, peek.isSensory {
            withAnimation(.spring(duration: 0.25, bounce: 0)) { ui.peek = peek }
        } else {
            withAnimation(Motion.peek) { ui.peek = peek }
        }
        let seconds = max(1, customSeconds ?? Prefs.d.double(forKey: Prefs.overlaySeconds))
        peekTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.peek) { self?.ui.peek = nil }
        }
    }
}
