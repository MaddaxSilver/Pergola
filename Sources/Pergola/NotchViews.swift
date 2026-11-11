import SwiftUI
import AppKit

enum NotchMetrics {
    /// The small outward curve where the notch meets the menu bar.
    static let flare: CGFloat = 10
    static let collapsedBottomRadius: CGFloat = 13
    static let expandedBottomRadius: CGFloat = 34
}

/// Every animation in Pergola comes from here so the whole app moves with one feel.
enum Motion {
    // Tuned to feel like the Dynamic Island: a lively open, a calm settle, no wobble on close.
    static let expand = Animation.spring(duration: 0.52, bounce: 0.22)
    static let collapse = Animation.spring(duration: 0.4, bounce: 0)
    static let hover = Animation.spring(duration: 0.35, bounce: 0.3)
    static let peek = Animation.spring(duration: 0.5, bounce: 0.2)
    static let content = Animation.spring(duration: 0.42, bounce: 0.1)

    /// iOS page-view settle: critically damped, starting at the finger's release speed.
    /// `velocity` is in points per second; `distance` is how far the strip still has to travel.
    static func pageSettle(velocity: CGFloat, distance: CGFloat) -> Animation {
        let relative = abs(distance) > 1 ? Double(velocity / -distance) : 0
        return .interpolatingSpring(mass: 1, stiffness: 260, damping: 32, initialVelocity: max(-12, min(12, relative)))
    }
}

/// A notch silhouette: concave flared top corners, rounded bottom corners.
/// `rect` includes the flares, so the body is `rect.width - 2 * topRadius` wide.
struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(topRadius, bottomRadius) }
        set { topRadius = newValue.first; bottomRadius = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let t = topRadius
        let b = min(bottomRadius, (r.height - t) / 2, (r.width - 2 * t) / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + t, y: r.minY + t), control: CGPoint(x: r.minX + t, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + t, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + t + b, y: r.maxY), control: CGPoint(x: r.minX + t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - t, y: r.maxY - b), control: CGPoint(x: r.maxX - t, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - t, y: r.minY + t))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - t, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct NotchRootView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.liquidGlass) private var liquidGlass = true
    @AppStorage(Prefs.glassDarkness) private var glassDarkness = 0.85

    private var ui: NotchUI { model.ui }

    private var bodySize: CGSize {
        if ui.expanded { return ui.expandedSize }
        var w = ui.notchSize.width
        var h = ui.notchSize.height
        let drop = dropShown
        if model.showsWings { w += 2 * ui.wingWidth }
        if drop { h += NotchUI.dropHeight } // straight down: an overlay never makes the notch wider
        if ui.hovering { w += 10; h += 3 } // a small lift before it opens
        return CGSize(width: w, height: h)
    }

    /// An overlay's line is showing under the closed notch.
    private var dropShown: Bool { !ui.expanded && ui.peek?.dropsDown(apple: ui.appleStyleSensory) == true }

    private var shape: NotchShape {
        NotchShape(topRadius: NotchMetrics.flare,
                   bottomRadius: ui.expanded ? NotchMetrics.expandedBottomRadius : NotchMetrics.collapsedBottomRadius)
    }

    var body: some View {
        let size = bodySize
        VStack(spacing: 10) {
            ZStack(alignment: .top) {
                background
                content
                    .padding(.horizontal, NotchMetrics.flare)
            }
            // Top-aligned: mid-spring the content is taller than the outline, and a centred frame would
            // push its top up past the screen edge.
            .frame(width: size.width + 2 * NotchMetrics.flare, height: size.height, alignment: .top)
            .clipShape(shape)
                .overlay {
                // A hairline rim on the open pill, like the edge of a sheet of glass. Faded out across the top
                // band so no line ever shows along the screen edge or around the hardware notch.
                shape.stroke(.white.opacity(ui.expanded || (dropShown && liquidGlass) ? 0.09 : 0), lineWidth: 1)
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                                 .init(color: .clear, location: min(0.9, (ui.notchSize.height + 6) / max(size.height, 1))),
                                                 .init(color: .black, location: min(1, (ui.notchSize.height + 40) / max(size.height, 1)))],
                                         startPoint: .top, endPoint: .bottom))
            }
            .background {
                // The drop shadow comes from a plain copy of the outline (cheap), cut out of the middle
                // so it never darkens the glass. Shadowing the glass view itself re-renders all of it
                // offscreen on every frame of the open/close spring.
                shape.fill(.black)
                    .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
                    .mask {
                        Rectangle().padding(-60)
                            .overlay { shape.blendMode(.destinationOut) }
                            .compositingGroup()
                    }
                    .opacity(ui.expanded ? 1 : (dropShown ? 0.6 : 0))
            }

            // "Apple Style" Sensory: a floating glass capsule under the notch instead of in it.
            if ui.appleStyleSensory, case .sensory(let kind, let level, let muted) = ui.peek {
                AppleStyleHUD(kind: kind, level: level, muted: muted)
                    .transition(.riseFromBelow(distance: 18))
            }
        }
        .opacity(ui.hidden ? 0 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }

    /// A black fade from `from` to `to` opacity between two heights (0…1), following a smootherstep
    /// curve sampled finely, so there's no visible edge where the fade begins or ends and no banding
    /// in between (a plain two-stop gradient leaves a hard "shelf" at both ends).
    static func easedFade(from: Double, to: Double, start: CGFloat, end: CGFloat) -> [Gradient.Stop] {
        let a = min(max(start, 0), 1), b = min(max(end, a + 0.01), 1)
        var stops: [Gradient.Stop] = [.init(color: .black.opacity(from), location: 0)]
        let n = 16
        for i in 0...n {
            let x = Double(i) / Double(n)
            let e = x * x * x * (x * (x * 6 - 15) + 10) // smootherstep
            stops.append(.init(color: .black.opacity(from + (to - from) * e), location: a + (b - a) * CGFloat(x)))
        }
        stops.append(.init(color: .black.opacity(to), location: 1))
        return stops
    }

    /// Black and glass are both always present and cross-fade, so opening never "pops".
    ///
    /// Open, the pill is solid black from the screen edge down through most of its height (so it
    /// reads as one piece with the hardware notch), then melts into clear Liquid Glass along the
    /// bottom edge, where the wallpaper shows through the lens. In big-art mode the album colours
    /// take over instead, with black kept only around the hardware notch.
    private var background: some View {
        // An overlay's drop-down line gets the same treatment as the open notch: black around the
        // hardware notch, melting into glass along the bottom.
        let drop = dropShown
        let glass = (ui.expanded || drop) && liquidGlass
        let art = ui.expanded && ui.bigArt
        let size = bodySize
        // The "Clear Glass ↔ Dark" slider (0.15…0.95) drives the whole look:
        //   Clear → the black ends just below the hardware notch and the glass underneath is undimmed;
        //   Dark  → the black reaches about two-thirds of the way down over well-dimmed glass.
        let t = min(1, max(0, (glassDarkness - 0.15) / 0.8))
        let notchEdge = (ui.notchSize.height + 16) / max(size.height, 1)
        let fadeStart = drop
            ? min(0.8, (ui.notchSize.height - 4) / max(size.height, 1))
            : min(0.8, max(0.2, notchEdge + 0.32 * t))
        let span = 1 - fadeStart
        let bottomDim = 0.8 * t
        return Color.clear.overlay(alignment: .top) {
            ZStack(alignment: .top) {
                // Dimming sits *behind* the glass so its rim light and lensing stay crisp on top.
                // One layer that morphs (never two that cross-fade, which goes see-through halfway).
                let artDim = 0.1 + glassDarkness * 0.85
                BlackFade(top: glass && art ? artDim : 1,
                          bottom: glass ? (art ? artDim : bottomDim) : 1,
                          start: glass && art ? 0 : fadeStart, end: 1)
                Color.clear
                    .glassEffect(art ? .regular : .clear, in: shape)
                    .opacity(glass ? 1 : 0)
                if art {
                    ArtWash(image: model.player.artwork)
                        .transition(.opacity)
                }
                // Solid black on top of the glass: everything above `fadeStart`, easing out to nothing
                // just before the bottom edge, so the glass only shows where the pill meets the desktop.
                // Closed it's solid; opening, its lower part eases away to reveal the glass.
                BlackFade(top: art ? 0 : 1, bottom: ui.expanded || drop ? 0 : 1,
                          start: fadeStart, end: fadeStart + span * 0.8)
                if art {
                    // Keep the menu bar edge and hardware notch seamless above the album colours.
                    LinearGradient(colors: [.black.opacity(0.55), .black.opacity(0)], startPoint: .top, endPoint: .bottom)
                        .frame(height: ui.notchSize.height + 24)
                        .frame(maxHeight: .infinity, alignment: .top)
                }
                if ui.hasNotch {
                    UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                        .fill(.black)
                        .frame(width: ui.notchSize.width + 8, height: ui.notchSize.height + 3)
                        .blur(radius: 3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
    }

    @ViewBuilder private var content: some View {
        if ui.expanded {
            ExpandedView()
                // Laid out once at the open size, so nothing inside reflows while the notch springs open:
                // the growing outline simply reveals content that's already in place.
                .frame(width: ui.expandedSize.width, height: ui.expandedSize.height, alignment: .top)
                // Opacity + scale only: these run on the GPU compositor for free, where a blur over the
                // whole open notch costs a full offscreen pass every frame and makes the spring stutter.
                .transition(.asymmetric(
                    insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                        .animation(.spring(duration: 0.4, bounce: 0.12).delay(0.07)),
                    removal: AnyTransition.opacity.combined(with: .scale(scale: 0.9, anchor: .top))
                        .animation(.easeOut(duration: 0.18))))
        } else {
            CollapsedView()
                .transition(.asymmetric(
                    insertion: AnyTransition.opacity.combined(with: .scale(scale: 0.88))
                        .animation(.spring(duration: 0.32, bounce: 0.1).delay(0.18)),
                    removal: AnyTransition.opacity.animation(.easeOut(duration: 0.1))))
        }
    }
}

/// A black fill fading from `top` to `bottom` opacity between `start` and `end` (fractions of the
/// height), on a smooth curve. All four values animate, so the notch morphs between solid (closed)
/// and black-into-glass (open) in one continuous motion.
struct BlackFade: View, Animatable {
    var top: Double
    var bottom: Double
    var start: CGFloat
    var end: CGFloat

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, AnimatablePair<CGFloat, CGFloat>> {
        get { .init(.init(top, bottom), .init(start, end)) }
        set { top = newValue.first.first; bottom = newValue.first.second; start = newValue.second.first; end = newValue.second.second }
    }

    var body: some View {
        LinearGradient(stops: NotchRootView.easedFade(from: top, to: bottom, start: start, end: end),
                       startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Collapsed

/// How the small indicators beside and under the notch arrive: they wait until the notch has mostly
/// widened, then rise into place from just below, sharpening as they come. Leaving, they sink and
/// fade quickly so they're gone before the notch narrows back.
struct RiseFromBelow: ViewModifier {
    var progress: Double // 0 = hidden below, 1 = in place
    var distance: CGFloat

    func body(content: Content) -> some View {
        content
            .offset(y: (1 - progress) * distance)
            .scaleEffect(0.82 + 0.18 * progress, anchor: .bottom)
            .opacity(progress)
    }
}

extension AnyTransition {
    static var riseFromBelow: AnyTransition { riseFromBelow(distance: 12) }

    static func riseFromBelow(distance: CGFloat) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: RiseFromBelow(progress: 0, distance: distance),
                                 identity: RiseFromBelow(progress: 1, distance: distance))
                .animation(.spring(duration: 0.45, bounce: 0.22).delay(0.16)),
            removal: .modifier(active: RiseFromBelow(progress: 0, distance: distance * 0.6),
                               identity: RiseFromBelow(progress: 1, distance: distance * 0.6))
                .animation(.easeIn(duration: 0.14)))
    }
}

struct CollapsedView: View {
    @Environment(AppModel.self) private var model
    private var ui: NotchUI { model.ui }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                leftWing.frame(width: ui.wingWidth, height: ui.notchSize.height)
                Spacer(minLength: ui.notchSize.width)
                rightWing.frame(width: ui.wingWidth, height: ui.notchSize.height)
            }
            .frame(height: ui.notchSize.height)

            // Every overlay arrives the same way: one line that drops down from under the notch.
            if let peek = ui.peek, peek.dropsDown(apple: ui.appleStyleSensory) {
                dropLine(peek)
                    .frame(height: NotchUI.dropHeight - 4)
                    .padding(.horizontal, 12)
                    .transition(.riseFromBelow)
            }
        }
    }

    private static let focusTint = Color(red: 0.62, green: 0.6, blue: 1.0)

    private static func tint(for state: LiveActivity.State) -> Color {
        switch state {
        case .done: Color(red: 0.2, green: 0.84, blue: 0.42)
        case .failed: Color(red: 1.0, green: 0.36, blue: 0.33)
        case .waiting: Color(red: 1.0, green: 0.7, blue: 0.25)
        case .running: .white.opacity(0.6)
        }
    }

    private func glyph(_ name: String, tint: Color = .white) -> some View {
        Image(systemName: name)
            .symbolRenderingMode(.hierarchical)
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
    }

    private func label(_ text: String, tint: Color = .white.opacity(0.88)) -> some View {
        Text(text)
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// The line under the notch: a small glyph, then words (or the level bar), centred.
    @ViewBuilder private func dropLine(_ peek: Peek) -> some View {
        switch peek {
        case .track:
            MarqueeText(text: [model.player.title, model.player.artist].filter { !$0.isEmpty }.joined(separator: " — "))
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
        case .activity(let title, let status, let state):
            HStack(spacing: 6) {
                label(title)
                label(status, tint: Self.tint(for: state)).layoutPriority(1)
            }
        case .sensory(let kind, let level, let muted):
            HStack(spacing: 9) {
                SensoryLabel(kind: kind, level: level, muted: muted)
                SensoryBar(level: muted ? 0 : level).frame(maxWidth: 130).frame(height: 5)
            }
        case .output(let name, let symbol):
            HStack(spacing: 6) { glyph(symbol); label(Self.shortName(name)) }
        case .focus(let name, let symbol, let on):
            HStack(spacing: 6) {
                glyph(symbol, tint: on ? Self.focusTint : .white.opacity(0.45))
                label(on ? name : "\(name) Off", tint: on ? Self.focusTint : .white.opacity(0.55))
            }
        case .charging(let percent, let charging):
            HStack(spacing: 6) {
                BatteryGlyph(percent: percent, charging: charging, size: 13.5)
                label(charging ? "Charging" : "On Battery")
                label("\(percent)%", tint: .white.opacity(0.55))
            }
        case .accessory(let acc):
            HStack(spacing: 6) {
                glyph(acc.symbol)
                label(Self.shortName(acc.name))
                if let level = acc.headline { label("\(level)%", tint: .white.opacity(0.55)) }
            }
        }
    }

    // The wings never change for an overlay: album art and the waveform, or a task's icon and ring.
    @ViewBuilder private var leftWing: some View {
        Group {
            if model.showsMusicWings {
                ArtworkView(image: model.player.artwork, cornerRadius: 5)
                    .frame(width: ui.notchSize.height - 10, height: ui.notchSize.height - 10)
            } else if let activity = model.activities.current {
                ActivityGlyph(activity: activity, size: 14)
            }
        }
        .transition(.riseFromBelow)
    }

    @ViewBuilder private var rightWing: some View {
        Group {
            // An app's progress takes the right wing; music keeps its artwork on the left.
            if let activity = model.activities.current {
                ActivityRing(activity: activity, size: 20, lineWidth: 3)
            } else if model.showsMusicWings {
                PlayingIndicator(barCount: 5)
                    .frame(width: 22, height: ui.notchSize.height * 0.4)
            }
        }
        .transition(.riseFromBelow)
    }

    /// "Alex’s AirPods Pro" → "AirPods Pro", so it fits beside the notch.
    static func shortName(_ name: String) -> String {
        if let r = name.range(of: "’s ") ?? name.range(of: "'s ") { return String(name[r.upperBound...]) }
        return name
    }
}

// MARK: - Expanded

/// The open notch is a horizontal pager: Files ← Media → Weather.
/// All pages sit side by side and the whole strip follows your fingers, like an iOS page view.
struct ExpandedView: View {
    @Environment(AppModel.self) private var model
    private var ui: NotchUI { model.ui }

    var body: some View {
        if ui.bigArt {
            BigArtView()
                .padding(.horizontal, 20)
                .padding(.top, ui.notchSize.height + 8)
                .padding(.bottom, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
        } else {
            pager
                // Always laid out at the player's own width, so nothing inside reflows while the pill
                // springs back from the big-art size.
                .frame(width: NotchUI.pagerWidth)
                .transition(AnyTransition.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
        }
    }

    private var pager: some View {
        let pages = ui.pages
        let index = CGFloat(pages.firstIndex(of: ui.tab) ?? 0)
        return GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                ForEach(Array(pages.enumerated()), id: \.element) { i, page in
                    // How far this page is from the centre, in pages (0 = fully on screen).
                    let distance = abs((CGFloat(i) - index) * w + ui.dragOffset) / max(w, 1)
                    // Pages fully off screen aren't drawn at all (they'd still cost a blur pass every
                    // frame); a neighbour appears the moment a swipe starts revealing it.
                    Group {
                        if distance < 0.999 {
                            pageView(page)
                                .padding(.horizontal, 22)
                                .padding(.bottom, 10)
                                .opacity(1 - distance * 0.75)
                                .scaleEffect(1 - distance * 0.06)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: w, height: geo.size.height, alignment: .top)
                }
            }
            .offset(x: -index * w + ui.dragOffset)
        }
    }

    @ViewBuilder private func pageView(_ page: NotchTab) -> some View {
        switch page {
        case .player:
            Group {
                if model.player.hasTrack && Prefs.d.bool(forKey: Prefs.mediaPlayer) { PlayerView() } else { NotPlayingView() }
            }
            .padding(.top, max(14, ui.notchSize.height - 12))
        case .weather:
            WeatherTab(weather: model.weather)
                .padding(.top, ui.notchSize.height + 2)
        case .tray:
            TrayView()
                .padding(.top, ui.notchSize.height + 4)
        case .calendar:
            CalendarPage()
                .padding(.top, ui.notchSize.height + 4)
        case .activity:
            ActivitiesPage()
                .padding(.top, ui.notchSize.height + 6)
        case .rings:
            RingsPage()
                .padding(.top, ui.notchSize.height - 2)
        }
    }
}

struct NotPlayingView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.system(size: 22))
                .foregroundStyle(.white.opacity(0.4))
            Text("Not Playing")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.55))
            Button("Open Music") {
                if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Music") {
                    NSWorkspace.shared.openApplication(at: url, configuration: .init())
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.7))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct BatteryGlyph: View {
    var percent: Int
    var charging: Bool
    var size: CGFloat = 14

    var body: some View {
        let name: String = switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
        Image(systemName: charging ? "battery.100percent.bolt" : name)
            .symbolRenderingMode(.palette)
            .foregroundStyle(charging ? .green : (percent < 20 ? .red : .white), .white.opacity(0.5))
            .font(.system(size: size))
    }
}

struct ArtworkView: View {
    var image: NSImage?
    var cornerRadius: CGFloat
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geo in
            let side = max(geo.size.width, geo.size.height)
            // Big covers (enlarged view, lock screen) turn more gently and settle slower: a wide swing
            // reads as heavy at 200–400 pt, and blurring that much image mid-turn costs frames.
            let big = side > 160
            let angle: Double = big ? 38 : 62
            let scale: CGFloat = big ? 0.92 : 0.86
            let blur: CGFloat = big ? 0 : 3
            ZStack {
                if let image {
                    // Each cover is its own rounded card, so the whole card (corners included) turns
                    // on a track change, rather than the picture swinging inside a fixed frame.
                    Image(nsImage: ArtResampler.image(image, pixels: side * displayScale))
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                        .id(ObjectIdentifier(image))
                        .transition(.asymmetric(
                            insertion: .modifier(active: ArtTurn(angle: -angle, scale: scale, opacity: 0, blur: blur),
                                                 identity: ArtTurn(angle: 0, scale: 1, opacity: 1, blur: 0)),
                            removal: .modifier(active: ArtTurn(angle: angle, scale: scale, opacity: 0, blur: blur),
                                               identity: ArtTurn(angle: 0, scale: 1, opacity: 1, blur: 0))))
                } else {
                    ZStack {
                        LinearGradient(colors: [.gray.opacity(0.5), .gray.opacity(0.25)], startPoint: .top, endPoint: .bottom)
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.38, weight: .medium))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .transition(.opacity)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(big ? .spring(duration: 0.9, bounce: 0.06) : .spring(duration: 0.7, bounce: 0.14),
                       value: image.map(ObjectIdentifier.init))
        }
    }
}

/// Rotation around the vertical axis with a touch of scale and blur, used when the album art changes.
struct ArtTurn: ViewModifier {
    var angle: Double
    var scale: CGFloat
    var opacity: Double
    var blur: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), anchor: .center, perspective: 0.35)
            .scaleEffect(scale)
            .blur(radius: blur)
            .opacity(opacity)
    }
}

/// Album art is 1000+ px square; drawing it at 40–60 pt makes the GPU skip most of the pixels, which
/// looks grainy and shimmers while the cover moves. This makes one properly filtered copy per size
/// the art is actually shown at (rounded up, so a few sizes cover every view) and caches it.
@MainActor
enum ArtResampler {
    // The source is kept alongside its copy, so its address can't be reused by another cover while cached.
    private static var cache: [String: (source: NSImage, image: NSImage)] = [:]
    private static var order: [String] = []

    static func image(_ source: NSImage, pixels: CGFloat) -> NSImage {
        let bucket = Int((max(64, pixels) / 64).rounded(.up)) * 64
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil),
              bucket < min(cg.width, cg.height) else { return source }
        let key = "\(ObjectIdentifier(source).hashValue)-\(bucket)"
        if let hit = cache[key], hit.source === source { return hit.image }

        let ratio = CGFloat(cg.width) / CGFloat(cg.height)
        let w = ratio >= 1 ? Int(CGFloat(bucket) * ratio) : bucket
        let h = ratio >= 1 ? bucket : Int(CGFloat(bucket) / ratio)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: cg.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return source }
        ctx.interpolationQuality = .high
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return source }
        let img = NSImage(cgImage: out, size: NSSize(width: w, height: h))
        cache[key] = (source, img)
        order.append(key)
        if order.count > 24 { cache[order.removeFirst()] = nil }
        return img
    }
}

/// Scrolls text horizontally when it doesn't fit.
struct MarqueeText: View {
    var text: String
    var alignment: Alignment = .center
    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let overflow = textWidth > geo.size.width
            TimelineView(.animation(paused: !overflow)) { ctx in
                let gap: CGFloat = 40
                let cycle = Double(textWidth + gap) / 30.0 // 30 pt/s
                let t = overflow ? ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) : 0
                HStack(spacing: gap) {
                    Text(text).fixedSize()
                    if overflow { Text(text).fixedSize() }
                }
                .offset(x: -CGFloat(t * 30))
                .frame(width: geo.size.width, alignment: overflow ? .leading : alignment)
            }
            .clipped()
        }
        .background(Text(text).fixedSize().hidden().onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 })
    }
}
