import SwiftUI

/// Global mount: `FanXPRewardOverlayHost` on ``MainTabView`` (top-center, above tabs).
struct FanXPRewardOverlayHost: View {
    @ObservedObject var manager: FanXPRewardOverlayManager

    var body: some View {
        ZStack(alignment: .top) {
            if let item = manager.presentation {
                FanXPRewardToastCard(presentation: item)
                    .padding(.top, 10)
                    .padding(.horizontal, 20)
                    .transition(
                        .asymmetric(
                            insertion: .offset(y: 18).combined(with: .opacity).combined(with: .scale(scale: 0.92)),
                            removal: .offset(y: -10).combined(with: .opacity)
                        )
                    )
                    .zIndex(10_000)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(response: 0.48, dampingFraction: 0.78), value: manager.presentation?.id)
        .allowsHitTesting(false)
    }
}

private struct FanXPRewardToastCard: View {
    let presentation: FanXPRewardPresentation

    @State private var floatUp = false

    private var isLevelUp: Bool { presentation.isLevelUp }

    var body: some View {
        ZStack {
            cardContent
                .offset(y: floatUp ? -3 : 6)
                .opacity(floatUp ? 1 : 0)
                .scaleEffect(floatUp ? 1 : 0.94)
        }
        .onAppear {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                floatUp = true
            }
        }
        .onDisappear {
            floatUp = false
        }
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(FGColor.accentGreen.opacity(isLevelUp ? 0.18 : 0.14))
                    .frame(width: isLevelUp ? 42 : 34, height: isLevelUp ? 42 : 34)
                    .blur(radius: isLevelUp ? 6 : 3)
                Image(systemName: isLevelUp ? "person.crop.circle.badge.checkmark" : "checkmark.circle.fill")
                    .font(.system(size: isLevelUp ? 22 : 19, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: FGColor.accentGreen.opacity(0.22), radius: isLevelUp ? 5 : 3)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.primaryLine)
                    .font(.system(size: isLevelUp ? 14 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(isLevelUp ? 0.7 : 0.2)

                Text(presentation.secondaryLine)
                    .font(.system(size: isLevelUp ? 11 : 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, isLevelUp ? 16 : 14)
        .padding(.vertical, isLevelUp ? 14 : 11)
        .background { stadiumGlassBackground }
        .overlay {
            RoundedRectangle(cornerRadius: isLevelUp ? 20 : 18, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            FGColor.accentGreen.opacity(isLevelUp ? 0.42 : 0.28),
                            Color.white.opacity(0.16),
                            FGColor.accentGreen.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isLevelUp ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: isLevelUp ? 20 : 18, style: .continuous))
        .shadow(color: FGColor.accentGreen.opacity(isLevelUp ? 0.16 : 0.1), radius: isLevelUp ? 16 : 10, y: 6)
        .shadow(color: Color.black.opacity(0.38), radius: 14, y: 9)
    }

    private var stadiumGlassBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isLevelUp ? 20 : 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: isLevelUp ? 20 : 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.055, green: 0.075, blue: 0.07).opacity(0.92),
                            Color(red: 0.035, green: 0.045, blue: 0.07).opacity(0.9)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RadialGradient(
                colors: [
                    Color(red: 1, green: 0.95, blue: 0.8).opacity(isLevelUp ? 0.1 : 0.07),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0),
                startRadius: 2,
                endRadius: isLevelUp ? 120 : 80
            )
            RadialGradient(
                colors: [
                    FGColor.accentGreen.opacity(isLevelUp ? 0.12 : 0.08),
                    Color.clear
                ],
                center: .init(x: 0.85, y: 1),
                startRadius: 4,
                endRadius: isLevelUp ? 100 : 70
            )
        }
    }
}
