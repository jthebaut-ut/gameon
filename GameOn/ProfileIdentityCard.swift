import SwiftUI
import CoreLocation

/// Unified Account-tab “Profile & Identity” card: compact profile, reputation, and favorite teams in one surface.
struct ProfileIdentityCard: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    @Binding var showProfileScreen: Bool
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @State private var showFavoriteTeamsPicker = false
    @State private var showHandleSetup = false

    init(viewModel: MapViewModel, showProfileScreen: Binding<Bool>) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
        _showProfileScreen = showProfileScreen
    }

    private var selectedTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private var selectedIDSet: Set<String> {
        Set(FavoriteTeamsStore.decodeIDs(from: favoriteTeamIDsRaw))
    }

    private var displayName: String {
        let current = viewModel.currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = viewModel.currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        guard !local.isEmpty else { return "Fan" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    /// Persisted @handle, or temporary email-prefix fallback only (never saved as username).
    private var handleLine: String {
        viewModel.currentUserPublicHandleLine
    }

    private var fanXP: FanXPState {
        viewModel.currentUserFanXP
    }

    private var reputation: FanReputationProfile {
        FanReputationEngine.evaluate(
            FanReputationSignals(
                fanXP: fanXP,
                favoriteTeams: selectedTeams,
                localContext: localContext,
                savedVenueCount: savedVenueCount,
                venuePlanCount: viewModel.followingTabGoingItems.count,
                pickupHostedCount: viewModel.myPickupGamesForSettings.count + viewModel.myRemovedPickupGamesForSettings.count,
                pickupJoinedCount: viewModel.myPickupGameJoinRequestCards.count,
                organizerStats: currentOrganizerStats,
                commentCount: locallyLoadedCommentCount,
                reactionCount: locallyLoadedReactionCount
            ),
            shouldLog: false
        )
    }

    private var currentOrganizerStats: PickupCreatorPublicRatingStats? {
        guard let uid = viewModel.currentUserAuthId else { return nil }
        return viewModel.pickupCreatorTrustStats(for: uid)
    }

    private var localContext: String? {
        FanReputationEngine.localContext(
            latitude: viewModel.currentUserLocation?.latitude,
            longitude: viewModel.currentUserLocation?.longitude
        )
    }

    private var locallyLoadedCommentCount: Int {
        fanUpdatesStore.venueEventComments.values.reduce(0) { $0 + $1.count }
    }

    private var locallyLoadedReactionCount: Int {
        fanUpdatesStore.venueEventVibeCounts.values.reduce(0) { total, counts in
            total + counts.values.reduce(0, +)
        }
    }

    private var savedVenueCount: Int {
        max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
    }

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] ProfileIdentityReadsStore=true")
#endif
    }

    var body: some View {
        let _: Void = logFanUpdatesStoreMigrationDebug()

        VStack(alignment: .leading, spacing: 0) {
            if viewModel.needsFanHandleSelection && !viewModel.needsBlockingFanIdentitySetup {
                handlePromptBanner
            }

            heroBlock

            integratedDivider

            fanReputationSection
                .padding(.horizontal, 13)
                .padding(.top, 8)

            integratedDivider
                .padding(.top, 10)

            favoriteTeamsSection
                .padding(.horizontal, 13)
                .padding(.top, 8)
                .padding(.bottom, 11)
        }
        .background(cardShellBackground)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 12, y: 7)
        .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.025 : 0.018), radius: 10, y: 2)
        .onAppear {
#if DEBUG
            print("[ProfileIdentityCardDebug] layout=compact_social_identity_card")
#endif
            FanReputationEngine.log(reputation)
        }
        .sheet(isPresented: $showProfileScreen) {
            UserProfileScreen(viewModel: viewModel) {
                showProfileScreen = false
            }
        }
        .sheet(isPresented: $showHandleSetup) {
            FanGeoIdentitySetupView(viewModel: viewModel, mode: .handleOnly)
        }
        .sheet(isPresented: $showFavoriteTeamsPicker) {
            FavoriteTeamsPickerSheet(
                selectedIDs: Binding(
                    get: { selectedIDSet },
                    set: { newSet in
                        let sorted = Array(newSet).sorted()
                        favoriteTeamIDsRaw = FavoriteTeamsStore.encodeIDs(sorted)
                        Task {
                            await viewModel.syncFavoriteTeamsToSupabase(teamIDs: sorted)
                        }
                    }
                )
            )
        }
    }

    // MARK: - Shell

    private var cardShellBackground: some View {
        ZStack {
            Color(red: 0.035, green: 0.045, blue: 0.052)
            LinearGradient(
                colors: [
                    Color.white.opacity(0.04),
                    Color(red: 0.025, green: 0.032, blue: 0.045).opacity(0.88)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 19, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.08 : 0.16),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.045 : 0.04),
                        Color.white.opacity(colorScheme == .dark ? 0.035 : 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
    }

    private var integratedDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.02),
                        Color.white.opacity(colorScheme == .dark ? 0.055 : 0.09),
                        Color.white.opacity(0.02)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    // MARK: - Handle prompt

    private var handlePromptBanner: some View {
        Button {
            showHandleSetup = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "at")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                Text("Choose your @handle for friend search")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(FGColor.accentGreen.opacity(0.12))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 14)
        .padding(.top, 12)
    }

    // MARK: - Hero (compact header + stats)

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 13)
                .padding(.top, 13)
                .padding(.bottom, 9)

            statsRow
                .padding(.horizontal, 13)
                .padding(.bottom, 10)
        }
        .background { MatteIdentityHeaderBackground() }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 19,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 19,
                style: .continuous
            )
        )
    }

    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Button {
                showProfileScreen = true
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    avatarStack

                    VStack(alignment: .leading, spacing: 3) {
                        Text(displayName)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)

                        Text(handleLine)
                            .font(.system(size: 11.5, weight: .medium, design: .rounded))
                            .foregroundStyle(.white.opacity(0.54))
                            .lineLimit(1)

                        Text(reputation.title.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.accentGreen.opacity(0.78))
                            .tracking(0.6)
                            .lineLimit(1)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit profile")

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 6) {
                compactHeaderButton(title: "Edit", systemImage: "pencil") {
                    showProfileScreen = true
                }
                compactHeaderButton(
                    title: savedVenueCount == 1 ? "1 saved" : "\(savedVenueCount) saved",
                    systemImage: "bookmark"
                ) {
                    showProfileScreen = true
                }
            }
        }
    }

    private var avatarStack: some View {
        ZStack(alignment: .bottomTrailing) {
            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                displayName: displayName,
                email: viewModel.currentUserEmail,
                size: 52,
                fallbackStyle: .darkCardTranslucent,
                imagePlaceholderTint: .white
            )
            .overlay {
                Circle()
                    .strokeBorder(Color.white.opacity(0.28), lineWidth: 1.2)
            }
            .shadow(color: .black.opacity(0.28), radius: 7, y: 4)

            Circle()
                .fill(Color(red: 0.04, green: 0.055, blue: 0.06))
                .frame(width: 18, height: 18)
                .overlay {
                    Image(systemName: "pencil")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(FGColor.accentGreen.opacity(0.9))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.16), lineWidth: 1)
                }
                .offset(x: 2, y: 2)
        }
    }

    private func compactHeaderButton(
        title: String,
        systemImage: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.56))
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.66))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule()
                    .fill(Color.white.opacity(0.04))
                    .overlay {
                        Capsule()
                            .strokeBorder(Color.white.opacity(0.045), lineWidth: 0.75)
                    }
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(value: gamesWatchedValue, label: "Plans")
            statDivider
            statCell(value: venuesVisitedValue, label: "Venues")
            statDivider
            statCell(value: teamsValue, label: "Teams")
            statDivider
            statCell(value: friendsValue, label: "Friends")
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .background {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Color.white.opacity(0.026))
                .overlay {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.035), lineWidth: 0.75)
                }
        }
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.04))
            .frame(width: 1)
            .padding(.vertical, 3)
    }

    private var gamesWatchedValue: String {
        let n = viewModel.followingTabGoingItems.count
        return n > 0 ? "\(n)" : "—"
    }

    private var venuesVisitedValue: String {
        let n = max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
        return n > 0 ? "\(n)" : "—"
    }

    private var teamsValue: String {
        let n = selectedTeams.count
        return n > 0 ? "\(n)" : "—"
    }

    private var friendsValue: String {
        let n = chatViewModel.friends.count
        return n > 0 ? "\(n)" : "—"
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.72))

            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.38))
                .multilineTextAlignment(.center)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Reputation

    private var fanReputationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Reputation")
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.58))
                .textCase(.uppercase)
                .tracking(0.7)

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "person.2.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen.opacity(0.82))
                    .frame(width: 24, height: 24)
                    .background {
                        Circle()
                    .fill(Color.white.opacity(0.034))
                    }

                VStack(alignment: .leading, spacing: 4) {
                    Text(reputation.title.uppercased())
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .tracking(0.6)

                    Text(reputation.subtitle)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.66))

                    Text(reputation.contextLine)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.5))

                    Text(reputation.whyEarnedText)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.36 : 0.48))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.026 : 0.048))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.038), lineWidth: 0.75)
                    }
            }
        }
    }

    // MARK: - Favorite teams

    private var favoriteTeamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Favorite Teams")
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.60))
                        .textCase(.uppercase)
                        .tracking(0.7)
                    Text(selectedTeams.isEmpty ? "Shape your fan identity" : "Part of your profile")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.34))
                }
                Spacer(minLength: 0)
                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 9, weight: .bold))
                        Text(selectedTeams.isEmpty ? "Add Teams" : "Edit Teams")
                            .font(.system(size: 10, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(.white.opacity(0.58))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background {
                        Capsule()
                            .fill(Color.white.opacity(0.045))
                    }
                }
                .buttonStyle(.plain)
            }

            if selectedTeams.isEmpty {
                addTeamsRow
            } else {
                favoriteTeamsBadgeRow
                addTeamsRow
                    .padding(.top, 4)
            }
        }
    }

    private var favoriteTeamsBadgeRow: some View {
        let visible = Array(selectedTeams.prefix(3))
        let overflow = selectedTeams.count - visible.count

        return HStack(alignment: .top, spacing: 8) {
            ForEach(visible) { team in
                teamBadgeColumn(team: team)
            }
            if overflow > 0 {
                moreTeamsBadge(count: overflow)
            }
            Spacer(minLength: 0)
        }
    }

    private func teamBadgeColumn(team: FavoriteTeam) -> some View {
        HStack(spacing: 7) {
            PremiumTeamIdentityOrb(team: team, diameter: 28)

            VStack(alignment: .leading, spacing: 1) {
                Text(team.name)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .minimumScaleFactor(0.75)

                Text(team.sport.chipTitle)
                    .font(.system(size: 8, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: 112, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.032 : 0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    team.badgeColor.opacity(0.12),
                                    Color.white.opacity(0.055)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                }
        }
    }

    private func moreTeamsBadge(count: Int) -> some View {
        HStack(spacing: 6) {
            Text("+\(count)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.accentGreen.opacity(0.84))
            Text("more")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.032 : 0.055))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.06), lineWidth: 1)
                }
        }
    }

    private var addTeamsRow: some View {
        Button {
            showFavoriteTeamsPicker = true
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.045))
                        .frame(width: 24, height: 24)
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.56))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(selectedTeams.isEmpty ? "Add your teams" : "Manage your teams")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.64))
                    Text("Reputation, venues, and fan matches")
                        .font(.system(size: 9, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.24))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.025 : 0.045))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.05), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedTeams.isEmpty ? "Add favorite teams" : "Manage favorite teams")
    }
}

private struct PremiumTeamIdentityOrb: View {
    let team: FavoriteTeam
    let diameter: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(team.badgeColor.opacity(0.18))
                .frame(width: diameter, height: diameter)
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.11), lineWidth: 1)
                }

            Text(team.initials)
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.86))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityLabel("\(team.name), \(team.sport.chipTitle)")
    }
}

// MARK: - Matte profile background

private struct MatteIdentityHeaderBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geo in
            ZStack {
                matteBase
                subtleTexture(in: geo.size)
            }
        }
        .clipped()
    }

    private var matteBase: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.045, green: 0.055, blue: 0.06),
                    Color(red: 0.025, green: 0.032, blue: 0.045)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.12 : 0.08),
                    Color.clear
                ],
                center: .init(x: 0.18, y: 0.02),
                startRadius: 2,
                endRadius: 145
            )

            RadialGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.05 : 0.08),
                    Color.clear
                ],
                center: .init(x: 0.82, y: 0.0),
                startRadius: 1,
                endRadius: 110
            )
        }
    }

    private func subtleTexture(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let light = Color.white.opacity(colorScheme == .dark ? 0.018 : 0.014)
            let glow = FGColor.accentGreen.opacity(0.035)
            for index in 0..<10 {
                let x = CGFloat(index * 43).truncatingRemainder(dividingBy: max(canvasSize.width, 1))
                let y = CGFloat((index * 19) + 9).truncatingRemainder(dividingBy: max(canvasSize.height, 1))
                context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1, height: 1)), with: .color(light))
            }
            for index in 0..<3 {
                let y = CGFloat(index) * 18 + 10
                var path = Path()
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y + 12))
                context.stroke(path, with: .color(glow), lineWidth: 0.7)
            }
        }
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
    }
}
