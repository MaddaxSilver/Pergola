import SwiftUI
import CoreImage

/// Compact player: art + title row, full-width progress, one row of controls.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.leftButton) private var leftButton = "shuffle"
    @AppStorage(Prefs.colorMatch) private var colorMatch = true

    private var player: NowPlaying { model.player }
    private var tint: Color { colorMatch ? player.accent : .white }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { withAnimation(Motion.expand) { model.ui.bigArt = true } } label: {
                    ArtworkView(image: player.artwork, cornerRadius: 11)
                        .frame(width: 54, height: 54)
                }
                .buttonStyle(PressStyle())
                .help("Show big album art and lyrics")

                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(text: player.title, alignment: .leading)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 19)
                    Text(player.artist)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }
                .padding(.top, 10)

                Spacer(minLength: 6)

                PlayingIndicator(barCount: 6)
                    .frame(width: 32, height: 17)
                    .frame(maxHeight: .infinity, alignment: .center) // level with the middle of the art
            }
            .frame(height: 54)
            .padding(.leading, -6) // the art sits a little further out than the controls below it

            ProgressBar(player: player, tint: tint)
                .padding(.top, 9)

            HStack(spacing: 0) {
                sideButton
                Spacer()
                ControlButton(symbol: "backward.fill", size: 18) { player.previous() }
                Spacer()
                ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 26) { player.playPause() }
                    .contentTransition(.symbolEffect(.replace))
                Spacer()
                ControlButton(symbol: "forward.fill", size: 18) { player.next() }
                Spacer()
                OutputDeviceButton()
            }
            .padding(.top, 8)
        }
    }

    @ViewBuilder private var sideButton: some View {
        if leftButton == "none" {
            Color.clear.frame(width: 34, height: 30)
        } else if leftButton == "favorite" {
            ControlButton(symbol: player.favorited ? "heart.fill" : "heart", size: 15,
                          active: player.favorited, tint: .pink) { player.toggleFavorite() }
        } else if leftButton == "repeat" {
            RepeatButton(player: player, size: 15, tint: tint)
        } else {
            ShuffleButton(player: player, size: 15, tint: tint)
        }
    }
}

/// A playback-mode toggle in the same plain style as the other controls (bare glyph, soft hover
/// circle). Off, the glyph is dimmed; on, it's fully lit in the player's tint. Changes swap the symbol
/// with a small bounce.
struct ModeButton: View {
    var symbol: String
    var on: Bool
    var size: CGFloat
    var tint: Color
    var help: String
    var action: () -> Void
    @State private var hovering = false
    @State private var taps = 0

    var body: some View {
        Button {
            taps += 1
            action()
        } label: {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .symbolEffect(.bounce.down, value: taps)
                .foregroundStyle(on ? tint : .white.opacity(hovering ? 0.6 : 0.4))
                .frame(width: 34, height: 30)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)).frame(width: 32, height: 32))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .help(help)
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: on)
    }
}

struct ShuffleButton: View {
    var player: NowPlaying
    var size: CGFloat = 14
    var tint: Color = .white
    var body: some View {
        ModeButton(symbol: "shuffle", on: player.shuffle, size: size, tint: tint,
                   help: player.shuffle ? "Shuffle: On" : "Shuffle: Off") { player.toggleShuffle() }
    }
}

/// Off → repeat all → repeat this song (the "1") → off.
struct RepeatButton: View {
    var player: NowPlaying
    var size: CGFloat = 14
    var tint: Color = .white
    var body: some View {
        ModeButton(symbol: player.repeatMode == 1 ? "repeat.1" : "repeat", on: player.repeatMode != 0, size: size, tint: tint,
                   help: ["Repeat: Off", "Repeat: This Song", "Repeat: All"][player.repeatMode]) { player.cycleRepeat() }
    }
}

struct ControlButton: View {
    var symbol: String
    var size: CGFloat
    var active = false
    var dim = false
    var tint: Color = .white
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .contentTransition(.symbolEffect(.replace.downUp))
                .foregroundStyle(active ? tint : .white.opacity(dim ? 0.5 : (hovering ? 1 : 0.88)))
                .frame(width: 34, height: 30)
                .background(Circle().fill(.white.opacity(hovering ? 0.12 : 0)).frame(width: 32, height: 32))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
    }
}

struct ProgressBar: View {
    var player: NowPlaying
    var tint: Color
    @State private var dragFraction: Double?
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !player.isPlaying || dragFraction != nil)) { ctx in
            let pos = player.currentPosition(at: ctx.date)
            let frac = dragFraction ?? (player.duration > 0 ? pos / player.duration : 0)
            HStack(spacing: 8) {
                Text(Self.format(dragFraction.map { $0 * player.duration } ?? pos))
                    .frame(width: 34, alignment: .leading)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        Capsule().fill(tint).frame(width: max(0, geo.size.width * min(1, frac)))
                    }
                    .frame(height: hovering || dragFraction != nil ? 7 : 4.5)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { v in dragFraction = min(1, max(0, v.location.x / geo.size.width)) }
                        .onEnded { _ in
                            if let f = dragFraction, player.duration > 0 { player.seek(to: f * player.duration) }
                            dragFraction = nil
                        })
                }
                .frame(height: 14)
                .onHover { hovering = $0 }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: hovering)
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: dragFraction != nil)
                Text(Self.format(max(0, player.duration - pos)))
                    .frame(width: 34, alignment: .trailing)
            }
            .font(.system(size: 10.5, weight: .medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.55))
        }
    }

    static func format(_ s: Double) -> String {
        guard s.isFinite else { return "0:00" }
        let t = Int(s.rounded(.down))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, t / 60 % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// Live waveform bars when capture is running; a gentle, capture-free animation otherwise.
/// Bars are real capsules whose height changes (never squashed), so they stay perfectly round,
/// and rest as round dots when paused.
struct PlayingIndicator: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.colorMatch) private var colorMatch = true
    var barCount: Int

    var body: some View {
        let player = model.player
        let wave = model.waveform
        let tint = colorMatch ? player.accent : .white
        GeometryReader { geo in
            let spacing = max(1.5, geo.size.width / CGFloat(barCount) * 0.38)
            let barWidth = (geo.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount)
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: !player.isPlaying || wave.active)) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                HStack(alignment: .center, spacing: spacing) {
                    ForEach(0..<barCount, id: \.self) { i in
                        let level: Double = {
                            guard player.isPlaying else { return 0 }
                            if wave.active { return Double(wave.level(i, of: barCount)) }
                            // No capture: a soft, layered bounce so the notch still feels alive.
                            let a = sin(t * (4.1 + Double(i) * 0.9) + Double(i) * 1.7)
                            let b = sin(t * (2.3 + Double(i) * 0.5) + Double(i))
                            return 0.42 + 0.22 * a + 0.16 * b
                        }()
                        Capsule(style: .continuous)
                            .fill(tint.opacity(player.isPlaying ? 1 : 0.55))
                            .frame(width: barWidth,
                                   height: max(barWidth, geo.size.height * CGFloat(min(1, max(0, level)))))
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .animation(.interpolatingSpring(stiffness: 260, damping: 20), value: wave.levels)
            .animation(.spring(response: 0.4, dampingFraction: 0.8), value: player.isPlaying)
        }
    }
}

/// Buttons sink slightly under your finger and spring back.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.84 : 1)
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

// MARK: - Big album art

/// The enlarged album-art view: huge artwork over a wash of its own colours, with synced lyrics
/// that slide in beside it. Two small buttons on the far left close it and toggle lyrics.
struct BigArtView: View {
    @Environment(AppModel.self) private var model
    private var player: NowPlaying { model.player }
    private var ui: NotchUI { model.ui }

    var body: some View {
        let showLyrics = ui.bigArtLyrics
        HStack(alignment: .center, spacing: showLyrics ? 22 : 0) {
            sideControls
            if !showLyrics { Spacer(minLength: 0) }
            VStack(spacing: 10) {
                ArtworkView(image: player.artwork, cornerRadius: 18)
                    .frame(width: 200, height: 200)
                    .background(ArtGlow(color: player.accent, radius: 18, blur: 26, y: 10, opacity: 0.5))
                    .scaleEffect(player.isPlaying ? 1 : 0.92)
                    .animation(.spring(duration: 0.5, bounce: 0.3), value: player.isPlaying)
                    .onTapGesture { player.playPause() }
                VStack(spacing: 1) {
                    MarqueeText(text: player.title, alignment: .center)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: 18)
                    Text(player.artist)
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(1)
                }
                .frame(width: 200)
            }
            if showLyrics {
                lyrics
                    .frame(width: NotchUI.lyricsWidth)
                    .frame(maxHeight: .infinity)
                    .transition(AnyTransition.opacity.combined(with: .offset(x: 40)))
            } else {
                Spacer(minLength: 0)
                Color.clear.frame(width: 30) // balances the side buttons so the art sits dead centre
            }
        }
        .animation(.spring(duration: 0.5, bounce: 0.15), value: showLyrics)
    }

    private var sideControls: some View {
        VStack(spacing: 6) {
            sideButton("arrow.down.right.and.arrow.up.left", active: false, help: "Back to the player") {
                withAnimation(Motion.collapse) { model.ui.bigArt = false }
            }
            sideButton("quote.bubble.fill", active: ui.bigArtLyrics, help: "Lyrics") {
                model.ui.bigArtLyrics.toggle()
            }
        }
        .padding(4)
        .background(Capsule().fill(.black.opacity(0.25)))
        .overlay(Capsule().stroke(.white.opacity(0.1)))
    }

    private func sideButton(_ symbol: String, active: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11.5, weight: .bold))
                .foregroundStyle(active ? .black : .white.opacity(0.85))
                .frame(width: 26, height: 26)
                .background(Circle().fill(active ? Color.white : .white.opacity(0.12)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    @ViewBuilder private var lyrics: some View {
        if model.lyrics.hasSynced || model.lyrics.loading || !(model.lyrics.plain ?? "").isEmpty {
            SyncedLyricsView(lyrics: model.lyrics, player: player, fontSize: 19, visibleLines: 6)
        } else {
            VStack(spacing: 6) {
                Image(systemName: "quote.bubble").font(.system(size: 20))
                Text("No lyrics for this song").font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.5))
        }
    }
}

/// The album art, blurred and saturated, filling the whole pill behind the big-art view.
struct ArtWash: View {
    var image: NSImage?
    var body: some View {
        ZStack {
            if let image {
                // A small, pre-blurred copy made once per cover: blurring the full-size art live across
                // the whole lock screen cost two huge passes per frame while covers cross-faded.
                Image(nsImage: ArtWashCache.wash(for: image))
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(1.25)
                    .id(ObjectIdentifier(image))
                    .transition(.opacity.animation(.easeInOut(duration: 0.7)))
            }
            LinearGradient(colors: [.black.opacity(0.15), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .clipped()
    }
}

/// Makes and keeps the blurred, saturated background versions of album covers.
@MainActor
enum ArtWashCache {
    private static var cache: [(source: NSImage, wash: NSImage)] = []
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func wash(for source: NSImage) -> NSImage {
        if let hit = cache.first(where: { $0.source === source }) { return hit.wash }
        guard let cg = ArtResampler.image(source, pixels: 96).cgImage(forProposedRect: nil, context: nil, hints: nil) else { return source }
        let input = CIImage(cgImage: cg).clampedToExtent()
        let blurred = input
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.4])
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5])
            .cropped(to: CIImage(cgImage: cg).extent)
        guard let out = context.createCGImage(blurred, from: blurred.extent) else { return source }
        let wash = NSImage(cgImage: out, size: NSSize(width: out.width, height: out.height))
        cache.append((source, wash))
        if cache.count > 6 { cache.removeFirst() }
        return wash
    }
}

/// The coloured glow under a cover, drawn from a plain blurred shape that doesn't change while the
/// cover turns (a shadow on the turning cover itself has to be recomputed on every frame).
struct ArtGlow: View {
    var color: Color
    var radius: CGFloat
    var blur: CGFloat
    var y: CGFloat
    var opacity: Double
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(color.opacity(opacity))
            .padding(blur * 0.25)
            .blur(radius: blur)
            .offset(y: y)
            .animation(.easeInOut(duration: 0.8), value: color)
    }
}
