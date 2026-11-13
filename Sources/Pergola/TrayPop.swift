import SwiftUI
import AppKit

/// Removing a file from the tray: a bubble of the notch's clear glass swells around its icon, then
/// bursts into droplets, and the file goes with it.
@Observable @MainActor
final class TrayPops {
    struct Pop: Identifiable {
        let id = UUID()
        var icon: NSImage
        /// The icon's rect in the notch window (top-left origin).
        var rect: CGRect
        var start: Date
    }

    private(set) var pops: [Pop] = []
    /// Where each tile's icon is, so a removal knows where to pop (notch window coordinates).
    @ObservationIgnored var iconRects: [UUID: CGRect] = [:]

    static let swell = 0.17
    static let burst = 0.42
    static var length: Double { swell + burst }

    func pop(_ item: TrayItem, delay: Double = 0) {
        guard let rect = iconRects[item.id], let url = item.url else { return }
        pop(icon: NSWorkspace.shared.icon(forFile: url.path), rect: rect, delay: delay)
    }

    func pop(icon: NSImage, rect: CGRect, delay: Double = 0) {
        let p = Pop(icon: icon, rect: rect, start: Date().addingTimeInterval(delay))
        pops.append(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + Self.length + 0.05) { [weak self] in
            self?.pops.removeAll { $0.id == p.id }
        }
    }
}

struct TrayPopView: View {
    let pops: TrayPops

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !pops.pops.isEmpty {
                // Runs only while something is popping.
                TimelineView(.animation) { ctx in
                    ZStack(alignment: .topLeading) {
                        ForEach(pops.pops) { p in bubble(p, at: ctx.date) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    /// The same burst as a file dragged out of the notch: a ring flashing outward and droplets.
    private static func burstFrame(center: CGPoint, radius: CGFloat, progress: CGFloat) -> WaterFrame {
        var f = WaterFrame()
        f.center = center
        f.rx = radius
        f.ry = radius
        f.burst = progress
        return f
    }

    @ViewBuilder
    private func bubble(_ p: TrayPops.Pop, at now: Date) -> some View {
        let t = now.timeIntervalSince(p.start)
        let c = CGPoint(x: p.rect.midX, y: p.rect.midY)
        let full = p.rect.width / 2 + 11
        // Swelling: the bubble grows around the icon with a little overshoot, lifting it slightly.
        let s = max(0, min(1, t / TrayPops.swell))
        let back = 1 + 2.2 * pow(s - 1, 3) + 1.2 * pow(s - 1, 2) // ease out, overshooting
        // Bursting: 0…1 after the swell.
        let b = max(0, min(1, (t - TrayPops.swell) / TrayPops.burst))
        let bursting = t >= TrayPops.swell
        let r = full * (0.55 + 0.45 * back)
        let iconScale = bursting ? max(0, 1.08 * (1 - b * 2.4)) : 1 + 0.08 * s
        ZStack(alignment: .topLeading) {
            if bursting {
                let shape = WaterShape(f: Self.burstFrame(center: c, radius: full, progress: b * (2 - b)))
                Color.clear
                    .glassEffect(.clear, in: shape)
                    .overlay { shape.fill(.white.opacity(0.22 * (1 - b))) }
            } else if t >= 0 {
                let ring = Circle().path(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                Color.clear
                    .glassEffect(.clear, in: ring)
                    .overlay {
                        ring.stroke(.white.opacity(0.35 * s), lineWidth: 1)
                        // A soft highlight, top left, like a soap bubble catching the light.
                        Path(ellipseIn: CGRect(x: c.x - r * 0.62, y: c.y - r * 0.7, width: r * 0.5, height: r * 0.28))
                            .fill(.white.opacity(0.28 * s))
                            .blur(radius: 1.5)
                    }
            }
            Image(nsImage: p.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: p.rect.width, height: p.rect.height)
                .scaleEffect(iconScale)
                .opacity(bursting ? max(0, 1 - b * 3) : 1)
                .position(x: c.x, y: c.y)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
