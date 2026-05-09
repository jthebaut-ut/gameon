import SwiftUI

struct LivePulseView: View {

    let isTrending: Bool

    @State private var animate = false

    var body: some View {

        Circle()
            .fill(
                isTrending
                ? Color.purple.opacity(0.30)
                : Color.orange.opacity(0.22)
            )
            .frame(
                width: isTrending ? 64 : 52,
                height: isTrending ? 64 : 52
            )
            .scaleEffect(animate ? 1.35 : 0.75)
            .opacity(animate ? 0.0 : 0.85)
            .animation(
                .easeOut(duration: isTrending ? 1.2 : 1.6)
                    .repeatForever(autoreverses: false),
                value: animate
            )
            .onAppear {
                animate = true
            }
    }
}
