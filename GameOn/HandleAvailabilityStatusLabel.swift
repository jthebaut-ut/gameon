import SwiftUI

struct HandleAvailabilityStatusLabel: View {
    let message: String
    let isPositive: Bool

    var body: some View {
        HStack(spacing: 5) {
            if message.localizedCaseInsensitiveContains("checking") {
                ProgressView()
                    .scaleEffect(0.65)
            } else {
                Image(systemName: isPositive ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption.weight(.semibold))
            }
            Text(message)
                .font(FGTypography.caption)
        }
        .foregroundStyle(statusTint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var statusTint: Color {
        if message.localizedCaseInsensitiveContains("checking") {
            return .secondary
        }
        return isPositive ? FGColor.accentGreen : FGColor.dangerRed
    }
}
