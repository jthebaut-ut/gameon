import SwiftUI

/// Shared purple shield + star badge for Home Crowd (cards, venue toggles, CTAs).
struct HomeCrowdShieldStarBadge: View {
    enum VisualState {
        case active
        case inactive
    }

    let diameter: CGFloat
    var visualState: VisualState = .active

    private static let purpleLight = Color(red: 0.72, green: 0.48, blue: 1.0)
    private static let purpleDeep = Color(red: 0.50, green: 0.30, blue: 0.90)
    private static let goldStar = Color(red: 1.0, green: 0.90, blue: 0.50)
    private static let inactiveTop = Color(red: 0.58, green: 0.54, blue: 0.68)
    private static let inactiveBottom = Color(red: 0.40, green: 0.38, blue: 0.48)

    var body: some View {
        let shieldSize = diameter * 0.50
        let cornerStar = diameter * 0.20

        ZStack {
            Circle()
                .fill(backgroundGradient)
                .frame(width: diameter, height: diameter)

            Image(systemName: "shield.fill")
                .font(.system(size: shieldSize, weight: .bold))
                .foregroundStyle(shieldColor)

            Image(systemName: "star.fill")
                .font(.system(size: cornerStar, weight: .bold))
                .foregroundStyle(cornerStarColor)
                .offset(x: diameter * 0.24, y: -diameter * 0.24)
        }
        .shadow(color: glowColor, radius: glowRadius, y: glowY)
    }

    private var backgroundGradient: LinearGradient {
        switch visualState {
        case .active:
            LinearGradient(
                colors: [Self.purpleLight, Self.purpleDeep],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        case .inactive:
            LinearGradient(
                colors: [
                    Self.inactiveTop.opacity(0.62),
                    Self.inactiveBottom.opacity(0.78)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var shieldColor: Color {
        switch visualState {
        case .active:
            .white
        case .inactive:
            Color.white.opacity(0.78)
        }
    }

    private var cornerStarColor: Color {
        switch visualState {
        case .active:
            Self.goldStar
        case .inactive:
            Color.white.opacity(0.50)
        }
    }

    private var glowColor: Color {
        visualState == .active ? Self.purpleLight.opacity(0.55) : .clear
    }

    private var glowRadius: CGFloat {
        visualState == .active ? max(6, diameter * 0.22) : 0
    }

    private var glowY: CGFloat {
        visualState == .active ? max(2, diameter * 0.08) : 0
    }
}
