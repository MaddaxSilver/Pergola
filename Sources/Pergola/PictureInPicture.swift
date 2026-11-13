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

private func mix(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
}

/// The floating window as one body of water. At rest it's a rounded rectangle. Attached, its whole
/// top edge flows up into a neck that pours into the anchor (the notch, or the art's slot): the
/// shoulders sweep inward in smooth S-curves, so there's never a seam between window and notch.
struct LiquidShape: Shape {
    var body: CGRect
    var radius: CGFloat
    /// Where the neck pours in (top-left origin, same space as `body`).
    var anchor: CGPoint
    var neck: CGFloat
    /// 0 = a plain rounded rectangle, 1 = fully poured into the anchor.
    var attach: CGFloat

    func path(in _: CGRect) -> Path {
        let b = body
        let r = max(0, min(radius, b.width / 2, b.height / 2))
        let t = max(0, min(1, attach))
        let k: CGFloat = 0.5523 // circular-arc handle length
        let nw = max(2, min(neck, b.width - 2 * r))
        let top = CGPoint(x: anchor.x, y: min(anchor.y, b.minY))
        let rise = max(0, b.minY + r - top.y)

        // Water rises from the middle: the shoulders draw in toward the neck quickly, while the top
        // climbs toward the anchor more gradually, so it reads as a dome swelling up, then a funnel.
        let tx = 1 - pow(1 - t, 3)
        func shoulder(_ side: CGFloat) -> (start: CGPoint, c1: CGPoint, c2: CGPoint, end: CGPoint) {
            let edgeX = side > 0 ? b.maxX : b.minX
            let start = CGPoint(x: edgeX, y: b.minY + r)
            let end = CGPoint(x: (edgeX - side * r) + (top.x + side * nw / 2 - (edgeX - side * r)) * tx,
                              y: b.minY + (top.y - b.minY) * t)
            let climb = max(0, start.y - end.y)
            let c1 = CGPoint(x: edgeX, y: start.y - (r * k) * (1 - t) - climb * 0.42 * t)
            let c2 = CGPoint(x: end.x + side * (r * k) * (1 - tx), y: end.y + climb * 0.5 * t)
            return (start, c1, c2, end)
        }
        let R = shoulder(1), L = shoulder(-1)
        let startR = R.start, endR = R.end, c1R = R.c1, c2R = R.c2
        let startL = L.start, endL = L.end, c1L = L.c1, c2L = L.c2

        var p = Path()
        p.move(to: startL)
        p.addLine(to: CGPoint(x: b.minX, y: b.maxY - r))
        p.addCurve(to: CGPoint(x: b.minX + r, y: b.maxY),
                   control1: CGPoint(x: b.minX, y: b.maxY - r + r * k), control2: CGPoint(x: b.minX + r - r * k, y: b.maxY))
        p.addLine(to: CGPoint(x: b.maxX - r, y: b.maxY))
        p.addCurve(to: CGPoint(x: b.maxX, y: b.maxY - r),
                   control1: CGPoint(x: b.maxX - r + r * k, y: b.maxY), control2: CGPoint(x: b.maxX, y: b.maxY - r + r * k))
        p.addLine(to: startR)
        p.addCurve(to: endR, control1: c1R, control2: c2R)
        // Across the top: straight at rest, a rounded cap where it pours in.
        p.addQuadCurve(to: endL, control: CGPoint(x: (endR.x + endL.x) / 2, y: min(endR.y, endL.y) - abs(endR.x - endL.x) * 0.45 * min(1, t * 3)))
        p.addCurve(to: startL, control1: c2L, control2: c1L)
        p.closeSubpath()
        return p
    }
}

/// One frame of water, in the overlay's own coordinates (top-left origin).
struct GooFrame {
    var visible = false
    var body: CGRect = .zero
    var radius: CGFloat = 18
    var anchor: CGPoint = .zero
    var neck: CGFloat = 0
    var attach: CGFloat = 0
    var contentAlpha: Double = 1
    /// The body's size before squash and stretch.
    var rest: CGSize = .zero

    var bounds: CGRect {
        var r = body
        if attach > 0.005 { r = r.union(CGRect(x: anchor.x - neck, y: anchor.y - neck, width: 2 * neck, height: 2 * neck)) }
        return r.insetBy(dx: -24, dy: -24).integral
    }
}

@Observable @MainActor
final class Goo {
    var frame = GooFrame()
}

/// Draws the water: the whole shape is one piece of Liquid Glass, with the picture inside it.
struct GooView: View {
    @Environment(AppModel.self) private var model
    let goo: Goo
    static let rim: CGFloat = 4

    var body: some View {
        let f = goo.frame
        let box = f.bounds
        let rim = min(Self.rim, f.body.width * 0.06)
        ZStack(alignment: .topLeading) {
            if f.visible {
                Color.clear
                    .frame(width: box.width, height: box.height)
                    .glassEffect(.clear.tint(.white.opacity(0.05)),
                                 in: LiquidShape(body: f.body.offsetBy(dx: -box.minX, dy: -box.minY), radius: f.radius,
                                                 anchor: CGPoint(x: f.anchor.x - box.minX, y: f.anchor.y - box.minY),
                                                 neck: f.neck, attach: f.attach))
                    .offset(x: box.minX, y: box.minY)
                let c = f.body.insetBy(dx: rim, dy: rim)
                let rest = CGSize(width: max(2, f.rest.width - 2 * rim), height: max(2, f.rest.height - 2 * rim))
                if c.width > 2, c.height > 2 {
                    let local = c.offsetBy(dx: -box.minX, dy: -box.minY)
                    let anchor = CGPoint(x: f.anchor.x - box.minX, y: f.anchor.y - box.minY)
                    ZStack(alignment: .topLeading) {
                        // Laid out at its resting size, then squashed and stretched with the water.
                        WaterPicture()
                            .frame(width: rest.width, height: rest.height)
                            .scaleEffect(x: c.width / rest.width, y: c.height / rest.height)
                            .frame(width: c.width, height: c.height)
                            .offset(x: local.minX, y: local.minY)
                    }
                    .frame(width: box.width, height: box.height, alignment: .topLeading)
                    // …and poured up into the neck along with it.
                    .distortionEffect(Liquid.warp(body: local, anchor: anchor, neck: f.neck * 0.8, attach: f.attach),
                                      maxSampleOffset: CGSize(width: box.width, height: box.height),
                                      isEnabled: Liquid.available && f.attach > 0.002 && WaterPicture.warpable(model))
                    .mask(LiquidShape(body: local, radius: max(3, f.radius - rim), anchor: anchor,
                                      neck: max(2, f.neck * 0.8), attach: f.attach))
                    .opacity(f.contentAlpha)
                    .offset(x: box.minX, y: box.minY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }
}

/// The warp shader (Shaders/Liquid.metal, built into Liquid.metallib).
enum Liquid {
    private static let library: ShaderLibrary? =
        Bundle.main.url(forResource: "Liquid", withExtension: "metallib").map { ShaderLibrary(url: $0) }
    static var available: Bool { library != nil }

    static func warp(body: CGRect, anchor: CGPoint, neck: CGFloat, attach: CGFloat) -> Shader {
        let lib = library ?? .default
        return lib.liquidWarp(.float4(body.minX, body.minY, body.width, body.height),
                              .float2(anchor.x, anchor.y), .float(neck), .float(attach))
    }
}

/// The picture inside the water, drawn as an image so it can be bent: the page's own video frames
/// (Safari), else the album art. Screen-captured video (other browsers) is shown as is.
struct WaterPicture: View {
    @Environment(AppModel.self) private var model

    static func warpable(_ model: AppModel) -> Bool {
        !(model.player.source == .web && model.video.hasFrame && model.video.frames.image == nil)
    }

    var body: some View {
        ZStack {
            Color.black
            if model.player.source == .web, let frame = model.video.frames.image {
                Image(decorative: frame, scale: 1).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            } else if model.player.source == .web, model.video.hasFrame {
                VideoSurface(mirror: model.video)
            } else if let art = model.player.artwork {
                Image(nsImage: art).resizable().interpolation(.medium).aspectRatio(contentMode: .fill)
            }
        }
        .clipped()
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

/// Picture in picture where the window itself is water.
///
///  • Pull the art down: it pours out of its slot as one body, swelling as it comes, still joined
///    by a neck that thins as you pull. Far enough and it lets go: the neck swoops back up and the
///    window, wobbling, follows the pointer.
///  • Bring the window back near the notch: its whole top edge is drawn up into the notch, more the
///    closer it gets. Let go and it pours itself in.
@MainActor
final class PiPController {
    private unowned let model: AppModel
    let goo = Goo()
    private var overlay: GooPanel?
    private var window: PiPPanel?
    private var timer: Timer?

    private enum Phase { case idle, pulling, landing, returning, floating, dragging, settling, merging }
    private var phase: Phase = .idle

    // The water (screen coordinates, bottom-left origin).
    private var body = Drop()
    private var radius = Springy(11)
    private var attach = Springy(0)
    private var neck = Springy(0)
    private var contentAlpha = Springy(1)
    private var anchor = CGPoint.zero
    /// How hard the notch is reaching for the window (also stretches the notch itself).
    private var grab = Springy(0, response: 0.32, damping: 0.5)
    /// Window position while it glides to rest after a throw.
    private var winX = Springy(0), winY = Springy(0)

    private var artRect = CGRect.zero
    private var artRadius: CGFloat = 11
    private var pullStart = CGPoint.zero
    private var broken = false
    private var brokeAt = Date.distantPast
    private var landingSince = Date.distantPast
    private var popRelease: Date?
    private var grabOffset = CGPoint.zero
    private var dragSamples: [(t: TimeInterval, p: CGPoint)] = []
    private var lastTick = CACurrentMediaTime()

    private static let breakDistance: CGFloat = 150
    private static let reachRadius: CGFloat = 240
    private static let rim = GooView.rim
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

    /// Where water pours into the notch: just inside its bottom edge.
    private var notchMouth: CGPoint { let n = notchRect; return CGPoint(x: n.midX, y: n.minY + n.height * 0.45) }

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
    private func local(_ p: CGPoint) -> CGPoint {
        let f = overlay?.frame ?? screen.frame
        return CGPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    private func wantVideo(_ who: String) {
        if model.player.source == .web { model.video.want(who, bundleID: model.player.webBundleID) }
    }

    private func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern) {
        if Prefs.d.bool(forKey: Prefs.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now) }
    }

    private static func smoothstep(_ a: CGFloat, _ b: CGFloat, _ x: CGFloat) -> CGFloat {
        let t = max(0, min(1, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

    // MARK: Pulling out

    /// The art was grabbed. `artRect` is where it is on screen.
    func beginPull(artRect: CGRect, radius r: CGFloat, mouse: CGPoint) {
        guard phase == .idle, !isOpen, model.player.hasTrack else { return }
        phase = .pulling
        broken = false
        popRelease = nil
        self.artRect = artRect
        artRadius = r
        pullStart = mouse
        anchor = CGPoint(x: artRect.midX, y: artRect.midY)
        wantVideo("pull")
        withAnimation(.easeOut(duration: 0.1)) { model.ui.artLifted = true }
        body.snap(artRect)
        body.move(response: 0.1, damping: 0.8); body.resize(response: 0.16, damping: 0.75)
        radius.snap(r)
        attach.snap(1)
        neck.snap(artRect.width * 0.8)
        contentAlpha.snap(1)
        grab.snap(0)
        showOverlay()
        startTimer()
        render()
    }

    /// The frame loop samples the pointer itself (smoother than gesture events).
    func pull(to mouse: CGPoint) {}

    private func pullStep(_ mouse: CGPoint) {
        let dx = mouse.x - pullStart.x, dy = mouse.y - pullStart.y
        let d = hypot(dx, dy)
        let dir = d > 0.01 ? CGPoint(x: dx / d, y: dy / d) : CGPoint(x: 0, y: -1)
        if !broken {
            // Held back by its neck: the further you pull, the less it follows…
            let t = min(1, d / Self.breakDistance)
            let shown = 190 * (1 - 1 / (d * 1.1 / 190 + 1))
            // …while it swells toward the window it's going to become, pouring out of the slot.
            let target = pipSize
            let grow = 0.35 * t * t
            let w = artRect.width + (target.width * 0.55 - artRect.width) * grow
            let h = artRect.height + (target.height * 0.55 - artRect.height) * grow
            body.aim(size: CGSize(width: w, height: h))
            body.aim(center: CGPoint(x: artRect.midX + dir.x * shown, y: artRect.midY + dir.y * shown - h * 0.15 * t))
            body.sx.target = 1 - 0.06 * t * abs(dir.y)
            body.sy.target = 1 + 0.12 * t * abs(dir.y)
            neck.snap(artRect.width * (0.8 - 0.5 * t))
            radius.snap(artRadius + 6 * t)
            if d > Self.breakDistance { letGo(mouse) }
        } else {
            body.aim(center: CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y))
            stretchWithSpeed()
        }
    }

    /// Moving water drags out behind itself a little, and narrows across the motion.
    private func stretchWithSpeed() {
        let v = body.velocity
        let s = hypot(v.x, v.y)
        guard s > 1 else { body.sx.target = 1; body.sy.target = 1; return }
        let e = min(0.08, s / 16000)
        body.sx.target = 1 + e * abs(v.x) / s - e * 0.5 * abs(v.y) / s
        body.sy.target = 1 + e * abs(v.y) / s - e * 0.5 * abs(v.x) / s
    }

    /// The neck lets go and swoops back up into the slot; the window springs free.
    private func letGo(_ mouse: CGPoint) {
        broken = true
        brokeAt = Date()
        haptic(.generic)
        let size = pipSize
        let rel = CGPoint(x: (mouse.x - body.cx.x) / max(body.w.x, 1), y: (mouse.y - body.cy.x) / max(body.h.x, 1))
        grabOffset = CGPoint(x: rel.x * size.width * 0.6, y: rel.y * size.height * 0.6)
        attach.tune(response: 0.34, damping: 0.62); attach.target = 0
        neck.tune(response: 0.3, damping: 1); neck.target = 0
        body.move(response: 0.22, damping: 0.7)
        body.resize(response: 0.45, damping: 0.6)
        body.aim(size: size)
        // The snap sets the whole window wobbling.
        body.sy.v = 3.5; body.sx.v = -2.5
        radius.tune(response: 0.4, damping: 0.9); radius.target = 18
    }

    func endPull() {
        guard phase == .pulling else { return }
        if broken {
            let v = body.velocity
            let size = CGSize(width: body.w.target, height: body.h.target)
            let c = clampCenter(CGPoint(x: body.cx.target + v.x * 0.1, y: body.cy.target + v.y * 0.1), size: size)
            body.aim(center: c)
            body.move(response: 0.36, damping: 0.8)
            phase = .landing
            landingSince = Date()
        } else {
            // Let go too early: it's drawn back into the slot.
            phase = .returning
            body.aim(artRect)
            body.move(response: 0.3, damping: 0.62); body.resize(response: 0.3, damping: 0.62)
            body.sx.target = 1; body.sy.target = 1
            neck.tune(response: 0.25, damping: 1); neck.target = artRect.width * 0.8
            radius.tune(response: 0.25, damping: 1); radius.target = artRadius
        }
    }

    private func clampCenter(_ c: CGPoint, size: CGSize) -> CGPoint {
        let vis = (NSScreen.screens.first { $0.frame.contains(c) } ?? screen).visibleFrame
        return CGPoint(x: min(max(c.x, vis.minX + size.width / 2 + 12), vis.maxX - size.width / 2 - 12),
                       y: min(max(c.y, vis.minY + size.height / 2 + 12), vis.maxY - size.height / 2 - 12))
    }

    /// Pops the picture out without a drag: it pours out of the notch and glides to the top-right.
    func popOut() {
        guard phase == .idle, !isOpen, model.player.hasTrack else { return }
        wantVideo("pull")
        let n = notchRect
        let size = pipSize
        let vis = screen.visibleFrame
        phase = .landing
        broken = true
        brokeAt = Date()
        landingSince = Date()
        popRelease = Date().addingTimeInterval(0.28)
        anchor = notchMouth
        body.snap(CGRect(x: n.midX - n.width * 0.25, y: n.minY - 12, width: n.width * 0.5, height: 14))
        body.move(response: 0.6, damping: 0.78); body.resize(response: 0.5, damping: 0.68)
        body.aim(center: CGPoint(x: vis.maxX - size.width / 2 - 20, y: vis.maxY - size.height / 2 - 20))
        body.aim(size: size)
        radius.snap(7); radius.tune(response: 0.4, damping: 1); radius.target = 18
        attach.snap(1)
        neck.snap(n.width * 0.5)
        contentAlpha.snap(0); contentAlpha.tune(response: 0.4, damping: 1); contentAlpha.target = 1
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

    /// While the water is drawn by the overlay, the real window steps aside (still catching the
    /// pointer, so the drag carries on).
    private func setWindowHidden(_ hidden: Bool) {
        guard let w = window else { return }
        let a: CGFloat = hidden ? 0 : 1
        if w.alphaValue != a { w.alphaValue = a; if !hidden { w.invalidateShadow() } }
    }

    // MARK: Dragging it around and back

    /// The drag starts from the window's gesture, but is then followed by the frame loop (pointer and
    /// button state read directly), so it carries on even while the window steps aside for the water.
    func windowDragChanged() {
        guard let w = window, phase != .dragging else { return }
        guard phase == .floating || phase == .settling else { return }
        let mouse = NSEvent.mouseLocation
        phase = .dragging
        grabOffset = CGPoint(x: mouse.x - w.frame.minX, y: mouse.y - w.frame.minY)
        w.level = Self.level
        dragSamples = []
        anchor = notchMouth
        attach.tune(response: 0.2, damping: 0.72)
        neck.tune(response: 0.2, damping: 0.85)
        grab.tune(response: 0.22, damping: 0.75)
        startTimer()
        dragStep(mouse)
    }

    private func dragStep(_ mouse: CGPoint) {
        guard let w = window else { return }
        dragSamples.append((CACurrentMediaTime(), mouse))
        dragSamples = dragSamples.filter { CACurrentMediaTime() - $0.t < 0.1 }
        var origin = CGPoint(x: mouse.x - grabOffset.x, y: mouse.y - grabOffset.y)
        let size = w.frame.size
        let u = reach(top: CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height))
        // Drawn in a little as it nears, as if by surface tension.
        let mouth = notchMouth
        origin.x += (mouth.x - (origin.x + size.width / 2)) * 0.18 * u * u
        origin.y += (notchRect.minY - (origin.y + size.height)) * 0.18 * u * u
        if w.frame.origin != origin { w.setFrameOrigin(origin) }
        body.snap(CGRect(origin: origin, size: size))
        radius.snap(18)
        // The whole top edge starts reaching up into the notch, more the closer it gets.
        let a = Self.smoothstep(0.08, 0.9, u)
        attach.target = a
        neck.target = notchRect.width * (0.25 + 0.35 * a)
        grab.target = u * 0.7
    }

    func windowDragEnded() {
        guard phase == .dragging, let w = window else { return }
        let f = w.frame
        let u = reach(top: CGPoint(x: f.midX, y: f.maxY))
        if u > 0.4 { merge(); return }
        var v = CGPoint.zero
        if let a = dragSamples.first, let b = dragSamples.last, b.t - a.t > 0.01 {
            v = CGPoint(x: (b.p.x - a.p.x) / (b.t - a.t), y: (b.p.y - a.p.y) / (b.t - a.t))
        }
        // Thrown windows glide on and come to rest, snapping to an edge they end up near.
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
        // Pulled away, the top lets go of the notch with a wobble.
        attach.tune(response: 0.32, damping: 0.55); attach.target = 0
        if attach.x > 0.1 { body.sy.v = 2.5 }
        grab.tune(response: 0.3, damping: 0.5); grab.target = 0
        phase = .settling
        startTimer()
    }

    private func reach(top: CGPoint) -> CGFloat {
        let n = notchRect
        let d = hypot(top.x - n.midX, top.y - n.minY)
        return max(0, min(1, 1 - d / Self.reachRadius))
    }

    /// Pours the window back into the notch.
    func merge() {
        guard let w = window, w.isVisible else { return }
        phase = .merging
        anchor = notchMouth
        showOverlay()
        body.snap(w.frame)
        radius.snap(18)
        contentAlpha.snap(1)
        setWindowHidden(true)
        let n = notchRect
        body.move(response: 0.42, damping: 0.86)
        body.resize(response: 0.38, damping: 0.95)
        body.aim(center: CGPoint(x: n.midX, y: n.minY + 2))
        body.aim(size: CGSize(width: n.width * 0.5, height: 4))
        radius.tune(response: 0.3, damping: 1); radius.target = 2
        attach.tune(response: 0.16, damping: 0.9); attach.target = 1
        neck.tune(response: 0.25, damping: 1); neck.target = n.width * 0.5
        contentAlpha.tune(response: 0.3, damping: 1); contentAlpha.target = 0
        grab.tune(response: 0.22, damping: 0.8); grab.target = 0.9
        startTimer()
        render()
    }

    private func finishMerge() {
        phase = .idle
        window?.orderOut(nil)
        window?.alphaValue = 1
        hideOverlay()
        model.video.release("pip")
        haptic(.levelChange)
        // A gulp: the notch swells once and settles with a wobble.
        grab.tune(response: 0.36, damping: 0.32)
        grab.target = 0
        grab.v = 4
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
        if phase == .dragging {
            if NSEvent.pressedMouseButtons & 1 == 0 { windowDragEnded() } else { dragStep(NSEvent.mouseLocation) }
        }
        if phase == .landing { stretchWithSpeed() }
        if let r = popRelease, Date() >= r {
            popRelease = nil
            attach.tune(response: 0.36, damping: 0.6); attach.target = 0
            neck.tune(response: 0.3, damping: 1); neck.target = 0
            body.sy.v = 2.5
        }

        body.step(dt); radius.step(dt); attach.step(dt); neck.step(dt); contentAlpha.step(dt); grab.step(dt)

        // Once the neck has swooped back up, the art takes its place in the slot again.
        if broken, model.ui.artLifted, Date().timeIntervalSince(brokeAt) > 0.3 {
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.artLifted = false }
        }

        switch phase {
        case .landing:
            let done = popRelease == nil && attach.x < 0.03
                && ((body.settled && Date().timeIntervalSince(landingSince) > 0.2) || Date().timeIntervalSince(landingSince) > 1.0)
            if done {
                wantVideo("pip")
                let r = body.restRect
                openWindow(at: CGRect(x: r.minX.rounded(), y: r.minY.rounded(), width: body.w.target.rounded(), height: body.h.target.rounded()))
                model.video.release("pull")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.hideOverlay() }
                stopTimer()
                return
            }
        case .returning:
            if body.settled && hypot(body.cx.x - artRect.midX, body.cy.x - artRect.midY) < 1 {
                phase = .idle
                hideOverlay()
                withAnimation(.easeOut(duration: 0.08)) { model.ui.artLifted = false }
                model.video.release("pull")
                stopTimer()
                return
            }
        case .merging:
            if body.h.x < 6 || (body.settled && contentAlpha.x < 0.03) {
                finishMerge()
            }
        case .dragging:
            break
        case .settling:
            winX.step(dt); winY.step(dt)
            if let w = window { w.setFrameOrigin(CGPoint(x: winX.x, y: winY.x)); body.snap(w.frame) }
            if winX.settled && winY.settled && attach.x < 0.01 && attach.settled && grab.settled {
                phase = .floating
                window?.level = .floating
            }
        case .pulling, .floating, .idle:
            break
        }

        // The overlay draws the water only while it's attached to something; otherwise the real
        // window shows itself.
        let liquid = phase == .pulling || phase == .landing || phase == .returning || phase == .merging || attach.x > 0.01
        if phase == .dragging || phase == .settling { setWindowHidden(liquid) }
        if liquid { if overlay?.isVisible != true { showOverlay(); window?.orderFrontRegardless() } }
        else if overlay?.isVisible == true { hideOverlay() }

        pushGrab()
        if liquid { render() }

        let idle = (phase == .idle || phase == .floating) && grab.settled && abs(grab.x) < 0.005
        if idle { grab.snap(0); pushGrab(); stopTimer() }
    }

    /// The notch itself stretches and leans toward the window it's reaching for.
    private func pushGrab() {
        let g = max(-0.3, min(1.3, grab.x))
        var lean: CGFloat = 0
        if phase == .dragging || phase == .settling || phase == .merging {
            let n = notchRect
            let c = body.center
            lean = max(-0.6, min(0.6, (c.x - n.midX) / max(80, n.minY - c.y + 80)))
        }
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) {
            if abs(model.ui.grab - g) > 0.001 { model.ui.grab = g }
            if abs(model.ui.grabLean - lean) > 0.001 { model.ui.grabLean = lean }
        }
    }

    private func render() {
        var f = GooFrame()
        f.visible = true
        f.body = local(body.rect)
        f.radius = radius.x
        f.anchor = local(anchor)
        f.neck = max(0, neck.x)
        f.attach = max(0, min(1, attach.x))
        f.contentAlpha = Double(max(0, min(1, contentAlpha.x)))
        f.rest = CGSize(width: max(1, body.w.x), height: max(1, body.h.x))
        goo.frame = f
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
            o.setFrame(screen.frame, display: false)
            o.orderFrontRegardless()
            // The notch lives in its own space above the desktops, which draws over every normal
            // window. Join it there (at a higher level) so the water shows on top of the open notch,
            // the enlarged view included.
            SkyLight.move(o, toLevel: SkyLight.aboveDesktopsLevel)
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
                case .needsReload:
                    Button("Reload the Page") { model.video.reconnect(force: true) }
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
        case .reconnecting: return "Connecting to Safari…"
        case .needsReload: return "This page was opened before Pergola updated. Reload it to show the video."
        default: return nil
        }
    }
}
