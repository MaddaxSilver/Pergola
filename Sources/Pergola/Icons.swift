import AppKit

/// Pergola's glyph, drawn in code so it stays crisp at every size:
/// two posts, a beam with rafters poking through, and a little notch-pill hanging underneath.
enum PergolaIcon {
    /// Draws the glyph into `rect` (a square) using the current fill colour.
    static func drawGlyph(in rect: CGRect) {
        let u = rect.width / 18 // design grid is 18 × 18
        func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ radius: CGFloat) {
            NSBezierPath(roundedRect: CGRect(x: rect.minX + x * u, y: rect.minY + y * u, width: w * u, height: h * u),
                         xRadius: radius * u, yRadius: radius * u).fill()
        }
        // Rafters above the beam.
        for x in [2.6, 6.2, 9.8, 13.4] as [CGFloat] { r(x, 13.2, 2.0, 3.6, 0.9) }
        // Beam.
        r(0.8, 11.4, 16.4, 2.4, 1.2)
        // Posts.
        r(2.6, 1.0, 2.2, 11.0, 1.1)
        r(13.2, 1.0, 2.2, 11.0, 1.1)
        // Corner braces.
        for flip in [false, true] {
            let p = NSBezierPath()
            let x0 = flip ? 13.2 : 4.8, dir: CGFloat = flip ? -1 : 1
            p.move(to: CGPoint(x: rect.minX + x0 * u, y: rect.minY + 11.4 * u))
            p.line(to: CGPoint(x: rect.minX + (x0 + 2.6 * dir) * u, y: rect.minY + 11.4 * u))
            p.curve(to: CGPoint(x: rect.minX + x0 * u, y: rect.minY + 8.8 * u),
                    controlPoint1: CGPoint(x: rect.minX + (x0 + 0.9 * dir) * u, y: rect.minY + 11.2 * u),
                    controlPoint2: CGPoint(x: rect.minX + x0 * u, y: rect.minY + 10.2 * u))
            p.close()
            p.fill()
        }
        // The notch pill.
        r(6.4, 6.6, 5.2, 2.6, 1.3)
    }

    /// Template image for the menu bar (adapts to light/dark menu bars automatically).
    static let menuBar: NSImage = {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            NSColor.black.setFill()
            drawGlyph(in: rect)
            return true
        }
        img.isTemplate = true
        return img
    }()

    /// The full-colour app icon at `size` points: a dusk-garden gradient squircle with a glass sheen.
    static func appIcon(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: size, height: size), flipped: false) { full in
            // macOS icon grid: 824/1024 body with a soft drop shadow.
            let inset = full.width * 0.1
            let body = full.insetBy(dx: inset, dy: inset)
            let radius = body.width * 0.225
            let shape = NSBezierPath(roundedRect: body, xRadius: radius, yRadius: radius)

            NSGraphicsContext.saveGraphicsState()
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
            shadow.shadowBlurRadius = full.width * 0.03
            shadow.shadowOffset = NSSize(width: 0, height: -full.width * 0.012)
            shadow.set()
            NSColor.black.setFill()
            shape.fill()
            NSGraphicsContext.restoreGraphicsState()

            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGradient(colors: [NSColor(red: 0.07, green: 0.42, blue: 0.36, alpha: 1),
                                NSColor(red: 0.05, green: 0.16, blue: 0.22, alpha: 1),
                                NSColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1)],
                       atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
                .draw(in: body, angle: -90)
            // Warm glow behind the glyph, like light through the slats.
            NSGradient(colors: [NSColor(red: 0.55, green: 1, blue: 0.75, alpha: 0.35), .clear])!
                .draw(fromCenter: CGPoint(x: body.midX, y: body.midY + body.height * 0.1), radius: 0,
                      toCenter: CGPoint(x: body.midX, y: body.midY + body.height * 0.1), radius: body.width * 0.55, options: [])
            // Glyph.
            let g = body.insetBy(dx: body.width * 0.2, dy: body.width * 0.2)
            NSGraphicsContext.saveGraphicsState()
            let glow = NSShadow()
            glow.shadowColor = NSColor(red: 0.6, green: 1, blue: 0.8, alpha: 0.6)
            glow.shadowBlurRadius = body.width * 0.04
            glow.set()
            NSColor.white.setFill()
            drawGlyph(in: g)
            NSGraphicsContext.restoreGraphicsState()
            // Glass sheen across the top half.
            NSGradient(colors: [NSColor.white.withAlphaComponent(0.22), NSColor.white.withAlphaComponent(0)])!
                .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
            NSGraphicsContext.restoreGraphicsState()

            // Hairline rim.
            NSColor.white.withAlphaComponent(0.18).setStroke()
            shape.lineWidth = max(1, full.width * 0.004)
            shape.stroke()
            return true
        }
    }

    /// Writes a .icns for the app bundle (used by build.sh via `Pergola --write-icon`).
    static func writeIcns(to url: URL) throws {
        let fm = FileManager.default
        let set = fm.temporaryDirectory.appendingPathComponent("Pergola.iconset")
        try? fm.removeItem(at: set)
        try fm.createDirectory(at: set, withIntermediateDirectories: true)
        for (pt, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
            let px = pt * scale
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                       samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                       bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            appIcon(size: CGFloat(px)).draw(in: NSRect(x: 0, y: 0, width: px, height: px))
            NSGraphicsContext.restoreGraphicsState()
            let name = "icon_\(pt)x\(pt)\(scale == 2 ? "@2x" : "").png"
            try rep.representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        p.arguments = ["-c", "icns", set.path, "-o", url.path]
        try p.run()
        p.waitUntilExit()
    }
}
