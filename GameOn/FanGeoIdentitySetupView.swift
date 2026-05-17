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
    @State private var selectedAvatarItem: PhotosPickerItem?
    @State private var isSaving = false
    @State private var isUploadingAvatar = false
    @State private var errorMessage = ""
    @State private var handleStatusMessage = ""
    @State private var handleStatusIsPositive = false
    @State private var availabilityTask: Task<Void, Never>?

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
                        Text(isSaving ? "Saving…" : "Continue")
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
            .navigationTitle(mode == .complete ? "Create your FanGeo identity" : "Choose your @handle")
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
            .onChange(of: handleDraft) { _, _ in
                scheduleHandleAvailabilityCheck()
            }
        }
    }

    private var headerCopy: some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            Text(mode == .complete
                ? "Pick how fans will see you across FanGeo."
                : "Set a unique @handle for friend search and your public profile.")
                .font(FGTypography.body)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
    }

    private func avatarSection(snapshot: IdentityAvatarSnapshot) -> some View {
        FGCard {
            FGSectionHeader("Profile photo", subtitle: "Optional — add or change anytime.")
            IdentitySetupAvatarPickerRow(
                snapshot: snapshot,
                displayName: displayNameDraft,
                isUploadingAvatar: isUploadingAvatar,
                isSaving: isSaving,
                selectedAvatarItem: $selectedAvatarItem
            )
        }
    }

    private var displayNameSection: some View {
        FGCard {
            FGSectionHeader("Display name", subtitle: "Required — your public friendly name.")
            TextField("Display name", text: $displayNameDraft)
                .textInputAutocapitalization(.words)
                .autocorrectionDisabled()
                .font(FGTypography.body)
                .padding(.horizontal, FGSpacing.md)
                .padding(.vertical, FGSpacing.sm + 2)
                .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
                .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
        }
    }

    private var handleSection: some View {
        FGCard {
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
            .padding(.horizontal, FGSpacing.md)
            .padding(.vertical, FGSpacing.sm + 2)
            .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.62 : 0.96))
            .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))

            if !handleStatusMessage.isEmpty {
                Text(handleStatusMessage)
                    .font(FGTypography.caption)
                    .foregroundStyle(handleStatusIsPositive ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
            }
        }
    }

    private var canSubmit: Bool {
        let handleOK = FanGeoHandleRules.validate(handleDraft) == nil
        switch mode {
        case .complete:
            return !displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && handleOK
        case .handleOnly:
            return handleOK
        }
    }

    @MainActor
    private func scheduleHandleAvailabilityCheck() {
        availabilityTask?.cancel()
        handleStatusMessage = ""
        handleStatusIsPositive = false

        let raw = handleDraft
        if let issue = FanGeoHandleRules.validate(raw) {
            handleStatusMessage = FanGeoHandleRules.validationMessage(for: issue)
            return
        }

        availabilityTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            guard let available = await viewModel.checkUsernameAvailable(raw) else { return }
            guard !Task.isCancelled else { return }
            if available {
                handleStatusMessage = "Handle available."
                handleStatusIsPositive = true
            } else {
                handleStatusMessage = "That handle is already taken."
                handleStatusIsPositive = false
            }
        }
    }

    @MainActor
    private func saveIdentity() async {
        errorMessage = ""
        isSaving = true
        defer { isSaving = false }

        let name = mode == .complete
            ? displayNameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            : viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)

        if mode == .complete, name.isEmpty {
            errorMessage = "Display name is required."
            return
        }

        if ModerationService.containsProfanity(name) {
            errorMessage = ModerationService.profanityRejectionUserMessage()
            return
        }

        if let issue = FanGeoHandleRules.validate(handleDraft) {
            errorMessage = FanGeoHandleRules.validationMessage(for: issue)
            return
        }

        if let err = await viewModel.saveUserProfile(
            displayName: name,
            avatarURL: viewModel.currentUserAvatarURL,
            avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
            username: handleDraft
        ) {
            errorMessage = err
            return
        }

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
