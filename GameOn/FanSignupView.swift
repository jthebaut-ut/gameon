import PhotosUI
import SwiftUI
import UIKit

/// Unified fan account creation: auth credentials + profile on one screen before submit.
struct FanSignupView: View {
    private enum SignupStep: Int, CaseIterable {
        case profile = 1
        case teams = 2
        case country = 3
        case bio = 4

        var title: String {
            switch self {
            case .profile: return "Create your fan profile"
            case .teams: return "Pick your favorite teams"
            case .country: return "Represent your country"
            case .bio: return "Tell fans about yourself"
            }
        }

        var subtitle: String {
            switch self {
            case .profile: return "Let's build your identity in the sports crowd."
            case .teams: return "Choose the teams you support."
            case .country: return "Which country do you represent?"
            case .bio: return "Add a little context for your public fan profile."
            }
        }

        var next: SignupStep? {
            SignupStep(rawValue: rawValue + 1)
        }

        var previous: SignupStep? {
            SignupStep(rawValue: rawValue - 1)
        }
    }

    @ObservedObject var viewModel: MapViewModel
    var prefilledEmail: String = ""
    var onSwitchToSignIn: () -> Void
    var onDismissAfterSuccess: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var showConfirmPassword = false
    @State private var displayNameDraft = ""
    @State private var handleDraft = ""
    @State private var bioDraft = ""
    @State private var favoriteTeamIDs: Set<String> = []
    @State private var showFavoriteTeamsPicker = false
    @State private var selectedNationalTeam: NationalTeamIdentity?
    @State private var showNationalTeamPicker = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var pendingAvatarData: Data?
    @State private var policiesAccepted = false
    @State private var fanSignupLegalDocument: SettingsLegalDocumentKind?

    @State private var currentStep: SignupStep = .profile
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
        Group {
            if viewModel.pendingEmailVerificationKind == .fan {
                ScrollView {
                    EmailVerificationPendingView(
                        viewModel: viewModel,
                        kind: .fan,
                        email: viewModel.pendingEmailVerificationEmail.isEmpty ? email : viewModel.pendingEmailVerificationEmail,
                        onBackToSignIn: onSwitchToSignIn
                    )
                    .padding(.horizontal, FGSpacing.lg)
                    .padding(.vertical, FGSpacing.lg)
                }
                .scrollIndicators(.hidden)
            } else {
                ScrollView {
                    VStack(spacing: 24) {
                        onboardingTopBar

                        if currentStep == .profile {
                            FanGeoAppleSignInButton(viewModel: viewModel, accountMode: .fan, entryPoint: .fanSignup)
                                .padding(.top, 2)
                        }

                        if !viewModel.appleAuthFanMessage.isEmpty {
                            SettingsSheetStatusBanner(
                                title: viewModel.appleAuthFanMessageIsError ? "Apple Sign In" : nil,
                                message: viewModel.appleAuthFanMessage,
                                tint: viewModel.appleAuthFanMessageIsError ? FGColor.dangerRed : FGColor.accentBlue,
                                systemImage: viewModel.appleAuthFanMessageIsError ? "exclamationmark.triangle.fill" : "person.crop.circle.badge.checkmark"
                            )
                        }

                        onboardingStepContent

                        if !errorMessage.isEmpty {
                            SettingsSheetStatusBanner(
                                title: profileRetryMode ? "Profile not saved yet" : "Couldn’t create account",
                                message: errorMessage,
                                tint: FGColor.dangerRed,
                                systemImage: "exclamationmark.triangle.fill"
                            )
                        }

                        onboardingBottomControls

                        if currentStep == .profile {
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
                    .padding(.top, 12)
                    .padding(.bottom, FGSpacing.lg)
                }
            }
        }
        .scrollIndicators(.hidden)
        .fanGeoScreenBackground()
        .onAppear {
            print("[SignupUX] render mode=create")
            if isApplePendingProfile {
                email = viewModel.applePendingFanSignupEmail
                password = ""
                confirmPassword = ""
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
                passwordError = ""
            }
        }
        .onChange(of: confirmPassword) { _, _ in
            if !isApplePendingProfile {
                viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "passwordEdited")
                passwordError = ""
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
        .sheet(isPresented: $showNationalTeamPicker) {
            NationalTeamPickerSheet(currentIdentity: selectedNationalTeam) { identity in
                selectedNationalTeam = identity
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
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
                confirmPassword = ""
                errorMessage = ""
                emailError = ""
                passwordError = ""
            }
        }
        .onDisappear {
            viewModel.clearAppleAuthMessage(accountMode: .fan, reason: "sheetClosed")
        }
    }

    private var onboardingTopBar: some View {
        VStack(spacing: 18) {
            HStack {
                Button {
                    if let previous = currentStep.previous {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            currentStep = previous
                            errorMessage = ""
                        }
                    } else {
                        onSwitchToSignIn()
                    }
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitting)

                Spacer()

                Text("Step \(currentStep.rawValue) of \(SignupStep.allCases.count)")
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)

                Spacer()

                Color.clear
                    .frame(width: 36, height: 36)
            }

            HStack(spacing: 7) {
                ForEach(SignupStep.allCases, id: \.rawValue) { step in
                    Capsule(style: .continuous)
                        .fill(step.rawValue <= currentStep.rawValue ? FGColor.brandGradient : LinearGradient(colors: [FGColor.divider(colorScheme), FGColor.divider(colorScheme)], startPoint: .leading, endPoint: .trailing))
                        .frame(height: 4)
                }
            }
            .padding(.horizontal, 54)
        }
    }

    @ViewBuilder
    private var onboardingStepContent: some View {
        VStack(spacing: 18) {
            VStack(spacing: 8) {
                Text(currentStep.title)
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                Text(currentStep.subtitle)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 18)

            switch currentStep {
            case .profile:
                profileStepCard
            case .teams:
                favoriteTeamsStepCard
            case .country:
                nationalTeamStepCard
            case .bio:
                bioStepCard
            }
        }
    }

    private var profileStepCard: some View {
        VStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                onboardingAvatarPreview
                    .frame(width: 132, height: 132)
                    .clipShape(Circle())
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white, lineWidth: 4)
                            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.10), radius: 10, y: 4)
                    }

                PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                    Image(systemName: "pencil")
                        .font(.system(size: 18, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(FGColor.brandGradient)
                        .clipShape(Circle())
                        .shadow(color: FGColor.accentBlue.opacity(0.28), radius: 10, y: 5)
                }
                .disabled(isSubmitting)
                .offset(x: -4, y: -6)
            }
            .padding(.top, 6)

            VStack(spacing: 13) {
                if !isApplePendingProfile {
                    onboardingField(systemImage: "envelope", placeholder: "you@email.com", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !emailError.isEmpty { fieldError(emailError) }

                    passwordEntryField(
                        placeholder: "Create a password",
                        text: $password,
                        isVisible: $showPassword
                    )
                    passwordEntryField(
                        placeholder: "Confirm password",
                        text: $confirmPassword,
                        isVisible: $showConfirmPassword
                    )
                    if !passwordError.isEmpty { fieldError(passwordError) }
                } else {
                    HStack(spacing: 10) {
                        Image(systemName: "apple.logo")
                            .font(.body.weight(.bold))
                        Text(email.isEmpty ? "Apple email verified" : email)
                            .font(FGTypography.body.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(FGColor.accentGreen)
                    }
                    .padding()
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                }

                onboardingField(systemImage: "person", placeholder: "Display name", text: $displayNameDraft)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .onChange(of: displayNameDraft) { _, newValue in
                        if newValue.count > Self.displayNameMaxLength {
                            displayNameDraft = String(newValue.prefix(Self.displayNameMaxLength))
                        }
                    }
                if !displayNameError.isEmpty { fieldError(displayNameError) }

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("@")
                            .font(FGTypography.body.weight(.heavy))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        TextField("handle", text: $handleDraft)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(FGTypography.body)
                        if handleIsConfirmedAvailable {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(FGColor.accentGreen)
                        }
                    }
                    .fanGeoInputFieldStyle()

                    if !handleStatusMessage.isEmpty {
                        HandleAvailabilityStatusLabel(
                            message: handleStatusMessage,
                            isPositive: handleStatusIsPositive
                        )
                    }
                }
            }
        }
    }

    private var favoriteTeamsStepCard: some View {
        VStack(spacing: 16) {
            LazyVGrid(columns: onboardingGridColumns, spacing: 12) {
                ForEach(onboardingTeamSuggestions) { team in
                    onboardingFavoriteTeamCard(team)
                }

                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        Text("Add more")
                            .font(FGTypography.caption.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity, minHeight: 104)
                    .background(FGColor.cardBackground(colorScheme))
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.7), lineWidth: 1)
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.05), radius: 8, y: 3)
                }
                .buttonStyle(.plain)
            }

            if !selectedFavoriteTeams.isEmpty {
                Text("\(selectedFavoriteTeams.count) selected")
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
            }
        }
    }

    private var nationalTeamStepCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 14) {
                ForEach(onboardingCountryOptions) { option in
                    onboardingCountryChip(option)
                }

                Button {
                    showNationalTeamPicker = true
                } label: {
                    VStack(spacing: 7) {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(width: 54, height: 54)
                            .background(FGColor.cardBackground(colorScheme))
                            .clipShape(Circle())
                            .overlay {
                                Circle().strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                            }
                        Text("More")
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity)

            if let selectedNationalTeam {
                NationalTeamIdentityCard(identity: selectedNationalTeam, showsEditAffordance: true, compact: true) {
                    showNationalTeamPicker = true
                }
            }
        }
    }

    private var bioStepCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Bio")
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.8)

            TextField("Tell fans about yourself (optional)", text: $bioDraft, axis: .vertical)
                .lineLimit(4...6)
                .font(FGTypography.body)
                .fanGeoInputFieldStyle()
                .onChange(of: bioDraft) { _, newValue in
                    if newValue.count > Self.bioCharacterLimit {
                        bioDraft = String(newValue.prefix(Self.bioCharacterLimit))
                    }
                }

            HStack {
                Spacer()
                Text("\(bioDraft.count)/\(Self.bioCharacterLimit)")
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            policiesSection
        }
        .fanGeoGlassCard()
    }

    private var onboardingBottomControls: some View {
        VStack(spacing: 12) {
            Button {
                Task { await advanceOnboarding() }
            } label: {
                HStack {
                    Spacer()
                    Text(primaryOnboardingButtonTitle)
                        .font(FGTypography.cardTitle.weight(.bold))
                    Image(systemName: currentStep == .bio ? "checkmark" : "arrow.right")
                        .font(.subheadline.weight(.heavy))
                    Spacer()
                }
                .foregroundStyle(.white)
                .padding(.vertical, 15)
                .background(FGColor.brandGradient)
                .clipShape(Capsule(style: .continuous))
                .shadow(color: FGColor.accentBlue.opacity(0.28), radius: 12, y: 6)
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || (currentStep == .bio && !canSubmit))

            if currentStep == .teams || currentStep == .country {
                Button("Skip for now") {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        currentStep = currentStep.next ?? currentStep
                    }
                }
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(FGColor.accentBlue)
                .buttonStyle(.plain)
                .disabled(isSubmitting)
            }
        }
    }

    private var primaryOnboardingButtonTitle: String {
        if currentStep == .bio { return submitButtonTitle }
        return "Continue"
    }

    private var onboardingGridColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: 3)
    }

    private var onboardingTeamSuggestions: [FavoriteTeam] {
        let preferredNames = ["France", "Real Madrid", "Juventus", "Lakers", "Utah Jazz", "Dallas Cowboys", "Manchester United", "Miami Heat"]
        var selected = preferredNames.compactMap { preferred in
            FavoriteTeamCatalog.all.first { team in
                team.name.localizedCaseInsensitiveCompare(preferred) == .orderedSame
                    || team.name.localizedCaseInsensitiveContains(preferred)
            }
        }
        var seen = Set(selected.map(\.id))
        selected.append(contentsOf: selectedFavoriteTeams.filter { seen.insert($0.id).inserted })
        return Array(selected.prefix(8))
    }

    private var onboardingCountryOptions: [NationalTeamCountryOption] {
        ["United States", "France", "Brazil", "Mexico"]
            .compactMap { NationalTeamCountryCatalog.option(named: $0, popular: true) }
    }

    private func onboardingFavoriteTeamCard(_ team: FavoriteTeam) -> some View {
        let isSelected = favoriteTeamIDs.contains(team.id)
        return Button {
            if isSelected {
                favoriteTeamIDs.remove(team.id)
            } else {
                favoriteTeamIDs.insert(team.id)
            }
        } label: {
            VStack(spacing: 9) {
                ZStack(alignment: .topTrailing) {
                    FavoriteTeamLogoBadge(team: team, diameter: 48)
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .bold))
                            .foregroundStyle(.white, FGColor.accentBlue)
                            .offset(x: 12, y: -10)
                    }
                }

                Text(team.name)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            .frame(maxWidth: .infinity, minHeight: 104)
            .padding(.horizontal, 5)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isSelected ? FGColor.brandGradient : LinearGradient(colors: [FGColor.cardBackground(colorScheme), FGColor.cardBackground(colorScheme)], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? Color.white.opacity(0.22) : FGColor.divider(colorScheme).opacity(0.6), lineWidth: 1)
            }
            .shadow(color: (isSelected ? FGColor.accentBlue : Color.black).opacity(isSelected ? 0.22 : (colorScheme == .dark ? 0.14 : 0.05)), radius: isSelected ? 12 : 8, y: isSelected ? 6 : 3)
        }
        .buttonStyle(.plain)
    }

    private func onboardingCountryChip(_ option: NationalTeamCountryOption) -> some View {
        let identity = NationalTeamIdentity(
            countryCode: option.code,
            countryName: option.name,
            flag: option.flag,
            supporterLabel: NationalTeamCopy.defaultSupporterLabelKey
        )
        let isSelected = selectedNationalTeam?.countryCode == option.code
        return Button {
            selectedNationalTeam = identity
        } label: {
            VStack(spacing: 7) {
                ZStack(alignment: .bottomTrailing) {
                    Text(option.flag)
                        .font(.system(size: 39))
                        .frame(width: 58, height: 58)
                        .background(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.92))
                        .clipShape(Circle())
                        .overlay {
                            Circle()
                                .strokeBorder(isSelected ? FGColor.accentBlue : FGColor.divider(colorScheme), lineWidth: isSelected ? 3 : 1)
                        }
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(.white, FGColor.accentBlue)
                    }
                }
                Text(option.code == "US" ? "USA" : option.name)
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .buttonStyle(.plain)
    }

    private func onboardingField(systemImage: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(width: 18)
            TextField(placeholder, text: text)
                .font(FGTypography.body)
        }
        .fanGeoInputFieldStyle()
    }

    private func passwordEntryField(
        placeholder: String,
        text: Binding<String>,
        isVisible: Binding<Bool>
    ) -> some View {
        HStack(spacing: 10) {
            if isVisible.wrappedValue {
                TextField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(FGTypography.body)
            } else {
                SecureField(placeholder, text: text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(FGTypography.body)
            }

            Button {
                isVisible.wrappedValue.toggle()
            } label: {
                Image(systemName: isVisible.wrappedValue ? "eye.slash" : "eye")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isVisible.wrappedValue ? "Hide password" : "Show password")
        }
        .fanGeoInputFieldStyle()
    }

    @ViewBuilder
    private var onboardingAvatarPreview: some View {
        if let pendingAvatarData, let image = UIImage(data: pendingAvatarData) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
        } else {
            UserAvatarView(
                avatarThumbnailURL: nil,
                avatarURL: "",
                avatarDisplayRefreshToken: UserAvatarView.placeholderRefreshToken,
                displayName: displayNameDraft,
                email: email,
                size: 132,
                fallbackStyle: .lightOnWhiteChrome,
                imagePlaceholderTint: FGColor.accentBlue
            )
        }
    }

    @MainActor
    private func advanceOnboarding() async {
        switch currentStep {
        case .profile:
            guard await validateProfileStepBeforeContinue() else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                currentStep = .teams
                errorMessage = ""
            }
        case .teams:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                currentStep = .country
                errorMessage = ""
            }
        case .country:
            withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                currentStep = .bio
                errorMessage = ""
            }
        case .bio:
            await submitSignup()
        }
    }

    @MainActor
    private func validateProfileStepBeforeContinue() async -> Bool {
        errorMessage = ""
        emailError = ""
        passwordError = ""
        refreshDisplayNameValidation(markTouched: true)

        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedEmail.isEmpty {
            emailError = isApplePendingProfile ? "Apple did not return a usable email address." : "Email is required."
            return false
        }
        if !OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(trimmedEmail)) {
            emailError = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            return false
        }
        if !isApplePendingProfile, password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Password is required."
            return false
        }
        if !isApplePendingProfile, confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Confirm password is required."
            return false
        }
        if !isApplePendingProfile, password != confirmPassword {
            passwordError = "Passwords do not match."
            return false
        }
        if !displayNameError.isEmpty {
            return false
        }
        if let issue = FanGeoHandleRules.validate(handleDraft) {
            errorMessage = FanGeoHandleRules.validationMessage(for: issue)
            handleStatusMessage = errorMessage
            handleStatusIsPositive = false
            return false
        }

        if !handleIsConfirmedAvailable {
            let stored = FanGeoHandleRules.normalizeForStorage(handleDraft)
            handleStatusMessage = "Checking availability..."
            guard let available = await viewModel.checkUsernameAvailableForSignup(handleDraft) else {
                errorMessage = "Could not verify whether this handle is available. Please try again."
                handleStatusMessage = errorMessage
                handleStatusIsPositive = false
                return false
            }
            print("[SignupUX] handleCheck username=\(stored) available=\(available)")
            print("[HandleValidationDebug] handleAvailable=\(available)")
            guard available else {
                errorMessage = "That handle is already taken."
                handleStatusMessage = "Already taken"
                handleStatusIsPositive = false
                handleIsConfirmedAvailable = false
                print("[HandleValidationDebug] handleRejected reason=already_taken")
                return false
            }
            handleStatusMessage = "Available"
            handleStatusIsPositive = true
            handleIsConfirmedAvailable = true
        }

        return true
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
                    VStack(spacing: 10) {
                        passwordEntryField(
                            placeholder: "Create a password",
                            text: $password,
                            isVisible: $showPassword
                        )
                        .disabled(profileRetryMode)
                        passwordEntryField(
                            placeholder: "Confirm password",
                            text: $confirmPassword,
                            isVisible: $showConfirmPassword
                        )
                        .disabled(profileRetryMode)
                    }
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
                avatarDisplayRefreshToken: UserAvatarView.placeholderRefreshToken,
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
            && !confirmPassword.isEmpty
            && password == confirmPassword
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
        if !isApplePendingProfile, confirmPassword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            passwordError = "Confirm password is required."
            print("[SignupUX] submitFailed step=validation error=confirm_password")
            print("[EmailConfirmDebug] formValidationFailed reason=confirm_password_required")
            return false
        }
        if !isApplePendingProfile, password != confirmPassword {
            passwordError = "Passwords do not match."
            print("[SignupUX] submitFailed step=validation error=password_mismatch")
            print("[EmailConfirmDebug] formValidationFailed reason=password_mismatch")
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
            favoriteTeamIDs: favoriteTeamIDs.sorted(),
            nationalTeamIdentity: selectedNationalTeam
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
            confirmPassword = ""
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
