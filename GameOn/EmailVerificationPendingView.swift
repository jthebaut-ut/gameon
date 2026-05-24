import SwiftUI

struct EmailVerificationPendingView: View {
    @ObservedObject var viewModel: MapViewModel
    let kind: EmailVerificationAccountKind
    let email: String
    var onBackToSignIn: () -> Void

    @State private var isResending = false
    @Environment(\.colorScheme) private var colorScheme

    private var title: String {
        kind == .business
            ? "Check your email to verify your business account."
            : "Check your email to verify your FanGeo account."
    }

    var body: some View {
        FGCard {
            FGSectionHeader(
                title,
                subtitle: "We sent a verification link to:"
            )

            Text(email)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .textSelection(.enabled)

            if !viewModel.emailVerificationMessage.isEmpty {
                SettingsSheetStatusBanner(
                    title: nil,
                    message: viewModel.emailVerificationMessage,
                    tint: FGColor.accentGreen,
                    systemImage: "envelope.badge.fill"
                )
            }

            if !viewModel.emailVerificationError.isEmpty {
                SettingsSheetStatusBanner(
                    title: "Verification email unavailable",
                    message: viewModel.emailVerificationError,
                    tint: FGColor.dangerRed,
                    systemImage: "exclamationmark.triangle.fill"
                )
            }

            FGPrimaryButton(
                title: isResending ? "Sending..." : "Resend verification email",
                systemImage: "envelope.arrow.triangle.branch.fill",
                isDisabled: isResending
            ) {
                Task {
                    isResending = true
                    await viewModel.resendEmailVerification(email: email, kind: kind)
                    isResending = false
                }
            }

            FGSecondaryButton(title: "Back to Sign In", systemImage: "arrow.left") {
                viewModel.clearEmailVerificationPending()
                onBackToSignIn()
            }
        }
    }
}
