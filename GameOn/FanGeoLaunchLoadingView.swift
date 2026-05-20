import SwiftUI

/// Full-screen static splash shown immediately after the static `LaunchScreen` storyboard.
struct FanGeoSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnabled
    @State private var statusIndex = 0

    private static let statusMessages = [
        "Finding nearby games...",
        "Checking live matchups...",
        "Building your fan feed...",
        "Loading FanGeo..."
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.white
                    .ignoresSafeArea()

                VStack(spacing: 16) {
                    Image("FanGeoSplashCollage")
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .padding(.horizontal, 18)
                        .frame(
                            maxWidth: .infinity,
                            maxHeight: max(320, proxy.size.height * 0.78)
                        )
                        .background(Color.white)
                        .accessibilityLabel("FanGeo")

                    FanGeoSplashStatusPill(
                        text: Self.statusMessages[statusIndex],
                        showsMotion: !reduceMotionEnabled
                    )
                    .padding(.bottom, 18)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .ignoresSafeArea()
        .task {
            await rotateStatusMessages()
        }
        .onAppear {
            #if DEBUG
            print("[FanGeoSplashDebug] splashViewAppeared")
            #endif
        }
    }

    @MainActor
    private func rotateStatusMessages() async {
        guard !reduceMotionEnabled else { return }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: FanGeoSplashAnimation.statusRotationInterval)
            guard !Task.isCancelled else { return }
            statusIndex = (statusIndex + 1) % Self.statusMessages.count
        }
    }
}

private struct FanGeoSplashStatusPill: View {
    let text: String
    let showsMotion: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "bolt.fill")
                .font(.system(size: 11, weight: .black))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.orange, Color(red: 1.0, green: 0.11, blue: 0.42)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.2)
                .foregroundStyle(Color.black.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .contentTransition(showsMotion ? .opacity : .identity)

            if showsMotion {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Color(red: 1.0, green: 0.30, blue: 0.18))
                    .scaleEffect(0.72)
                    .accessibilityHidden(true)
            } else {
                Circle()
                    .fill(Color(red: 1.0, green: 0.30, blue: 0.18).opacity(0.7))
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(0.92))
                .shadow(color: Color.black.opacity(0.08), radius: 14, y: 6)
        }
        .overlay {
            Capsule(style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.orange.opacity(0.26),
                            Color(red: 1.0, green: 0.11, blue: 0.42).opacity(0.22)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 0.8
                )
        }
        .accessibilityLabel(text)
    }
}
