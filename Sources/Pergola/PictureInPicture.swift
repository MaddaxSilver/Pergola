import SwiftUI
import AppKit

// MARK: - Springs

/// One value pulled toward a target by a damped spring, stepped by hand every frame. Hand-stepped
/// springs keep their velocity when the target moves mid-flight, which is what makes the water
/// feel continuous: it carries momentum, overshoots and wobbles like the real thing.
struct Springy {
    var x: CGFloat
    var v: CGFloat = 0
    var target: CGFloat
    private var k: CGFloat = 0
    private var c: CGFloat = 0

    init(_ x: CGFloat, response: CGFloat = 0.4, damping: CGFloat = 0.8) {
        self.x = x; target = x; tune(response: response, damping: damping)
    }

    /// `response` is roughly the period in seconds; `damping` 1 = no overshoot, lower = wobble.
    mutating func tune(response: CGFloat, damping: CGFloat) {
        k = pow(2 * .pi / response, 2)
        c = 4 * .pi * damping / response
    }

    mutating func snap(_ value: CGFloat) { x = value; target = value; v = 0 }

    mutating func step(_ dt: CGFloat) {
        // Two half steps: stays stable with the stiff springs used for following the pointer.
        for _ in 0..<2 {
            let h = dt / 2
            let a = -k * (x - target) - c * v
            v += a * h
            x += v * h
        }
    }

    var settled: Bool { abs(x - target) < 0.5 && abs(v) < 6 }
}

/// A drop of water: where it is, how big, and how it's squashed or stretched right now.
struct Drop {
    var cx = Springy(0), cy = Springy(0), w = Springy(0), h = Springy(0)
    /// Squash and stretch, 1 = at rest. Lightly damped so a jolt sets it wobbling.
    var sx = Springy(1, response: 0.3, damping: 0.32), sy = Springy(1, response: 0.3, damping: 0.32)

    var rect: CGRect {
        let W = max(0, w.x * sx.x), H = max(0, h.x * sy.x)
        return CGRect(x: cx.x - W / 2, y: cy.x - H / 2, width: W, height: H)
    }
    var restRect: CGRect { CGRect(x: cx.x - w.x / 2, y: cy.x - h.x / 2, width: w.x, height: h.x) }
    var center: CGPoint { CGPoint(x: cx.x, y: cy.x) }
    var velocity: CGPoint { CGPoint(x: cx.v, y: cy.v) }

    mutating func move(response: CGFloat, damping: CGFloat) {
        cx.tune(response: response, damping: damping); cy.tune(response: response, damping: damping)
    }
    mutating func resize(response: CGFloat, damping: CGFloat) {
        w.tune(response: response, damping: damping); h.tune(response: response, damping: damping)
    }
    mutating func snap(_ r: CGRect) {
        cx.snap(r.midX); cy.snap(r.midY); w.snap(r.width); h.snap(r.height); sx.snap(1); sy.snap(1)
    }
    mutating func aim(center c: CGPoint) { cx.target = c.x; cy.target = c.y }
    mutating func aim(size s: CGSize) { w.target = s.width; h.target = s.height }
    mutating func aim(_ r: CGRect) { aim(center: CGPoint(x: r.midX, y: r.midY)); aim(size: r.size) }
    mutating func step(_ dt: CGFloat) {
        cx.step(dt); cy.step(dt); w.step(dt); h.step(dt); sx.step(dt); sy.step(dt)
    }
    var settled: Bool { cx.settled && cy.settled && w.settled && h.settled }
}

// MARK: - What the overlay draws

/// One frame of water, in the overlay's own coordinates (top-left origin).
struct GooFrame {
    struct Blob: Identifiable { var id: String; var rect: CGRect; var radius: CGFloat }
    var blobs: [Blob] = []
    /// The picture the drop carries.
    var content: CGRect?
    var contentRadius: CGFloat = 12
    var contentAlpha: Double = 1

    var bounds: CGRect? {
        var r: CGRect?
        for b in blobs { r = r?.union(b.rect) ?? b.rect }
        if let c = content { r = r?.union(c) ?? c }
        guard let r else { return nil }
        // Rounded out to a coarse grid so the glass layer isn't re-sized on every frame.
        let g: CGFloat = 48
        let x0 = floor((r.minX - 40) / g) * g, y0 = floor((r.minY - 40) / g) * g
        let x1 = ceil((r.maxX + 40) / g) * g, y1 = ceil((r.maxY + 40) / g) * g
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }
}

@Observable @MainActor
final class Goo {
    var frame = GooFrame()
}

/// The water is real Liquid Glass: every drop and every bead of the neck is a glass shape in one
/// container, so macOS itself melts them together when they're close and lets them part when the
/// neck gets thin enough, with the lensing and rim light of the rest of the system.
struct GooView: View {
    @Environment(AppModel.self) private var model
    let goo: Goo

    var body: some View {
        let f = goo.frame
        ZStack(alignment: .topLeading) {
            if let box = f.bounds {
                GlassEffectContainer(spacing: 14) {
                    ZStack(alignment: .topLeading) {
                        ForEach(f.blobs) { b in
                            Color.clear
                                .frame(width: b.rect.width, height: b.rect.height)
                                .glassEffect(.clear.tint(.white.opacity(0.04)),
                                             in: RoundedRectangle(cornerRadius: b.radius, style: .continuous))
                                .offset(x: b.rect.minX - box.minX, y: b.rect.minY - box.minY)
                        }
                    }
                    .frame(width: box.width, height: box.height, alignment: .topLeading)
                }
                .frame(width: box.width, height: box.height, alignment: .topLeading)
                .offset(x: box.minX, y: box.minY)
            }
            if let c = f.content, c.width > 2, c.height > 2 {
                VideoCard(cornerRadius: f.contentRadius, cheap: true)
                    .frame(width: c.width, height: c.height)
                    .opacity(f.contentAlpha)
                    .offset(x: c.minX, y: c.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }
}

/// The picture: the live video when there is one, the artwork until then (or for music apps).
struct VideoCard: View {
    @Environment(AppModel.self) private var model
    var cornerRadius: CGFloat
    /// For views that change size every frame: skips the high-quality artwork resampling.
    var cheap = false

    var body: some View {
        let mirror = model.video
        let live = model.player.source == .web && mirror.hasFrame
        ZStack {
            Color.black
            if cheap {
                if let art = model.player.artwork {
                    Image(nsImage: art).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
                }
            } else {
                ArtworkView(image: model.player.artwork, cornerRadius: 0)
            }
            if live { VideoSurface(mirror: mirror).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.3), value: live)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

// MARK: - Windows

final class GooPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

final class PiPPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class PiPHostingView: NSHostingView<AnyView> {
    var onPinch: ((CGFloat) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func magnify(with event: NSEvent) { onPinch?(event.magnification) }
}

// MARK: - Controller

/// Picture in picture you pull out of the notch like water.
///
///  • Pull the art down: it bulges out against surface tension, held by a neck that thins in the
///    middle like a stretching drop, then pinches off, leaving a tiny satellite droplet. Both drops
///    wobble as they settle; the freed one swells into a floating video window.
///  • Drag the window back near the notch: the whole notch stretches toward it while a glass arm
///    reaches out, and once released close enough the window is drawn in and swallowed.
@MainActor
final class PiPController {
    private unowned let model: AppModel
    let goo = Goo()
    private var overlay: GooPanel?
    private var window: PiPPanel?
    private var timer: Timer?

    private enum Phase { case idle, pulling, landing, returning, floating, dragging, settling, merging }
    private var phase: Phase = .idle

    // Water (screen coordinates).
    private var home = Drop()
    private var homeShown = false
    private var drop = Drop()
    private var dropRadius = Springy(11)
    /// 0 = a thick neck, 1 = pinched through in the middle.
    private var pinch = Springy(0)
    /// After the neck breaks, its two halves pull back into their drops (0 → 1).
    private var retract = Springy(0, response: 0.2, damping: 1)
    private var satellite = Drop()
    private var satelliteShown = false
    private var contentAlpha = Springy(1)
    /// How hard the notch is reaching for the window (also drives the notch's own stretch).
    private var grab = Springy(0, response: 0.32, damping: 0.4)
    /// Window position while it glides to rest after a throw.
    private var winX = Springy(0), winY = Springy(0)

    private var artRect = CGRect.zero
    private var artRadius: CGFloat = 11
    private var pullStart = CGPoint.zero
    private var broken = false
    private var brokeAt = Date.distantPast
    private var landingSince = Date.distantPast
    private var grabOffset = CGPoint.zero
    private var dragSamples: [(t: TimeInterval, p: CGPoint)] = []
    private var lastTick = CACurrentMediaTime()

    private static let breakDistance: CGFloat = 130
    private static let reachRadius: CGFloat = 210
    private static let rim: CGFloat = 4
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)

    init(model: AppModel) { self.model = model }

    var isOpen: Bool { window?.isVisible == true }

    // MARK: Geometry

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    private var notchRect: CGRect {
        let s = screen.frame, n = model.ui.notchSize
        return CGRect(x: s.midX - n.width / 2, y: s.maxY - n.height, width: n.width, height: n.height)
    }

    private var aspect: CGFloat {
        guard model.player.source == .web else { return 1 }
        return model.video.hasFrame ? model.video.aspect : 16 / 9
    }

    private var pipWidth: CGFloat {
        get { let w = Prefs.d.double(forKey: "pipWidth"); return w > 0 ? w : (aspect > 1.2 ? 420 : 260) }
        set { Prefs.d.set(newValue, forKey: "pipWidth") }
    }

    /// The window's size, glass rim included.
    private var pipSize: CGSize {
        let w = pipWidth
        return CGSize(width: w, height: ((w - 2 * Self.rim) / aspect + 2 * Self.rim).rounded())
    }

    private func local(_ r: CGRect) -> CGRect {
        let f = overlay?.frame ?? screen.frame
        return CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }

    private func wantVideo(_ who: String) {
        if model.player.source == .web { model.video.want(who, bundleID: model.player.webBundleID) }
    }

    private func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern) {
        if Prefs.d.bool(forKey: Prefs.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now) }
    }

    // MARK: Pulling out of the notch

    /// The art was grabbed. `artRect` is where it is on screen.
    func beginPull(artRect: CGRect, radius: CGFloat, mouse: CGPoint) {
        guard phase == .idle, !isOpen, model.player.hasTrack else { return }
        phase = .pulling
        broken = false
        satelliteShown = false
        self.artRect = artRect
        artRadius = radius
        pullStart = mouse
        wantVideo("pull")
        withAnimation(.easeOut(duration: 0.1)) { model.ui.artLifted = true }
        home.snap(artRect); homeShown = true
        home.move(response: 0.12, damping: 0.85); home.resize(response: 0.12, damping: 0.85)
        drop.snap(artRect)
        // Stiff enough to feel attached to the finger, soft enough to never step.
        drop.move(response: 0.085, damping: 0.82); drop.resize(response: 0.1, damping: 0.85)
        dropRadius.snap(radius)
        pinch.snap(0)
        retract.snap(0)
        contentAlpha.snap(1)
        grab.snap(0)
        showOverlay()
        startTimer()
        render()
    }

    /// Mouse moves are sampled by the frame loop (smoother than gesture events), so this only
    /// needs to exist for the gesture's sake.
    func pull(to mouse: CGPoint) {}

    /// Called every frame while pulling.
    private func pullStep(_ mouse: CGPoint) {
        let dx = mouse.x - pullStart.x, dy = mouse.y - pullStart.y
        let d = hypot(dx, dy)
        let dir = d > 0.01 ? CGPoint(x: dx / d, y: dy / d) : CGPoint(x: 0, y: -1)
        if !broken {
            // Surface tension: the further you pull, the less the water follows.
            let t = min(1, d / Self.breakDistance)
            let shown = 170 * (1 - 1 / (d * 1.05 / 170 + 1))
            drop.aim(center: CGPoint(x: artRect.midX + dir.x * shown, y: artRect.midY + dir.y * shown))
            // Water is conserved: the drop swells as the pool it's leaving shrinks.
            drop.aim(size: CGSize(width: artRect.width * (1 + 0.1 * t), height: artRect.height * (1 + 0.1 * t)))
            drop.sx.target = 1 + 0.2 * t * abs(dir.x) - 0.08 * t * abs(dir.y)
            drop.sy.target = 1 + 0.2 * t * abs(dir.y) - 0.08 * t * abs(dir.x)
            home.aim(center: CGPoint(x: artRect.midX + dir.x * shown * 0.1, y: artRect.midY + dir.y * shown * 0.1))
            home.aim(size: CGSize(width: artRect.width * (1 - 0.2 * t), height: artRect.height * (1 - 0.2 * t)))
            home.sx.target = 1 - 0.06 * t * abs(dir.y); home.sy.target = 1 + 0.1 * t * abs(dir.y)
            pinch.snap(pow(t, 1.6))
            if d > Self.breakDistance { breakOff(mouse) }
        } else {
            drop.aim(center: CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
            stretchWithSpeed()
        }
    }

    /// A moving drop trails into a teardrop: it stretches along its motion and narrows across it.
    private func stretchWithSpeed() {
        let v = drop.velocity
        let s = hypot(v.x, v.y)
        guard s > 1 else { drop.sx.target = 1; drop.sy.target = 1; return }
        let e = min(0.1, s / 14000)
        drop.sx.target = 1 + e * abs(v.x) / s - e * 0.5 * abs(v.y) / s
        drop.sy.target = 1 + e * abs(v.y) / s - e * 0.5 * abs(v.x) / s
    }

    private func breakOff(_ mouse: CGPoint) {
        broken = true
        brokeAt = Date()
        haptic(.generic)
        let size = pipSize
        // Keep the grip where it was on the art, scaled up to the window.
        let rel = CGPoint(x: (mouse.x - drop.cx.x) / max(drop.w.x, 1), y: (mouse.y - drop.cy.x) / max(drop.h.x, 1))
        grabOffset = CGPoint(x: rel.x * size.width * 0.5, y: rel.y * size.height * 0.5)
        // The neck snaps and both halves spring back into their drops; a little droplet is left
        // floating where it broke and gets swept up by the drop.
        let mid = CGPoint(x: (home.cx.x + drop.cx.x) / 2, y: (home.cy.x + drop.cy.x) / 2)
        satellite.snap(CGRect(x: mid.x - 4, y: mid.y - 4, width: 8, height: 8))
        satellite.move(response: 0.32, damping: 0.75)
        satellite.resize(response: 0.3, damping: 1)
        satelliteShown = true
        retract.target = 1
        // The drop left behind recoils and wobbles back to shape.
        home.aim(artRect)
        home.move(response: 0.3, damping: 0.5); home.resize(response: 0.3, damping: 0.5)
        home.sx.target = 1; home.sy.target = 1
        home.sy.v = 4; home.sx.v = -3
        // The freed drop swells into the window, wobbling from the snap.
        drop.move(response: 0.2, damping: 0.68)
        drop.resize(response: 0.42, damping: 0.62)
        drop.aim(size: size)
        drop.sy.v = -5; drop.sx.v = 4
        dropRadius.tune(response: 0.4, damping: 0.9); dropRadius.target = 18
    }

    func endPull() {
        guard phase == .pulling else { return }
        if broken {
            // Thrown: it carries on a little in the direction it was moving.
            let v = drop.velocity
            let size = drop.w.target > 0 ? CGSize(width: drop.w.target, height: drop.h.target) : pipSize
            var c = CGPoint(x: drop.cx.target + v.x * 0.1, y: drop.cy.target + v.y * 0.1)
            c = clampCenter(c, size: size)
            drop.aim(center: c)
            drop.move(response: 0.34, damping: 0.8)
            phase = .landing
            landingSince = Date()
        } else {
            // Let go too early: surface tension pulls it back into the pool.
            phase = .returning
            drop.aim(artRect)
            drop.move(response: 0.3, damping: 0.55); drop.resize(response: 0.3, damping: 0.55)
            drop.sx.target = 1; drop.sy.target = 1
            home.aim(artRect); home.sx.target = 1; home.sy.target = 1
            pinch.tune(response: 0.25, damping: 1); pinch.target = 0
        }
    }

    private func clampCenter(_ c: CGPoint, size: CGSize) -> CGPoint {
        let vis = (NSScreen.screens.first { $0.frame.contains(c) } ?? screen).visibleFrame
        return CGPoint(x: min(max(c.x, vis.minX + size.width / 2 + 12), vis.maxX - size.width / 2 - 12),
                       y: min(max(c.y, vis.minY + size.height / 2 + 12), vis.maxY - size.height / 2 - 12))
    }

    /// Pops the picture out without a drag (button): a drop falls out of the notch and glides to
    /// the top-right corner.
    func popOut() {
        guard phase == .idle, !isOpen, model.player.hasTrack else { return }
        wantVideo("pull")
        let n = notchRect
        let size = pipSize
        let vis = screen.visibleFrame
        let target = CGPoint(x: vis.maxX - size.width / 2 - 20, y: vis.maxY - size.height / 2 - 20)
        phase = .landing
        broken = true
        brokeAt = .distantPast
        landingSince = Date()
        homeShown = false
        satelliteShown = false
        home.snap(CGRect(x: n.midX - 20, y: n.minY - 8, width: 40, height: 16))
        drop.snap(CGRect(x: n.midX - 22, y: n.minY - 30, width: 44, height: 30))
        drop.move(response: 0.55, damping: 0.72); drop.resize(response: 0.5, damping: 0.65)
        drop.aim(center: target); drop.aim(size: size)
        dropRadius.snap(14); dropRadius.target = 18
        pinch.snap(0.3)
        retract.snap(0); retract.tune(response: 0.35, damping: 1); retract.target = 1
        contentAlpha.snap(0); contentAlpha.tune(response: 0.35, damping: 1); contentAlpha.target = 1
        showOverlay()
        startTimer()
        render()
    }

    // MARK: The floating window

    private func openWindow(at frame: CGRect) {
        let w: PiPPanel
        if let window { w = window } else {
            w = PiPPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            w.isFloatingPanel = true
            w.backgroundColor = .clear
            w.isOpaque = false
            w.hasShadow = true
            w.hidesOnDeactivate = false
            w.isMovable = false
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
            let host = PiPHostingView(rootView: AnyView(PiPView().environment(model)))
            host.sizingOptions = []
            host.onPinch = { [weak self] m in self?.resize(by: 1 + m) }
            w.contentView = host
            window = w
        }
        w.level = .floating
        w.sharingType = Prefs.d.bool(forKey: Prefs.hideFromCapture) ? .none : .readOnly
        w.setFrame(frame, display: true)
        w.alphaValue = 1
        w.orderFrontRegardless()
        w.invalidateShadow()
        phase = .floating
    }

    func close() {
        guard let w = window, w.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.2
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                w.orderOut(nil)
                self?.phase = .idle
                self?.model.video.release("pip")
            }
        })
    }

    /// Keeps the window's shape matched to the video's once the real picture arrives.
    func fitAspect() {
        guard let w = window, w.isVisible, phase == .floating else { return }
        let f = w.frame
        let h = ((f.width - 2 * Self.rim) / aspect + 2 * Self.rim).rounded()
        guard abs(h - f.height) > 1 else { return }
        w.setFrame(CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true, animate: true)
        w.invalidateShadow()
    }

    private func resize(by factor: CGFloat) {
        guard let w = window, phase == .floating else { return }
        let f = w.frame
        let width = min(900, max(220, f.width * factor))
        let h = ((width - 2 * Self.rim) / aspect + 2 * Self.rim).rounded()
        pipWidth = width
        w.setFrame(CGRect(x: f.midX - width / 2, y: f.midY - h / 2, width: width, height: h), display: true)
        w.invalidateShadow()
    }

    // MARK: Dragging it around and back

    func windowDragChanged() {
        guard let w = window else { return }
        let mouse = NSEvent.mouseLocation
        if phase != .dragging {
            guard phase == .floating || phase == .settling else { return }
            phase = .dragging
            grabOffset = CGPoint(x: mouse.x - w.frame.minX, y: mouse.y - w.frame.minY)
            w.level = Self.level
            dragSamples = []
            grab.tune(response: 0.2, damping: 0.75)
        }
        dragSamples.append((CACurrentMediaTime(), mouse))
        dragSamples = dragSamples.filter { CACurrentMediaTime() - $0.t < 0.1 }
        var origin = CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        let size = w.frame.size
        let u = reach(top: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height))
        // Near the notch the window is drawn in a little, as if by surface tension.
        let n = notchRect
        origin.x += (n.midX - (origin.x + size.width / 2)) * 0.22 * u * u
        origin.y += (n.minY - (origin.y + size.height)) * 0.22 * u * u
        w.setFrameOrigin(origin)
        drop.snap(CGRect(origin: origin, size: size))
        dropRadius.snap(18)
        grab.target = u
        if u > 0 || grab.x > 0.01 {
            if overlay?.isVisible != true { showOverlay(); w.orderFrontRegardless() }
            startTimer()
        }
    }

    func windowDragEnded() {
        guard phase == .dragging, let w = window else { return }
        let f = w.frame
        let u = reach(top: CGPoint(x: f.midX, y: f.maxY))
        if u > 0.42 { merge(); return }
        // Thrown windows glide on and come to rest, snapping to an edge they end up near.
        var v = CGPoint.zero
        if let a = dragSamples.first, let b = dragSamples.last, b.t - a.t > 0.01 {
            v = CGPoint(x: (b.p.x - a.p.x) / (b.t - a.t), y: (b.p.y - a.p.y) / (b.t - a.t))
        }
        var c = CGPoint(x: f.midX + v.x * 0.16, y: f.midY + v.y * 0.16)
        let vis = (NSScreen.screens.first { $0.frame.contains(c) } ?? NSScreen.screens.first { $0.frame.intersects(f) } ?? screen).visibleFrame
        let m: CGFloat = 16, snap: CGFloat = 90
        if c.x - f.width / 2 - vis.minX < snap { c.x = vis.minX + f.width / 2 + m }
        if vis.maxX - (c.x + f.width / 2) < snap { c.x = vis.maxX - f.width / 2 - m }
        if c.y - f.height / 2 - vis.minY < snap { c.y = vis.minY + f.height / 2 + m }
        if vis.maxY - (c.y + f.height / 2) < snap { c.y = vis.maxY - f.height / 2 - m }
        c = clampCenter(c, size: f.size)
        winX.snap(f.minX); winY.snap(f.minY)
        winX.v = v.x; winY.v = v.y
        winX.tune(response: 0.42, damping: 0.86); winY.tune(response: 0.42, damping: 0.86)
        winX.target = c.x - f.width / 2; winY.target = c.y - f.height / 2
        grab.tune(response: 0.3, damping: 0.5); grab.target = 0
        phase = .settling
        startTimer()
    }

    /// 0 when far from the notch, 1 when touching it.
    private func reach(top: CGPoint) -> CGFloat {
        let n = notchRect
        let d = hypot(top.x - n.midX, top.y - n.minY)
        return max(0, min(1, 1 - d / Self.reachRadius))
    }

    /// Sends the window home: it's drawn into the notch and swallowed.
    func merge() {
        guard let w = window, w.isVisible else { return }
        phase = .merging
        showOverlay()
        drop.snap(w.frame)
        dropRadius.snap(18)
        contentAlpha.snap(1)
        homeShown = false
        satelliteShown = false
        w.orderOut(nil)
        let n = notchRect
        drop.move(response: 0.46, damping: 0.88)
        drop.resize(response: 0.42, damping: 0.95)
        drop.aim(center: CGPoint(x: n.midX, y: n.minY + n.height * 0.35))
        drop.aim(size: CGSize(width: n.width * 0.45, height: n.height * 0.7))
        dropRadius.tune(response: 0.4, damping: 1); dropRadius.target = n.height * 0.35
        contentAlpha.tune(response: 0.32, damping: 1); contentAlpha.target = 0
        grab.tune(response: 0.25, damping: 0.8); grab.target = 1
        startTimer()
        render()
    }

    private func finishMerge() {
        phase = .idle
        hideOverlay()
        model.video.release("pip")
        haptic(.levelChange)
        // A gulp: the notch swells once and settles with a wobble.
        grab.tune(response: 0.34, damping: 0.3)
        grab.target = 0
        grab.v = 5
        startTimer()
    }

    // MARK: Frame loop

    private func startTimer() {
        guard timer == nil else { return }
        lastTick = CACurrentMediaTime()
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30, max(1.0 / 240, now - lastTick)))
        lastTick = now

        if phase == .pulling { pullStep(NSEvent.mouseLocation) }
        if phase == .landing { stretchWithSpeed() }

        home.step(dt); drop.step(dt); dropRadius.step(dt); pinch.step(dt); retract.step(dt)
        satellite.step(dt); contentAlpha.step(dt); grab.step(dt)

        // The droplet left by the break is swept into the drop.
        if satelliteShown {
            satellite.aim(center: drop.center)
            let r = drop.rect
            if r.insetBy(dx: -6, dy: -6).contains(satellite.center) { satellite.aim(size: .zero) }
            if satellite.w.x < 0.5, satellite.w.target == 0 { satelliteShown = false }
        }
        // Once the drop left behind has settled, the real art takes its place again.
        if broken, homeShown, Date().timeIntervalSince(brokeAt) > 0.5 {
            homeShown = false
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.artLifted = false }
        }

        switch phase {
        case .landing:
            let done = (drop.settled && Date().timeIntervalSince(landingSince) > 0.25) || Date().timeIntervalSince(landingSince) > 0.9
            if done {
                if homeShown { homeShown = false; withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.artLifted = false } }
                wantVideo("pip")
                let r = drop.restRect
                openWindow(at: CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: drop.w.target.rounded(), height: drop.h.target.rounded()))
                model.video.release("pull")
                // Give the window a frame to draw before the water copy goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.hideOverlay() }
                stopTimer()
                return
            }
        case .returning:
            if drop.settled && hypot(drop.cx.x - artRect.midX, drop.cy.x - artRect.midY) < 1 {
                phase = .idle
                hideOverlay()
                withAnimation(.easeOut(duration: 0.08)) { model.ui.artLifted = false }
                model.video.release("pull")
                stopTimer()
                return
            }
        case .merging:
            let n = notchRect
            if hypot(drop.cx.x - n.midX, drop.cy.x - (n.minY + n.height * 0.35)) < 6 || (drop.settled && contentAlpha.x < 0.05) {
                finishMerge()
                pushGrab()
                return
            }
        case .settling:
            winX.step(dt); winY.step(dt)
            if let w = window { w.setFrameOrigin(CGPoint(x: winX.x, y: winY.x)); drop.snap(w.frame) }
            if winX.settled && winY.settled && grab.settled && grab.x < 0.01 {
                phase = .floating
                window?.level = .floating
                hideOverlay()
                pushGrab()
                stopTimer()
                return
            }
        case .idle, .floating:
            if grab.settled && abs(grab.x) < 0.005 {
                grab.snap(0)
                pushGrab()
                if overlay?.isVisible == true, phase != .pulling { hideOverlay() }
                stopTimer()
                return
            }
        case .pulling, .dragging:
            break
        }
        pushGrab()
        render()
    }

    /// The notch itself leans and stretches toward the window it's reaching for.
    private func pushGrab() {
        let g = max(-0.3, min(1.4, grab.x))
        var lean: CGFloat = 0
        if let w = window, phase == .dragging || phase == .settling || phase == .merging {
            let n = notchRect
            let top = phase == .merging ? drop.center : CGPoint(x: w.frame.midX, y: w.frame.maxY)
            lean = max(-0.7, min(0.7, (top.x - n.midX) / max(60, n.minY - top.y + 60)))
        }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            if abs(model.ui.grab - g) > 0.001 { model.ui.grab = g }
            if abs(model.ui.grabLean - lean) > 0.001 { model.ui.grabLean = lean }
        }
    }

    /// Turns the water into what the overlay draws.
    private func render() {
        var f = GooFrame()
        let d = drop.rect

        switch phase {
        case .pulling, .landing, .returning:
            if homeShown {
                f.blobs.append(.init(id: "home", rect: local(home.rect), radius: artRadius * home.sx.x))
            }
            f.blobs.append(.init(id: "drop", rect: local(d), radius: dropRadius.x))
            appendNeck(&f, from: homeShown || phase == .landing ? home : nil, to: drop)
            if satelliteShown {
                let s = satellite.rect
                f.blobs.append(.init(id: "satellite", rect: local(s), radius: s.width / 2))
            }
            let inset = min(Self.rim, d.width * 0.06)
            f.content = local(d).insetBy(dx: inset, dy: inset)
            f.contentRadius = max(4, dropRadius.x - inset)
            f.contentAlpha = Double(max(0, min(1, contentAlpha.x)))
        case .dragging, .settling, .merging, .floating, .idle:
            let u = phase == .merging ? 1 : max(0, min(1, grab.x))
            guard u > 0.01 || phase == .merging else { break }
            let n = notchRect
            // The notch's own drop, hanging down past the hardware notch as it reaches.
            let bulge = CGRect(x: n.minX + 6, y: n.minY - 10 * u, width: n.width - 12, height: n.height + 10 * u)
            f.blobs.append(.init(id: "notch", rect: local(bulge), radius: min(bulge.height / 2, 14)))
            if phase == .merging {
                f.blobs.append(.init(id: "drop", rect: local(d), radius: dropRadius.x))
                let inset = min(Self.rim, d.width * 0.06)
                f.content = local(d).insetBy(dx: inset, dy: inset)
                f.contentRadius = max(4, dropRadius.x - inset)
                f.contentAlpha = Double(max(0, min(1, contentAlpha.x)))
            }
            appendArm(&f, notch: bulge, target: d, u: u)
        }
        goo.frame = f
    }

    /// The neck between two drops: beads of glass along the line between them, fat at the ends and
    /// thinning in the middle as it stretches, like water does just before it breaks.
    private func appendNeck(_ f: inout GooFrame, from a: Drop?, to b: Drop) {
        guard let a else { return }
        let r = retract.x
        guard r < 0.98 else { return }
        let ra = min(a.rect.width, a.rect.height) * 0.4
        let rb = min(min(b.rect.width, b.rect.height) * 0.4, ra * 1.6)
        let p = max(0, min(1, pinch.x))
        let n = 12
        for i in 0...n {
            let s0 = CGFloat(i) / CGFloat(n)
            // After the break, each half slides back into its own drop.
            let s = s0 < 0.5 ? s0 * (1 - r) : 1 - (1 - s0) * (1 - r)
            let mid = 1 - pow(2 * s0 - 1, 2) // 0 at the ends, 1 in the middle
            var rad = (ra + (rb - ra) * s0) * (1 - p * mid * 1.05) * (1 - r)
            if broken, abs(s0 - 0.5) < 0.09 { rad = 0 }
            guard rad > 1.2 else { continue }
            let c = CGPoint(x: a.cx.x + (b.cx.x - a.cx.x) * s, y: a.cy.x + (b.cy.x - a.cy.x) * s)
            f.blobs.append(.init(id: "neck\(i)", rect: local(CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad)), radius: rad))
        }
    }

    /// The notch's arm reaching for the window (and the window's for the notch). Far away they're
    /// two bumps; close, the middle fills in and they become one stream.
    private func appendArm(_ f: inout GooFrame, notch: CGRect, target: CGRect, u: CGFloat) {
        let a = CGPoint(x: notch.midX, y: notch.minY + 4)
        let b = CGPoint(x: target.midX, y: target.maxY - 6)
        let end = 6 + 16 * u
        let fill = max(0, min(1, (u - 0.3) / 0.4)) // 0 → two separate bumps, 1 → joined
        let n = 14
        for i in 0...n {
            let s = CGFloat(i) / CGFloat(n)
            let fromEnd = min(s, 1 - s) * 2 // 0 at the ends, 1 in the middle
            let bump = max(0, 1 - fromEnd / max(0.05, 0.3 + 0.5 * u)) // how far each end's bump reaches
            let rad = end * max(bump, fill * (0.55 + 0.25 * (1 - fromEnd)))
            guard rad > 1.2 else { continue }
            let c = CGPoint(x: a.x + (b.x - a.x) * s, y: a.y + (b.y - a.y) * s)
            f.blobs.append(.init(id: "arm\(i)", rect: local(CGRect(x: c.x - rad, y: c.y - rad, width: 2 * rad, height: 2 * rad)), radius: rad))
        }
    }

    // MARK: Overlay window

    private func showOverlay() {
        let o: GooPanel
        if let overlay { o = overlay } else {
            o = GooPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            o.backgroundColor = .clear
            o.isOpaque = false
            o.hasShadow = false
            o.ignoresMouseEvents = true
            o.hidesOnDeactivate = false
            o.level = Self.level
            o.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let host = NSHostingView(rootView: AnyView(GooView(goo: goo).environment(model)))
            host.sizingOptions = []
            o.contentView = host
            overlay = o
        }
        o.setFrame(screen.frame, display: false)
        o.sharingType = Prefs.d.bool(forKey: Prefs.hideFromCapture) ? .none : .readOnly
        o.orderFrontRegardless()
    }

    private func hideOverlay() {
        overlay?.orderOut(nil)
        goo.frame = GooFrame()
    }
}

// MARK: - The floating window's content

struct PiPView: View {
    @Environment(AppModel.self) private var model
    @State private var hover = false

    private var player: NowPlaying { model.player }

    var body: some View {
        VideoCard(cornerRadius: 14)
            .overlay { controls.opacity(hover ? 1 : 0) }
            .overlay(alignment: .bottom) { note }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .padding(4)
            // A rim of the same Liquid Glass the water is made of.
            .glassEffect(.clear.tint(.white.opacity(0.04)), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.2)) { hover = h } }
            .onTapGesture(count: 2) { player.openPlayer() }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in model.pip.windowDragChanged() }
                .onEnded { _ in model.pip.windowDragEnded() })
            .onChange(of: model.video.aspect) { model.pip.fitAspect() }
            .onChange(of: model.video.hasFrame) { model.pip.fitAspect() }
            .onChange(of: player.hasTrack) { _, has in if !has { model.pip.close() } }
            .environment(\.colorScheme, .dark)
    }

    private var controls: some View {
        ZStack {
            LinearGradient(stops: [.init(color: .black.opacity(0.5), location: 0), .init(color: .clear, location: 0.35),
                                   .init(color: .clear, location: 0.6), .init(color: .black.opacity(0.55), location: 1)],
                           startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    chip("xmark", help: "Close") { model.pip.close() }
                    Text(player.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                    chip("pip.exit", help: "Back to the Notch") { model.pip.merge() }
                }
                Spacer(minLength: 0)
                ProgressBar(player: player, tint: .white)
                    .padding(.horizontal, 6)
            }
            .padding(10)
            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 14) {
                    round("backward.fill", size: 15, box: 38) { player.previous() }
                    round(player.isPlaying ? "pause.fill" : "play.fill", size: 21, box: 50) { player.playPause() }
                    round("forward.fill", size: 15, box: 38) { player.next() }
                }
            }
        }
    }

    private func round(_ symbol: String, size: CGFloat, box: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: box, height: box)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: Circle())
    }

    private func chip(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: Circle())
        .help(help)
    }

    @ViewBuilder private var note: some View {
        if player.source == .web, let text = noteText {
            VStack(spacing: 7) {
                Text(text)
                    .font(.system(size: 11.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                switch model.video.status {
                case .protected:
                    Button("Use the Browser's Picture in Picture") {
                        model.video.nativePictureInPicture()
                        model.pip.close()
                    }
                    .buttonStyle(.glassProminent).controlSize(.small)
                case .noPermission:
                    Button("Open Screen Recording Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.glassProminent).controlSize(.small)
                case .noExtension:
                    Button("Turn On in Safari") { model.video.openExtensionSettings() }
                        .buttonStyle(.glassProminent).controlSize(.small)
                default: EmptyView()
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.55))
        }
    }

    private var noteText: String? {
        switch model.video.status {
        case .noPermission: return "Pergola needs Screen Recording permission to show the video."
        case .noExtension: return "Turn on the Pergola extension in Safari to show the video here."
        case .noJavaScript: return "Turn on View › Developer › Allow JavaScript from Apple Events in your browser to show the video."
        case .protected: return "This video is protected, so only the browser can show it."
        default: return nil
        }
    }
}
