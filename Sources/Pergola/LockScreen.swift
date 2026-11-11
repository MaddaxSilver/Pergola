import SwiftUI
import AppKit
import IOKit.pwr_mgt

// MARK: - SkyLight (private): put a window on the lock screen

/// macOS draws the lock screen in its own "space". Apps can create a space at the lock screen's
/// level through the private SkyLight framework and move a window into it. Loaded at runtime so a
/// future macOS that removes these symbols just means no lock screen, never a crash.
enum SkyLight {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias SpaceSetLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32

    private static let lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func fn<T>(_ name: String, _: T.Type) -> T? {
        guard let lib, let sym = dlsym(lib, name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }

    /// Absolute space levels: normal desktops are 0, the lock screen is 300, 400 is above it.
    static let lockScreenLevel: Int32 = 400
    /// Just above the desktops: windows here don't slide when you swipe between desktops,
    /// but the lock screen still covers them.
    static let aboveDesktopsLevel: Int32 = 1
    private static var spaces: [Int32: UInt64] = [:]

    static var available: Bool {
        fn("SLSMainConnectionID", MainConnection.self) != nil && fn("SLSSpaceCreate", SpaceCreate.self) != nil
    }

    /// Moves `window` into a space that shows above the lock screen. Safe to call once per window.
    @discardableResult
    static func moveToLockScreen(_ window: NSWindow) -> Bool { move(window, toLevel: lockScreenLevel) }

    /// Moves `window` into a private space at `level`. One space is created per level and reused.
    @discardableResult
    static func move(_ window: NSWindow, toLevel level: Int32) -> Bool {
        guard let main = fn("SLSMainConnectionID", MainConnection.self),
              let create = fn("SLSSpaceCreate", SpaceCreate.self),
              let setLevel = fn("SLSSpaceSetAbsoluteLevel", SpaceSetLevel.self),
              let show = fn("SLSShowSpaces", ShowSpaces.self),
              let add = fn("SLSSpaceAddWindowsAndRemoveFromSpaces", AddWindows.self) else { return false }
        let cid = main()
        let space: UInt64
        if let existing = spaces[level] {
            space = existing
        } else {
            space = create(cid, 1, nil) // flag must be 1, or Finder draws desktop icons into it
            _ = setLevel(cid, space, level)
            _ = show(cid, [NSNumber(value: space)] as CFArray)
            spaces[level] = space
        }
        _ = add(cid, space, [NSNumber(value: window.windowNumber)] as CFArray, 7)
        return true
    }
}

// MARK: - Controller

/// Shows Pergola's lock-screen widgets while the Mac is locked, plays the lock/unlock sounds,
/// and optionally keeps the display awake while music plays.
@MainActor
final class LockScreenController {
    private let model: AppModel
    private var window: NSWindow?
    private var delegated = false
    private var awakeAssertion: IOPMAssertionID = 0
    private var activityAssertion: IOPMAssertionID = 0
    /// When the current keep-awake period ends (set when music starts playing while locked).
    private var awakeUntil: Date?
    private var lastActivity = Date.distantPast
    private var wasPlaying = false
    /// The display was switched off on purpose (lid, power key, hot corner): don't fight that.
    private var displaysAsleep = false
    private(set) var locked = false

    init(model: AppModel) { self.model = model }

    func start() {
        // Have the wallpaper ready before the first lock, so the card's glass is there from the first frame.
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main {
            WallpaperBackdrop.shared.refresh(for: screen)
        }
        let dnc = DistributedNotificationCenter.default()
        dnc.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didLock() }
        }
        dnc.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didUnlock() }
        }
        // Keep-awake follows playback while locked.
        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateKeepAwake() }
        }
        let wnc = NSWorkspace.shared.notificationCenter
        wnc.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysAsleep = true; self?.releaseKeepAwake() }
        }
        wnc.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysAsleep = false; self?.updateKeepAwake() }
        }
        // Debug: PERGOLA_LOCK_PREVIEW=1 shows the lock-screen layout over the desktop.
        if ProcessInfo.processInfo.environment["PERGOLA_LOCK_PREVIEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                self.model.ui.lockBig = ProcessInfo.processInfo.environment["PERGOLA_LOCK_PREVIEW"] != "card"
                self.present(preview: true)
            }
        }
    }

    private func didLock() {
        locked = true
        model.ui.locked = true
        if Prefs.d.bool(forKey: Prefs.lockSound) { LockSounds.play(lock: true) }
        guard Prefs.d.bool(forKey: Prefs.lockScreen) else { return }
        model.ui.lockBig = Prefs.d.bool(forKey: Prefs.lockFullArt) // "Full Art" opens straight into the big view
        model.accessories.refreshBatteries()
        present(preview: false)
        updateKeepAwake()
    }

    private func didUnlock() {
        locked = false
        model.ui.locked = false
        if Prefs.d.bool(forKey: Prefs.unlockSound) { LockSounds.play(lock: false) }
        releaseKeepAwake()
        awakeUntil = nil
        wasPlaying = false
        guard let window else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.25
            window.animator().alphaValue = 0
        } completionHandler: {
            // Keep the window (and its space) alive; just hide it. Re-delegating is what crashes SkyLight.
            MainActor.assumeIsolated { window.orderOut(nil) }
        }
    }

    private func present(preview: Bool) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        WallpaperBackdrop.shared.refresh(for: screen)
        let w = window ?? makeWindow()
        w.setFrame(screen.frame, display: true)
        if !preview, !delegated {
            delegated = SkyLight.moveToLockScreen(w)
        }
        w.alphaValue = 0
        w.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.45
            w.animator().alphaValue = 1
        }
    }

    private func makeWindow() -> NSWindow {
        let w = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()))
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        w.canBecomeVisibleWithoutLogin = true
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = false
        w.contentView = NSHostingView(rootView: LockScreenView().environment(model))
        window = w
        return w
    }

    // MARK: Keep display awake

    /// While locked and playing, keeps the lock screen lit for the chosen number of minutes.
    ///
    /// macOS turns the display off about a minute after locking, on its own timer that ignores
    /// "prevent display sleep" requests. So besides holding that assertion, Pergola reports user
    /// activity every 20 s, which is what resets the lock screen's timer. A new period starts each time
    /// music starts playing; when it runs out the display is allowed to sleep normally.
    func updateKeepAwake() {
        let playing = model.player.isPlaying
        defer { wasPlaying = playing }
        guard locked, Prefs.d.bool(forKey: Prefs.lockKeepAwake), playing, !displaysAsleep else {
            releaseKeepAwake()
            if !playing { awakeUntil = nil }
            return
        }
        if awakeUntil == nil || (playing && !wasPlaying) {
            awakeUntil = Date().addingTimeInterval(max(1, Prefs.d.double(forKey: Prefs.lockKeepAwakeMinutes)) * 60)
        }
        guard let until = awakeUntil, Date() < until else { releaseKeepAwake(); return }

        if awakeAssertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Pergola lock screen is showing music" as CFString, &awakeAssertion)
        }
        if Date().timeIntervalSince(lastActivity) >= 20 {
            lastActivity = Date()
            IOPMAssertionDeclareUserActivity("Pergola lock screen is showing music" as CFString,
                                             kIOPMUserActiveLocal, &activityAssertion)
        }
    }

    private func releaseKeepAwake() {
        if awakeAssertion != 0 { IOPMAssertionRelease(awakeAssertion); awakeAssertion = 0 }
        if activityAssertion != 0 { IOPMAssertionRelease(activityAssertion); activityAssertion = 0 }
        lastActivity = .distantPast
    }
}

enum LockSounds {
    @MainActor static func play(lock: Bool) {
        // Short, soft system sounds that read as "click shut" and "open".
        guard let sound = NSSound(named: lock ? "Pop" : "Tink")?.copy() as? NSSound else { return }
        sound.volume = Float(Prefs.d.double(forKey: Prefs.lockSoundVolume))
        sound.play()
    }
}

// MARK: - Views

/// Full-screen, transparent layout that sits on top of the macOS lock screen. macOS still draws the
/// clock and the password field; Pergola adds widgets under the clock and the player above the login.
struct LockScreenView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.lockLyrics) private var showLyrics = true

    var body: some View {
        ZStack {
            if model.ui.lockBig && model.player.hasTrack {
                LockBigArtView()
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
            } else {
                standard
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
            }
        }
        .environment(\.colorScheme, .dark)
        .animation(.spring(duration: 0.6, bounce: 0.12), value: model.ui.lockBig)
    }

    /// Just the player card, in the lower part of the screen above the login.
    private var standard: some View {
        GeometryReader { geo in
            if model.player.hasTrack {
                LockPlayerCard()
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.7)
                    .transition(AnyTransition(.blurReplace).combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.15), value: model.player.hasTrack)
    }
}

struct LockGlass: ViewModifier {
    var radius: CGFloat
    /// Build the glass from the wallpaper picture (for the full-screen lock window, where real Liquid
    /// Glass can't see the wallpaper). Off for small previews elsewhere, which use real glass.
    var fromWallpaper = false
    @AppStorage(Prefs.lockGlassStyle) private var style = "clear"
    @AppStorage(Prefs.lockGlassCard) private var glassCard = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let frosted = style == "frosted"
        let wallpaper = fromWallpaper && WallpaperBackdrop.shared.sharp != nil
        if glassCard {
            content
                .background {
                    if wallpaper {
                        ZStack {
                            WallpaperGlassFill(frosted: frosted)
                            // Shade so the text stays readable; frosted glass also lifts a little.
                            Color.black.opacity(frosted ? 0.22 : 0.3)
                            if frosted { Color.white.opacity(0.05) }
                        }
                        .clipShape(shape)
                    } else {
                        // Clear glass needs a whisper of shade behind the text to stay readable.
                        shape.fill(.black.opacity(frosted ? 0.04 : 0.12))
                    }
                }
                .modifier(RealGlass(enabled: !wallpaper, frosted: frosted, shape: shape))
                // Light catching the rim and the top edge, as on Apple's own glass.
                .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.5), .white.opacity(0.08), .white.opacity(0.22)],
                                                           startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
                .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.1), .clear], startPoint: .top, endPoint: .center))
                    .allowsHitTesting(false))
                // The drop shadow comes from a separate outline, cut out of the middle. A shadow on the
                // glass itself renders it off-screen, where it can't see the wallpaper and turns flat grey.
                .background {
                    shape.fill(.black)
                        .shadow(color: .black.opacity(0.28), radius: 30, y: 12)
                        .mask {
                            Rectangle().padding(-80)
                                .overlay { shape.blendMode(.destinationOut) }
                                .compositingGroup()
                        }
                        .allowsHitTesting(false)
                }
        } else {
            content.background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(.black.opacity(0.45)))
        }
    }
}

private struct RealGlass<S: Shape>: ViewModifier {
    var enabled: Bool
    var frosted: Bool
    var shape: S
    func body(content: Content) -> some View {
        if enabled { content.glassEffect(frosted ? .regular : .clear, in: shape) } else { content }
    }
}

struct LockPlayerCard: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.lockGlassArt) private var glassArt = true
    @AppStorage(Prefs.colorMatch) private var colorMatch = true

    private var player: NowPlaying { model.player }

    var body: some View {
        let tint = colorMatch ? player.accent : .white
        VStack(spacing: 16) {
            HStack(spacing: 14) {
                Button { model.ui.lockBig = true } label: {
                    LockArt(size: 64, radius: 13, glass: glassArt)
                }
                .buttonStyle(PressStyle())
                .help("Show big album art")
                VStack(alignment: .leading, spacing: 2) {
                    MarqueeText(text: player.title, alignment: .leading)
                        .font(.system(size: 17, weight: .semibold))
                        .frame(height: 22)
                    Text(player.artist)
                        .font(.system(size: 14))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                PlayingIndicator(barCount: 6).frame(width: 26, height: 14)
            }
            ProgressBar(player: player, tint: tint)
            HStack(spacing: 44) {
                ControlButton(symbol: "backward.fill", size: 20) { player.previous() }
                ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 30) { player.playPause() }
                ControlButton(symbol: "forward.fill", size: 20) { player.next() }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20)
        .padding(.vertical, 18)
        .frame(width: 360)
        .modifier(LockGlass(radius: 32, fromWallpaper: true))
    }
}

/// Album art with an optional glassy rim and highlight.
struct LockArt: View {
    @Environment(AppModel.self) private var model
    var size: CGFloat
    var radius: CGFloat
    var glass: Bool

    var body: some View {
        let player = model.player
        ArtworkView(image: player.artwork, cornerRadius: radius)
            .frame(width: size, height: size)
            .overlay {
                if glass {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.25)],
                                                     startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1.2)
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .fill(LinearGradient(colors: [.white.opacity(0.16), .clear], startPoint: .top, endPoint: .center))
                }
            }
            .background(ArtGlow(color: player.artwork == nil ? .black : player.accent, radius: radius,
                                blur: size * 0.12, y: size * 0.05, opacity: 0.45))
    }
}

/// The lock screen's enlarged album-art view. The background becomes the album art; two buttons on
/// the far left close it and toggle lyrics; with lyrics on, the art slides left and lyrics run beside it.
struct LockBigArtView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.lockLyrics) private var lyricsOn = true
    @AppStorage(Prefs.lockGlassArt) private var glassArt = true
    @AppStorage(Prefs.colorMatch) private var colorMatch = true

    private var player: NowPlaying { model.player }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                // The album art becomes the background, fading out above the password field.
                ArtWash(image: player.artwork)
                    .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.68),
                                                 .init(color: .clear, location: 0.84)],
                                         startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea()

                // Fixed positions: clock at the top, player just above centre, and the bottom fifth
                // left clear for macOS's user picture and password field.
                LockClock()
                    .fixedSize()
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.05 + 84)
                content
                    .fixedSize()
                    .position(x: geo.size.width / 2, y: geo.size.height * 0.528)
                // The art background also covers macOS's own battery icon, so show one in its place.
                if model.battery.hasBattery {
                    LockBattery(battery: model.battery)
                        .fixedSize()
                        .position(x: geo.size.width - 58, y: 22)
                }
            }
        }
        .foregroundStyle(.white)
    }

    private var content: some View {
        let tint = colorMatch ? player.accent : .white
        // Still loading counts as having lyrics, so the art doesn't slide to the middle and back on
        // every track change while the next song's lyrics are fetched.
        let hasLyrics = model.lyrics.hasSynced || model.lyrics.plain != nil || model.lyrics.loading
        let showLyrics = lyricsOn && hasLyrics
        // Only the art column and the lyrics are centred on screen; the two side buttons float just
        // left of the art, and the lyrics line up with the middle of the art (not the whole column).
        return HStack(alignment: .artMiddle, spacing: showLyrics ? 72 : 0) {
            VStack(spacing: 16) {
                LockArt(size: 490, radius: 37, glass: glassArt)
                    .alignmentGuide(.artMiddle) { $0[VerticalAlignment.center] }
                    .scaleEffect(player.isPlaying ? 1 : 0.94)
                    .animation(.spring(duration: 0.55, bounce: 0.3), value: player.isPlaying)
                VStack(spacing: 3) {
                    MarqueeText(text: player.title, alignment: .center)
                        .font(.system(size: 28, weight: .bold))
                        .frame(height: 35)
                    Text(player.artist)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                ProgressBar(player: player, tint: tint)
                HStack(spacing: 0) {
                    ShuffleButton(player: player, size: 22, tint: .white)
                    Spacer()
                    ControlButton(symbol: "backward.fill", size: 28) { player.previous() }
                    Spacer()
                    ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 44) { player.playPause() }
                    Spacer()
                    ControlButton(symbol: "forward.fill", size: 28) { player.next() }
                    Spacer()
                    RepeatButton(player: player, size: 22, tint: .white)
                }
                .padding(.horizontal, 6)
                LockVolumeSlider()
                    .padding(.top, 2)
            }
            .frame(width: 490)
            .overlay(alignment: .topLeading) {
                sideControls
                    .frame(height: 490)
                    .alignmentGuide(.leading) { $0.width + 30 }
            }
            if showLyrics {
                SyncedLyricsView(lyrics: model.lyrics, player: player, fontSize: 38, visibleLines: 8)
                .frame(width: 680, height: 600)
                .alignmentGuide(.artMiddle) { $0[VerticalAlignment.center] }
                .shadow(color: .black.opacity(0.25), radius: 10)
                .transition(AnyTransition(.blurReplace).combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.spring(duration: 0.6, bounce: 0.15), value: showLyrics)
    }

    private var sideControls: some View {
        VStack(spacing: 8) {
            sideButton("arrow.down.right.and.arrow.up.left", active: false, help: "Smaller") { model.ui.lockBig = false }
            sideButton("quote.bubble.fill", active: lyricsOn, help: "Lyrics") { lyricsOn.toggle() }
        }
        .padding(5)
        .background(Capsule().fill(.black.opacity(0.22)))
        .overlay(Capsule().stroke(.white.opacity(0.12)))
    }

    private func sideButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(active ? .black : .white.opacity(0.9))
                .frame(width: 42, height: 42)
                .background(Circle().fill(active ? Color.white : .white.opacity(0.14)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// The Mac's charge, where macOS shows it in the lock screen's top-right corner.
struct LockBattery: View {
    var battery: Battery
    var body: some View {
        HStack(spacing: 6) {
            Text("\(battery.percent)%")
                .font(.system(size: 13, weight: .semibold).monospacedDigit())
                .contentTransition(.numericText())
            BatteryGlyph(percent: battery.percent, charging: battery.charging, size: 17)
        }
        .foregroundStyle(.white.opacity(0.92))
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(Capsule().fill(.black.opacity(0.18)))
        .shadow(color: .black.opacity(0.2), radius: 6)
        .animation(.smooth, value: battery.percent)
        .help(battery.charging ? "Charging" : (battery.pluggedIn ? "Plugged in" : "On battery"))
    }
}

/// The art background covers macOS's own clock, so the big view draws its own in the same spot.
struct LockClock: View {
    var body: some View {
        TimelineView(.everyMinute) { ctx in
            VStack(spacing: 2) {
                Text(ctx.date, format: .dateTime.weekday(.wide).month(.wide).day())
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                Text(ctx.date, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute())
                    .font(.system(size: 132, weight: .bold))
                    .tracking(-2)
                    .foregroundStyle(.white.opacity(0.92))
            }
            .shadow(color: .black.opacity(0.2), radius: 10)
        }
    }
}


extension VerticalAlignment {
    /// The vertical middle of the big album art, so the lyrics beside it centre on the art itself.
    private enum ArtMiddle: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let artMiddle = VerticalAlignment(ArtMiddle.self)
}

/// System volume, styled like the progress bar: tap or drag anywhere on the track; the speaker at
/// the left mutes, the one at the right steps up. Follows changes from the volume keys too.
struct LockVolumeSlider: View {
    @State private var level: Double = Double(SystemVolume.level)
    @State private var muted = SystemVolume.muted
    @State private var controllable = SystemVolume.isControllable
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 12) {
            Button { muted.toggle(); SystemVolume.muted = muted } label: {
                Image(systemName: muted || level == 0 ? "speaker.slash.fill" : "speaker.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 22)
            }
            .buttonStyle(PressStyle())
            .help(muted ? "Unmute" : "Mute")

            GeometryReader { geo in
                let shown = muted ? 0 : level
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.2))
                    Capsule().fill(.white.opacity(0.9)).frame(width: max(0, geo.size.width * shown))
                }
                .frame(height: hovering || dragging ? 8 : 5)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        dragging = true
                        set(min(1, max(0, v.location.x / geo.size.width)))
                    }
                    .onEnded { _ in dragging = false })
            }
            .frame(height: 18)
            .onHover { hovering = $0 }

            Button { set(min(1, level + 0.0625)) } label: {
                Image(systemName: "speaker.wave.3.fill").frame(width: 26)
            }
            .buttonStyle(PressStyle())
            .help("Louder")
        }
        .font(.system(size: 14, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
        .opacity(controllable ? 1 : 0.35)
        .disabled(!controllable)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering || dragging)
        .animation(.smooth(duration: 0.2), value: muted)
        .task {
            // Keep in step with the volume keys and output switches while it's on screen.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard !dragging else { continue }
                let l = Double(SystemVolume.level), m = SystemVolume.muted, c = SystemVolume.isControllable
                if abs(l - level) > 0.005 { withAnimation(.smooth(duration: 0.25)) { level = l } }
                if m != muted { muted = m }
                if c != controllable { controllable = c }
            }
        }
    }

    private func set(_ value: Double) {
        level = value
        if muted && value > 0 { muted = false; SystemVolume.muted = false }
        SystemVolume.level = Float(value)
    }
}
