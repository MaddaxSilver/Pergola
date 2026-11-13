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
    /// Upside down: the drop hangs from above and pours *down* into the anchor (the notch's side).
    var flip = false

    func path(in r: CGRect) -> Path {
        if flip {
            var m = self
            m.flip = false
            m.anchor.y = 2 * body.midY - anchor.y
            return m.path(in: r).applying(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 2 * body.midY))
        }
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

// MARK: - What the overlay draws

/// One frame of water, in the overlay's own coordinates (top-left origin).
struct GooFrame {
    var visible = false
    /// The drop carrying a file.
    var body: CGRect?
    var radius: CGFloat = 16
    /// Where the necks meet: on the open notch's bottom edge.
    var anchor: CGPoint = .zero
    var neck: CGFloat = 0
    var attach: CGFloat = 0
    /// The open notch, whose bottom edge bulges toward the drop (only the part below the edge shows).
    var notch: CGRect?
    var notchRadius: CGFloat = 24
    var notchAttach: CGFloat = 0
    var icon: NSImage?
    var iconAlpha: Double = 1
    var squash = CGSize(width: 1, height: 1)

    var bounds: CGRect {
        var r = body ?? .zero
        if let notch { r = r.isEmpty ? notch : r.union(notch) }
        return r.insetBy(dx: -40, dy: -40).integral
    }
}

@Observable @MainActor
final class Goo {
    var frame = GooFrame()
}

/// The water: the drop and the open notch's bulge are two shapes of the same clear Liquid Glass, so
/// they melt into one where their necks meet.
struct GooView: View {
    let goo: Goo

    var body: some View {
        let f = goo.frame
        let box = f.bounds
        let anchor = CGPoint(x: f.anchor.x - box.minX, y: f.anchor.y - box.minY)
        ZStack(alignment: .topLeading) {
            if f.visible {
                GlassEffectContainer(spacing: 16) {
                    ZStack(alignment: .topLeading) {
                        if let b = f.body {
                            Color.clear
                                .frame(width: box.width, height: box.height)
                                .glassEffect(.clear, in: LiquidShape(body: b.offsetBy(dx: -box.minX, dy: -box.minY), radius: f.radius,
                                                                     anchor: anchor, neck: f.neck, attach: f.attach))
                        }
                        if let n = f.notch, f.notchAttach > 0.005 {
                            let local = n.offsetBy(dx: -box.minX, dy: -box.minY)
                            Color.clear
                                .frame(width: box.width, height: box.height)
                                .glassEffect(.clear, in: LiquidShape(body: local, radius: f.notchRadius, anchor: anchor,
                                                                     neck: f.neck, attach: f.notchAttach, flip: true))
                                // Only what reaches out below the notch's edge: the notch above is real.
                                .mask(alignment: .topLeading) {
                                    Rectangle()
                                        .frame(width: box.width, height: max(0, box.height - (local.maxY - 2)))
                                        .offset(y: local.maxY - 2)
                                }
                        }
                    }
                    .frame(width: box.width, height: box.height, alignment: .topLeading)
                }
                .frame(width: box.width, height: box.height, alignment: .topLeading)
                .offset(x: box.minX, y: box.minY)

                if let b = f.body, let icon = f.icon {
                    let side = min(b.width / max(f.squash.width, 0.01), b.height / max(f.squash.height, 0.01)) * 0.68
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: side, height: side)
                        .scaleEffect(x: f.squash.width, y: f.squash.height)
                        .opacity(f.iconAlpha)
                        .position(x: b.midX, y: b.midY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .environment(\.colorScheme, .dark)
    }
}

final class GooPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

// MARK: - Controller

/// The file tray's water. Everything comes out of (and goes back into) the *open* notch's bottom edge.
///
///  • Drag a file out of the tray: it lifts off as a drop of glass; pulled past the notch's edge, the
///    edge bulges down after it on a neck that thins until it pinches off, and the drop, wobbling,
///    follows the pointer. Let go inside the notch and it flows back to its place.
///  • Bring files toward the open notch from below: its edge reaches out for them, and a drop on the
///    drop is swallowed with a gulp.
@MainActor
final class LiquidTray {
    private unowned let model: AppModel
    let goo = Goo()
    private var overlay: GooPanel?
    private var timer: Timer?

    private enum Phase { case idle, pulling, flying, returning, popping, reaching, gulping }
    private var phase: Phase = .idle

    private var body = Drop()
    private var radius = Springy(14)
    private var attach = Springy(0)
    private var notchAttach = Springy(0)
    private var neck = Springy(0)
    private var iconAlpha = Springy(1)
    private var bulge = Springy(0, response: 0.36, damping: 0.35)

    private var slot = CGRect.zero
    private var pullStart = CGPoint.zero
    private var icon: NSImage?
    private var broken = false
    private var lastTick = CACurrentMediaTime()

    private static let breakDistance: CGFloat = 70
    private static let dropSize: CGFloat = 62
    private static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 4)

    init(model: AppModel) { self.model = model }

    // MARK: Geometry

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The open notch, in screen coordinates (its bottom edge is where the water comes from).
    private var openNotch: CGRect {
        let s = screen.frame, e = model.ui.expandedSize
        return CGRect(x: s.midX - e.width / 2, y: s.maxY - e.height, width: e.width, height: e.height)
    }

    private func local(_ r: CGRect) -> CGRect {
        let f = overlay?.frame ?? screen.frame
        return CGRect(x: r.minX - f.minX, y: f.maxY - r.maxY, width: r.width, height: r.height)
    }
    private func local(_ p: CGPoint) -> CGPoint {
        let f = overlay?.frame ?? screen.frame
        return CGPoint(x: p.x - f.minX, y: f.maxY - p.y)
    }

    private func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern) {
        if Prefs.d.bool(forKey: Prefs.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now) }
    }

    // MARK: Dragging a file out

    /// A tray tile started being dragged. `slot` is its icon's rect on screen.
    func beginDragOut(_ item: UUID, icon: NSImage, slot: CGRect) {
        guard phase == .idle || phase == .reaching else { return }
        phase = .pulling
        broken = false
        self.icon = icon
        self.slot = slot
        pullStart = NSEvent.mouseLocation
        let start = CGRect(x: slot.midX - Self.dropSize / 2, y: slot.midY - Self.dropSize / 2, width: Self.dropSize, height: Self.dropSize)
        body.snap(start)
        body.move(response: 0.09, damping: 0.8); body.resize(response: 0.2, damping: 0.6)
        radius.snap(18)
        attach.snap(0); notchAttach.snap(0)
        neck.snap(34)
        iconAlpha.snap(1)
        // The pickup itself: a small squish, as if lifted off a surface.
        body.sx.v = 2.5; body.sy.v = -2.5
        model.ui.liftedTrayItem = item
        showOverlay()
        startTimer()
    }

    private func pullStep(_ mouse: CGPoint) {
        let n = openNotch
        if !broken {
            // Inside the notch it follows freely; past the edge, surface tension holds it back.
            let edge = n.minY
            var target = CGPoint(x: slot.midX + (mouse.x - pullStart.x), y: slot.midY + (mouse.y - pullStart.y))
            let below = edge - (target.y + Self.dropSize / 2) // how far its top is past the edge
            if below > 0 {
                let held = 120 * (1 - 1 / (below * 1.1 / 120 + 1))
                target.y = edge - Self.dropSize / 2 - held
                let t = min(1, below / Self.breakDistance)
                attach.snap(1)
                notchAttach.snap(1)
                neck.snap(34 * (1 - 0.8 * t) + 4)
                body.sy.target = 1 + 0.14 * t; body.sx.target = 1 - 0.07 * t
                bulge.target = 0.5 * t
                if below > Self.breakDistance { letGo() }
            } else {
                attach.target = 0; notchAttach.target = 0
                body.sx.target = 1; body.sy.target = 1
                bulge.target = 0
            }
            body.aim(center: target)
        } else {
            body.aim(center: mouse)
            stretchWithSpeed()
        }
    }

    private func letGo() {
        broken = true
        haptic(.generic)
        attach.tune(response: 0.3, damping: 0.6); attach.target = 0
        notchAttach.tune(response: 0.34, damping: 0.5); notchAttach.target = 0
        neck.tune(response: 0.25, damping: 1); neck.target = 0
        body.move(response: 0.16, damping: 0.68)
        body.sy.v = -4; body.sx.v = 3
        bulge.target = 0; bulge.v = -2
    }

    private func stretchWithSpeed() {
        let v = body.velocity
        let s = hypot(v.x, v.y)
        guard s > 1 else { body.sx.target = 1; body.sy.target = 1; return }
        let e = min(0.16, s / 9000)
        body.sx.target = 1 + e * abs(v.x) / s - e * 0.5 * abs(v.y) / s
        body.sy.target = 1 + e * abs(v.y) / s - e * 0.5 * abs(v.x) / s
    }

    private func endDragOut() {
        let mouse = NSEvent.mouseLocation
        if openNotch.insetBy(dx: -6, dy: -6).contains(mouse) && model.ui.expanded {
            // Let go over the notch: it flows back to its place.
            phase = .returning
            body.aim(center: CGPoint(x: slot.midX, y: slot.midY))
            body.move(response: 0.3, damping: 0.62)
            body.sx.target = 1; body.sy.target = 1
            attach.target = 0; notchAttach.target = 0
        } else {
            // Dropped somewhere: the drop splashes out and is gone.
            phase = .popping
            body.resize(response: 0.22, damping: 0.55)
            body.aim(size: CGSize(width: Self.dropSize * 1.35, height: Self.dropSize * 1.35))
            iconAlpha.tune(response: 0.18, damping: 1); iconAlpha.target = 0
            attach.target = 0; notchAttach.target = 0
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.liftedTrayItem = nil }
    }

    // MARK: Files coming in

    /// Files are being dragged near the open notch (from outside it): its edge reaches for them.
    func reach(toward mouse: CGPoint) {
        guard phase == .idle || phase == .reaching else { return }
        let n = openNotch
        let gap = n.minY - mouse.y
        guard model.ui.expanded, gap > 0, gap < 170, mouse.x > n.minX - 40, mouse.x < n.maxX + 40 else { endReach(); return }
        if phase != .reaching {
            phase = .reaching
            icon = nil
            body.snap(CGRect(x: mouse.x - 26, y: mouse.y - 26, width: 52, height: 52))
            body.move(response: 0.12, damping: 0.8)
            radius.snap(26)
            attach.tune(response: 0.2, damping: 0.7); notchAttach.tune(response: 0.2, damping: 0.7)
            neck.tune(response: 0.2, damping: 0.9)
            showOverlay()
            startTimer()
        }
        body.aim(center: mouse)
        let u = max(0, min(1, 1 - gap / 170))
        let a = u * u * (3 - 2 * u)
        attach.target = a
        notchAttach.target = a
        neck.target = 20 + 24 * a
        bulge.target = 0.4 * a
    }

    func endReach() {
        guard phase == .reaching else { return }
        phase = .idle
        attach.tune(response: 0.3, damping: 0.55); attach.target = 0
        notchAttach.tune(response: 0.3, damping: 0.5); notchAttach.target = 0
        bulge.target = 0
    }

    /// Files were dropped into the tray: the notch swallows them with a wobble.
    func gulp() {
        guard model.ui.expanded else { return }
        if phase == .reaching { phase = .idle }
        phase = .gulping
        attach.snap(0); notchAttach.snap(0)
        bulge.tune(response: 0.36, damping: 0.3)
        bulge.target = 0
        bulge.v = 5
        showOverlay()
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

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = CGFloat(min(1.0 / 30, max(1.0 / 240, now - lastTick)))
        lastTick = now
        let buttonDown = NSEvent.pressedMouseButtons & 1 == 1

        switch phase {
        case .pulling:
            if buttonDown { pullStep(NSEvent.mouseLocation) } else { endDragOut() }
        default: break
        }

        body.step(dt); radius.step(dt); attach.step(dt); notchAttach.step(dt); neck.step(dt)
        iconAlpha.step(dt); bulge.step(dt)

        var done = false
        switch phase {
        case .returning:
            done = body.settled && hypot(body.cx.x - slot.midX, body.cy.x - slot.midY) < 1
        case .popping:
            done = iconAlpha.x < 0.03
        case .idle, .gulping:
            done = attach.x < 0.01 && notchAttach.x < 0.01 && abs(bulge.x) < 0.01 && abs(bulge.v) < 0.1
        case .pulling, .flying, .reaching:
            break
        }
        if done || (!model.ui.expanded && phase != .pulling && phase != .popping) {
            phase = .idle
            overlay?.orderOut(nil)
            goo.frame = GooFrame()
            timer?.invalidate(); timer = nil
            return
        }
        render()
    }

    private func render() {
        var f = GooFrame()
        f.visible = true
        let n = openNotch
        let showsBody = phase == .pulling || phase == .returning || phase == .popping || phase == .reaching
        let b = body.rect
        if showsBody {
            f.body = local(b)
            f.radius = radius.x
            f.icon = icon
            f.iconAlpha = Double(max(0, min(1, iconAlpha.x)))
            f.squash = CGSize(width: body.sx.x, height: body.sy.x)
        }
        // The necks meet on the notch's bottom edge, just above the drop.
        let ax = min(max(b.midX, n.minX + 40), n.maxX - 40)
        let ay = showsBody ? max(b.maxY + 4, n.minY - min(26, max(0, n.minY - b.maxY) * 0.5)) : n.minY - 6
        f.anchor = local(CGPoint(x: ax, y: min(ay, n.minY + 4)))
        f.neck = max(2, neck.x)
        f.attach = max(0, min(1, attach.x))
        // The notch's edge: bulges down a little as it reaches (and gulps), and pours toward the drop.
        let g = max(-0.4, min(1.2, bulge.x))
        f.notch = local(CGRect(x: n.minX, y: n.minY - 14 * g, width: n.width, height: n.height + 14 * g))
        f.notchRadius = NotchMetrics.expandedBottomRadius
        f.notchAttach = max(abs(g) > 0.01 ? 0.01 : 0, min(1, notchAttach.x))
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
            o.contentView = NSHostingView(rootView: GooView(goo: goo))
            overlay = o
            o.setFrame(screen.frame, display: false)
            o.orderFrontRegardless()
            // The notch lives in its own space above the desktops; join it there, above it.
            SkyLight.move(o, toLevel: SkyLight.aboveDesktopsLevel)
        }
        o.setFrame(screen.frame, display: false)
        o.sharingType = Prefs.d.bool(forKey: Prefs.hideFromCapture) ? .none : .readOnly
        o.orderFrontRegardless()
    }
}
