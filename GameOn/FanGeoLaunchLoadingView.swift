import SwiftUI

struct FanGeoSplashView: View {
    let bootstrapError: String?
    @State private var animateIn = false
    @State private var pulse = false

    private var backgroundGradient: LinearGradient {
        LinearGradient(
            colors: [Color.black, Color(red: 0.05, green: 0.06, blue: 0.11)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        ZStack {
            backgroundGradient
                .ignoresSafeArea()

            VStack(spacing: 24) {
                FanGeoInlineLogoView(
                    variant: .dark,
                    width: 220,
                    innerPadding: 10,
                    materialBackground: false
                )
                .scaleEffect(animateIn ? (pulse ? 1.012 : 1.0) : 0.965)
                .opacity(animateIn ? 1 : 0)
                .shadow(color: .black.opacity(0.30), radius: 22, y: 10)

                FanGeoLoadingView(
                    message: bootstrapError ?? "Loading FanGeo...",
                    tint: .white.opacity(0.9),
                    textColor: .white.opacity(0.72)
                )
                .opacity(animateIn ? 1 : 0)
            }
            .padding(.horizontal, 28)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                animateIn = true
            }
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
    }
}
