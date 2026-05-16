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
    @State private var glowPulse = false
    @State private var confettiSeed = 0

    private var isLevelUp: Bool { presentation.isLevelUp }

    var body: some View {
        ZStack {
            if isLevelUp {
                FanXPConfettiBurst(seed: confettiSeed)
                    .allowsHitTesting(false)
            }

            cardContent
                .offset(y: floatUp ? (isLevelUp ? -6 : -4) : 8)
                .opacity(floatUp ? 1 : 0)
                .scaleEffect(floatUp ? 1 : 0.9)
        }
        .onAppear {
            confettiSeed &+= 1
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
                floatUp = true
            }
            if isLevelUp {
                withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                    glowPulse = true
                }
            }
        }
        .onDisappear {
            floatUp = false
            glowPulse = false
        }
    }

    private var cardContent: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(FGColor.accentGreen.opacity(isLevelUp ? 0.35 : 0.22))
                    .frame(width: isLevelUp ? 44 : 36, height: isLevelUp ? 44 : 36)
                    .blur(radius: isLevelUp ? (glowPulse ? 10 : 6) : 4)
                Image(systemName: isLevelUp ? "star.circle.fill" : "bolt.circle.fill")
                    .font(.system(size: isLevelUp ? 24 : 20, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [.white, FGColor.accentGreen],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .shadow(color: FGColor.accentGreen.opacity(0.65), radius: isLevelUp ? 8 : 4)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(presentation.primaryLine)
                    .font(.system(size: isLevelUp ? 15 : 14, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)
                    .tracking(isLevelUp ? 1.2 : 0.3)

                Text(presentation.secondaryLine)
                    .font(.system(size: isLevelUp ? 12 : 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.accentGreen.opacity(0.95))
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
                            FGColor.accentGreen.opacity(isLevelUp ? 0.85 : 0.55),
                            Color.white.opacity(0.2),
                            FGColor.accentGreen.opacity(0.35)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isLevelUp ? 1.5 : 1
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: isLevelUp ? 20 : 18, style: .continuous))
        .shadow(color: FGColor.accentGreen.opacity(isLevelUp ? 0.45 : 0.28), radius: isLevelUp ? 22 : 14, y: 8)
        .shadow(color: Color.black.opacity(0.45), radius: 16, y: 10)
    }

    private var stadiumGlassBackground: some View {
        ZStack {
            RoundedRectangle(cornerRadius: isLevelUp ? 20 : 18, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: isLevelUp ? 20 : 18, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.06, green: 0.1, blue: 0.08).opacity(0.92),
                            Color(red: 0.04, green: 0.06, blue: 0.1).opacity(0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            RadialGradient(
                colors: [
                    Color(red: 1, green: 0.95, blue: 0.8).opacity(isLevelUp ? 0.2 : 0.12),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0),
                startRadius: 2,
                endRadius: isLevelUp ? 120 : 80
            )
            RadialGradient(
                colors: [
                    FGColor.accentGreen.opacity(isLevelUp ? 0.28 : 0.14),
                    Color.clear
                ],
                center: .init(x: 0.85, y: 1),
                startRadius: 4,
                endRadius: isLevelUp ? 100 : 70
            )
        }
    }
}

private struct FanXPConfettiBurst: View {
    let seed: Int

    private struct Particle: Identifiable {
        let id: Int
        let x: CGFloat
        let size: CGFloat
        let delay: Double
        let hue: Color
    }

    @State private var animate = false

    private var particles: [Particle] {
        let colors: [Color] = [
            FGColor.accentGreen,
            .white,
            Color(red: 0.75, green: 1, blue: 0.55),
            Color(red: 1, green: 0.92, blue: 0.45)
        ]
        return (0..<14).map { i in
            let pseudo = Double((seed &* 31 &+ i &* 17) % 1000) / 1000
            return Particle(
                id: i,
                x: CGFloat(pseudo) * 220 - 110,
                size: CGFloat(4 + (pseudo * 5)),
                delay: pseudo * 0.18,
                hue: colors[i % colors.count]
            )
        }
    }

    var body: some View {
        ZStack {
            ForEach(particles) { p in
                Circle()
                    .fill(p.hue.opacity(0.9))
                    .frame(width: p.size, height: p.size)
                    .offset(
                        x: p.x,
                        y: animate ? -CGFloat(50 + p.delay * 40) : 12
                    )
                    .opacity(animate ? 0 : 1)
                    .animation(
                        .easeOut(duration: 1.05).delay(p.delay),
                        value: animate
                    )
            }
        }
        .frame(height: 70)
        .onAppear {
            animate = false
            animate = true
        }
        .onChange(of: seed) { _, _ in
            animate = false
            animate = true
        }
    }
}
