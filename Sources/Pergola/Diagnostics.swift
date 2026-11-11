import AppKit
import QuartzCore

/// Frame-pacing self-test, off unless launched with `PERGOLA_STRESS=<cycles>`.
///
/// It opens and closes the notch and flips through its pages by itself while a display link on the
/// main thread records every frame interval, then prints how many frames arrived late and exits.
/// A late frame here is the main thread being busy (layout, view construction, drawing) when the
/// display asked for a frame, which is what a stutter in an animation is.
@MainActor
final class FrameMeter: NSObject {
    static var shared: FrameMeter?

    private var link: CADisplayLink?
    private var last: CFTimeInterval = 0
    private var phase = "idle"
    private var gaps: [String: [Double]] = [:]
    private var order: [String] = []
    private var stalls: [String] = []
    private var markTime: CFTimeInterval = 0

    static func runIfAsked(notch: NotchWindowController?, view: NSView?) {
        guard let raw = ProcessInfo.processInfo.environment["PERGOLA_STRESS"], let notch, let view else { return }
        let meter = FrameMeter()
        shared = meter
        meter.run(cycles: max(1, Int(raw) ?? 6), notch: notch, view: view)
    }

    private func run(cycles: Int, notch: NotchWindowController, view: NSView) {
        link = view.displayLink(target: self, selector: #selector(frame(_:)))
        link?.add(to: .main, forMode: .common)
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3)) // let launch work settle
            for _ in 0..<cycles {
                mark("open");  notch.keyboardToggle(); try? await Task.sleep(for: .seconds(1.1))
                mark("page");  notch.keyboardPage(1);  try? await Task.sleep(for: .seconds(0.8))
                mark("page");  notch.keyboardPage(-1); try? await Task.sleep(for: .seconds(0.8))
                mark("art");   notch.keyboardBigArt(); try? await Task.sleep(for: .seconds(1.1))
                mark("art");   notch.keyboardBigArt(); try? await Task.sleep(for: .seconds(1.1))
                mark("close"); notch.keyboardToggle(); try? await Task.sleep(for: .seconds(0.9))
            }
            mark("idle")
            report()
            exit(0)
        }
    }

    private func mark(_ name: String) {
        phase = name
        markTime = CACurrentMediaTime()
        last = 0 // don't count the wait before this transition as a late frame
        if !order.contains(name) { order.append(name) }
    }

    @objc private func frame(_ link: CADisplayLink) {
        let now = link.timestamp
        defer { last = now }
        guard last > 0, phase != "idle" else { return }
        let ms = (now - last) * 1000
        gaps[phase, default: []].append(ms)
        if ms > 45 { stalls.append(String(format: "%@ +%.0f ms: %.0f ms", phase, (last - markTime) * 1000, ms)) }
    }

    private func report() {
        let hz = Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        let frameMs = 1000 / hz
        for s in stalls { print("stall", s) }
        print(String(format: "display %.0f Hz (%.2f ms a frame)", hz, frameMs))
        for name in order where name != "idle" {
            let g = gaps[name] ?? []
            guard !g.isEmpty else { continue }
            let late = g.filter { $0 > frameMs * 1.5 }
            let worst = g.max() ?? 0
            let sorted = g.sorted()
            let p99 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.99))]
            print(String(format: "%-6@ frames %5d  late %4d (%.1f%%)  p99 %5.1f ms  worst %5.1f ms",
                         name as NSString, g.count, late.count, 100 * Double(late.count) / Double(g.count), p99, worst))
        }
    }
}
