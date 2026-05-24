import PhotosUI
import SwiftUI
import UIKit

/// Unified fan account creation: auth credentials + profile on one screen before submit.
struct FanSignupView: View {
    @ObservedObject var viewModel: MapViewModel
    var prefilledEmail: String = ""
    var onSwitchToSignIn: () -> Void
    var onDismissAfterSuccess: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var email = ""
    @State private var password = ""
    @State private var displayNameDraft = ""
    @State private var handleDraft = ""
    @State private var bioDraft = ""
    @State private var favoriteTeamIDs: Set<String> = []
    @State private var showFavoriteTeamsPicker = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var pendingAvatarData: Data?
    @State private var policiesAccepted = false
    @State private var fanSignupLegalDocument: SettingsLegalDocumentKind?

    @State private var isSubmitting = false
    @State private var profileRetryMode = false
    @State private var errorMessage = ""
    @State private var displayNameError = ""
    @State private var emailError = ""
    @State private var passwordError = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var handleIsConfirmedAvailable = false
    @State private var availabilityTask: Task<Void, Never>?

    private static let displayNameMaxLength = 40
    private static let bioCharacterLimit = 160

    var body: some View {
        ScrollView {
            VStack(spacing: FGSpacing.lg) {
                if viewModel.pendingEmailVerificationKind == .fan {
                    EmailVerificationPendingView(
                        viewModel: viewModel,
                        kind: .fan,
                        email: viewModel.pendingEmailVerificationEmail.isEmpty ? email : viewModel.pendingEmailVerificationEmail,
                        onBackToSignIn: onSwitchToSignIn
                    )
                } else {
                FanGeoBrandHeroView(
                    title: "Create your fan profile",
                    subtitle: "Join the sports crowd around you.",
                    variant: colorScheme == .dark ? .white : .dark,
                    logoWidth: 120,
                    alignment: .center,
                    textAlignment: .center
                )
                .frame(maxWidth: .infinity)

                FanGeoAppleSignInButton(viewModel: viewModel, accountMode: .fan, entryPoint: .fanSignup)

                if !viewModel.appleAuthFanMessage.isEmpty {
                    SettingsSheetStatusBanner(
                        title: viewModel.appleAuthFanMessageIsError ? "Apple Sign In" : nil,
                        message: viewModel.appleAuthFanMessage,
                        tint: viewModel.appleAuthFanMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                        systemImage: viewModel.appleAuthFanMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                    )
                }

                signupGlassCard

                signupLegalFooter

                if !errorMessage.isEmpty {
                    SettingsSheetStatusBanner(
                        title: profileRetryMode ? "Profile not saved yet" : "Couldn’t create account",
                        message: errorMessage,
                        tint: FGColor.dangerRed,
                        systemImage: "exclamationmark.triangle.fill"
                    )
                }

                submitButton

                Button(action: onSwitchToSignIn) {
                    Text("Already have an account? Sign in")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)
                }
            }
            .padding(.horizontal, FGSpacing.lg)
            .padding(.bottom, FGSpacing.md)
        }
        .scrollIndicators(.hidden)
        .fanGeoScreenBackground()
        .onAppear {
            print("[SignupUX] render mode=create")
            if isApplePendingProfile {
                email = viewModel.applePendingFanSignupEmail
                password = ""
                return
            }
            if email.isEmpty, !prefilledEmail.isEmpty {
                email = prefilledEmail
            }
        }
        .onChange(of: handleDraft) { _, newValue in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "signupEdited")
            handleDraft = FanGeoHandleRules.normalizeForStorage(newValue)
            scheduleHandleAvailabilityCheck()
        }
        .onChange(of: email) { _, _ in
            if !isApplePendingProfile {
                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "emailEdited")
            }
        }
        .onChange(of: password) { _, _ in
            if !isApplePendingProfile {
                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "passwordEdited")
            }
        }
        .onChange(of: displayNameDraft) { _, _ in
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "signupEdited")
            refreshDisplayNameValidation(markTouched: false)
        }
        .onChange(of: selectedAvatarItem) { _, item in
            guard let item else { return }
            Task { await loadPendingAvatar(from: item) }
        }
        .sheet(isPresented: $showFavoriteTeamsPicker) {
            FavoriteTeamsPickerSheet(selectedIDs: $favoriteTeamIDs)
        }
        .sheet(item: $fanSignupLegalDocument) { document in
            SettingsLegalDocumentSheet(document: document)
        }
        .onChange(of: viewModel.isLoggedIn) { wasLoggedIn, isLoggedIn in
            if !wasLoggedIn && isLoggedIn && !profileRetryMode && errorMessage.isEmpty {
                onDismissAfterSuccess()
            }
        }
        .onChange(of: viewModel.applePendingFanSignupEmail) { _, newEmail in
            let normalized = OwnerBusinessEmail.normalized(newEmail)
            if !normalized.isEmpty {
                email = normalized
                password = ""
                errorMessage = ""
                emailError = ""
                passwordError = ""
            }
        }
        .onDisappear {
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "sheetClosed")
        }
    }

    private var signupGlassCard: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            avatarPickerRow

            labeledField(title: "Email", required: true) {
                TextField("you@email.com", text: $email)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.emailAddress)
                    .autocorrectionDisabled()
                    .font(FGTypography.body)
                    .fanGeoInputFieldStyle()
                    .disabled(profileRetryMode || isApplePendingProfile)
            }
            if !emailError.isEmpty {
                fieldError(emailError)
            }

            if !isApplePendingProfile {
                labeledField(title: "Password", required: true) {
                    SecureField("Create a password", text: $password)
                        .font(FGTypography.body)
                        .fanGeoInputFieldStyle()
                        .disabled(profileRetryMode)
                }
                if !passwordError.isEmpty {
                    fieldError(passwordError)
                }
            }

            labeledField(title: "Display name", required: true) {
                TextField("Your name", text: $displayNameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .font(FGTypography.body)
                    .fanGeoInputFieldStyle()
                    .onChange(of: displayNameDraft) { _, newValue in
                        if newValue.count > Self.displayNameMaxLength {
                            displayNameDraft = String(newValue.prefix(Self.displayNameMaxLength))
                        }
                    }
            }
            if !displayNameError.isEmpty {
                fieldError(displayNameError)
            }

            labeledField(title: "@handle", required: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Text("@")
                            .font(FGTypography.body.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        TextField("handle", text: $handleDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(FGTypography.body)
                    }
                    .fanGeoInputFieldStyle()

                    Text(handlePreview)
                        .font(FGTypography.caption.weight(.medium))
                        .foregroundStyle(FGColor.mutedText(colorScheme))

                    if !handleStatusMessage.isEmpty {
                        HandleAvailabilityStatusLabel(
                            message: handleStatusMessage,
                            isPositive: handleStatusIsPositive
                        )
                    }
                }
            }

            labeledField(title: "Bio", required: false) {
                TextField("Optional", text: $bioDraft, axis: .vertical)
                    .lineLimit(2...4)
                    .font(FGTypography.body)
                    .fanGeoInputFieldStyle()
                    .onChange(of: bioDraft) { _, newValue in
                        if newValue.count > Self.bioCharacterLimit {
                            bioDraft = String(newValue.prefix(Self.bioCharacterLimit))
                        }
                    }
            }

            favoriteTeamsRow

            if !profileRetryMode {
                policiesSection
            }
        }
        .fanGeoGlassCard()
    }

    private var signupLegalFooter: some View {
        Text(signupLegalFooterText)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .multilineTextAlignment(.center)
            .tint(FGColor.accentBlue)
            .environment(\.openURL, OpenURLAction { url in
                openURL(url)
                return .handled
            })
            .padding(.horizontal, FGSpacing.sm)
    }

    private var signupLegalFooterText: AttributedString {
        var text = AttributedString("By creating an account, you agree to FanGeo's Terms of Service and Privacy Policy.")
        if let range = text.range(of: "Terms of Service") {
            text[range].link = FanGeoLegalLinks.termsOfService
            text[range].foregroundColor = FGColor.accentBlue
            text[range].underlineStyle = .single
        }
        if let range = text.range(of: "Privacy Policy") {
            text[range].link = FanGeoLegalLinks.privacyPolicy
            text[range].foregroundColor = FGColor.accentBlue
            text[range].underlineStyle = .single
        }
        return text
    }

    private var handlePreview: String {
        let slug = handleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if slug.isEmpty { return "@yourname" }
        return "@\(slug)"
    }

    private var avatarPickerRow: some View {
        HStack(spacing: FGSpacing.md) {
            signupAvatarPreview
            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Add profile photo")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Optional")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            .disabled(isSubmitting)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var signupAvatarPreview: some View {
        if let pendingAvatarData, let image = UIImage(data: pendingAvatarData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
        } else {
            UserAvatarView(
                avatarThumbnailURL: nil,
                avatarURL: "",
                avatarDisplayRefreshToken: UUID(),
                displayName: displayNameDraft,
                email: email,
                size: 64,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
        }
    }

    private var favoriteTeamsRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pick your teams")
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.5)

            HStack {
                if selectedFavoriteTeams.isEmpty {
                    Text("Optional — add teams you follow")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                } else {
                    Text(selectedFavoriteTeams.map(\.name).joined(separator: ", "))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Choose") {
                    showFavoriteTeamsPicker = true
                }
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
            }
        }
    }

    private var selectedFavoriteTeams: [FavoriteTeam] {
        favoriteTeamIDs
            .compactMap { FavoriteTeamCatalog.team(id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var policiesSection: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                policiesAccepted.toggle()
            } label: {
                Image(systemName: policiesAccepted ? "checkmark.square.fill" : "square")
                    .font(.title3)
                    .foregroundStyle(policiesAccepted ? FGColor.accentBlue : FGColor.mutedText(colorScheme))
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Text("I agree to the ")
                    Button { fanSignupLegalDocument = .termsOfService } label: {
                        Text("Terms of Service").underline()
                    }
                    .buttonStyle(.plain)
                    Text(", ")
                    Button { fanSignupLegalDocument = .privacyPolicy } label: {
                        Text("Privacy Policy").underline()
                    }
                    .buttonStyle(.plain)
                    Text(", and ")
                    Button { fanSignupLegalDocument = .communityGuidelines } label: {
                        Text("Community Guidelines").underline()
                    }
                    .buttonStyle(.plain)
                    Text(".")
                }
                .font(.footnote)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .tint(FGColor.accentBlue)
            }
        }
    }

    private var submitButton: some View {
        FGPrimaryButton(
            title: submitButtonTitle,
            isDisabled: !canSubmit || isSubmitting
        ) {
            Task { await submitSignup() }
        }
    }

    private var submitButtonTitle: String {
        if isSubmitting {
            if isApplePendingProfile {
                return "Creating profile…"
            }
            return profileRetryMode ? "Saving profile…" : "Creating account…"
        }
        if profileRetryMode {
            return "Retry saving profile"
        }
        if isApplePendingProfile {
            return "Create profile"
        }
        return "Create FanGeo account"
    }

    private var canSubmit: Bool {
        if profileRetryMode {
            return profileFieldsValid && policiesAccepted
        }
        if isApplePendingProfile {
            return profileFieldsValid
                && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && policiesAccepted
        }
        return profileFieldsValid
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !password.isEmpty
            && policiesAccepted
    }

    private var isApplePendingProfile: Bool {
        !OwnerBusinessEmail.normalized(viewModel.applePendingFanSignupEmail).isEmpty
    }

    private var profileFieldsValid: Bool {
        let trimmedName = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmedName.isEmpty
            && trimmedName.count <= Self.displayNameMaxLength
            && FanGeoHandleRules.validate(handleDraft) == nil
    }

    private func labeledField<Content: View>(
        title: String,
        required: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .textCase(.uppercase)
                    .tracking(0.5)
                if !required {
                    Text("Optional")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.8))
                }
            }
            content()
        }
    }

    private func fieldError(_ text: String) -> some View {
        Text(text)
            .font(FGTypography.caption)
            .foregroundStyle(.red)
    }

    @MainActor
    private func refreshDisplayNameValidation(markTouched: Bool) {
        let trimmed = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if markTouched || !displayNameError.isEmpty {
                displayNameError = "Display name is required."
            }
            return
        }
        displayNameError = trimmed.count > Self.displayNameMaxLength ? "Display name is too long." : ""
    }

    @MainActor
    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false
        handleIsConfirmedAvailable = false

        let stored = FanGeoHandleRules.normalizeForStorage(handleDraft)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")

        if let issue = FanGeoHandleRules.validate(handleDraft) {
            handleStatusMessage = "Invalid handle: \(FanGeoHandleRules.validationMessage(for: issue))"
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }

        handleStatusMessage = "Checking availability..."
        availabilityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            guard let available = await viewModel.checkUsernameAvailableForSignup(handleDraft) else { return }
            guard !Task.isCancelled else { return }
            print("[SignupUX] handleCheck username=\(stored) available=\(available)")
            print("[HandleValidationDebug] handleAvailable=\(available)")
            if available {
                handleStatusMessage = "Available"
                handleStatusIsPositive = true
                handleIsConfirmedAvailable = true
            } else {
                handleStatusMessage = "Already taken"
                handleIsConfirmedAvailable = false
                print("[HandleValidationDebug] handleRejected reason=already_taken")
            }
        }
    }

    @MainActor
    private func validateBeforeSubmit() -> Bool {
        errorMessage = ""
        emailError = ""
        passwordError = ""
        refreshDisplayNameValidation(markTouched: true)

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty {
            emailError = "Email is required."
            print("[SignupUX] submitFailed step=validation error=email")
            print("[EmailConfirmDebug] formValidationFailed reason=email_required")
            return false
        }
        if !OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(trimmedEmail)) {
            emailError = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            print("[SignupUX] submitFailed step=validation error=email")
            print("[EmailConfirmDebug] formValidationFailed reason=invalid_email")
            return false
        }

        if !isApplePendingProfile, password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Password is required."
            print("[SignupUX] submitFailed step=validation error=password")
            print("[EmailConfirmDebug] formValidationFailed reason=password_required")
            return false
        }

        if !displayNameError.isEmpty {
            print("[SignupUX] submitFailed step=validation error=displayName")
            print("[EmailConfirmDebug] formValidationFailed reason=display_name_invalid")
            return false
        }

        if let issue = FanGeoHandleRules.validate(handleDraft) {
            errorMessage = FanGeoHandleRules.validationMessage(for: issue)
            print("[SignupUX] submitFailed step=validation error=handle")
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            print("[EmailConfirmDebug] formValidationFailed reason=invalid_handle")
            return false
        }

        if !profileRetryMode, !policiesAccepted {
            errorMessage = "Accept the Terms of Service, Privacy Policy, and Community Guidelines to continue."
            print("[SignupUX] submitFailed step=validation error=policies")
            print("[EmailConfirmDebug] formValidationFailed reason=policies_required")
            return false
        }

        return true
    }

    private func buildProfileInput() -> FanSignupProfileInput {
        let bioTrimmed = bioDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return FanSignupProfileInput(
            displayName: displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            handle: handleDraft,
            bio: bioTrimmed.isEmpty ? MapViewModel.defaultFanSignupBio : bioTrimmed,
            avatarData: pendingAvatarData,
            favoriteTeamIDs: favoriteTeamIDs.sorted()
        )
    }

    @MainActor
    private func submitSignup() async {
        if !isApplePendingProfile {
            print("[EmailConfirmDebug] signupButtonTapped=true")
        }
        guard validateBeforeSubmit() else { return }

        viewModel.clearAppleAuthMessage(
            accountMode: .fan,
            reason: isApplePendingProfile ? "appleProfileSubmit" : "emailPasswordSignUp"
        )
        print("[SignupUX] submitStarted")
        isSubmitting = true
        defer { isSubmitting = false }

        let profile = buildProfileInput()

        if profileRetryMode {
            let outcome = await viewModel.retryFanSignupProfileSave(profile: profile)
            if outcome.succeeded {
                errorMessage = ""
                profileRetryMode = false
                onDismissAfterSuccess()
            } else {
                errorMessage = outcome.errorMessage ?? "Couldn’t save your profile. Please try again."
            }
            return
        }

        if isApplePendingProfile {
            print("[FanSignupDebug] submitApplePendingProfile=true email=\(email)")
            let outcome = await viewModel.completeAppleFanSignupProfile(
                profile: profile,
                recordFanGuidelinesAcceptance: policiesAccepted
            )
            if outcome.succeeded {
                errorMessage = ""
                profileRetryMode = false
                onDismissAfterSuccess()
                return
            }
            if outcome.authSucceeded {
                profileRetryMode = true
            }
            errorMessage = outcome.errorMessage ?? "Couldn’t save your profile. Please try again."
            return
        }

        let outcome = await viewModel.registerFanAccountWithProfile(
            email: email,
            password: password,
            profile: profile,
            recordFanGuidelinesAcceptance: policiesAccepted
        )

        if outcome.succeeded, !outcome.authSucceeded {
            errorMessage = ""
            profileRetryMode = false
            password = ""
            return
        }

        if outcome.succeeded {
            errorMessage = ""
            profileRetryMode = false
            onDismissAfterSuccess()
            return
        }

        if outcome.authSucceeded {
            profileRetryMode = true
            password = ""
        }

        errorMessage = outcome.errorMessage ?? "Something went wrong. Please try again."
    }

    @MainActor
    private func loadPendingAvatar(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        pendingAvatarData = data
    }
}
