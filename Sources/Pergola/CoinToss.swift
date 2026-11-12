import SwiftUI

/// A coin that spins about its own width, showing each side in turn. Animating `angle` re-draws
/// only this small view, so the toss costs nothing elsewhere.
private struct Coin: View, Animatable {
    var angle: Double   // degrees; 0 is heads up, 180 is tails up
    var size: CGFloat

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    private static let gold = Color(red: 1.0, green: 0.8, blue: 0.27)
    private static let deep = Color(red: 0.82, green: 0.55, blue: 0.1)
    private static let ink = Color(red: 0.42, green: 0.26, blue: 0.02)

    var body: some View {
        let turn = angle.truncatingRemainder(dividingBy: 360)
        let headsUp = turn < 90 || turn > 270
        // Edge-on the coin is a sliver; never let it vanish entirely.
        let squash = max(0.1, abs(cos(angle * .pi / 180)))
        ZStack {
            Circle().fill(LinearGradient(colors: [Self.gold, Self.deep], startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(Self.ink.opacity(0.35), lineWidth: 1)
            Text(headsUp ? "H" : "T")
                .font(.system(size: size * 0.6, weight: .heavy, design: .rounded))
                .foregroundStyle(Self.ink)
        }
        .frame(width: size, height: size)
        .scaleEffect(x: 1, y: squash)
    }
}

/// How long the coin is in the air before it settles.
private let coinFlight = 1.0

/// The coin in the notch's right wing: it tosses, spins and lands on its side.
struct CoinSpin: View {
    var heads: Bool
    @State private var angle: Double = 0
    @State private var lift: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Coin(angle: angle, size: 19)
            .scaleEffect(1 + lift * 0.14)
            .accessibilityHidden(true)
            .task {
                let end: Double = heads ? 1800 : 1980
                if reduceMotion { angle = end; return }
                // Fast at first, slowing into the landing, the way a tossed coin settles.
                withAnimation(.timingCurve(0.2, 0.7, 0.25, 1, duration: coinFlight)) { angle = end }
                withAnimation(.easeOut(duration: coinFlight * 0.45)) { lift = 1 }
                try? await Task.sleep(for: .seconds(coinFlight * 0.45))
                withAnimation(.easeIn(duration: coinFlight * 0.45)) { lift = 0 }
            }
    }
}

/// The result in the left wing, spelled out once the coin has landed.
struct CoinResult: View {
    var heads: Bool
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(heads ? "Heads" : "Tails")
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color(red: 1.0, green: 0.8, blue: 0.27))
            .lineLimit(1)
            .fixedSize()
            .opacity(landed ? 1 : 0)
            .scaleEffect(landed ? 1 : 0.7)
            .accessibilityLabel(landed ? (heads ? "Heads" : "Tails") : "Flipping a coin")
            .task {
                if !reduceMotion { try? await Task.sleep(for: .seconds(coinFlight * 0.92)) }
                withAnimation(.spring(duration: 0.35, bounce: 0.3)) { landed = true }
            }
    }
}
