import Photos
import SwiftUI
import PhotosUI
import CoreLocation

struct UserProfileScreen: View {
    @ObservedObject var viewModel: MapViewModel
    var onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @State private var editedDisplayName: String = ""
    @State private var editedUsername: String = ""
    @State private var editedBio: String = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var availabilityTask: Task<Void, Never>?
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var isSaving: Bool = false
    @State private var isUploadingAvatar: Bool = false
    @State private var message: String = ""
    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""

    private static let bioCharacterLimit = 160

    private var selectedTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private var reputation: FanReputationProfile {
        FanReputationEngine.evaluate(
            FanReputationSignals(
                fanXP: viewModel.currentUserFanXP,
                favoriteTeams: selectedTeams,
                localContext: FanReputationEngine.localContext(
                    latitude: viewModel.currentUserLocation?.latitude,
                    longitude: viewModel.currentUserLocation?.longitude
                ),
                savedVenueCount: viewModel.favoriteVenueIDs.count,
                venuePlanCount: viewModel.followingTabGoingItems.count,
                pickupHostedCount: viewModel.myPickupGamesForSettings.count + viewModel.myRemovedPickupGamesForSettings.count,
                pickupJoinedCount: viewModel.myPickupGameJoinRequestCards.count,
                organizerStats: viewModel.currentUserAuthId.flatMap { viewModel.pickupCreatorTrustStats(for: $0) }
            ),
            shouldLog: false
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.xl) {
                    profileHeaderCard
                    displayNameCard
                    usernameCard
                    bioCard
                    photoCard

                    if !message.isEmpty {
                        messageBanner
                    }
                }
                .padding(.horizontal, FGSpacing.lg)
                .padding(.top, FGSpacing.lg)
                .padding(.bottom, SettingsScrollBottomLayout.sheetScrollComfortInset + 16)
            }
            .scrollIndicators(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("Edit Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isSaving || isUploadingAvatar)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await saveProfile() }
                    }
                    .disabled(isSaving || isUploadingAvatar)
                }
            }
            .onAppear {
                editedDisplayName = resolvedDisplayName
                editedUsername = viewModel.currentUserUsername
                editedBio = limitedBio(viewModel.currentUserBio)
            }
            .onChange(of: editedUsername) { _, newValue in
                let normalized = FanGeoHandleRules.normalizeForStorage(newValue)
                if normalized != newValue {
                    editedUsername = normalized
                    return
                }
                scheduleHandleAvailabilityCheck()
            }
            .onChange(of: editedBio) { _, newValue in
                let limited = limitedBio(newValue)
                if limited != newValue {
                    editedBio = limited
                }
            }
            .onChange(of: selectedAvatarItem) { _, item in
                guard let item else { return }
                Task { await replaceAvatar(with: item) }
            }
        }
    }

    private var profileHeaderCard: some View {
        ZStack(alignment: .bottomTrailing) {
            LinearGradient(
                colors: [FGColor.gradientMiddle.opacity(0.95), FGColor.gradientEnd.opacity(0.86)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                HStack(alignment: .top, spacing: FGSpacing.md) {
                    profileAvatar

                    VStack(alignment: .leading, spacing: FGSpacing.xs) {
                        Text(resolvedDisplayName.isEmpty ? "My profile" : resolvedDisplayName)
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(.white)

                        Text(viewModel.currentUserPublicHandleLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(.white.opacity(0.82))
                            .lineLimit(1)

                        HStack(spacing: FGSpacing.sm) {
                            FGStatusPill(title: reputation.title, kind: .custom(tint: .white))
                            FGStatusPill(
                                title: reputation.contextLine,
                                kind: .custom(tint: Color.white.opacity(0.92))
                            )
                        }
                    }

                    Spacer(minLength: 0)
                }

                Text(reputation.profileSubtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(.white.opacity(0.82))
            }
            .padding(FGSpacing.xl)

            FanGeoLogoWatermark(variant: .white, width: 70, opacity: 0.12)
                .padding(.trailing, FGSpacing.md)
                .padding(.bottom, FGSpacing.md)
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
        .floatingShadow()
    }

    private var usernameCard: some View {
        FGCard {
            FGSectionHeader(
                "@handle",
                subtitle: "Your unique public FanGeo handle for friend search."
            )

            HStack(spacing: 4) {
                Text("@")
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                TextField("handle", text: $editedUsername)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(FGTypography.body)
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, FGSpacing.sm + 2)
            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }

            if !handleStatusMessage.isEmpty {
                HandleAvailabilityStatusLabel(
                    message: handleStatusMessage,
                    isPositive: handleStatusIsPositive
                )
            }
        }
    }

    private var displayNameCard: some View {
        FGCard {
            FGSectionHeader(
                "Display name",
                subtitle: "Shown across FanGeo. Display names do not need to be unique."
            )

            TextField("Name", text: $editedDisplayName)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .font(FGTypography.body)
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.sm + 2)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
        }
    }

    private var bioCard: some View {
        FGCard {
            FGSectionHeader(
                "Bio",
                subtitle: "A short line about you. Optional."
            )

            TextEditor(text: $editedBio)
                .font(FGTypography.body)
                .frame(minHeight: 86)
                .scrollContentBackground(.hidden)
                .padding(.horizontal, FGSpacing.sm)
                .padding(.vertical, FGSpacing.xs)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }

            Text("\(editedBio.count)/\(Self.bioCharacterLimit)")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var photoCard: some View {
        FGCard {
            FGSectionHeader(
                "Photo",
                subtitle: "We only access a photo when you choose one here."
            )

            PhotosPicker(selection: $selectedAvatarItem, matching: .images) {
                HStack(spacing: FGSpacing.md) {
                    ZStack {
                        Circle()
                            .fill(FGColor.accentBlue.opacity(0.12))
                        if isUploadingAvatar {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(FGColor.accentBlue)
                        }
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Update avatar")
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text("Choose a new profile photo")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(FGSpacing.md)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
            }
            .disabled(isUploadingAvatar || isSaving)
            .buttonStyle(.plain)

            Text("If nothing appears, open Settings ▸ Privacy & Security ▸ Photos for FanGeo.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
    }

    private var messageBanner: some View {
        HStack(alignment: .top, spacing: FGSpacing.sm) {
            Image(systemName: message == "Saved." || message == "Avatar updated." ? "checkmark.circle.fill" : "info.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(message == "Saved." || message == "Avatar updated." ? FGColor.accentGreen : FGColor.accentBlue)

            Text(message)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm + 2)
        .fanGeoFloatingStyle()
    }

    private var resolvedDisplayName: String {
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    private func limitedBio(_ raw: String) -> String {
        String(raw.prefix(Self.bioCharacterLimit))
    }

    private var initials: String {
        let name = resolvedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let parts = name.split(separator: " ").filter { !$0.isEmpty }
            if parts.count >= 2 {
                return "\(parts[0].prefix(1))\(parts[1].prefix(1))".uppercased()
            }
            return "\(name.prefix(2))".uppercased()
        }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? "U" : "\(local.prefix(2))".uppercased()
    }

    private func profilePhotoPickFailureHint() -> String {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .denied, .restricted:
            return "Photo access is off. Turn it on in Settings ▸ Privacy & Security ▸ Photos to upload a profile picture."
        case .limited:
            return "Couldn’t use that photo. Try another image, or allow more photos for FanGeo in Settings."
        default:
            return "Unable to read that photo. Try a different image or check your connection."
        }
    }

    private var profileAvatar: some View {
        ZStack {
            Circle()
                .fill(Color.white.opacity(0.18))

            if let urlString = ImageDisplayURL.forDetailDisplay(
                thumbnail: viewModel.currentUserAvatarThumbnailURL,
                full: viewModel.currentUserAvatarURL,
                refreshToken: viewModel.currentUserAvatarDisplayRefreshToken
            ),
               let url = URL(string: urlString) {
                AsyncImage(url: url) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ProgressView()
                        .tint(.white)
                }
            } else {
                Text(initials)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 76, height: 76)
        .clipShape(Circle())
        .overlay {
            Circle()
                .strokeBorder(Color.white.opacity(0.22), lineWidth: 2)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 8)
    }

    private func saveProfile() async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { message = "Please sign in to edit your profile." }
            return
        }

        isSaving = true
        defer { isSaving = false }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? resolvedDisplayName : trimmed
        if ModerationService.containsProfanity(nextName) {
            await MainActor.run { message = ModerationService.profanityRejectionUserMessage() }
            return
        }
        if let issue = FanGeoHandleRules.validate(editedUsername) {
            await MainActor.run { message = FanGeoHandleRules.validationMessage(for: issue) }
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }
        let nextBio = limitedBio(editedBio)

        if let err = await viewModel.saveUserProfile(
            displayName: nextName,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            username: editedUsername,
            bio: nextBio
        ) {
            await MainActor.run { message = err }
            return
        }
#if DEBUG
        print("[ProfileBioDebug] saveBio=\(nextBio)")
#endif
        await MainActor.run { message = "Saved." }
        onDone()
    }

    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false

        let raw = editedUsername
        if raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }
        let stored = FanGeoHandleRules.normalizeForStorage(raw)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")
        if let issue = FanGeoHandleRules.validate(raw) {
            handleStatusMessage = "Invalid handle: \(FanGeoHandleRules.validationMessage(for: issue))"
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            return
        }

        handleStatusMessage = "Checking availability..."
        availabilityTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            guard let available = await viewModel.checkUsernameAvailable(raw) else { return }
            await MainActor.run {
                guard !Task.isCancelled else { return }
                print("[HandleValidationDebug] handleAvailable=\(available)")
                if available {
                    handleStatusMessage = "Available"
                    handleStatusIsPositive = true
                } else {
                    handleStatusMessage = "Already taken"
                    handleStatusIsPositive = false
                    print("[HandleValidationDebug] handleRejected reason=already_taken")
                }
            }
        }
    }

    private func replaceAvatar(with item: PhotosPickerItem) async {
        guard viewModel.isLoggedIn else {
            await MainActor.run { message = "Please sign in to update your avatar." }
            return
        }

        isUploadingAvatar = true
        defer { isUploadingAvatar = false }
        await MainActor.run { message = "Uploading avatar..." }

        guard let data = try? await item.loadTransferable(type: Data.self) else {
            await MainActor.run { message = profilePhotoPickFailureHint() }
            return
        }
        guard let urls = await viewModel.uploadUserAvatar(data: data, fileName: "avatar.jpg") else {
            await MainActor.run { message = "Unable to upload avatar." }
            return
        }

        let trimmed = editedDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let nextName = trimmed.isEmpty ? resolvedDisplayName : trimmed
        if ModerationService.containsProfanity(nextName) {
            await MainActor.run { message = ModerationService.profanityRejectionUserMessage() }
            return
        }
        if let err = await viewModel.saveUserProfile(
            displayName: nextName,
            avatarURL: urls.fullURL,
            avatarThumbnailURL: urls.thumbnailURL
        ) {
            await MainActor.run { message = err }
            return
        }
        await MainActor.run { message = "Avatar updated." }
    }
}
