import SwiftUI

/// Full-screen static splash shown immediately after the static `LaunchScreen` storyboard.
struct FanGeoSplashView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnabled
    @State private var statusIndex = 0

    private static let statusMessages = [
        "Loading FanGeo...",
        "Finding nearby games...",
        "Loading live matchups..."
    ]

    var body: some View {
        ZStack {
            ZStack {
                Color.white
                    .ignoresSafeArea()

                Image("FanGeoSplashCollage")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .padding(.horizontal, 18)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .accessibilityLabel("FanGeo")
            }

            VStack {
                Spacer()
                FanGeoLoadingStatusText(text: Self.statusMessages[statusIndex])
                    .padding(.horizontal, 24)
                    .padding(.bottom, 34)
            }
        }
        .ignoresSafeArea()
        .task {
            await rotateStatusMessages()
        }
        .onAppear {
            #if DEBUG
            print("[FanGeoLoadingDebug] splashDisplayed")
            print("[FanGeoLoadingDebug] loadingStatus=\(Self.statusMessages[statusIndex])")
            #endif
        }
        .onChange(of: statusIndex) { _, newValue in
            #if DEBUG
            print("[FanGeoLoadingDebug] loadingStatus=\(Self.statusMessages[newValue])")
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

private struct FanGeoLoadingStatusText: View {
    let text: String

    var body: some View {
        HStack(spacing: 7) {
            Text("⚡")
                .font(.system(size: 12, weight: .semibold))
                .accessibilityHidden(true)

            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .tracking(0.2)
                .foregroundStyle(Color.black.opacity(0.68))
                .lineLimit(1)
                .minimumScaleFactor(0.82)
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(text)
    }
}
