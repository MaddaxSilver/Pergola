import SwiftUI
import AppKit

// MARK: - Springs

/// One value pulled toward a target by a damped spring, stepped by hand every frame. Hand-stepped
/// springs keep their velocity when the target moves mid-flight, which is what makes the liquid
/// feel continuous (SwiftUI animations can't drive a Canvas).
struct Springy {
    var x: CGFloat
    var v: CGFloat = 0
    var target: CGFloat
    private var k: CGFloat = 0
    private var c: CGFloat = 0

    init(_ x: CGFloat) { self.x = x; target = x; tune(response: 0.4, damping: 0.8) }

    /// `response` is roughly the period in seconds; `damping` 1 = no overshoot, lower = wobble.
    mutating func tune(response: CGFloat, damping: CGFloat) {
        k = pow(2 * .pi / response, 2)
        c = 4 * .pi * damping / response
    }

    mutating func snap(_ value: CGFloat) { x = value; target = value; v = 0 }

    mutating func step(_ dt: CGFloat) {
        let a = -k * (x - target) - c * v
        v += a * dt
        x += v * dt
    }

    var settled: Bool { abs(x - target) < 0.4 && abs(v) < 4 }
}

struct SpringRect {
    var x = Springy(0), y = Springy(0), w = Springy(0), h = Springy(0)

    var rect: CGRect { CGRect(x: x.x, y: y.x, width: max(0, w.x), height: max(0, h.x)) }
    var targetRect: CGRect { CGRect(x: x.target, y: y.target, width: w.target, height: h.target) }

    mutating func tune(response: CGFloat, damping: CGFloat) {
        x.tune(response: response, damping: damping); y.tune(response: response, damping: damping)
        w.tune(response: response, damping: damping); h.tune(response: response, damping: damping)
    }
    mutating func snap(_ r: CGRect) { x.snap(r.minX); y.snap(r.minY); w.snap(r.width); h.snap(r.height) }
    mutating func aim(_ r: CGRect) { x.target = r.minX; y.target = r.minY; w.target = r.width; h.target = r.height }
    mutating func step(_ dt: CGFloat) { x.step(dt); y.step(dt); w.step(dt); h.step(dt) }
    var settled: Bool { x.settled && y.settled && w.settled && h.settled }
}

// MARK: - What the liquid overlay draws

/// One frame of liquid, in the overlay's own coordinates (top-left origin).
struct GooFrame {
    struct Blob { var rect: CGRect; var radius: CGFloat }
    struct Bridge { var a: CGPoint; var b: CGPoint; var width: CGFloat }
    var blobs: [Blob] = []
    var bridges: [Bridge] = []
    /// The moving drop, which carries the picture.
    var drop: CGRect = .zero
    var dropRadius: CGFloat = 12
    var showsContent = false
    var contentAlpha: Double = 1

    var bounds: CGRect? {
        var r: CGRect?
        for b in blobs { r = r?.union(b.rect) ?? b.rect }
        for b in bridges {
            let s = CGRect(x: min(b.a.x, b.b.x), y: min(b.a.y, b.b.y), width: abs(b.a.x - b.b.x), height: abs(b.a.y - b.b.y))
                .insetBy(dx: -b.width, dy: -b.width)
            r = r?.union(s) ?? s
        }
        return r?.insetBy(dx: -30, dy: -30).integral
    }
}

@Observable @MainActor
final class Goo {
    var frame = GooFrame()
}

/// Black liquid, drawn the classic metaball way: blurred shapes cut at half opacity, so anything
/// close together melts into one smooth drop and thin necks pinch off by themselves.
struct GooView: View {
    @Environment(AppModel.self) private var model
    let goo: Goo

    var body: some View {
        let f = goo.frame
        ZStack(alignment: .topLeading) {
            if let box = f.bounds {
                Canvas { ctx, _ in
                    ctx.addFilter(.alphaThreshold(min: 0.5, color: .black))
                    ctx.addFilter(.blur(radius: 9))
                    ctx.drawLayer { l in
                        l.translateBy(x: -box.minX, y: -box.minY)
                        for b in f.blobs {
                            l.fill(Path(roundedRect: b.rect, cornerRadius: b.radius, style: .continuous), with: .color(.black))
                        }
                        for b in f.bridges where b.width > 0.5 {
                            var p = Path(); p.move(to: b.a); p.addLine(to: b.b)
                            l.stroke(p, with: .color(.black), style: StrokeStyle(lineWidth: b.width, lineCap: .round))
                        }
                    }
                }
                .frame(width: box.width, height: box.height)
                .offset(x: box.minX, y: box.minY)
            }
            if f.showsContent, f.drop.width > 1 {
                VideoCard(cornerRadius: f.dropRadius)
                    .frame(width: f.drop.width, height: f.drop.height)
                    .opacity(f.contentAlpha)
                    .offset(x: f.drop.minX, y: f.drop.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

/// The picture: the live video when there is one, the artwork until then (or for music apps).
struct VideoCard: View {
    @Environment(AppModel.self) private var model
    var cornerRadius: CGFloat

    var body: some View {
        let mirror = model.video
        let live = model.player.source == .web && mirror.hasFrame
        ZStack {
            Color.black
            ArtworkView(image: model.player.artwork, cornerRadius: 0)
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

/// Picture in picture you pull out of the notch like a drop of water.
///
///  • Pull the art down: it stretches against the notch with growing resistance, a neck of liquid
///    holding it back, until it pinches off into a floating video window.
///  • Drag that window back up: the notch and the window reach for each other and, once released
///    close enough, it melts back into the notch.
@MainActor
final class PiPController {
    private unowned let model: AppModel
    let goo = Goo()
    private var overlay: GooPanel?
    private var window: PiPPanel?
    private var timer: Timer?

    private enum Phase { case idle, pulling, landing, returning, floating, dragging, merging }
    private var phase: Phase = .idle

    // Liquid state (screen coordinates).
    private var home = SpringRect()
    private var homeShown = false
    private var drop = SpringRect()
    private var dropRadius = Springy(11)
    private var bridge = Springy(0)
    private var contentAlpha = Springy(1)
    /// Fades the notch↔window tendrils out after a drag that didn't merge.
    private var reachFade = Springy(0)

    private var artRect = CGRect.zero
    private var artRadius: CGFloat = 11
    private var pullStart = CGPoint.zero
    private var broken = false
    private var brokeAt = Date.distantPast
    private var landingSince = Date.distantPast
    private var grab = CGPoint.zero

    private static let breakDistance: CGFloat = 115
    private static let reachRadius: CGFloat = 190
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
        get { let w = Prefs.d.double(forKey: "pipWidth"); return w > 0 ? w : (aspect > 1.2 ? 340 : 240) }
        set { Prefs.d.set(newValue, forKey: "pipWidth") }
    }

    private func pipRect(centeredAt c: CGPoint) -> CGRect {
        let w = pipWidth, h = (w / aspect).rounded()
        return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
    }

    /// Screen rect (bottom-left origin) → overlay rect (top-left origin).
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

    // MARK: Pulling out of the notch

    /// The art was grabbed. `artRect` is where it is on screen.
    func beginPull(artRect: CGRect, radius: CGFloat, mouse: CGPoint) {
        guard phase == .idle, !isOpen, model.player.hasTrack else { return }
        phase = .pulling
        broken = false
        self.artRect = artRect
        artRadius = radius
        pullStart = mouse
        wantVideo("pull")
        withAnimation(.easeOut(duration: 0.12)) { model.ui.artLifted = true }
        home.snap(artRect); homeShown = true
        drop.snap(artRect)
        dropRadius.snap(radius)
        bridge.snap(artRect.width * 0.62)
        contentAlpha.snap(1)
        reachFade.snap(0)
        showOverlay()
        render()
    }

    func pull(to mouse: CGPoint) {
        guard phase == .pulling else { return }
        let dx = mouse.x - pullStart.x, dy = mouse.y - pullStart.y
        let d = hypot(dx, dy)
        if !broken {
            // Rubber-band: the art follows less and less the further you pull.
            let t = min(1, d / Self.breakDistance)
            let shown = 150 * (1 - 1 / (d * 0.95 / 150 + 1))
            let dir = d > 0 ? CGPoint(x: dx / d, y: dy / d) : .zero
            let grow = 1 + 0.12 * t
            let c = CGPoint(x: artRect.midX + dir.x * shown, y: artRect.midY + dir.y * shown)
            drop.snap(CGRect(x: c.x - artRect.width * grow / 2, y: c.y - artRect.height * grow / 2,
                             width: artRect.width * grow, height: artRect.height * grow))
            home.snap(artRect.insetBy(dx: artRect.width * 0.14 * t, dy: artRect.height * 0.14 * t))
            // The neck thins as it stretches; past the break point it's too thin to hold.
            bridge.snap(artRect.width * 0.62 * pow(1 - t, 1.2) + 7)
            if d > Self.breakDistance { breakOff(mouse) }
        } else {
            drop.aim(pipRect(centeredAt: mouse))
        }
        render()
    }

    private func breakOff(_ mouse: CGPoint) {
        broken = true
        brokeAt = Date()
        if Prefs.d.bool(forKey: Prefs.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        }
        // The neck snaps, the drop left behind wobbles back into shape…
        bridge.tune(response: 0.16, damping: 1); bridge.target = 0
        home.tune(response: 0.32, damping: 0.42); home.aim(artRect)
        // …and the freed drop leaps to the pointer and swells into the video.
        drop.tune(response: 0.42, damping: 0.68); drop.aim(pipRect(centeredAt: mouse))
        dropRadius.tune(response: 0.4, damping: 0.8); dropRadius.target = 14
        startTimer()
    }

    func endPull() {
        guard phase == .pulling else { return }
        if broken {
            phase = .landing
            landingSince = Date()
            drop.tune(response: 0.3, damping: 0.85)
        } else {
            // Let go too early: it springs back into the notch with a wobble.
            phase = .returning
            drop.tune(response: 0.34, damping: 0.5); drop.aim(artRect)
            home.tune(response: 0.3, damping: 0.6); home.aim(artRect)
            bridge.tune(response: 0.3, damping: 0.7); bridge.target = artRect.width * 0.62
        }
        startTimer()
    }

    /// Pops the picture out without a drag (button or shortcut): a drop falls out of the notch and
    /// floats to the top-right corner.
    func popOut() {
        guard phase == .idle, !isOpen, model.player.hasTrack else { return }
        wantVideo("pull")
        let n = notchRect
        let visible = screen.visibleFrame
        let size = pipRect(centeredAt: .zero).size
        let target = CGRect(x: visible.maxX - size.width - 20, y: visible.maxY - size.height - 20,
                            width: size.width, height: size.height)
        phase = .landing
        broken = true
        brokeAt = .distantPast
        landingSince = Date()
        homeShown = false
        home.snap(n)
        drop.snap(CGRect(x: n.midX - 20, y: n.minY - 10, width: 40, height: 30))
        dropRadius.snap(15)
        contentAlpha.snap(0)
        bridge.snap(26)
        showOverlay()
        drop.tune(response: 0.55, damping: 0.75); drop.aim(target)
        dropRadius.tune(response: 0.4, damping: 1); dropRadius.target = 14
        contentAlpha.tune(response: 0.35, damping: 1); contentAlpha.target = 1
        bridge.tune(response: 0.3, damping: 1); bridge.target = 0
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
            ctx.duration = 0.18
            w.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                w.orderOut(nil)
                self?.phase = .idle
            }
        })
    }

    /// Keeps the window's shape matched to the video's once the real picture arrives.
    func fitAspect() {
        guard let w = window, w.isVisible, phase == .floating else { return }
        let f = w.frame
        let h = (f.width / aspect).rounded()
        guard abs(h - f.height) > 1 else { return }
        w.setFrame(CGRect(x: f.minX, y: f.maxY - h, width: f.width, height: h), display: true, animate: true)
        w.invalidateShadow()
    }

    private func resize(by factor: CGFloat) {
        guard let w = window, phase == .floating else { return }
        let f = w.frame
        let width = min(760, max(200, f.width * factor))
        let h = (width / aspect).rounded()
        pipWidth = width
        w.setFrame(CGRect(x: f.midX - width / 2, y: f.midY - h / 2, width: width, height: h), display: true)
        w.invalidateShadow()
    }

    // MARK: Dragging it back

    func windowDragChanged() {
        guard let w = window else { return }
        let mouse = NSEvent.mouseLocation
        if phase != .dragging {
            guard phase == .floating else { return }
            phase = .dragging
            grab = CGPoint(x: mouse.x - w.frame.minX, y: mouse.y - w.frame.minY)
            w.level = Self.level
        }
        var origin = CGPoint(x: mouse.x - grab.x, y: mouse.y - grab.y)
        // Near the notch, the two reach for each other and the window is drawn in a little.
        let size = w.frame.size
        let n = notchRect
        let top = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height)
        let u = reach(from: top, notch: n)
        origin.x += (n.midX - top.x) * 0.25 * u * u
        origin.y += (n.minY - top.y) * 0.25 * u * u
        w.setFrameOrigin(origin)
        drop.snap(CGRect(origin: origin, size: size))
        dropRadius.snap(14)
        if u > 0 {
            reachFade.snap(1)
            if overlay?.isVisible != true { showOverlay(); w.orderFrontRegardless() }
            render()
        } else if overlay?.isVisible == true {
            reachFade.snap(0)
            render()
        }
    }

    func windowDragEnded() {
        guard phase == .dragging, let w = window else { return }
        let f = w.frame
        let u = reach(from: CGPoint(x: f.midX, y: f.maxY), notch: notchRect)
        if u > 0.45 { merge() } else {
            phase = .floating
            w.level = .floating
            // Keep it on screen.
            let visible = (NSScreen.screens.first { $0.frame.intersects(f) } ?? screen).visibleFrame
            var o = f.origin
            o.x = min(max(o.x, visible.minX + 8), visible.maxX - f.width - 8)
            o.y = min(max(o.y, visible.minY + 8), visible.maxY - f.height - 8)
            if o != f.origin { w.setFrame(CGRect(origin: o, size: f.size), display: true, animate: true) }
            reachFade.tune(response: 0.3, damping: 1); reachFade.target = 0
            startTimer()
        }
    }

    /// 0 when far from the notch, 1 when touching it.
    private func reach(from top: CGPoint, notch n: CGRect) -> CGFloat {
        let d = hypot(top.x - n.midX, top.y - n.minY)
        return max(0, min(1, 1 - d / Self.reachRadius))
    }

    /// Sends the window home: it flies into the notch and is swallowed.
    func merge() {
        guard let w = window, w.isVisible else { return }
        phase = .merging
        showOverlay()
        drop.snap(w.frame)
        dropRadius.snap(14)
        contentAlpha.snap(1)
        reachFade.snap(1)
        homeShown = false
        w.orderOut(nil)
        let n = notchRect
        let target = CGRect(x: n.midX - n.width * 0.3, y: n.maxY - n.height, width: n.width * 0.6, height: n.height)
        drop.tune(response: 0.5, damping: 0.86); drop.aim(target)
        dropRadius.tune(response: 0.4, damping: 1); dropRadius.target = n.height / 2
        contentAlpha.tune(response: 0.45, damping: 1); contentAlpha.target = 0
        startTimer()
        render()
    }

    private func finishMerge() {
        phase = .idle
        hideOverlay()
        model.video.release("pip")
        if Prefs.d.bool(forKey: Prefs.haptics) {
            NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        }
        // A little gulp.
        withAnimation(Motion.hover) { model.ui.hovering = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) { [weak self] in
            withAnimation(Motion.hover) { self?.model.ui.hovering = false }
        }
    }

    // MARK: Frame loop

    private func startTimer() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 120.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        t.tolerance = 0
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopTimer() { timer?.invalidate(); timer = nil }

    private func tick() {
        let dt: CGFloat = 1.0 / 120.0
        home.step(dt); drop.step(dt); dropRadius.step(dt); bridge.step(dt); contentAlpha.step(dt); reachFade.step(dt)

        switch phase {
        case .pulling:
            // Once the left-behind drop has settled, the real art takes its place again.
            if broken, homeShown, Date().timeIntervalSince(brokeAt) > 0.45 {
                homeShown = false
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.artLifted = false }
            }
        case .landing:
            if homeShown, Date().timeIntervalSince(brokeAt) > 0.45 {
                homeShown = false
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.artLifted = false }
            }
            if drop.settled || Date().timeIntervalSince(landingSince) > 0.7 {
                if homeShown { homeShown = false; withAnimation(.spring(duration: 0.35, bounce: 0.3)) { model.ui.artLifted = false } }
                wantVideo("pip")
                openWindow(at: drop.targetRect.integral)
                model.video.release("pull")
                // Give the window a frame to draw before the liquid copy goes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in self?.hideOverlay() }
                stopTimer()
                return
            }
        case .returning:
            if drop.settled && bridge.settled {
                phase = .idle
                hideOverlay()
                withAnimation(.easeOut(duration: 0.1)) { model.ui.artLifted = false }
                model.video.release("pull")
                stopTimer()
                return
            }
        case .merging:
            if (drop.settled && contentAlpha.x < 0.05) || drop.rect.height <= model.ui.notchSize.height + 1 && contentAlpha.x < 0.1 {
                stopTimer()
                finishMerge()
                return
            }
        case .floating:
            if reachFade.settled && reachFade.x < 0.02 {
                hideOverlay(); stopTimer(); return
            }
        case .idle, .dragging:
            stopTimer()
            return
        }
        render()
    }

    /// Turns the springs into what the overlay draws.
    private func render() {
        var f = GooFrame()
        let d = drop.rect
        f.drop = local(d)
        f.dropRadius = dropRadius.x
        f.contentAlpha = Double(max(0, min(1, contentAlpha.x)))

        switch phase {
        case .pulling, .landing, .returning:
            f.showsContent = true
            if homeShown {
                f.blobs.append(.init(rect: local(home.rect), radius: artRadius))
            }
            f.blobs.append(.init(rect: local(d).insetBy(dx: 1, dy: 1), radius: dropRadius.x))
            if bridge.x > 0.5 {
                let a = CGPoint(x: home.rect.midX, y: home.rect.midY)
                let b = CGPoint(x: d.midX, y: d.midY)
                f.bridges.append(.init(a: local(a), b: local(b), width: bridge.x))
            }
        case .dragging, .floating, .merging:
            f.showsContent = phase == .merging
            let n = notchRect
            let top = CGPoint(x: d.midX, y: d.maxY)
            let u = reach(from: top, notch: n) * max(0, min(1, reachFade.x))
            // The notch itself is one drop (stretched up past the screen edge so only its bottom shows).
            f.blobs.append(.init(rect: local(n.insetBy(dx: 0, dy: -20)).offsetBy(dx: 0, dy: -10), radius: n.height / 2))
            f.blobs.append(.init(rect: local(d).insetBy(dx: 2, dy: 2), radius: dropRadius.x))
            if u > 0 {
                // Two tendrils reach for each other; close enough, they meet and become one neck.
                let nb = CGPoint(x: n.midX, y: n.minY)
                let reachLen = min(1, 0.12 + 0.62 * u)
                let width = 6 + 26 * u
                let p1 = CGPoint(x: nb.x + (top.x - nb.x) * reachLen, y: nb.y + (top.y - nb.y) * reachLen)
                let p2 = CGPoint(x: top.x + (nb.x - top.x) * reachLen, y: top.y + (nb.y - top.y) * reachLen)
                f.bridges.append(.init(a: local(nb), b: local(p1), width: width))
                f.bridges.append(.init(a: local(top), b: local(p2), width: width))
            }
        case .idle:
            break
        }
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
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.18)) { hover = h } }
            .onTapGesture(count: 2) { player.openPlayer() }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .global)
                .onChanged { _ in model.pip.windowDragChanged() }
                .onEnded { _ in model.pip.windowDragEnded() })
            .onChange(of: model.video.aspect) { model.pip.fitAspect() }
            .onChange(of: model.video.hasFrame) { model.pip.fitAspect() }
            .onChange(of: player.hasTrack) { _, has in if !has { model.pip.close() } }
            .onDisappear { model.video.release("pip") }
    }

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.45), .clear, .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
            VStack {
                HStack {
                    chip("xmark", help: "Close") { model.pip.close() }
                    Spacer()
                    chip("pip.exit", help: "Back to the notch") { model.pip.merge() }
                }
                Spacer()
            }
            .padding(8)
            HStack(spacing: 22) {
                ControlButton(symbol: "backward.fill", size: 17) { player.previous() }
                ControlButton(symbol: player.isPlaying ? "pause.fill" : "play.fill", size: 24) { player.playPause() }
                    .contentTransition(.symbolEffect(.replace))
                ControlButton(symbol: "forward.fill", size: 17) { player.next() }
            }
            .shadow(color: .black.opacity(0.4), radius: 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func chip(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(Circle().fill(.black.opacity(0.45)))
                .contentShape(Circle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }

    @ViewBuilder private var note: some View {
        if player.source == .web, let text = noteText {
            VStack(spacing: 6) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                if model.video.status == .protected {
                    Button("Use the Browser's Picture in Picture") {
                        model.video.nativePictureInPicture()
                        model.pip.close()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                } else if model.video.status == .noPermission {
                    Button("Open Screen Recording Settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity)
            .background(.black.opacity(0.6))
        }
    }

    private var noteText: String? {
        let safari = player.webBundleID?.hasPrefix("com.apple.Safari") ?? true
        switch model.video.status {
        case .noPermission: return "Allow Pergola to record the screen to show the video here."
        case .noJavaScript:
            return safari
                ? "To show the video, turn on Safari › Settings › Developer › Allow JavaScript from Apple Events."
                : "To show the video, turn on View › Developer › Allow JavaScript from Apple Events in your browser."
        case .protected: return "This video is protected, so it can't be shown here."
        default: return nil
        }
    }
}
