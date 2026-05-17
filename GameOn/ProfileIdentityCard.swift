import SwiftUI
import UIKit

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

    private var fanXP: FanXPState {
        viewModel.currentUserFanXP
    }

    private var savedVenueCount: Int {
        max(viewModel.favoriteVenueIDs.count, viewModel.followingTabSavedVenues.count)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if viewModel.needsFanHandleSelection && !viewModel.needsBlockingFanIdentitySetup {
                handlePromptBanner
            }

            heroBlock

            integratedDivider

            fanLevelSection
                .padding(.horizontal, 14)
                .padding(.top, 12)

            integratedDivider
                .padding(.top, 12)

            favoriteTeamsSection
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 14)
        }
        .background(cardShellBackground)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(cardBorder)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.5 : 0.16), radius: 20, y: 10)
        .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.12 : 0.06), radius: 28, y: 4)
        .onAppear {
#if DEBUG
            print("[ProfileIdentityCardDebug] layout=stadium_identity_card")
#endif
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
            Color(red: 0.03, green: 0.04, blue: 0.06)
            LinearGradient(
                colors: [
                    Color(red: 0.05, green: 0.08, blue: 0.06).opacity(0.55),
                    Color(red: 0.03, green: 0.04, blue: 0.07)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        }
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(colorScheme == .dark ? 0.22 : 0.38),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.28 : 0.18),
                        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.12)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }

    private var integratedDivider: some View {
        Rectangle()
            .fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.02),
                        Color.white.opacity(colorScheme == .dark ? 0.1 : 0.14),
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

    // MARK: - Hero (stadium header + stats)

    private var heroBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerRow
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 10)

            quickActionRow
                .padding(.horizontal, 14)
                .padding(.bottom, 12)

            statsRow
                .padding(.horizontal, 8)
                .padding(.bottom, 14)
        }
        .background { StadiumIdentityBackground() }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: 22,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 22,
                style: .continuous
            )
        )
    }

    private var headerRow: some View {
        Button {
            showProfileScreen = true
        } label: {
            HStack(alignment: .center, spacing: 14) {
                avatarStack

                VStack(alignment: .leading, spacing: 5) {
                    Text("FanGeo profile")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)
                        .shadow(color: FGColor.accentGreen.opacity(0.35), radius: 4)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(displayName)
                            .font(.system(size: 26, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .shadow(color: .black.opacity(0.45), radius: 6, y: 2)

                        fanLevelBadge
                    }

                    Text(handleLine)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }

                Spacer(minLength: 72)
            }
            .padding(.trailing, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit profile")
    }

    private var avatarStack: some View {
        ZStack(alignment: .bottomTrailing) {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            FGColor.accentGreen.opacity(0.42),
                            FGColor.accentGreen.opacity(0.08),
                            Color.clear
                        ],
                        center: .center,
                        startRadius: 8,
                        endRadius: 44
                    )
                )
                .frame(width: 78, height: 78)
                .blur(radius: 2)
                .offset(y: -2)

            UserAvatarView(
                avatarThumbnailURL: viewModel.currentUserAvatarThumbnailURL,
                avatarURL: viewModel.currentUserAvatarURL,
                avatarDisplayRefreshToken: viewModel.currentUserAvatarDisplayRefreshToken,
                displayName: displayName,
                email: viewModel.currentUserEmail,
                size: 64,
                fallbackStyle: .darkCardTranslucent,
                imagePlaceholderTint: .white
            )
            .overlay {
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(0.65),
                                FGColor.accentGreen.opacity(0.45)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 2.5
                    )
            }
            .shadow(color: FGColor.accentGreen.opacity(0.38), radius: 12, y: 2)
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)

            Circle()
                .fill(FGColor.accentGreen)
                .frame(width: 22, height: 22)
                .overlay {
                    Image(systemName: "pencil")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 0.04, green: 0.06, blue: 0.08))
                }
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.35), lineWidth: 1)
                }
                .offset(x: 2, y: 2)
        }
    }

    private var fanLevelBadge: some View {
        Text("Level \(fanXP.level)")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(FGColor.accentGreen.opacity(0.16))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(FGColor.accentGreen.opacity(0.65), lineWidth: 1)
            }
            .shadow(color: FGColor.accentGreen.opacity(0.35), radius: 6)
    }

    private var quickActionRow: some View {
        HStack(spacing: 10) {
            quickActionPill(title: "User account", systemImage: "person.crop.circle") {
                showProfileScreen = true
            }

            quickActionPill(
                title: savedVenueCount == 1 ? "1 saved venue" : "\(savedVenueCount) saved venues",
                systemImage: "mappin.circle.fill",
                accentDot: savedVenueCount > 0
            ) {
                showProfileScreen = true
            }
        }
    }

    private func quickActionPill(
        title: String,
        systemImage: String,
        accentDot: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text(title)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if accentDot {
                    Circle()
                        .fill(FGColor.accentYellow)
                        .frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.1 : 0.14))
                    .background {
                        Capsule(style: .continuous)
                            .fill(Color.black.opacity(0.28))
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    // MARK: - Stats

    private var statsRow: some View {
        HStack(spacing: 0) {
            statCell(value: gamesWatchedValue, label: "Games Watched", icon: "sportscourt.fill")
            statDivider
            statCell(value: venuesVisitedValue, label: "Venues Visited", icon: "mappin.and.ellipse")
            statDivider
            statCell(value: pickupGamesValue, label: "Pickup Games", icon: "figure.run")
            statDivider
            statCell(value: friendsValue, label: "Friends", icon: "person.2.fill")
        }
        .padding(.vertical, 10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.22))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
        }
        .padding(.horizontal, 6)
    }

    private var statDivider: some View {
        Rectangle()
            .fill(Color.white.opacity(0.12))
            .frame(width: 1)
            .padding(.vertical, 8)
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

    private func statCell(value: String, label: String, icon: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(FGColor.accentGreen)
                .shadow(color: FGColor.accentGreen.opacity(0.45), radius: 4)

            Text(value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(label)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Fan level

    private var fanLevelSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Fan Level")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white.opacity(0.9))

            HStack(spacing: 14) {
                fanLevelRing

                VStack(alignment: .leading, spacing: 6) {
                    Text("Level \(fanXP.level) · \(fanXP.title)")
                        .font(.system(size: 13, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)

                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.18))
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            FGColor.accentGreen,
                                            FGColor.accentGreen.opacity(0.72)
                                        ],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(width: max(0, geo.size.width * fanXP.progressFraction))
                                .shadow(color: FGColor.accentGreen.opacity(0.5), radius: 4)
                        }
                    }
                    .frame(height: 6)

                    Text(fanXP.xpRangeLine)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen.opacity(0.9))

                    Text(fanXP.progressLine)
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(colorScheme == .dark ? 0.45 : 0.55))
                }
            }
        }
    }

    private var fanLevelRing: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 4)
                .frame(width: 56, height: 56)

            Circle()
                .trim(from: 0, to: fanXP.progressFraction)
                .stroke(
                    LinearGradient(
                        colors: [FGColor.accentGreen, FGColor.accentGreen.opacity(0.65)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 56, height: 56)
                .shadow(color: FGColor.accentGreen.opacity(0.45), radius: 6)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            FGColor.accentGreen.opacity(0.22),
                            Color(red: 0.06, green: 0.08, blue: 0.1)
                        ],
                        center: .center,
                        startRadius: 4,
                        endRadius: 28
                    )
                )
                .frame(width: 46, height: 46)

            Image(systemName: "soccerball")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: FGColor.accentGreen.opacity(0.35), radius: 4)
        }
    }

    // MARK: - Favorite teams

    private var favoriteTeamsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                Text("Favorite Teams")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                Spacer(minLength: 0)
                Button {
                    showFavoriteTeamsPicker = true
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .bold))
                        Text(selectedTeams.isEmpty ? "Add Teams" : "Edit Teams")
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(FGColor.accentGreen)
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

        return HStack(alignment: .top, spacing: 12) {
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
        VStack(spacing: 5) {
            ZStack(alignment: .bottomTrailing) {
                FavoriteTeamLogoBadge(team: team, diameter: 44)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .background(Circle().fill(Color(red: 0.04, green: 0.05, blue: 0.07)))
                    .offset(x: 3, y: 3)
            }

            Text(team.name)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
                .lineLimit(1)
                .frame(maxWidth: 72)

            Text(team.sport.chipTitle)
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
                .lineLimit(1)
        }
        .frame(width: 72)
    }

    private func moreTeamsBadge(count: Int) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .strokeBorder(
                        FGColor.accentGreen.opacity(0.55),
                        style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])
                    )
                    .frame(width: 44, height: 44)
                Text("+\(count)")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.accentGreen)
            }

            Text("More")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))
            Text("Teams")
                .font(.system(size: 9, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.48))
        }
        .frame(width: 72)
    }

    private var addTeamsRow: some View {
        Button {
            showFavoriteTeamsPicker = true
        } label: {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FGColor.accentGreen.opacity(0.16))
                        .frame(width: 32, height: 32)
                    Image(systemName: "plus")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(FGColor.accentGreen)
                }

                Text(selectedTeams.isEmpty ? "Add your teams" : "Manage your teams")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.82))

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.35))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.1))
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.1), lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selectedTeams.isEmpty ? "Add favorite teams" : "Manage favorite teams")
    }
}

// MARK: - Stadium hero background (real image + generated fallback)

private struct StadiumIdentityBackground: View {
    static let assetName = "StadiumHeroBackground"

    @Environment(\.colorScheme) private var colorScheme
    @State private var useGeneratedFallback = false
    @State private var shimmerOffset: CGFloat = -0.4

    var body: some View {
        GeometryReader { geo in
            ZStack {
                heroPhotographyLayer(in: geo.size)
                cinematicOverlayStack
                logoWatermark
                shimmerSweep(in: geo.size)
            }
        }
        .clipped()
        .onAppear {
            // Asset must be stadium photography only — never a UI mockup/screenshot.
            useGeneratedFallback = UIImage(named: Self.assetName) == nil
#if DEBUG
            if useGeneratedFallback {
                print("[ProfileIdentityCardDebug] stadiumHero=generated_fallback")
            } else {
                print("[ProfileIdentityCardDebug] stadiumHero=real_image asset=\(Self.assetName)")
            }
            print("[ProfileIdentityCardDebug] logoWatermark=FanGeoLogoWhite_overlay")
#endif
            withAnimation(.linear(duration: 5.2).repeatForever(autoreverses: false)) {
                shimmerOffset = 1.35
            }
        }
    }

    @ViewBuilder
    private func heroPhotographyLayer(in size: CGSize) -> some View {
        if useGeneratedFallback {
            GeneratedStadiumFallbackBackground()
        } else {
            Image(Self.assetName)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .blur(radius: 0.8)
                .clipped()
        }
    }

    private var cinematicOverlayStack: some View {
        ZStack {
            Color.black.opacity(colorScheme == .dark ? 0.34 : 0.28)

            RadialGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.16),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0.88),
                startRadius: 12,
                endRadius: 220
            )

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.96, blue: 0.84).opacity(0.2),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0.0),
                startRadius: 4,
                endRadius: 180
            )

            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.55 : 0.42),
                    Color.black.opacity(0.12),
                    Color.black.opacity(colorScheme == .dark ? 0.68 : 0.52)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            RadialGradient(
                colors: [
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.62 : 0.45)
                ],
                center: .center,
                startRadius: 40,
                endRadius: 320
            )
        }
    }

    private var logoWatermark: some View {
        VStack {
            HStack {
                Spacer(minLength: 0)
                Image("FanGeoLogoWhite")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 170)
                    .opacity(colorScheme == .dark ? 0.18 : 0.16)
                    .blur(radius: 0.25)
                    .shadow(color: .white.opacity(0.12), radius: 14)
                    .shadow(color: FGColor.accentGreen.opacity(0.08), radius: 18)
                    .padding(.top, 8)
                    .padding(.trailing, 6)
                    .allowsHitTesting(false)
            }
            Spacer(minLength: 0)
        }
    }

    private func shimmerSweep(in size: CGSize) -> some View {
        LinearGradient(
            colors: [
                Color.clear,
                Color.white.opacity(colorScheme == .dark ? 0.07 : 0.05),
                Color.clear
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .frame(width: size.width * 0.42)
        .rotationEffect(.degrees(14))
        .offset(x: shimmerOffset * size.width)
        .blendMode(.screen)
        .allowsHitTesting(false)
    }
}

/// Procedural stadium art used when ``StadiumIdentityBackground`` asset is unavailable.
private struct GeneratedStadiumFallbackBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.04, green: 0.07, blue: 0.12),
                    Color(red: 0.03, green: 0.10, blue: 0.08),
                    Color(red: 0.02, green: 0.05, blue: 0.07)
                ],
                startPoint: .top,
                endPoint: .bottom
            )

            fieldLayer

            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.95, blue: 0.82).opacity(colorScheme == .dark ? 0.38 : 0.28),
                    Color.clear
                ],
                center: .init(x: 0.18, y: 0.0),
                startRadius: 4,
                endRadius: 140
            )
            RadialGradient(
                colors: [
                    Color(red: 1.0, green: 0.95, blue: 0.82).opacity(colorScheme == .dark ? 0.32 : 0.22),
                    Color.clear
                ],
                center: .init(x: 0.82, y: 0.0),
                startRadius: 4,
                endRadius: 135
            )

            RadialGradient(
                colors: [
                    Color(red: 0.12, green: 0.62, blue: 0.34).opacity(0.5),
                    Color.clear
                ],
                center: .init(x: 0.5, y: 0.92),
                startRadius: 8,
                endRadius: 200
            )

            stadiumCrowdSilhouette
        }
    }

    private var fieldLayer: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.10, green: 0.42, blue: 0.24).opacity(0.85),
                                Color(red: 0.06, green: 0.32, blue: 0.18).opacity(0.9)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .frame(width: w * 0.92, height: h * 0.42)
                    .offset(y: h * 0.08)

                fieldMarkings(in: CGSize(width: w * 0.92, height: h * 0.42))
                    .offset(y: h * 0.08)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func fieldMarkings(in size: CGSize) -> some View {
        Canvas { context, canvasSize in
            let lineColor = Color.white.opacity(0.22)
            var path = Path()
            let midX = canvasSize.width / 2
            let midY = canvasSize.height / 2

            path.addRect(CGRect(x: 8, y: 8, width: canvasSize.width - 16, height: canvasSize.height - 16))
            path.move(to: CGPoint(x: midX, y: 8))
            path.addLine(to: CGPoint(x: midX, y: canvasSize.height - 8))
            path.addEllipse(in: CGRect(x: midX - 28, y: midY - 28, width: 56, height: 56))
            path.addRect(CGRect(x: midX - 70, y: 8, width: 140, height: 52))
            path.addRect(CGRect(x: midX - 70, y: canvasSize.height - 60, width: 140, height: 52))

            context.stroke(path, with: .color(lineColor), lineWidth: 1.2)
        }
        .frame(width: size.width, height: size.height)
    }

    private var stadiumCrowdSilhouette: some View {
        VStack {
            HStack(spacing: 3) {
                ForEach(0..<24, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.white.opacity(0.04 + Double(i % 3) * 0.02))
                        .frame(width: 8, height: CGFloat(10 + (i % 5) * 3))
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 6)
            Spacer()
        }
    }
}
