import PhotosUI
import SwiftUI

/// Blocking or in-flow setup for display name + @handle after fan signup (or handle-only from profile).
struct FanGeoIdentitySetupView: View {
    enum Mode {
        /// New account: display name + @handle required before using the app.
        case complete
        /// Existing user: choose a real @handle only.
        case handleOnly
    }

    @ObservedObject var viewModel: MapViewModel
    var mode: Mode = .complete
    var onFinished: () -> Void = {}

    @Environment(\.colorScheme) private var colorScheme
    @State private var displayNameDraft = ""
    @State private var handleDraft = ""
    @State private var bioDraft = ""
    @State private var favoriteTeamIDs: Set<String> = []
    @State private var showFavoriteTeamsPicker = false
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var isUploadingAvatar = false
    @State private var errorMessage = ""
    @State private var displayNameError = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var handleIsConfirmedAvailable = false
    @State private var availabilityTask: Task<Void, Never>?

    private static let defaultFanBio = "I am a FanGeo Fan."
    private static let displayNameMaxLength = 40
    private static let bioCharacterLimit = 160

    var body: some View {
        let avatarSnapshot = IdentityAvatarSnapshot(
            thumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            avatarURL: viewModel.currentUserAvatarURL,
            refreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
            email: viewModel.currentUserEmail
        )

        return NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    headerCopy

                    if mode == .complete {
                        avatarSection(snapshot: avatarSnapshot)
                        displayNameSection
                        bioSection
                        favoriteTeamsSection
                    }

                    handleSection

                    if !errorMessage.isEmpty {
                        Text(errorMessage)
                            .font(FGTypography.caption)
                            .foregroundStyle(.red)
                    }

                    Button {
                        Task { await saveIdentity() }
                    } label: {
                        Text(primaryButtonTitle)
                            .font(FGTypography.cardTitle)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, FGSpacing.md)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentGreen)
                    .disabled(!canSubmit || isSaving || isUploadingAvatar)
                }
                .padding(FGSpacing.lg)
            }
            .fanGeoScreenBackground()
            .navigationTitle(mode == .complete ? "Create your fan profile" : "Choose your @handle")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(mode == .complete)
            .onAppear {
                if mode == .handleOnly {
                    displayNameDraft = viewModel.currentUserDisplayName
                }
            }
            .onChange(of: selectedAvatarItem) { _, item in
                guard let item else { return }
                Task { await replaceAvatar(with: item) }
            }
            .onChange(of: handleDraft) { _, newValue in
                handleDraft = FanGeoHandleRules.normalizeForStorage(newValue)
                scheduleHandleAvailabilityCheck()
            }
            .onChange(of: displayNameDraft) { _, _ in
                refreshDisplayNameValidation(markTouched: false)
            }
            .sheet(isPresented: $showFavoriteTeamsPicker) {
                FavoriteTeamsPickerSheet(selectedIDs: $favoriteTeamIDs)
            }
        }
    }

    private var primaryButtonTitle: String {
        if isSaving { return "Saving…" }
        return mode == .complete ? "Start using FanGeo" : "Continue"
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            if mode == .complete {
                Text("Pick a name and handle so other fans can recognize you.")
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            } else {
                Text("Set a unique @handle for friend search and your public profile.")
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
    }

    private func avatarSection(snapshot: IdentityAvatarSnapshot) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGSectionHeader("Profile photo", subtitle: "Optional")
            IdentitySetupAvatarPickerRow(
                snapshot: snapshot,
                displayName: displayNameDraft,
                isUploadingAvatar: isUploadingAvatar,
                isSaving: isSaving,
                selectedAvatarItem: $selectedAvatarItem
            )
        }
        .fanGeoGlassCard()
    }

    private var displayNameSection: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGSectionHeader("Display name", subtitle: "Required")
            TextField("Display name", text: $displayNameDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(FGTypography.body)
                .fanGeoInputFieldStyle()
                .onChange(of: displayNameDraft) { _, newValue in
                    if newValue.count > Self.displayNameMaxLength {
                        displayNameDraft = String(newValue.prefix(Self.displayNameMaxLength))
                    }
                }

            if !displayNameError.isEmpty {
                Text(displayNameError)
                    .font(FGTypography.caption)
                    .foregroundStyle(.red)
            }
        }
        .fanGeoGlassCard()
    }

    private var bioSection: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGSectionHeader("Bio", subtitle: "Optional")
            TextField("Tell fans about yourself", text: $bioDraft, axis: .vertical)
                .lineLimit(3...5)
                .font(FGTypography.body)
                .fanGeoInputFieldStyle()
                .onChange(of: bioDraft) { _, newValue in
                    if newValue.count > Self.bioCharacterLimit {
                        bioDraft = String(newValue.prefix(Self.bioCharacterLimit))
                    }
                }
        }
        .fanGeoGlassCard()
    }

    private var favoriteTeamsSection: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGSectionHeader("Favorite teams", subtitle: "Optional")
            HStack {
                if selectedFavoriteTeams.isEmpty {
                    Text("Add teams you follow")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                } else {
                    Text(selectedFavoriteTeams.map(\.name).joined(separator: ", "))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
                Button("Add") {
                    showFavoriteTeamsPicker = true
                }
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
            }
        }
        .fanGeoGlassCard()
    }

    private var selectedFavoriteTeams: [FavoriteTeam] {
        favoriteTeamIDs
            .compactMap { FavoriteTeamCatalog.team(id: $0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var handleSection: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGSectionHeader("@handle", subtitle: "Required — 3–20 characters; letters, numbers, _ or .")
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

            if !handleStatusMessage.isEmpty {
                HandleAvailabilityStatusLabel(
                    message: handleStatusMessage,
                    isPositive: handleStatusIsPositive
                )
            }
        }
        .fanGeoGlassCard()
    }

    private var canSubmit: Bool {
        let handleOK = FanGeoHandleRules.validate(handleDraft) == nil && handleIsConfirmedAvailable
        switch mode {
        case .complete:
            let trimmedName = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            return !trimmedName.isEmpty
                && trimmedName.count <= Self.displayNameMaxLength
                && handleOK
        case .handleOnly:
            return handleOK
        }
    }

    @MainActor
    private func refreshDisplayNameValidation(markTouched: Bool) {
        let trimmed = displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            if markTouched || !displayNameError.isEmpty {
                displayNameError = "Display name is required."
                if markTouched {
                    print("[SignupProfileDebug] validationError field=displayName")
                }
            }
            return
        }
        if trimmed.count > Self.displayNameMaxLength {
            displayNameError = "Display name is too long."
            print("[SignupProfileDebug] validationError field=displayName")
            return
        }
        displayNameError = ""
    }

    @MainActor
    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false
        handleIsConfirmedAvailable = false

        let raw = handleDraft
        let stored = FanGeoHandleRules.normalizeForStorage(raw)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")

        if let issue = FanGeoHandleRules.validate(raw) {
            handleStatusMessage = "Invalid handle: \(FanGeoHandleRules.validationMessage(for: issue))"
            print("[SignupProfileDebug] validationError field=handle")
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }

        handleStatusMessage = "Checking availability..."
        availabilityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            guard let available = await viewModel.checkUsernameAvailable(raw) else { return }
            guard !Task.isCancelled else { return }
            print("[SignupProfileDebug] handleCheck username=\(stored) available=\(available)")
            print("[HandleValidationDebug] handleAvailable=\(available)")
            if available {
                handleStatusMessage = "Available"
                handleStatusIsPositive = true
                handleIsConfirmedAvailable = true
            } else {
                handleStatusMessage = "Already taken"
                handleStatusIsPositive = false
                handleIsConfirmedAvailable = false
                print("[SignupProfileDebug] validationError field=handle")
                print("[HandleValidationDebug] handleRejected reason=already_taken")
            }
        }
    }

    @MainActor
    private func saveIdentity() async {
        errorMessage = ""
        refreshDisplayNameValidation(markTouched: true)

        let name = mode == .complete
            ? displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            : viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)

        if mode == .complete, name.isEmpty {
            displayNameError = "Display name is required."
            print("[SignupProfileDebug] validationError field=displayName")
            return
        }

        if mode == .complete, name.count > Self.displayNameMaxLength {
            displayNameError = "Display name is too long."
            print("[SignupProfileDebug] validationError field=displayName")
            return
        }

        if ModerationService.containsProfanity(name) {
            errorMessage = ModerationService.profanityRejectionUserMessage()
            print("[SignupProfileDebug] validationError field=displayName")
            return
        }

        if let issue = FanGeoHandleRules.validate(handleDraft) {
            errorMessage = FanGeoHandleRules.validationMessage(for: issue)
            print("[SignupProfileDebug] validationError field=handle")
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }

        let storedHandle = FanGeoHandleRules.normalizeForStorage(handleDraft)
        guard let available = await viewModel.checkUsernameAvailable(handleDraft) else {
            errorMessage = "Could not verify whether this handle is available. Please try again."
            return
        }
        print("[SignupProfileDebug] handleCheck username=\(storedHandle) available=\(available)")
        print("[HandleValidationDebug] handleAvailable=\(available)")
        guard available else {
            handleStatusMessage = "Already taken"
            handleStatusIsPositive = false
            handleIsConfirmedAvailable = false
            print("[SignupProfileDebug] validationError field=handle")
            print("[HandleValidationDebug] handleRejected reason=already_taken")
            return
        }

        let bioTrimmed = bioDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let bioToSave = bioTrimmed.isEmpty ? Self.defaultFanBio : bioTrimmed

        print("[SignupProfileDebug] profileSaveStarted")
        isSaving = true
        defer { isSaving = false }

        if let err = await viewModel.saveUserProfile(
            displayName: name,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            username: handleDraft,
            bio: bioToSave
        ) {
            errorMessage = err
            return
        }

        if mode == .complete, !favoriteTeamIDs.isEmpty {
            let sortedIDs = favoriteTeamIDs.sorted()
            FavoriteTeamsStore.writeToAppStorage(sortedIDs)
            _ = await viewModel.syncFavoriteTeamsToSupabase(teamIDs: sortedIDs)
        }

        print("[SignupProfileDebug] profileSaveSuccess")
        onFinished()
    }

    @MainActor
    private func replaceAvatar(with item: PhotosPickerItem) async {
        isUploadingAvatar = true
        defer { isUploadingAvatar = false }

        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        let fileName = "avatar-\(Int(Date().timeIntervalSince1970)).jpg"
        guard let urls = await viewModel.uploadUserAvatar(data: data, fileName: fileName) else { return }
        _ = await viewModel.saveUserProfile(
            displayName: viewModel.currentUserDisplayName,
            avatarURL: urls.fullURL,
            avatarThumbnailURL: urls.thumbnailURL
        )
    }
}

/// Value snapshot for avatar UI (PhotosPicker label closure is nonisolated).
private struct IdentityAvatarSnapshot {
    let thumbnailURL: String?
    let avatarURL: String
    let refreshToken: UUID
    let email: String
}

/// PhotosPicker label uses plain snapshot fields — not MapViewModel — to satisfy concurrency checking.
private struct IdentitySetupAvatarPickerRow: View {
    let snapshot: IdentityAvatarSnapshot
    let displayName: String
    let isUploadingAvatar: Bool
    let isSaving: Bool
    @Binding var selectedAvatarItem: PhotosPickerItem?

    var body: some View {
        PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
            HStack(spacing: FGSpacing.md) {
                UserAvatarView(
                    avatarThumbnailURL: snapshot.thumbnailURL,
                    avatarURL: snapshot.avatarURL,
                    avatarDisplayRefreshToken: snapshot.refreshToken,
                    displayName: displayName,
                    email: snapshot.email,
                    size: 56,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: FGColor.accentBlue
                )
                Text(isUploadingAvatar ? "Uploading…" : "Choose photo")
                    .font(FGTypography.cardTitle)
                Spacer(minLength: 0)
            }
        }
        .disabled(isUploadingAvatar || isSaving)
    }
}
