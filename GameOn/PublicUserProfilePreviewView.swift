import SwiftUI

/// Polished read-only profile preview for another fan (no email, no UUID in UI). Shown via ``PublicProfileOverlayWindowPresenter``.
struct PublicUserProfilePreviewView: View {
    let userId: UUID
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    var onDismiss: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var profile: PublicUserProfileData?
    @State private var isLoading = true
    @State private var identityLoadWarning: String?
    @State private var friendButtonState: PublicProfileFriendButtonState = .hidden
    @State private var isFriendActionInFlight = false
    @State private var friendActionError: String?
    @State private var pokeSummary: ProfilePokeSummary?
    @State private var isPokeInFlight = false
    @State private var pokeActionError: String?
    @State private var pokeJustSucceeded = false

    private let profilePokesService = ProfilePokesService()

    private var profileContentHorizontalPadding: CGFloat {
        PublicProfileSheetLayout.horizontalPadding()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: PublicProfileSheetLayout.sectionSpacing) {
                    if isLoading, profile == nil {
                        loadingSkeleton
                    } else if let profile {
                        if !profile.isPubliclyVisible {
                            profileUnavailableState
                        } else {
                            if let identityLoadWarning {
                                identityWarningBanner(identityLoadWarning)
                            }
                            profileContent(profile)
                        }
                    } else {
                        loadingSkeleton
                    }
                }
                .padding(.horizontal, profileContentHorizontalPadding)
                .padding(.top, 8)
                .padding(.bottom, 28)
            }
            .background(sheetBackground.ignoresSafeArea())
            .navigationTitle("Fan Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("done", languageCode: appLanguageRaw)) { onDismiss() }
                }
            }
        }
        .task(id: userId) {
            await loadProfile()
            await loadPokeSummary(for: userId)
        }
        .onChange(of: viewModel.publicProfileOpenToRevision) { _, _ in
            Task { await loadProfile() }
        }
        .onChange(of: viewModel.publicProfileHomeCrowdRevision) { _, _ in
            Task { await loadProfile() }
        }
        .onChange(of: viewModel.publicProfileBioRevision) { _, _ in
            Task { await loadProfile() }
        }
        .onChange(of: chatViewModel.friendshipChipByOtherUserId) { _, _ in
            refreshFriendButtonState()
        }
    }

    // MARK: - Editorial layout

    @ViewBuilder
    private func profileContent(_ data: PublicUserProfileData) -> some View {
        VStack(spacing: PublicProfileSheetLayout.sectionSpacing) {
            PublicProfileEditorialHero(data: data)
                .onAppear {
#if DEBUG
                    print("[PublicProfileEditorialUI] rendered user_id=\(data.userId.uuidString.lowercased())")
#endif
                }

            if friendButtonState != .hidden || canShowPokeControls(for: data.userId) {
                PublicProfileSocialActionBar(
                    friendState: friendButtonState,
                    showsPoke: canShowPokeControls(for: data.userId),
                    isFriendActionInFlight: isFriendActionInFlight,
                    pokeTitle: pokeButtonTitle,
                    pokeIcon: pokeButtonIcon,
                    pokeForeground: pokeButtonForeground,
                    pokeBackground: pokeButtonBackground,
                    pokeBorder: pokeButtonBorder,
                    isPokeDisabled: isPokeActionDisabled,
                    isPokeInFlight: isPokeInFlight,
                    onFriendAction: { Task { await performFriendAction(data) } },
                    onPoke: { Task { await sendPoke(to: data.userId) } }
                )
            }

            PublicProfileFavoriteTeamsCard(data: data)
                .frame(maxWidth: .infinity)

            PublicProfileTwoColumnGrid(data: data, colorScheme: colorScheme)

            if data.organizerStats?.hasPublicOrganizerRatings == true || data.pickupHostedCount > 0 {
                PublicProfilePickupOrganizerCard(
                    creatorUserId: data.userId,
                    stats: data.organizerStats,
                    compact: true
                )
            }

            if let friendActionError, !friendActionError.isEmpty {
                inlineError(friendActionError)
            }
            if let pokeActionError, !pokeActionError.isEmpty {
                inlineError(pokeActionError)
            }
        }
    }

    @MainActor
    private func performFriendAction(_ data: PublicUserProfileData) async {
        switch friendButtonState {
        case .messageFriend:
            await messageFriend(data)
        case .requestFriendship:
            await requestFriendship(userId: data.userId)
        case .hidden, .friendshipRequested:
            break
        }
    }

    private var profileUnavailableState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("This profile isn't available")
                .font(.system(size: 16, weight: .bold, design: .rounded))
            Text("The fan may have turned off discoverability or this profile can't be shown.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .publicProfileEditorialCard()
    }

    // MARK: - Poke UI helpers

    private var pokeButtonTitle: String {
        if pokeJustSucceeded { return "Poked!" }
        if let pokeSummary, pokeSummary.viewerCanPokeNow { return L10n.t("poke", languageCode: appLanguageRaw) }
        if pokeSummary != nil { return "Soon" }
        return L10n.t("poke", languageCode: appLanguageRaw)
    }

    private var pokeButtonIcon: String {
        pokeJustSucceeded ? "checkmark" : "hand.wave.fill"
    }

    private var pokeButtonForeground: Color {
        if pokeJustSucceeded { return FGColor.accentGreen }
        if pokeSummary?.viewerCanPokeNow == true { return .white }
        return FGColor.accentBlue
    }

    private var pokeButtonBackground: Color {
        if pokeJustSucceeded {
            return FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11)
        }
        if pokeSummary?.viewerCanPokeNow == true {
            return FGColor.accentBlue
        }
        return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.10)
    }

    private var pokeButtonBorder: Color {
        if pokeJustSucceeded { return FGColor.accentGreen.opacity(0.28) }
        return FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.18)
    }

    private var isPokeActionDisabled: Bool {
        isPokeInFlight || pokeSummary == nil || (pokeJustSucceeded == false && pokeSummary?.viewerCanPokeNow == false)
    }

    // MARK: - Shared chrome

    private func inlineError(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.72))
                .frame(height: 168)
                .redacted(reason: .placeholder)
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.62))
                .frame(height: 44)
                .redacted(reason: .placeholder)
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.62))
                    .frame(height: 176)
                    .redacted(reason: .placeholder)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.62))
                    .frame(height: 176)
                    .redacted(reason: .placeholder)
            }
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.62))
                .frame(height: 120)
                .redacted(reason: .placeholder)
            ProgressView().tint(FGColor.accentGreen).padding(.top, 4)
        }
    }

    private func identityWarningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
            Spacer(minLength: 0)
            Button("Retry") { Task { await loadProfile() } }
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(FGColor.secondaryText(colorScheme))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.14))
        )
    }

    private var sheetBackground: some View {
        Color(red: 0.94, green: 0.95, blue: 0.97)
            .opacity(colorScheme == .dark ? 0.92 : 1)
    }

    // MARK: - Actions

    private func loadProfile() async {
        await MainActor.run {
            isLoading = true
            friendActionError = nil
            pokeSummary = nil
            pokeActionError = nil
            pokeJustSucceeded = false
        }

        await chatViewModel.loadIfNeeded()

        var cached = viewModel.cachedUserProfileRowForPublicProfile(userId: userId)
        if cached == nil,
           let friend = chatViewModel.friends.first(where: { $0.preview.id == userId }) {
            cached = PublicUserProfileService.userProfileRow(from: friend.preview)
        }
        if userId == viewModel.currentUserAuthId {
            cached = viewModel.currentUserProfileRowForPublicProfileCache()
        }

        let loaded = await PublicUserProfileService.load(userId: userId, cachedProfile: cached)

        let chip = chatViewModel.chipKind(forOtherUserId: userId)
        let blocked = chatViewModel.isEitherDirectionBlocked(with: userId)
        let isSelf = viewModel.currentUserAuthId == userId
        let friendState = PublicUserProfileService.friendButtonState(
            for: userId,
            chipKind: chip,
            isBlocked: blocked,
            isSelf: isSelf,
            isBusiness: loaded.isBusinessAccount
        )

        await MainActor.run {
            profile = loaded
            isLoading = false
            identityLoadWarning = loaded.hasResolvedIdentity || !loaded.isPubliclyVisible
                ? nil
                : "Limited profile — identity still loading. Tap Retry."
            friendButtonState = friendState
        }
    }

    private func canShowPokeControls(for targetUserId: UUID) -> Bool {
        guard let currentUserId = viewModel.currentUserAuthId else { return false }
        return currentUserId != targetUserId
    }

    private func loadPokeSummary(for targetUserId: UUID) async {
        guard canShowPokeControls(for: targetUserId) else {
            await MainActor.run {
                pokeSummary = nil
                pokeActionError = nil
                pokeJustSucceeded = false
            }
            return
        }

        do {
            let summary = try await profilePokesService.fetchPokeSummary(targetUserId: targetUserId)
            await MainActor.run {
                pokeSummary = summary
                pokeActionError = nil
            }
        } catch {
            await MainActor.run {
                pokeSummary = nil
                pokeActionError = "Couldn't load Pokes. Try again later."
            }
        }
    }

    private func sendPoke(to targetUserId: UUID) async {
        guard canShowPokeControls(for: targetUserId), !isPokeInFlight else { return }

        await MainActor.run {
            isPokeInFlight = true
            pokeActionError = nil
            pokeJustSucceeded = false
        }

        do {
            _ = try await profilePokesService.pokeProfile(targetUserId: targetUserId)
            await loadPokeSummary(for: targetUserId)
            await MainActor.run {
                pokeJustSucceeded = true
                isPokeInFlight = false
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run { pokeJustSucceeded = false }
            await loadPokeSummary(for: targetUserId)
        } catch let error as ProfilePokesServiceError {
            await MainActor.run {
                if case .onCooldown(let until) = error {
                    pokeActionError = Self.cooldownMessage(until: until)
                } else {
                    pokeActionError = error.localizedDescription
                }
                isPokeInFlight = false
            }
            await loadPokeSummary(for: targetUserId)
        } catch {
            await MainActor.run {
                pokeActionError = "Couldn't send poke. Try again."
                isPokeInFlight = false
            }
            await loadPokeSummary(for: targetUserId)
        }
    }

    private static func cooldownMessage(until raw: String?) -> String {
        guard let raw,
              let end = SupabaseTimestampParsing.parseTimestamptz(raw),
              end > Date() else {
            return "You can poke again soon"
        }
        let minutes = max(1, Int(ceil(end.timeIntervalSinceNow / 60)))
        return minutes < 60 ? "You can poke again in \(minutes)m" : "You can poke again soon"
    }

    private func refreshFriendButtonState() {
        guard let profile else {
            friendButtonState = .hidden
            return
        }
        let chip = chatViewModel.chipKind(forOtherUserId: userId)
        let blocked = chatViewModel.isEitherDirectionBlocked(with: userId)
        let isSelf = viewModel.currentUserAuthId == userId
        friendButtonState = PublicUserProfileService.friendButtonState(
            for: userId,
            chipKind: chip,
            isBlocked: blocked,
            isSelf: isSelf,
            isBusiness: profile.isBusinessAccount
        )
    }

    private func requestFriendship(userId: UUID) async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
        }
        await chatViewModel.sendFriendRequest(to: userId)
        await chatViewModel.refresh()
        await MainActor.run {
            isFriendActionInFlight = false
            refreshFriendButtonState()
        }
    }

    private func messageFriend(_ data: PublicUserProfileData) async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
        }
        let preview = data.userPreviewForMessaging
        do {
            _ = try await chatViewModel.startDirectConversationWithFriend(friendUserId: data.userId)
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            await MainActor.run {
                chatViewModel.pendingDmOpenPreview = preview
                onDismiss()
            }
        } catch {
            await MainActor.run {
                friendActionError = "Couldn't open chat. Try again."
                isFriendActionInFlight = false
            }
        }
    }
}

private extension PublicUserProfileData {
    var userPreviewForMessaging: UserPreview {
        let handleStored = publicHandleLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
            .lowercased()
        return UserPreview(
            id: userId,
            displayName: displayName,
            username: handleStored.isEmpty ? nil : handleStored,
            email: nil,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            isBusinessAccount: isBusinessAccount
        )
    }
}
