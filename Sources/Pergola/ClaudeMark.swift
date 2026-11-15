import SwiftUI

/// Claude's mark: a hand-drawn starburst of rounded rays of uneven length, drawn in code (SF Symbols
/// has nothing like it; its sparkle looked like Gemini's). Activities use it by the symbol "claude".
struct ClaudeMark: Shape {
    /// The name activities use for this mark in place of an SF Symbol.
    static let symbol = "claude"

    // (angle in degrees, length as a share of the radius)
    static let rays: [(CGFloat, CGFloat)] = [
        (-93, 1.0), (-64, 0.74), (-34, 0.95), (-4, 0.80), (24, 0.99), (55, 0.72),
        (86, 0.93), (114, 0.79), (147, 1.0), (178, 0.76), (206, 0.94), (236, 0.84),
    ]

    func path(in rect: CGRect) -> Path {
        let R = min(rect.width, rect.height) / 2
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let tip = R * 0.25, base = R * 0.1
        var p = Path()
        for (deg, len) in Self.rays {
            let L = R * len
            var ray = Path()
            ray.move(to: CGPoint(x: 0, y: -base / 2))
            ray.addLine(to: CGPoint(x: L - tip / 2, y: -tip / 2))
            ray.addArc(center: CGPoint(x: L - tip / 2, y: 0), radius: tip / 2, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
            ray.addLine(to: CGPoint(x: 0, y: base / 2))
            ray.closeSubpath()
            p.addPath(ray, transform: CGAffineTransform(translationX: c.x, y: c.y).rotated(by: deg * .pi / 180))
        }
        p.addEllipse(in: CGRect(x: c.x - R * 0.17, y: c.y - R * 0.17, width: R * 0.34, height: R * 0.34))
        return p
    }
}
