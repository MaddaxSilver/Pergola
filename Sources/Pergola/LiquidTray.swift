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

// MARK: - The water's shape

/// One frame of water, in the notch window's coordinates (top-left origin).
struct WaterFrame: Equatable {
    var visible = false
    /// The water is built facing straight down from a flat surface, then turned to face out of the
    /// notch's outline at the point it leaves from (bottom, corner or side).
    var origin: CGPoint = .zero
    var angle: CGFloat = 0
    /// The open notch's outline, which the water never draws inside.
    var notch: CGRect = .zero
    var notchRadius: CGFloat = 34
    /// The open notch's bottom edge (the water's surface) and where along it the water pulls down.
    var edgeY: CGFloat = 0
    var anchorX: CGFloat = 0
    /// Half-width of the meniscus: how wide the surface dips where the neck leaves it.
    var foot: CGFloat = 0
    /// The drop: an ellipse (it squashes and stretches).
    var center: CGPoint = .zero
    var rx: CGFloat = 0
    var ry: CGFloat = 0
    var hasDrop = false
    /// Joined to the surface by a neck of this width.
    var connected = false
    var neck: CGFloat = 0
    /// Once apart: the surface's bulge springing back, and the drop's tail snapping into it.
    var bump: CGFloat = 0
    var tail: CGFloat = 0
    var alpha: Double = 1
    var icon: NSImage?
    var iconFrame: CGRect?
    var iconAlpha: Double = 1
}

/// Water hanging from a surface: the surface dips in a wide meniscus, narrows to a neck and flows,
/// tangent, into a round drop. Apart, the surface keeps a springing bulge and the drop a tail.
struct WaterShape: Shape {
    var f: WaterFrame

    private func point(_ phi: CGFloat) -> CGPoint {
        CGPoint(x: f.center.x - f.rx * sin(phi), y: f.center.y - f.ry * cos(phi))
    }
    private func tangent(_ phi: CGFloat) -> CGPoint {
        CGPoint(x: -f.rx * cos(phi), y: f.ry * sin(phi))
    }

    func path(in _: CGRect) -> Path {
        let turn = CGAffineTransform(translationX: f.origin.x, y: f.origin.y).rotated(by: f.angle)
        return built().applying(turn)
    }

    /// The water facing straight down from a surface at y = 0 (drawing coordinates).
    private func built() -> Path {
        var p = Path()
        let E: CGFloat = 0
        // The base tucks a little way into the notch (where it's never drawn) as a shallow wedge, so
        // it stays inside even where the outline curves away at the corners and sides.
        let apex = CGPoint(x: 0, y: -12)
        // Too far off to the side to bridge without turning into a thin film: real water wouldn't
        // join yet, so the surface reaches with a dome and the drop stays apart.
        let bridgeable = abs(f.center.x - f.anchorX) < f.foot + f.rx * 0.6
        if f.hasDrop && f.connected && bridgeable {
            // Never wider than the surface it leaves can hold.
            let w = max(1.5, min(f.neck, 2 * f.foot - 8))
            let dropTop = f.center.y - f.ry
            let neckY = E + max(0, dropTop - E) * 0.5
            let theta = asin(max(0.12, min(0.97, (w / 2 + 2) / max(f.rx, 1))))
            let tL = point(theta), tR = point(2 * .pi - theta)
            let h: CGFloat = 0.38
            let footL = CGPoint(x: f.anchorX - f.foot, y: E), footR = CGPoint(x: f.anchorX + f.foot, y: E)
            // A drop off to one side bends the neck toward it; the base stays flat on the surface.
            let bend = max(-f.foot * 0.8, min(f.foot * 0.8, (f.center.x - f.anchorX) * 0.5))
            let neckL = CGPoint(x: f.anchorX + bend - w / 2, y: neckY), neckR = CGPoint(x: f.anchorX + bend + w / 2, y: neckY)
            let spreadL = max(0, neckL.x - footL.x), spreadR = max(0, footR.x - neckR.x)
            p.move(to: apex)
            p.addLine(to: footL)
            p.addCurve(to: neckL, control1: CGPoint(x: footL.x + spreadL * 0.62, y: E),
                       control2: CGPoint(x: neckL.x, y: neckY - (neckY - E) * 0.6))
            let tanL = tangent(theta)
            p.addCurve(to: tL, control1: CGPoint(x: neckL.x, y: neckY + (tL.y - neckY) * 0.6),
                       control2: CGPoint(x: tL.x - tanL.x * h, y: tL.y - tanL.y * h))
            addArc(&p, from: theta, to: 2 * .pi - theta)
            let tanR = tangent(2 * .pi - theta)
            p.addCurve(to: neckR, control1: CGPoint(x: tR.x + tanR.x * h, y: tR.y + tanR.y * h),
                       control2: CGPoint(x: neckR.x, y: neckY + (tR.y - neckY) * 0.6))
            p.addCurve(to: footR, control1: CGPoint(x: neckR.x, y: neckY - (neckY - E) * 0.6),
                       control2: CGPoint(x: footR.x - spreadR * 0.62, y: E))
            p.closeSubpath()
            return p
        }
        // The surface's bulge.
        if f.bump > 0.4 || (f.connected && !bridgeable) {
            let m = min(max(f.foot * 0.75, f.bump * 1.15), 58, f.foot)
            let bumpDepth = min(max(f.bump, f.connected ? 16 : 0), m * 1.25) // a dome, never a spike
            let footL = CGPoint(x: f.anchorX - m, y: E), footR = CGPoint(x: f.anchorX + m, y: E)
            let peak = CGPoint(x: f.anchorX, y: E + bumpDepth)
            p.move(to: apex)
            p.addLine(to: footL)
            p.addCurve(to: peak, control1: CGPoint(x: footL.x + m * 0.55, y: E), control2: CGPoint(x: peak.x - m * 0.45, y: peak.y))
            p.addCurve(to: footR, control1: CGPoint(x: peak.x + m * 0.45, y: peak.y), control2: CGPoint(x: footR.x - m * 0.55, y: E))
            p.closeSubpath()
        }
        // The drop, with its tail if it has one.
        if f.hasDrop {
            if f.tail > 0.5 {
                let theta: CGFloat = 0.55
                let tip = CGPoint(x: f.center.x, y: f.center.y - f.ry - f.tail)
                let tL = point(theta), tR = point(2 * .pi - theta)
                let tanL = tangent(theta), tanR = tangent(2 * .pi - theta)
                p.move(to: tip)
                p.addCurve(to: tL, control1: CGPoint(x: tip.x, y: tip.y + f.tail * 0.5),
                           control2: CGPoint(x: tL.x - tanL.x * 0.35, y: tL.y - tanL.y * 0.35))
                addArc(&p, from: theta, to: 2 * .pi - theta)
                p.addCurve(to: tip, control1: CGPoint(x: tR.x + tanR.x * 0.35, y: tR.y + tanR.y * 0.35),
                           control2: CGPoint(x: tip.x, y: tip.y + f.tail * 0.5))
                p.closeSubpath()
            } else {
                p.addEllipse(in: CGRect(x: f.center.x - f.rx, y: f.center.y - f.ry, width: 2 * f.rx, height: 2 * f.ry))
            }
        }
        return p
    }

    private func addArc(_ p: inout Path, from a: CGFloat, to b: CGFloat) {
        let steps = 48
        for i in 1...steps {
            p.addLine(to: point(a + (b - a) * CGFloat(i) / CGFloat(steps)))
        }
    }
}

@Observable @MainActor
final class Goo {
    var frame = WaterFrame()
}

/// The water, drawn inside the notch's own window with the same clear Liquid Glass as the notch.
/// It's cut off exactly at the notch's edge, so it reads as the notch's own surface pulled down.
struct TrayLiquidView: View {
    let goo: Goo

    var body: some View {
        let f = goo.frame
        ZStack(alignment: .topLeading) {
            if f.visible {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .glassEffect(.clear, in: WaterShape(f: f))
                    .mask {
                        // Everywhere but inside the notch: the water is the notch's own surface pulled out.
                        Path { p in
                            p.addRect(CGRect(x: -2000, y: -2000, width: 6000, height: 6000))
                            p.addRoundedRect(in: f.notch.insetBy(dx: 0.5, dy: 0.5),
                                             cornerSize: CGSize(width: f.notchRadius, height: f.notchRadius), style: .continuous)
                        }
                        .fill(style: FillStyle(eoFill: true))
                    }
                    .opacity(f.alpha)
                if let b = f.iconFrame, let icon = f.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: b.width, height: b.height)
                        .opacity(f.iconAlpha)
                        .position(x: b.midX, y: b.midY)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Controller

/// The file tray's water. It only ever comes out of (and goes back into) the *open* notch's edge.
///
///  • Drag a file out of the tray: inside the notch only its icon moves. Past the edge, the notch's
///    surface pulls down after it in a meniscus and a neck that thins as you pull, until it pinches:
///    the surface springs back up with a wobble, the drop's tail snaps in, and the drop, wobbling,
///    follows the pointer. Let go over the notch and it sinks back in.
///  • Bring files up toward the open notch: its surface bulges down to meet them, and joins them once
///    they're close. Dropping them in makes the surface gulp.
@MainActor
final class LiquidTray {
    private unowned let model: AppModel
    let goo = Goo()
    private var timer: Timer?

    private enum Phase { case idle, pulling, returning, popping, reaching, settling }
    private var phase: Phase = .idle

    private var drop = Drop()
    private var neck = Springy(0, response: 0.2, damping: 0.9)
    private var bump = Springy(0, response: 0.34, damping: 0.32)
    private var tail = Springy(0, response: 0.2, damping: 0.6)
    private var alpha = Springy(1, response: 0.2, damping: 1)
    private var connected = false
    private var anchorX: CGFloat = 0
    /// Where on the outline the water leaves from, and which way is out (screen coordinates).
    private var anchorPoint = CGPoint.zero
    private var anchorNormal = CGPoint(x: 0, y: -1)
    private var foot: CGFloat = 0
    private var hasDrop = false

    private var slot = CGRect.zero
    private var pullStart = CGPoint.zero
    private var icon: NSImage?
    private var broken = false
    private var lastTick = CACurrentMediaTime()

    private static let radius: CGFloat = 30
    private static let breakPull: CGFloat = 150
    /// How far below the open notch the notch's window reaches, for the water.
    static let roomBelow: CGFloat = 300

    init(model: AppModel) { self.model = model }

    // MARK: Test mode

    /// PERGOLA_LIQUID_DEMO=pull:<points> holds a file drag that far below its slot (add ",go" to let
    /// go there); reach:<points> holds files that far below the open notch. For checking the look.
    private var demoMouse: CGPoint?
    private var demoDown = true
    private var pointer: CGPoint { demoMouse ?? NSEvent.mouseLocation }
    private var buttonDown: Bool { demoMouse != nil ? demoDown : NSEvent.pressedMouseButtons & 1 == 1 }

    func startDemoIfAsked() {
        guard let spec = ProcessInfo.processInfo.environment["PERGOLA_LIQUID_DEMO"] else { return }
        // pull:<dx>,<dy> / reach:<dx>,<dy>, in points from the open notch's bottom centre (dy down).
        let parts = spec.split(separator: ":")
        let nums = (parts.last ?? "").split(separator: ",").compactMap { Double($0) }.map { CGFloat($0) }
        let dx = nums.count > 1 ? nums[0] : 0, dy = nums.last ?? 0
        let n = openNotch
        if parts.first == "reach" {
            demoMouse = CGPoint(x: n.midX + dx, y: n.minY - dy)
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { if let self, let m = self.demoMouse { self.reach(toward: m) } }
            }
        } else {
            let slot = CGRect(x: n.midX - 20, y: n.minY + 30, width: 40, height: 40)
            demoMouse = CGPoint(x: slot.midX, y: slot.midY)
            beginDragOut(UUID(), icon: NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app"), slot: slot)
            let start = Date()
            Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    let k = min(1, Date().timeIntervalSince(start) / 0.8)
                    // Out through the bottom, then across to the side if asked.
                    self?.demoMouse = CGPoint(x: slot.midX + dx * k, y: slot.midY - (dy + 50) * k)
                    if k >= 1 { t.invalidate() }
                }
            }
        }
    }

    // MARK: Geometry

    private var screen: NSScreen {
        NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main ?? NSScreen.screens[0]
    }

    /// The open notch, in screen coordinates (its bottom edge is the water's surface).
    private var openNotch: CGRect {
        let s = screen.frame, e = model.ui.expandedSize
        return CGRect(x: s.midX - e.width / 2, y: s.maxY - e.height, width: e.width, height: e.height)
    }

    /// The nearest point on the open notch's outline to `p` (screen coordinates), the outward
    /// direction there, and how far outside the outline `p` is (negative inside).
    private func outline(_ p: CGPoint) -> (point: CGPoint, normal: CGPoint, distance: CGFloat, room: CGFloat) {
        let n = openNotch, cr = NotchMetrics.expandedBottomRadius
        let q = CGPoint(x: min(max(p.x, n.minX + cr), n.maxX - cr), y: min(max(p.y, n.minY + cr), n.maxY))
        var v = CGPoint(x: p.x - q.x, y: p.y - q.y)
        var len = hypot(v.x, v.y)
        if len < 0.001 { v = CGPoint(x: 0, y: -1); len = 0 }
        let normal = len > 0 ? CGPoint(x: v.x / len, y: v.y / len) : v
        let point = CGPoint(x: q.x + normal.x * cr, y: q.y + normal.y * cr)
        // Inside the core (well within the notch): how deep, roughly.
        let distance = len > 0 ? len - cr : -min(p.y - (n.minY + cr), p.x - n.minX, n.maxX - p.x) - cr
        // Water clings to flat surface: near a rounded corner it leaves from the nearer flat stretch
        // (bottom or side), just inside the corner, and bends toward the file from there. The
        // `room` is how far the surface runs flat either side, which the water may spread over.
        let margin: CGFloat = 20
        var anchor = point, out = normal
        if p.y < n.minY + 4 || (q.x > n.minX + cr && q.x < n.maxX - cr) {
            anchor = CGPoint(x: min(max(p.x, n.minX + cr + margin), n.maxX - cr - margin), y: n.minY)
            out = CGPoint(x: 0, y: -1)
        } else {
            anchor = CGPoint(x: normal.x < 0 ? n.minX : n.maxX, y: min(max(p.y, n.minY + cr + margin), n.maxY - margin))
            out = CGPoint(x: normal.x < 0 ? -1 : 1, y: 0)
        }
        let room = out.y != 0 ? min(anchor.x - (n.minX + cr), (n.maxX - cr) - anchor.x)
                              : min(anchor.y - (n.minY + cr), n.maxY - anchor.y)
        let point2 = anchor, normal2 = out
        return (point2, normal2, distance, room)
    }

    /// Screen y → the notch window's y (top-left origin).
    private func ly(_ y: CGFloat) -> CGFloat { model.ui.panelFrame.maxY - y }
    private func lx(_ x: CGFloat) -> CGFloat { x - model.ui.panelFrame.minX }

    private func haptic(_ p: NSHapticFeedbackManager.FeedbackPattern) {
        if Prefs.d.bool(forKey: Prefs.haptics) { NSHapticFeedbackManager.defaultPerformer.perform(p, performanceTime: .now) }
    }

    // MARK: Dragging a file out

    /// A tray tile started being dragged. `slot` is its icon's rect on screen.
    func beginDragOut(_ item: UUID, icon: NSImage, slot: CGRect) {
        guard phase == .idle || phase == .reaching || phase == .settling else { return }
        phase = .pulling
        broken = false
        connected = false
        hasDrop = true
        self.icon = icon
        self.slot = slot
        pullStart = pointer
        let r = Self.radius
        drop.snap(CGRect(x: slot.midX - r, y: slot.midY - r, width: 2 * r, height: 2 * r))
        drop.move(response: 0.08, damping: 0.82)
        drop.resize(response: 0.2, damping: 0.6)
        neck.snap(2 * r); bump.snap(0); tail.snap(0); alpha.snap(1)
        model.ui.liftedTrayItem = item
        startTimer()
    }

    private func pullStep(_ mouse: CGPoint) {
        let r = Self.radius
        var target = CGPoint(x: slot.midX + (mouse.x - pullStart.x), y: slot.midY + (mouse.y - pullStart.y))
        if broken {
            drop.aim(center: mouse)
            stretchWithSpeed()
            return
        }
        // Out of the notch in any direction: past the outline, surface tension holds it back along
        // the way it's leaving.
        let o = outline(target)
        if o.distance > 0 {
            let held = 150 * (1 - 1 / (o.distance / 150 + 1))
            target = CGPoint(x: o.point.x + o.normal.x * held, y: o.point.y + o.normal.y * held)
        }
        drop.aim(center: target)
        let now = outline(drop.center)
        let out = now.distance // how far the drop's centre is outside the notch
        connected = out > -r * 0.95
        let t = max(0, min(1, (out - r) / 75)) // 0 just out … 1 about to break
        // It stretches along the way it's being pulled.
        drop.sy.target = 1 + 0.2 * t
        drop.sx.target = 1 - 0.09 * t
        let w = out < r ? 2 * r * 0.92 : 2 * r * 0.9 * pow(1 - t, 1.25) + 2
        neck.target = w
        foot = w / 2 + 16 + 22 * (1 - t)
        setAnchor(now.point, now.normal, room: now.room)
        if o.distance > Self.breakPull { letGo(mouse) }
    }

    private func setAnchor(_ point: CGPoint, _ normal: CGPoint, room: CGFloat) {
        anchorPoint = point
        anchorNormal = normal
        foot = min(foot, room + 6)
    }

    private func letGo(_ mouse: CGPoint) {
        broken = true
        connected = false
        haptic(.generic)
        let gap = max(0, outline(drop.center).distance - drop.h.x / 2 * drop.sy.x)
        // The surface springs back up, wobbling; the drop's tail snaps in.
        bump.snap(gap * 0.55); bump.target = 0
        tail.snap(gap * 0.5); tail.target = 0
        drop.move(response: 0.16, damping: 0.66)
        drop.sy.v = -4; drop.sx.v = 3
        drop.sx.target = 1; drop.sy.target = 1
    }

    private func stretchWithSpeed() {
        let v = drop.velocity
        let s = hypot(v.x, v.y)
        guard s > 1 else { drop.sx.target = 1; drop.sy.target = 1; return }
        let e = min(0.16, s / 9000)
        drop.sx.target = 1 + e * abs(v.x) / s - e * 0.5 * abs(v.y) / s
        drop.sy.target = 1 + e * abs(v.y) / s - e * 0.5 * abs(v.x) / s
    }

    private func endDragOut() {
        let mouse = pointer
        if openNotch.insetBy(dx: -6, dy: -6).contains(mouse) && model.ui.expanded {
            // Let go over the notch: it sinks back in.
            phase = .returning
            connected = false
            drop.aim(center: CGPoint(x: slot.midX, y: slot.midY))
            drop.move(response: 0.3, damping: 0.7)
            drop.sx.target = 1; drop.sy.target = 1
        } else {
            // Dropped somewhere: the drop splashes out and is gone.
            phase = .popping
            connected = false
            drop.resize(response: 0.2, damping: 0.6)
            drop.aim(size: CGSize(width: Self.radius * 2.7, height: Self.radius * 2.7))
            alpha.target = 0
        }
        withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.liftedTrayItem = nil }
    }

    // MARK: Files coming in

    /// Files are being dragged near the open notch (from below): its surface reaches for them.
    func reach(toward mouse: CGPoint) {
        guard phase == .idle || phase == .reaching || phase == .settling else { return }
        let r: CGFloat = 26
        let o = outline(mouse)
        let gap = o.distance - r
        guard model.ui.expanded, gap > -r, gap < 260, mouse.y < openNotch.maxY - 4 else { endReach(); return }
        if phase != .reaching {
            phase = .reaching
            icon = nil
            hasDrop = false
            drop.snap(CGRect(x: mouse.x - r, y: mouse.y - r, width: 2 * r, height: 2 * r))
            drop.move(response: 0.12, damping: 0.8)
            drop.resize(response: 0.25, damping: 0.6)
            alpha.snap(1)
            bump.tune(response: 0.22, damping: 0.75)
            startTimer()
        }
        drop.aim(center: mouse)
        let u = max(0, min(1, 1 - gap / 260))
        // The surface bulges down toward the files; nearer, a drop forms around them, and close
        // enough the two join.
        bump.target = min(max(gap, 0) * 0.62, 70) * pow(u, 1.2)
        connected = gap < 56
        hasDrop = gap < 110
        let near = max(0, min(1, (110 - gap) / 60))
        drop.aim(size: CGSize(width: 2 * r * (0.55 + 0.45 * near), height: 2 * r * (0.55 + 0.45 * near)))
        neck.target = 2 * r * (0.35 + 0.35 * max(0, min(1, (56 - gap) / 56)))
        foot = 34 + 22 * u
        setAnchor(o.point, o.normal, room: o.room)
    }

    func endReach() {
        guard phase == .reaching else { return }
        phase = .settling
        hasDrop = false
        connected = false
        bump.tune(response: 0.34, damping: 0.35)
        bump.target = 0
    }

    /// Files were dropped into the tray: the surface gulps.
    func gulp() {
        guard model.ui.expanded else { return }
        phase = .settling
        hasDrop = false
        connected = false
        foot = 46
        let o = outline(NSEvent.mouseLocation)
        setAnchor(o.point, o.normal, room: o.room)
        bump.tune(response: 0.34, damping: 0.3)
        bump.target = 0
        bump.v = 260
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

        if phase == .pulling {
            if buttonDown { pullStep(pointer) } else { endDragOut() }
        }
        drop.step(dt); neck.step(dt); bump.step(dt); tail.step(dt); alpha.step(dt)

        // Once the surface has settled after the break, the tile shows again in the tray.
        var done = false
        switch phase {
        case .returning: done = drop.settled
        case .popping: done = alpha.x < 0.03
        case .settling: done = abs(bump.x) < 0.3 && abs(bump.v) < 4
        case .idle: done = true
        case .pulling, .reaching: break
        }
        if done || (!model.ui.expanded && phase != .pulling && phase != .popping) {
            phase = .idle
            goo.frame = WaterFrame()
            timer?.invalidate(); timer = nil
            return
        }
        render()
    }

    private func render() {
        let n = openNotch
        var f = WaterFrame()
        // Turn the water to face out of the outline: local "down" becomes the outward direction.
        let o = CGPoint(x: lx(anchorPoint.x), y: ly(anchorPoint.y))
        let out = CGPoint(x: anchorNormal.x, y: -anchorNormal.y) // drawing coordinates (y down)
        let angle = atan2(-out.x, out.y)
        f.origin = o
        f.angle = angle
        f.notch = CGRect(x: lx(n.minX), y: ly(n.maxY), width: n.width, height: n.height)
        f.notchRadius = NotchMetrics.expandedBottomRadius
        f.edgeY = 0
        f.anchorX = 0
        f.foot = foot
        f.connected = connected
        f.neck = max(0, neck.x)
        f.bump = max(0, bump.x)
        f.tail = max(0, tail.x)
        f.alpha = Double(max(0, min(1, alpha.x)))
        // The drop, in the water's own (turned) frame.
        let c = CGPoint(x: lx(drop.cx.x) - o.x, y: ly(drop.cy.x) - o.y)
        let cosA = cos(-angle), sinA = sin(-angle)
        f.center = CGPoint(x: c.x * cosA - c.y * sinA, y: c.x * sinA + c.y * cosA)
        f.rx = drop.w.x / 2 * drop.sx.x
        f.ry = drop.h.x / 2 * drop.sy.x
        let outside = outline(drop.center).distance > -f.ry
        f.hasDrop = hasDrop && (phase == .reaching || outside)
        if let icon, phase == .pulling || phase == .returning || phase == .popping {
            let side: CGFloat = 40
            let ic = CGPoint(x: lx(drop.cx.x), y: ly(drop.cy.x))
            f.icon = icon
            f.iconFrame = CGRect(x: ic.x - side / 2, y: ic.y - side / 2, width: side, height: side)
            f.iconAlpha = f.alpha
        }
        f.visible = f.hasDrop || f.bump > 0.4 || f.icon != nil
        if f != goo.frame { goo.frame = f }
    }
}
