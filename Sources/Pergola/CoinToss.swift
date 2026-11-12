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

/// The coin-flip line under the notch: the coin tosses, lands, then the result is spelled out.
struct CoinToss: View {
    var heads: Bool
    @State private var angle: Double = 0
    @State private var lift: CGFloat = 0
    @State private var landed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let flight = 1.0

    var body: some View {
        HStack(spacing: 7) {
            Coin(angle: angle, size: 17)
                .scaleEffect(1 + lift * 0.18)
                .offset(y: -lift * 2)
            // Sized for the longer word from the start, so nothing shifts when the result appears.
            ZStack(alignment: .leading) {
                Text("Heads").hidden()
                Text(heads ? "Heads" : "Tails")
                    .opacity(landed ? 1 : 0)
                    .offset(x: landed ? 0 : -6)
            }
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.9))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(landed ? (heads ? "Heads" : "Tails") : "Flipping a coin")
        .task {
            let end: Double = heads ? 1800 : 1980
            if reduceMotion {
                angle = end
                withAnimation(.smooth(duration: 0.25)) { landed = true }
                return
            }
            // Fast at first, slowing into the landing, the way a tossed coin settles.
            withAnimation(.timingCurve(0.2, 0.7, 0.25, 1, duration: Self.flight)) { angle = end }
            withAnimation(.easeOut(duration: Self.flight * 0.45)) { lift = 1 }
            try? await Task.sleep(for: .seconds(Self.flight * 0.45))
            withAnimation(.easeIn(duration: Self.flight * 0.45)) { lift = 0 }
            try? await Task.sleep(for: .seconds(Self.flight * 0.47))
            withAnimation(.spring(duration: 0.35, bounce: 0.3)) { landed = true }
        }
    }
}
