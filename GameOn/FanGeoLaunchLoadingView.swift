import SwiftUI

/// Full-screen static splash shown immediately after the static `LaunchScreen` storyboard.
struct FanGeoSplashView: View {
    private static let statusMessage = "Loading FanGeo..."

    var body: some View {
        GeometryReader { proxy in
            let imageWidth = min(proxy.size.width * 0.82, 360)

            ZStack {
                Color.white
                    .ignoresSafeArea()

                Image("FanGeoSplashCollage")
                    .resizable()
                    .interpolation(.high)
                    .antialiased(true)
                    .scaledToFit()
                    .frame(width: imageWidth)
                    .accessibilityLabel("FanGeo")

                VStack {
                    Spacer()
                    FanGeoLoadingStatusText(text: Self.statusMessage)
                        .padding(.horizontal, 24)
                        .frame(height: 56)
                        .padding(.bottom, 28)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .onAppear {
            #if DEBUG
            print("[FanGeoLoadingDebug] splashDisplayed")
            print("[FanGeoLoadingDebug] stableImageLayout=true")
            print("[FanGeoLoadingDebug] loadingStatus=\(Self.statusMessage)")
            #endif
        }
    }
}

private struct FanGeoLoadingStatusText: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .tracking(0.2)
            .foregroundStyle(Color.black.opacity(0.68))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
        .frame(maxWidth: .infinity)
        .accessibilityLabel(text)
    }
}
