import SwiftUI
import AppKit

/// One line of text that, when it doesn't fit, rests for a moment and then scrolls across to its
/// start again, with its edges fading. It sizes itself like a one-line `Text`.
///
/// The text is drawn once into an image and moved by Core Animation in the window server, so a long
/// task title can scroll for hours without Pergola redrawing anything.
struct ScrollingText: NSViewRepresentable {
    var text: String
    var font: NSFont
    var color: NSColor
    /// Points per second.
    var speed: CGFloat = 30
    /// How long it rests at the start before each pass.
    var pause: Double = 1.6

    func makeNSView(context: Context) -> ScrollingTextView { ScrollingTextView() }

    func updateNSView(_ view: ScrollingTextView, context: Context) {
        view.configure(text: text, font: font, color: color, speed: speed, pause: pause)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: ScrollingTextView, context: Context) -> CGSize? {
        let natural = ScrollingTextView.measure(text, font)
        let width = proposal.width.map { min($0, natural.width) } ?? natural.width
        return CGSize(width: max(0, width), height: natural.height)
    }
}

final class ScrollingTextView: NSView {
    private let strip = CALayer()
    private let fade = CAGradientLayer()
    private var text = ""
    private var font = NSFont.systemFont(ofSize: 12)
    private var color = NSColor.white
    private var speed: CGFloat = 30
    private var pause: Double = 1.6
    private var textSize = CGSize.zero
    private var drawnFor: (scale: CGFloat, overflow: Bool)?
    private static let gap: CGFloat = 36

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true
        strip.anchorPoint = .zero
        strip.contentsGravity = .bottomLeft
        layer?.addSublayer(strip)
        fade.startPoint = CGPoint(x: 0, y: 0.5)
        fade.endPoint = CGPoint(x: 1, y: 0.5)
    }
    required init?(coder: NSCoder) { fatalError() }

    static func measure(_ text: String, _ font: NSFont) -> CGSize {
        let s = (text as NSString).size(withAttributes: [.font: font])
        return CGSize(width: ceil(s.width), height: ceil(font.ascender - font.descender + font.leading))
    }

    func configure(text: String, font: NSFont, color: NSColor, speed: CGFloat, pause: Double) {
        guard text != self.text || font != self.font || color != self.color || speed != self.speed || pause != self.pause else { return }
        self.text = text; self.font = font; self.color = color; self.speed = speed; self.pause = pause
        textSize = Self.measure(text, font)
        drawnFor = nil
        needsLayout = true
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        drawnFor = nil
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Animations are dropped while a view is out of a window; start again when it's back.
        drawnFor = nil
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let overflow = textSize.width > bounds.width + 0.5
        let scale = window?.backingScaleFactor ?? 2
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if drawnFor?.scale != scale || drawnFor?.overflow != overflow {
            draw(copies: overflow ? 2 : 1, scale: scale)
            drawnFor = (scale, overflow)
            strip.removeAnimation(forKey: "scroll")
        }
        strip.position = CGPoint(x: 0, y: floor((bounds.height - textSize.height) / 2))
        if overflow {
            // Soft edges: a short fade on the left, a longer one where the text runs off on the right.
            let w = max(bounds.width, 1)
            fade.frame = bounds
            fade.colors = [NSColor.clear.cgColor, NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.locations = [0, NSNumber(value: Double(min(0.2, 6 / w))), NSNumber(value: Double(max(0.5, 1 - 14 / w))), 1]
            layer?.mask = fade
            if strip.animation(forKey: "scroll") == nil {
                let distance = textSize.width + Self.gap
                let travel = Double(distance / max(speed, 1))
                let a = CAKeyframeAnimation(keyPath: "position.x")
                a.values = [0, 0, -distance]
                a.keyTimes = [0, NSNumber(value: pause / (pause + travel)), 1]
                a.duration = pause + travel
                a.repeatCount = .infinity
                a.isRemovedOnCompletion = false
                a.timingFunctions = [CAMediaTimingFunction(name: .linear), CAMediaTimingFunction(name: .linear)]
                strip.add(a, forKey: "scroll")
            }
        } else {
            layer?.mask = nil
            strip.removeAnimation(forKey: "scroll")
        }
        CATransaction.commit()
    }

    /// The text, twice with a gap between when it scrolls (so the end flows into the start).
    private func draw(copies: Int, scale: CGFloat) {
        let width = textSize.width * CGFloat(copies) + Self.gap * CGFloat(copies - 1)
        let size = CGSize(width: max(1, width), height: max(1, textSize.height))
        let px = (w: Int(ceil(size.width * scale)), h: Int(ceil(size.height * scale)))
        guard let ctx = CGContext(data: nil, width: px.w, height: px.h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        for i in 0..<copies {
            (text as NSString).draw(at: CGPoint(x: CGFloat(i) * (textSize.width + Self.gap), y: -font.descender), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        strip.contents = ctx.makeImage()
        strip.contentsScale = scale
        strip.bounds = CGRect(origin: .zero, size: size)
    }
}
