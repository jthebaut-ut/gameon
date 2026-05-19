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
            .background(sheetBackground.ignoresSafeArea())
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
            await loadPokeSummary(for: userId)
        }
        .onAppear {
            DebugLogGate.debug("[PokesConsolidation] propsUIRemoved")
            DebugLogGate.debug("[PokesConsolidation] primarySocialSurface=pokes")
        }
        .onChange(of: chatViewModel.friendshipChipByOtherUserId) { _, _ in
            refreshFriendButtonState()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private func profileContent(_ data: PublicUserProfileData) -> some View {
        heroCard(data)
            .onAppear {
#if DEBUG
                print("[PublicProfileModernUI] rendered user_id=\(data.userId.uuidString.lowercased())")
#endif
            }
        pokeSection(data)
        reputationCard(data.reputation)
        favoriteTeamsCard(data.favoriteTeams)
        PublicProfilePickupOrganizerCard(creatorUserId: data.userId, stats: data.organizerStats)
        friendActionSection(data)
        if let friendActionError, !friendActionError.isEmpty {
            Text(friendActionError)
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let pokeActionError, !pokeActionError.isEmpty {
            Text(pokeActionError)
                .font(.caption)
                .foregroundStyle(.red.opacity(0.9))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func heroCard(_ data: PublicUserProfileData) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .bottomLeading) {
                stadiumHeroBackground
                    .frame(height: 118)
                    .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))

                HStack(alignment: .bottom, spacing: 14) {
                    UserAvatarView(
                        avatarThumbnailURL: data.avatarThumbnailURL,
                        avatarURL: data.avatarURL ?? "",
                        avatarDisplayRefreshToken: UUID(),
                        displayName: data.displayName,
                        email: "",
                        size: 88,
                        fallbackStyle: .lightOnWhiteChrome,
                        imagePlaceholderTint: FGColor.accentBlue
                    )
                    .overlay(
                        Circle()
                            .strokeBorder(
                                AngularGradient(
                                    colors: [
                                        FGColor.accentBlue,
                                        FGColor.accentGreen,
                                        Color(red: 0.98, green: 0.67, blue: 0.33),
                                        FGColor.accentBlue
                                    ],
                                    center: .center
                                ),
                                lineWidth: 3
                            )
                    )
                    .padding(3)
                    .background(Circle().fill(Color.white.opacity(0.96)))
                    .shadow(color: FGColor.accentBlue.opacity(0.16), radius: 12, y: 5)

                    VStack(alignment: .leading, spacing: 6) {
                        Text(data.displayName)
                            .font(.system(size: 24, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                        Text(data.publicHandleLine)
                            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                        reputationBadge(data.reputation)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(heroCardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.92),
                                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.12),
                                    Color.black.opacity(colorScheme == .dark ? 0.02 : 0.055)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.75
                        )
                }
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 22, y: 12)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.035 : 0.055), radius: 18, y: 3)
    }

    private func reputationBadge(_ reputation: FanReputationProfile) -> some View {
        HStack(spacing: 4) {
            Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "person.crop.circle.badge.checkmark")
                .font(.system(size: 9, weight: .bold))
            Text(reputation.title)
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(FGColor.accentGreen)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            Capsule(style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
        )
        .accessibilityLabel("Fan reputation, \(reputation.title)")
    }

    private func reputationCard(_ reputation: FanReputationProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Reputation")
                .sectionHeaderStyle(colorScheme: colorScheme)

            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.11))
                        .frame(width: 40, height: 40)
                    Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "person.2.wave.2.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(FGColor.accentGreen)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(reputation.title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .tracking(0.8)

                    Text(reputation.subtitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(FGColor.divider(colorScheme).opacity(0.72))
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [FGColor.accentGreen, FGColor.accentGreen.opacity(0.7)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * reputation.progressFraction))
                        }
                    }
                    .frame(height: 4)

                    Text(reputation.whyEarnedText)
                        .font(.system(size: 9, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .lineLimit(2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func favoriteTeamsCard(_ teams: [FavoriteTeam]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Favorite Teams")
                .sectionHeaderStyle(colorScheme: colorScheme)

            if teams.isEmpty {
                Text("No favorite teams selected yet")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(teams) { team in
                            VStack(spacing: 6) {
                                FavoriteTeamLogoBadge(team: team, diameter: 44)
                                Text(team.name)
                                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .lineLimit(1)
                                    .frame(maxWidth: 72)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background {
                                RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .fill(Color.white.opacity(colorScheme == .dark ? 0.045 : 0.72))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 0.75)
                                    }
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    @ViewBuilder
    private func pokeSection(_ data: PublicUserProfileData) -> some View {
        if canShowPokeControls(for: data.userId) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Pokes")
                        .sectionHeaderStyle(colorScheme: colorScheme)
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
                    .background(
                        Capsule(style: .continuous)
                            .fill(pokeButtonBackground)
                    )
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(pokeButtonBorder, lineWidth: 1)
                    }
                }
                .buttonStyle(.plain)
                .disabled(isPokeActionDisabled)
                .opacity(isPokeActionDisabled ? 0.65 : 1)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

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
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(disabled ? FGColor.accentGreen.opacity(0.35) : FGColor.accentGreen)
            )
            .shadow(color: FGColor.accentGreen.opacity(disabled ? 0 : 0.18), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .disabled(disabled || isFriendActionInFlight)
        .opacity(disabled ? 0.85 : 1)
    }

    // MARK: - Loading / error

    private var loadingSkeleton: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.72))
                .frame(height: 140)
                .redacted(reason: .placeholder)
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.62))
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

    private var heroCardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.07 : 0.96),
                Color(red: 0.94, green: 0.98, blue: 1.0).opacity(colorScheme == .dark ? 0.05 : 0.72),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.035 : 0.055)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.065 : 0.96),
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.07 : 0.06),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.82),
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.14)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            }
            .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.08), radius: 12, y: 7)
    }

    private var stadiumHeroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.12),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.13 : 0.10),
                    Color.white.opacity(colorScheme == .dark ? 0.04 : 0.82)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Image(systemName: "sportscourt.fill")
                .font(.system(size: 78, weight: .ultraLight))
                .foregroundStyle(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.13))
                .offset(x: 98, y: -8)
            Circle()
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.10 : 0.16), lineWidth: 1)
                .frame(width: 180, height: 180)
                .offset(x: -110, y: 62)
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
        DebugLogGate.debug("[PokesUI] public poke tapped target=\(targetUserId.uuidString.lowercased())")

        await MainActor.run {
            isPokeInFlight = true
            pokeActionError = nil
            pokeJustSucceeded = false
        }

        do {
            _ = try await profilePokesService.pokeProfile(targetUserId: targetUserId)
            DebugLogGate.debug("[PokesUI] poke success")
            await loadPokeSummary(for: targetUserId)
            await MainActor.run {
                pokeJustSucceeded = true
                isPokeInFlight = false
            }
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            await MainActor.run {
                pokeJustSucceeded = false
            }
            await loadPokeSummary(for: targetUserId)
        } catch let error as ProfilePokesServiceError {
            switch error {
            case .onCooldown(let until):
                DebugLogGate.debug("[PokesUI] poke cooldown interval=5m until=\(until ?? "unknown")")
                await MainActor.run {
                    pokeActionError = Self.cooldownMessage(until: until)
                    isPokeInFlight = false
                }
            default:
                await MainActor.run {
                    pokeActionError = error.localizedDescription
                    isPokeInFlight = false
                }
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
        if minutes < 60 {
            return "You can poke again in \(minutes)m"
        }
        return "You can poke again soon"
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

private extension Text {
    func sectionHeaderStyle(colorScheme: ColorScheme) -> some View {
        self
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .textCase(.uppercase)
            .tracking(0.7)
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
