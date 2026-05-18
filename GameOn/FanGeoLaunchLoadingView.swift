import SwiftUI

struct FanGeoSplashView: View {
    let bootstrapError: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotionEnabled
    @State private var animateIn = true
    @State private var loadingStatusIndex = 0
    @State private var pulse = false

    private static let artworkAssetName = "FanGeoCircularLogo"
    private static let loadingStatusMessages = [
        "Loading FanGeo...",
        "Finding live sports energy...",
        "Loading venues and games...",
        "Preparing your map..."
    ]

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black
                    .ignoresSafeArea()

                VStack(spacing: 26) {
                    Spacer(minLength: 24)

                    Image(Self.artworkAssetName)
                        .resizable()
                        .interpolation(.high)
                        .antialiased(true)
                        .scaledToFit()
                        .frame(width: proxy.size.width * 0.94)
                        .scaleEffect(logoScale)
                        .opacity(logoOpacity)
                        .shadow(color: .white.opacity(0.10), radius: 22, y: 0)
                        .shadow(color: .black.opacity(0.65), radius: 28, y: 14)
                        .accessibilityLabel("FanGeo")

                    FanGeoLaunchLoadingCluster(
                        message: currentLoadingStatusText,
                        isAnimating: !reduceMotionEnabled,
                        ringSize: 44
                    )

                    Spacer(minLength: 34)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .task {
            await runLaunchAnimation()
        }
        .task(id: bootstrapError) {
            await runLoadingStatusCycle()
        }
        .onAppear {
            logInitialVisibility()
            logLoadingStatusText(currentLoadingStatusText)
        }
        .onChange(of: loadingStatusIndex) {
            logLoadingStatusText(currentLoadingStatusText)
        }
        .onChange(of: bootstrapError) {
            logLoadingStatusText(currentLoadingStatusText)
        }
        .onDisappear {
            #if DEBUG
            print("[LaunchScreenDebug] appBootstrapComplete=true")
            #endif
        }
    }

    private var currentLoadingStatusText: String {
        bootstrapError ?? Self.loadingStatusMessages[loadingStatusIndex]
    }

    private var logoScale: CGFloat {
        if reduceMotionEnabled { return 1 }
        guard animateIn else { return 0.985 }
        return pulse ? 1.01 : 1.0
    }

    private var logoOpacity: Double {
        if reduceMotionEnabled { return 1 }
        guard animateIn else { return 1 }
        return pulse ? 0.98 : 1
    }

    @MainActor
    private func runLaunchAnimation() async {
        #if DEBUG
        print("[LaunchScreenDebug] animationStarted=true")
        #endif

        if reduceMotionEnabled {
            animateIn = true
            return
        }

        animateIn = false
        withAnimation(.easeOut(duration: 0.28)) {
            animateIn = true
        }

        try? await Task.sleep(nanoseconds: 260_000_000)
        withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
            pulse = true
        }
    }

    @MainActor
    private func runLoadingStatusCycle() async {
        guard bootstrapError == nil, !reduceMotionEnabled else { return }

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled, bootstrapError == nil else { continue }

            withAnimation(.easeInOut(duration: 0.22)) {
                loadingStatusIndex = (loadingStatusIndex + 1) % Self.loadingStatusMessages.count
            }
        }
    }

    private func logInitialVisibility() {
        #if DEBUG
        print("[LaunchPathDebug] FanGeoSplashViewMounted=true")
        print("[LaunchPathDebug] selectedSplashAsset=\(Self.artworkAssetName)")
        print("[LaunchScreenDebug] visibleLogo=true")
        print("[LaunchScreenDebug] artworkAsset=\(Self.artworkAssetName)")
        print("[LaunchScreenDebug] loadingWheelVisible=true")
        print("[LaunchScreenDebug] reduceMotionEnabled=\(reduceMotionEnabled)")
        #endif
    }

    private func logLoadingStatusText(_ text: String) {
        #if DEBUG
        print("[LaunchScreenDebug] statusText=\(text)")
        #endif
    }
}

private struct FanGeoLaunchLoadingCluster: View {
    let message: String
    let isAnimating: Bool
    let ringSize: CGFloat

    var body: some View {
        VStack(spacing: 12) {
            FanGeoPremiumLoadingWheel(isAnimating: isAnimating, size: ringSize)

            Text(message)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .tracking(0.2)
                .foregroundStyle(.white.opacity(0.94))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .contentTransition(isAnimating ? .opacity : .identity)
        }
        .frame(maxWidth: 300)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
    }
}

private struct FanGeoPremiumLoadingWheel: View {
    let isAnimating: Bool
    let size: CGFloat
    @State private var rotationDegrees = 0.0

    var body: some View {
        ZStack {
            Circle()
                .stroke(.white.opacity(0.24), lineWidth: 2.4)

            Circle()
                .trim(from: 0.08, to: 0.78)
                .stroke(
                    AngularGradient(
                        colors: [
                            .white,
                            FGColor.accentGreen,
                            Color.orange,
                            FGColor.accentBlue
                        ],
                        center: .center
                    ),
                    style: StrokeStyle(lineWidth: 4.8, lineCap: .round)
                )
                .rotationEffect(.degrees(rotationDegrees))
                .shadow(color: FGColor.accentGreen.opacity(0.62), radius: 10, y: 0)
                .shadow(color: Color.orange.opacity(0.34), radius: 12, y: 0)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
        .onAppear {
            updateRotation()
        }
        .onChange(of: isAnimating) {
            updateRotation()
        }
    }

    private func updateRotation() {
        if isAnimating {
            rotationDegrees = 0
            withAnimation(.linear(duration: 1.15).repeatForever(autoreverses: false)) {
                rotationDegrees = 360
            }
        } else {
            withAnimation(.none) {
                rotationDegrees = 0
            }
        }
    }
}
