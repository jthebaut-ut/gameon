import SwiftUI

/// Unified Account-tab “Profile & Identity” card: stadium hero, stats, fan level, and favorite teams in one surface.
struct ProfileIdentityCard: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showProfileScreen: Bool
    @EnvironmentObject private var chatViewModel: ChatViewModel
    @Environment(\.colorScheme) private var colorScheme

    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @State private var showFavoriteTeamsPicker = false
    @State private var showHandleSetup = false

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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.needsFanHandleSelection && !viewModel.needsBlockingFanIdentitySetup {
                handlePromptBanner
            }
            heroBlock
            fanLevelSection
                .padding(.horizontal, 12)
                .padding(.top, 8)
            favoriteTeamsSection
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 10)
        }
        .background {
            Color(red: 0.04, green: 0.05, blue: 0.07)
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(colorScheme == .dark ? 0.16 : 0.32),
                            Color.white.opacity(colorScheme == .dark ? 0.05 : 0.1)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.12), radius: 14, y: 6)
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
        .padding(.horizontal, 12)
        .padding(.top, 10)
    }

    // MARK: - Hero (stadium header + stats)

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)

            statsRow
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
        }
        .background { stadiumHeroBackground }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 20,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 20,
                style: .continuous
            )
        )
    }

    private var headerRow: some View {
        Button {
            showProfileScreen = true
        } label: {
            HStack(alignment: .center, spacing: 11) {
                UserAvatarView(
                    avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                    avatarURL: viewModel.currentUserAvatarURL,
                    avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                    displayName: displayName,
                    email: viewModel.currentUserEmail,
                    size: 56,
                    fallbackStyle: .darkCardTranslucent,
                    imagePlaceholderTint: .white
                )
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.42), lineWidth: 2)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)

                    Text(handleLine)
                        .font(.system(size: 13, weight: .regular, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                fanLevelBadge
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit profile")
    }

    private var fanXP: FanXPState {
        viewModel.currentUserFanXP
    }

    private var fanLevelBadge: some View {
        Text("Level \(fanXP.level)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background {
                Capsule(style: .continuous)
                    .fill(FGColor.accentGreen.opacity(0.14))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(0.55), lineWidth: 1)
            }
    }

    private var stadiumHeroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.09, blue: 0.13),
                    Color(red: 0.03, green: 0.11, blue: 0.08),
                    Color(red: 0.04, green: 0.06, blue: 0.09)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.94, blue: 0.78).opacity(0.34),
                    Color.clear
                ],
                center: .init(x: 0.2, y: 0.0),
                startRadius: 2,
                endRadius: 120
            )
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.94, blue: 0.78).opacity(0.28),
                    Color.clear
                ],
                center: .init(x: 0.82, y: 0.0),
                startRadius: 2,
                endRadius: 115
            )

            RadialGradient(
                colors: [
                    Color(red: 0.14, green: 0.58, blue: 0.30).opacity(0.55),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 1.0),
                startRadius: 10,
                endRadius: 180
            )

            Image(systemName: "sportscourt.fill")
                .font(.system(size: 96, weight: .ultraLight))
                .foregroundStyle(.white.opacity(0.1))
                .offset(y: -22)

            LinearGradient(
                colors: [
                    Color.black.opacity(0.2),
                    Color.black.opacity(0.55)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(value: gamesWatchedValue, label: "Games Watched")
            statCell(value: venuesVisitedValue, label: "Venues Visited")
            statCell(value: pickupGamesValue, label: "Pickup Games")
            statCell(value: friendsValue, label: "Friends")
        }
    }

    private var gamesWatchedValue: String {
        let n = viewModel.followingTabGoingItems.count
        return n > 0 ? "\(n)" : "—"
    }

    private var venuesVisitedValue: String {
        let n = max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
        return n > 0 ? "\(n)" : "—"
    }

    private var pickupGamesValue: String {
        let n = viewModel.myPickupGameJoinRequestCards.count + viewModel.myPickupGamesForSettings.count
        return n > 0 ? "\(n)" : "—"
    }

    private var friendsValue: String {
        let n = chatViewModel.friends.count
        return n > 0 ? "\(n)" : "—"
    }

    private func statCell(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.52))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Fan level

    private var fanLevelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
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
                .shadow(color: FGColor.accentGreen.opacity(0.35), radius: 5)

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
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.09))
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.black.opacity(0.38))
                }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
    }

    // MARK: - Favorite teams

    private var favoriteTeamsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center) {
                Text("Favorite Teams")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                Spacer(minLength: 0)
                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    Text(selectedTeams.isEmpty ? "Add Teams" : "Edit Teams")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)
                }
                .buttonStyle(.plain)
            }

            Button {
                showFavoriteTeamsPicker = true
            } label: {
                favoriteTeamsRow
            }
            .buttonStyle(.plain)
            .accessibilityLabel(selectedTeams.isEmpty ? "Add favorite teams" : "Edit favorite teams")
        }
    }

    private var favoriteTeamsRow: some View {
        HStack(spacing: 10) {
            if selectedTeams.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(FGColor.accentGreen.opacity(0.9))
                    Text("Add your teams")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.72))
                }
                Spacer(minLength: 0)
            } else {
                let visible = Array(selectedTeams.prefix(3))
                let overflow = selectedTeams.count - visible.count
                ForEach(visible) { team in
                    FavoriteTeamLogoBadge(team: team, diameter: 34)
                }
                if overflow > 0 {
                    Text("+\(overflow)")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 34, height: 34)
                        .background {
                            Circle()
                                .fill(Color.white.opacity(0.12))
                        }
                        .overlay {
                            Circle()
                                .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                        }
                }
                Spacer(minLength: 0)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.35))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.05 : 0.08))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
        }
    }
}
