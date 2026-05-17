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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if isLoading, profile == nil {
                        loadingSkeleton
                    } else if let profile {
                        if let identityLoadWarning {
                            identityWarningBanner(identityLoadWarning)
                        }
                        profileContent(profile)
                    } else {
                        loadingSkeleton
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 24)
            }
            .background(Color(red: 0.04, green: 0.05, blue: 0.07).ignoresSafeArea())
            .navigationTitle("Fan Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        onDismiss()
                    }
                }
            }
        }
        .task(id: userId) {
            await loadProfile()
        }
        .onChange(of: chatViewModel.friendshipChipByOtherUserId) { _, _ in
            refreshFriendButtonState()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func profileContent(_ data: PublicUserProfileData) -> some View {
        heroCard(data)
        fanLevelCard(data.fanXP)
        favoriteTeamsCard(data.favoriteTeams)
        PublicProfilePickupOrganizerCard(creatorUserId: data.userId, stats: data.organizerStats)
        friendActionSection(data)
        if let friendActionError, !friendActionError.isEmpty {
            Text(friendActionError)
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heroCard(_ data: PublicUserProfileData) -> some View {
        VStack(spacing: 12) {
            ZStack {
                stadiumHeroBackground
                    .frame(height: 100)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(alignment: .bottom, spacing: 12) {
                    UserAvatarView(
                        avatarThumbnailURL: data.avatarThumbnailURL,
                        avatarURL: data.avatarURL ?? "",
                        avatarDisplayRefreshToken: UUID(),
                        displayName: data.displayName,
                        email: "",
                        size: 72,
                        fallbackStyle: .darkCardTranslucent,
                        imagePlaceholderTint: .white.opacity(0.75)
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(Color.white.opacity(0.35), lineWidth: 2)
                    )
                    .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(data.displayName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                        Text(data.publicHandleLine)
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.accentGreen.opacity(0.95))
                        levelBadge(level: data.fanXP.level, title: data.fanXP.title)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 8)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color(red: 0.06, green: 0.07, blue: 0.10))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.white.opacity(0.12), lineWidth: 1)
        }
    }

    private func levelBadge(level: Int, title: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 9, weight: .bold))
            Text("Lv \(level)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(FGColor.accentGreen.opacity(0.35))
        )
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(0.6), lineWidth: 1)
        }
        .accessibilityLabel("Fan level \(level), \(title)")
    }

    private func fanLevelCard(_ fanXP: FanXPState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Fan Level")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.7))

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .strokeBorder(FGColor.accentGreen.opacity(0.5), lineWidth: 2)
                        .frame(width: 40, height: 40)
                    Circle()
                        .fill(FGColor.accentGreen.opacity(0.18))
                        .frame(width: 36, height: 36)
                    Image(systemName: "soccerball")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Level \(fanXP.level) · \(fanXP.title)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(0.14))
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [FGColor.accentGreen, FGColor.accentGreen.opacity(0.7)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * fanXP.progressFraction))
                        }
                    }
                    .frame(height: 5)

                    Text(fanXP.xpRangeLine)
                        .font(.system(size: 9, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen.opacity(0.85))
                    Text(fanXP.progressLine)
                        .font(.system(size: 8, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func favoriteTeamsCard(_ teams: [FavoriteTeam]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Favorite Teams")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

            if teams.isEmpty {
                Text("No favorite teams selected yet")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(teams) { team in
                            VStack(spacing: 4) {
                                FavoriteTeamLogoBadge(team: team, diameter: 40)
                                Text(team.name)
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white.opacity(0.72))
                                    .lineLimit(1)
                                    .frame(maxWidth: 72)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
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
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(disabled ? FGColor.accentGreen.opacity(0.35) : FGColor.accentGreen)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled || isFriendActionInFlight)
        .opacity(disabled ? 0.85 : 1)
    }

    // MARK: - Loading / error

    private var loadingSkeleton: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.08))
                .frame(height: 140)
                .redacted(reason: .placeholder)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(height: 72)
                    .redacted(reason: .placeholder)
            }
            ProgressView()
                .tint(FGColor.accentGreen)
                .padding(.top, 8)
        }
    }

    private func identityWarningBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 12, weight: .semibold))
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
            Spacer(minLength: 0)
            Button("Retry") {
                Task { await loadProfile() }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .foregroundStyle(.white.opacity(0.85))
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.orange.opacity(0.22))
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.09))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
            }
    }

    private var stadiumHeroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.09, blue: 0.13),
                    Color(red: 0.03, green: 0.11, blue: 0.08)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            Image(systemName: "sportscourt.fill")
                .font(.system(size: 72, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.1))
        }
    }

    // MARK: - Actions

    private func loadProfile() async {
        await MainActor.run {
            isLoading = true
            friendActionError = nil
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

#if DEBUG
        print("[PublicProfileLoadDebug] friendState=\(friendState)")
#endif

        await MainActor.run {
            profile = loaded
            isLoading = false
            identityLoadWarning = loaded.hasResolvedIdentity
                ? nil
                : "Limited profile — identity still loading. Tap Retry."
            friendButtonState = friendState
        }
    }

    private func refreshFriendButtonState() {
        guard profile != nil else {
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
            isBusiness: profile?.isBusinessAccount == true
        )
#if DEBUG
        print("[PublicProfileLoadDebug] friendState=\(friendButtonState)")
#endif
    }

    private func requestFriendship(userId: UUID) async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
        }
#if DEBUG
        print("[PublicProfileFriendActionDebug] request_start userId=\(userId.uuidString.lowercased())")
#endif
        await chatViewModel.sendFriendRequest(to: userId)
        await chatViewModel.refresh()
        await MainActor.run {
            isFriendActionInFlight = false
            refreshFriendButtonState()
#if DEBUG
            print(
                "[PublicProfileFriendActionDebug] request_done userId=\(userId.uuidString.lowercased()) state=\(friendButtonState)"
            )
#endif
        }
    }

    private func messageFriend(_ data: PublicUserProfileData) async {
        guard !isFriendActionInFlight else { return }
        await MainActor.run {
            isFriendActionInFlight = true
            friendActionError = nil
        }
        let preview = data.userPreviewForMessaging
#if DEBUG
        print("[PublicProfileFriendActionDebug] message_start userId=\(data.userId.uuidString.lowercased())")
#endif
        do {
            _ = try await chatViewModel.startDirectConversationWithFriend(friendUserId: data.userId)
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            await MainActor.run {
                chatViewModel.pendingDmOpenPreview = preview
                onDismiss()
            }
#if DEBUG
            print("[PublicProfileFriendActionDebug] message_opened_dm userId=\(data.userId.uuidString.lowercased())")
#endif
        } catch {
            await MainActor.run {
                friendActionError = "Couldn't open chat. Try again."
                isFriendActionInFlight = false
            }
#if DEBUG
            print(
                "[PublicProfileFriendActionDebug] message_failed userId=\(data.userId.uuidString.lowercased()) error=\(error.localizedDescription)"
            )
#endif
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
