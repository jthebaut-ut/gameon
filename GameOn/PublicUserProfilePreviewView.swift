import SwiftUI

/// Polished read-only profile preview for another fan (no email, no UUID in UI). Shown via ``PublicProfileOverlayWindowPresenter``.
struct PublicUserProfilePreviewView: View {
    let userId: UUID
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    var onDismiss: () -> Void = {}
    @Environment(\.colorScheme) private var colorScheme

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

    private let gridColumns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
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
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(sheetBackground.ignoresSafeArea())
            .navigationTitle("Fan Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }
        }
        .task(id: userId) {
            await loadProfile()
            await loadPokeSummary(for: userId)
        }
        .onChange(of: chatViewModel.friendshipChipByOtherUserId) { _, _ in
            refreshFriendButtonState()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func profileContent(_ data: PublicUserProfileData) -> some View {
        identityHeaderCard(data)
            .onAppear {
#if DEBUG
                print("[PublicProfileModernUI] rendered user_id=\(data.userId.uuidString.lowercased())")
#endif
            }

        LazyVGrid(columns: gridColumns, spacing: 12) {
            openToCard(data)
            mutualFansCard(data)
            venuesVisitedCard(data)
            if data.sharedTeamsCount > 0 {
                sharedTeamsCard(data)
            }
        }

        if !data.socialHighlightLabels.isEmpty {
            socialHighlightsCard(data)
        }

        PublicProfilePickupOrganizerCard(creatorUserId: data.userId, stats: data.organizerStats)

        pokeSection(data)
        friendActionSection(data)

        if let friendActionError, !friendActionError.isEmpty {
            inlineError(friendActionError)
        }
        if let pokeActionError, !pokeActionError.isEmpty {
            inlineError(pokeActionError)
        }
    }

    private func identityHeaderCard(_ data: PublicUserProfileData) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                UserAvatarView(
                    avatarThumbnailURL: data.avatarThumbnailURL,
                    avatarURL: data.avatarURL ?? "",
                    avatarDisplayRefreshToken: UUID(),
                    displayName: data.displayName,
                    email: "",
                    size: 84,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: FGColor.accentBlue
                )
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [FGColor.accentBlue, FGColor.accentGreen],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 2.5
                        )
                )
                .shadow(color: FGColor.accentBlue.opacity(0.14), radius: 10, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(data.displayName)
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(data.publicHandleLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    reputationPill(data.reputation)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !data.favoriteTeams.isEmpty {
                favoriteTeamsRow(data.favoriteTeams)
            }

            if let bio = data.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let memberSince = data.memberSinceLabel {
                Text(memberSince)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .publicProfileGlassCard()
    }

    private func reputationPill(_ reputation: FanReputationProfile) -> some View {
        HStack(spacing: 5) {
            Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "sparkles")
                .font(.system(size: 9, weight: .bold))
            Text("Fan Reputation · \(reputation.title)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(FGColor.accentGreen)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10))
        )
        .accessibilityLabel("Fan reputation, \(reputation.title)")
    }

    private func favoriteTeamsRow(_ teams: [FavoriteTeam]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(teams.prefix(8)) { team in
                    FavoriteTeamLogoBadge(team: team, diameter: 34)
                }
            }
        }
    }

    private func openToCard(_ data: PublicUserProfileData) -> some View {
        PublicProfileSectionCard(
            title: "Open To",
            accent: FGColor.accentBlue,
            colorScheme: colorScheme
        ) {
            if data.openToItems.isEmpty {
                Text("Still building their fan interests")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(data.openToItems.prefix(4)) { item in
                        HStack(spacing: 8) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(FGColor.accentBlue)
                                .frame(width: 22)
                            Text(item.title)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .lineLimit(2)
                        }
                    }
                }
            }
        }
    }

    private func mutualFansCard(_ data: PublicUserProfileData) -> some View {
        PublicProfileSectionCard(
            title: "Mutual Fans",
            accent: Color(red: 0.58, green: 0.36, blue: 0.92),
            colorScheme: colorScheme
        ) {
            if data.mutualFansCount == 0 {
                Text("No mutual fans yet")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(data.mutualFansCount) mutual fans")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    if !data.mutualFanAvatars.isEmpty {
                        mutualAvatarStack(data.mutualFanAvatars)
                    }
                }
            }
        }
    }

    private func mutualAvatarStack(_ avatars: [PublicProfileMutualFanAvatar]) -> some View {
        HStack(spacing: -10) {
            ForEach(avatars.prefix(4)) { fan in
                UserAvatarView(
                    avatarThumbnailURL: fan.avatarURL,
                    avatarURL: fan.avatarURL ?? "",
                    avatarDisplayRefreshToken: UUID(),
                    displayName: fan.displayName,
                    email: "",
                    size: 32,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: FGColor.accentBlue
                )
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            }
            if avatars.count > 4 {
                Text("+\(avatars.count - 4)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.leading, 6)
            }
        }
    }

    private func venuesVisitedCard(_ data: PublicUserProfileData) -> some View {
        PublicProfileSectionCard(
            title: data.venueCount > 0 ? "Venues Visited" : "Favorite Venues",
            accent: Color(red: 0.58, green: 0.36, blue: 0.92),
            colorScheme: colorScheme
        ) {
            if data.venueCount == 0, data.venueCards.isEmpty {
                Text("No favorite venues yet")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text(data.venueCount == 1 ? "1 venue" : "\(data.venueCount) venues")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    ForEach(data.venueCards.prefix(3)) { venue in
                        HStack(spacing: 8) {
                            Image(systemName: "building.2.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(FGColor.accentBlue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(venue.venueName)
                                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .lineLimit(1)
                                if !venue.cityLabel.isEmpty {
                                    Text(venue.cityLabel)
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(FGColor.mutedText(colorScheme))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func sharedTeamsCard(_ data: PublicUserProfileData) -> some View {
        PublicProfileSectionCard(
            title: "Shared Teams",
            accent: FGColor.accentGreen,
            colorScheme: colorScheme
        ) {
            Text(data.sharedTeamsCount == 1 ? "1 team in common" : "\(data.sharedTeamsCount) teams in common")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
    }

    private func socialHighlightsCard(_ data: PublicUserProfileData) -> some View {
        PublicProfileSectionCard(
            title: "Fan Activity",
            accent: FGColor.accentGreen,
            colorScheme: colorScheme,
            fullWidth: true
        ) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(data.socialHighlightLabels, id: \.self) { label in
                    HStack(spacing: 8) {
                        Image(systemName: "sparkle")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(FGColor.accentGreen)
                        Text(label)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func pokeSection(_ data: PublicUserProfileData) -> some View {
        if canShowPokeControls(for: data.userId) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pokes")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(pokeCountText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle((pokeSummary?.totalPokes ?? 0) == 0 ? FGColor.mutedText(colorScheme) : FGColor.secondaryText(colorScheme))
                    if let cooldown = pokeCooldownHintText {
                        Text(cooldown)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 8)

                Button {
                    Task { await sendPoke(to: data.userId) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: pokeButtonIcon)
                            .font(.system(size: 11, weight: .bold))
                        Text(pokeButtonTitle)
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(pokeButtonForeground)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Capsule(style: .continuous).fill(pokeButtonBackground))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(pokeButtonBorder, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPokeActionDisabled)
                .opacity(isPokeActionDisabled ? 0.65 : 1)
            }
            .publicProfileGlassCard()
        }
    }

    @ViewBuilder
    private func friendActionSection(_ data: PublicUserProfileData) -> some View {
        switch friendButtonState {
        case .hidden:
            EmptyView()
        case .messageFriend:
            primaryFriendButton(title: "Message friend", systemImage: "message.fill") {
                Task { await messageFriend(data) }
            }
        case .requestFriendship:
            primaryFriendButton(title: "Request friendship", systemImage: "person.badge.plus") {
                Task { await requestFriendship(userId: data.userId) }
            }
        case .friendshipRequested:
            primaryFriendButton(title: "Friendship requested", systemImage: "clock.fill", disabled: true) {}
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
        .publicProfileGlassCard()
    }

    // MARK: - Poke UI helpers

    private var pokeCountText: String {
        guard let pokeSummary else { return "Pokes loading" }
        guard pokeSummary.totalPokes > 0 else { return "No pokes yet" }
        return pokeSummary.totalPokes == 1 ? "1 poke" : "\(pokeSummary.totalPokes) pokes"
    }

    private var pokeCooldownHintText: String? {
        guard pokeJustSucceeded == false else { return nil }
        guard let pokeSummary, !pokeSummary.viewerCanPokeNow else { return nil }
        return Self.cooldownMessage(until: pokeSummary.viewerCooldownEndsAt)
    }

    private var pokeButtonTitle: String {
        if pokeJustSucceeded { return "Poked!" }
        if let pokeSummary, pokeSummary.viewerCanPokeNow { return "Poke" }
        if pokeSummary != nil { return "Poke again soon" }
        return "Poke"
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

    private func primaryFriendButton(
        title: String,
        systemImage: String,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 14, weight: .semibold))
                Text(title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(disabled ? FGColor.accentGreen.opacity(0.35) : FGColor.accentGreen)
            )
            .shadow(color: FGColor.accentGreen.opacity(disabled ? 0 : 0.18), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled || isFriendActionInFlight)
    }

    private func inlineError(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red.opacity(0.9))
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var loadingSkeleton: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.72))
                .frame(height: 180)
                .redacted(reason: .placeholder)
            LazyVGrid(columns: gridColumns, spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.62))
                        .frame(height: 120)
                        .redacted(reason: .placeholder)
                }
            }
            ProgressView().tint(FGColor.accentGreen).padding(.top, 8)
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
        ZStack {
            Color(.systemGroupedBackground)
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.02 : 0.96),
                    Color(red: 0.94, green: 0.98, blue: 1.0).opacity(colorScheme == .dark ? 0.04 : 0.74),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.035 : 0.055)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
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

// MARK: - Card chrome

private struct PublicProfileSectionCard<Content: View>: View {
    let title: String
    let accent: Color
    let colorScheme: ColorScheme
    var fullWidth: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(accent.opacity(0.92))
                .textCase(.uppercase)
                .tracking(0.7)
            content()
        }
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .publicProfileGlassCard()
        .gridCellColumns(fullWidth ? 2 : 1)
    }
}

private extension View {
    func publicProfileGlassCard() -> some View {
        fanGeoGlassCard(cornerRadius: 22)
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
