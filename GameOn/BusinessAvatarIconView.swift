import SwiftUI

enum BusinessStatusIconChrome {
    static func statusColor(
        isPro: Bool,
        hasPendingVenueClaim: Bool,
        colorScheme: ColorScheme
    ) -> Color {
        if isPro {
            return proGold(colorScheme)
        }
        if hasPendingVenueClaim {
            return .orange
        }
        return FGColor.accentGreen
    }

    static func showsPendingClaimDot(isPro: Bool, hasPendingVenueClaim: Bool) -> Bool {
        isPro && hasPendingVenueClaim
    }

    static func proGold(_ colorScheme: ColorScheme) -> Color {
        colorScheme == .dark
            ? Color(red: 0.94, green: 0.73, blue: 0.34)
            : Color(red: 0.72, green: 0.50, blue: 0.16)
    }

    static func deepColor(for color: Color) -> Color {
        color.opacity(0.78)
    }
}

/// Default business identity avatar used across social/chat surfaces.
struct BusinessAvatarIconView: View {
    let size: CGFloat
    var statusColor: Color = FGColor.accentGreen
    var showsPendingClaimDot = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Circle()
                .fill(Color.white)
            Circle()
                .stroke(Color.black.opacity(0.08), lineWidth: 1)
            Image(systemName: "building.2.fill")
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(statusColor)

            if showsPendingClaimDot {
                Circle()
                    .fill(Color.orange)
                    .frame(width: max(7, size * 0.18), height: max(7, size * 0.18))
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.92), lineWidth: max(1, size * 0.025))
                    }
                    .offset(x: size * 0.03, y: -size * 0.03)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}
