import SwiftUI

struct PasswordResetCreatePasswordSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var newPassword = ""
    @State private var confirmPassword = ""
    @State private var validationMessage = ""
    @State private var isSubmitting = false

    private var canSubmit: Bool {
        !isSubmitting
            && viewModel.isPasswordResetRecoverySessionActive
            && newPassword.count >= 8
            && newPassword == confirmPassword
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    header

                    FGCard {
                        FGSectionHeader(
                            "Create new password",
                            subtitle: "Choose a new FanGeo password for your account."
                        )

                        SecureField("New password", text: $newPassword)
                            .textContentType(.newPassword)
                            .fanGeoInputFieldStyle()

                        SecureField("Confirm password", text: $confirmPassword)
                            .textContentType(.newPassword)
                            .fanGeoInputFieldStyle()

                        passwordGuidance

                        FGPrimaryButton(
                            title: isSubmitting ? "Updating password..." : "Update password",
                            systemImage: "key.fill",
                            isDisabled: !canSubmit
                        ) {
                            submit()
                        }

                        if !validationMessage.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Check password",
                                message: validationMessage,
                                tint: FGColor.dangerRed,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                        }

                        if !viewModel.passwordResetUpdateError.isEmpty {
                            SettingsSheetStatusBanner(
                                title: "Reset unavailable",
                                message: viewModel.passwordResetUpdateError,
                                tint: FGColor.dangerRed,
                                systemImage: "xmark.circle.fill"
                            )
                        }
                    }
                }
                .padding(FGSpacing.lg)
            }
            .scrollIndicators(.hidden)
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .navigationTitle("Reset password")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(viewModel.isPasswordResetRecoverySessionActive ? "Cancel" : "Close") {
                        close()
                    }
                    .disabled(isSubmitting)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text("FanGeo account")
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text("Your reset link has opened FanGeo. Set a new password, then sign in again.")
                .font(.subheadline)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passwordGuidance: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Minimum 8 characters", systemImage: newPassword.count >= 8 ? "checkmark.circle.fill" : "circle")
            Label("Passwords match", systemImage: !confirmPassword.isEmpty && newPassword == confirmPassword ? "checkmark.circle.fill" : "circle")
        }
        .font(FGTypography.caption.weight(.semibold))
        .foregroundStyle(FGColor.secondaryText(colorScheme))
    }

    private func submit() {
        validationMessage = ""
        guard newPassword.count >= 8 else {
            validationMessage = "Password must be at least 8 characters."
            print("[PasswordResetDebug] success=false step=validate_password error=password_too_short")
            return
        }
        guard newPassword == confirmPassword else {
            validationMessage = "Passwords must match."
            print("[PasswordResetDebug] success=false step=validate_password error=password_mismatch")
            return
        }

        Task {
            isSubmitting = true
            await viewModel.updateRecoveredPassword(newPassword)
            isSubmitting = false
        }
    }

    private func close() {
        if viewModel.isPasswordResetRecoverySessionActive {
            Task {
                await viewModel.cancelPasswordResetRecovery()
            }
        } else {
            viewModel.isShowingPasswordResetCreateSheet = false
            viewModel.passwordResetSheetMode = .requestLink
            viewModel.passwordResetUpdateError = ""
        }
    }
}
