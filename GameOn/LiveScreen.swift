import SwiftUI

struct LiveScreen: View {
    private static let liveAutoRefreshIntervalNanoseconds: UInt64 = 15_000_000_000

    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var chatViewModel: ChatViewModel
    @Binding var selectedTab: MainTabView.AppTab

    @AppStorage(FavoriteTeamsStore.appStorageKey) private var favoriteTeamIDsRaw: String = ""
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @State private var showVenueDetails = false
    @State private var showVenueRatingSheet = false
    @State private var fanFeatureGateAlertMessage: String?
    @State private var liveIndicatorPulse = false
    @State private var liveAutoRefreshTask: Task<Void, Never>?

    private struct LiveFeedItem: Identifiable {
        let id: String
        let bar: BarVenue
        let event: SportsEvent
        let venueEventID: UUID?
        let energy: FanGeoLiveEnergy
        let score: Int
        let vibeCount: Int
        let topVibeText: String?
    }

    private enum FeaturedLiveType: String {
        case liveGame
        case eventStartingSoon
        case crowdBuilding
        case friendsGoing
        case fansChatting
        case pickupNeedsPlayers
        case empty
    }

    private enum FeaturedLiveSource {
        case liveMatch(LiveMatch)
        case liveItem(LiveFeedItem)
        case pickupGame(PickupGameRow)
        case empty
    }

    private struct FeaturedLive {
        let type: FeaturedLiveType
        let title: String
        let subtitle: String
        let tokens: [String]
        let score: Int
        let source: FeaturedLiveSource
        let eventID: UUID?
        let venueID: UUID?
        let venuePhotoURL: String?
        let socialProfiles: [UserProfileRow]
        let rawGoingProfilesCount: Int

        var liveItem: LiveFeedItem? {
            if case .liveItem(let item) = source {
                return item
            }
            return nil
        }
    }

    fileprivate struct FavoriteTeamLiveItem: Identifiable {
        let id: String
        let team: FavoriteTeam
        let title: String
        let leagueSportText: String
        let statusText: String
        let isLiveNow: Bool
        let startsSoon: Bool
        let nearbyFanCount: Int
        let nearbyVenueCount: Int
        let friendGoingCount: Int
        let activityCount: Int
        let score: Int
        let startDate: Date?

        var socialTokens: [String] {
            var tokens: [String] = []
            if nearbyFanCount > 0 {
                tokens.append(nearbyFanCount == 1 ? "1 fan going nearby" : "\(nearbyFanCount) fans going nearby")
            }
            if nearbyVenueCount > 0 {
                tokens.append(nearbyVenueCount == 1 ? "1 venue showing" : "\(nearbyVenueCount) venues showing")
            }
            if friendGoingCount > 0 {
                tokens.append(friendGoingCount == 1 ? "1 friend going" : "\(friendGoingCount) friends going")
            }
            if activityCount > 0 {
                tokens.append(activityCount == 1 ? "1 crowd update" : "\(activityCount) crowd updates")
            }
            return tokens
        }
    }

    private var acceptedFriendUserIDs: Set<UUID> {
        guard viewModel.canUseFanSocialFeatures else { return [] }
        return Set(chatViewModel.friendshipChipByOtherUserId.compactMap { userID, kind in
            kind == .friends ? userID : nil
        })
    }

    private var isBusinessLiveAudienceUser: Bool {
        viewModel.currentUserIsBusinessAccount || viewModel.isVenueOwnerLoggedIn || viewModel.hasAuthenticatedVenueOwnerSession
    }

    private var canShowPersonalLiveSections: Bool {
        viewModel.canUseFanSocialFeatures
    }

    private var displayedLiveMatches: [LiveMatch] {
        viewModel.liveTabLiveMatchesDisplayed(searchQuery: "")
    }

    private var shouldAutoRefreshLiveMatches: Bool {
        selectedTab == .live && scenePhase == .active
    }

    var body: some View {
        liveFeedLayer
            .sheet(isPresented: Binding(
                get: {
                    showVenueDetails
                        && viewModel.selectedBar != nil
                        && (viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode)
                },
                set: { if !$0 { showVenueDetails = false } }
            )) {
                liveVenueDetailSheet()
            }
            .sheet(isPresented: Binding(
                get: { showVenueRatingSheet && viewModel.canRateVenues && viewModel.isAuthenticatedForSocialFeatures && viewModel.selectedBar != nil },
                set: { if !$0 { showVenueRatingSheet = false } }
            )) {
                if let bar = viewModel.selectedBar {
                    VenueUserRatingSheet(viewModel: viewModel, bar: bar)
                }
            }
            .alert(
                "FanGeo",
                isPresented: Binding(
                    get: { fanFeatureGateAlertMessage != nil },
                    set: { if !$0 { fanFeatureGateAlertMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    fanFeatureGateAlertMessage = nil
                }
            } message: {
                Text(fanFeatureGateAlertMessage ?? "")
            }
            .onAppear {
                logLiveFeedRefresh(reason: "appear")
                logLiveAudienceDebug()
                updateLiveAutoRefreshForCurrentState(immediatelyRefresh: true)
            }
            .onDisappear {
                stopLiveAutoRefresh()
            }
            .onChange(of: selectedTab) { _, _ in
                updateLiveAutoRefreshForCurrentState(immediatelyRefresh: true)
            }
            .onChange(of: scenePhase) { _, phase in
                updateLiveAutoRefreshForCurrentState(immediatelyRefresh: phase == .active)
            }
    }

    private var liveFeedLayer: some View {
        let showPersonalLiveSections = canShowPersonalLiveSections
        let rankedItems = liveRankedItems
        let happeningNow = Array(rankedItems.filter { $0.energy.isLiveNow }.prefix(8))
        let startingSoon = Array(rankedItems.filter { !$0.energy.isLiveNow && $0.energy.startsSoon }.prefix(6))
        let friendsGoing = showPersonalLiveSections ? Array(rankedItems.filter { $0.energy.friendGoingCount > 0 }.prefix(6)) : []
        let crowdBuilding = Array(rankedItems.filter { $0.energy.goingCount >= 8 && !$0.energy.isLiveNow }.prefix(6))
        let fansChatting = showPersonalLiveSections ? Array(rankedItems.filter { $0.energy.commentCount > 0 }.prefix(6)) : []
        let featuredLive = featuredLiveCard(
            rankedItems: rankedItems,
            matches: displayedLiveMatches,
            pickupGames: viewModel.pickupGamesForDiscoverMap
        )
        let favoriteTeamItems = showPersonalLiveSections ? favoriteTeamsLiveItems(rankedItems: rankedItems) : []
        let visibleSectionCount = visibleLiveSectionCount(
            matches: displayedLiveMatches,
            happeningNow: happeningNow,
            startingSoon: startingSoon,
            friendsGoing: friendsGoing,
            crowdBuilding: crowdBuilding,
            fansChatting: fansChatting
        )
        let _: Void = logLiveFeedSnapshot(
            happeningNowCount: happeningNow.count,
            startingSoonCount: startingSoon.count,
            friendsGoingCount: friendsGoing.count
        )
        let _: Void = logLivePolishSnapshot(featuredLive: featuredLive, visibleSectionCount: visibleSectionCount)

        return ZStack {
            liveBackground

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 22) {
                    liveHeroHeader(totalCount: rankedItems.count)

                    liveFeaturedCard(featuredLive)
                    if showPersonalLiveSections {
                        FavoriteTeamsLiveSection(
                            items: favoriteTeamItems,
                            hasFavoriteTeams: !favoriteTeams.isEmpty,
                            onWatchNearby: { _ in
                                selectedTab = .discover
                            }
                        )
                    }
                    liveGamesSection(matches: displayedLiveMatches, rankedItems: rankedItems)
                    liveHappeningNowSection(items: happeningNow)
                    liveStartingSoonSection(items: startingSoon)
                    if showPersonalLiveSections {
                        liveFriendsSection(items: friendsGoing)
                    }
                    if !crowdBuilding.isEmpty {
                        liveCompactSection(
                            title: "Crowd Building",
                            subtitle: isBusinessLiveAudienceUser ? "Events building venue activity" : "Events gaining fan momentum",
                            items: crowdBuilding
                        )
                    }
                    if !fansChatting.isEmpty {
                        liveCompactSection(title: "Fans Chatting", subtitle: "Where the conversation is active", items: fansChatting)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 76)
                .padding(.bottom, 112)
            }
            .refreshable {
                await MainActor.run {
                    refreshLiveMatches(forceRefresh: true)
                }
            }
        }
        .ignoresSafeArea()
    }

    private var liveBackground: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.02, green: 0.035, blue: 0.045),
                    Color(red: 0.045, green: 0.065, blue: 0.085),
                    Color(red: 0.018, green: 0.028, blue: 0.036)
                ]
                : [
                    Color(red: 0.94, green: 0.97, blue: 0.965),
                    Color(red: 0.985, green: 0.995, blue: 0.99)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.10))
                .frame(width: 260, height: 260)
                .blur(radius: 58)
                .offset(x: 110, y: 80)
        }
        .overlay(alignment: .bottomLeading) {
            Circle()
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.07))
                .frame(width: 240, height: 240)
                .blur(radius: 62)
                .offset(x: -120, y: -80)
        }
    }

    private func liveHeroHeader(totalCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live")
                .font(.system(size: 36, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text(liveHeroSubtitle(totalCount: totalCount))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 4)
    }

    private func liveHeroSubtitle(totalCount: Int) -> String {
        if isBusinessLiveAudienceUser {
            return totalCount > 0
                ? "Operational live signals for games and venues around you."
                : "Live games and nearby venue activity will appear here."
        }
        return totalCount > 0
            ? "What feels alive in sports around you right now."
            : "Live updates appear as fans go, chat, and react."
    }

    private func liveFeaturedCard(_ featured: FeaturedLive) -> some View {
        liveFeaturedCardContent(featured, item: featured.liveItem)
            .contentShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
            .onTapGesture {
                openFeaturedLive(featured)
            }
            .task(id: featured.eventID) {
                guard let id = featured.eventID else { return }
                await MainActor.run {
                    viewModel.prefetchFanUpdatesCardSocialData(for: id)
                }
            }
        .onAppear {
            liveIndicatorPulse = true
        }
    }

    private func liveFeaturedCardContent(_ featured: FeaturedLive, item: LiveFeedItem?) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 10) {
                featuredLiveBadge(featured.type)
                Spacer(minLength: 8)
                if featured.type != .empty {
                    liveDot
                }
                featuredVenuePhoto(featured)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(featured.title)
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(featured.subtitle)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !featured.tokens.isEmpty {
                FGWrappingLayout(horizontalSpacing: 7, verticalSpacing: 7) {
                    ForEach(featured.tokens, id: \.self) { token in
                        liveToken(token)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if featuredShouldShowSocialLine(featured, item: item) {
                liveSocialPresenceLine(featured, item: item)
            }

            liveFeaturedActions(featured)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(liveFeaturedSurface(isActive: featured.type != .empty))
        .overlay(alignment: .topTrailing) {
            if featured.type != .empty {
                Circle()
                    .fill(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.16 : 0.09))
                    .frame(width: 118, height: 118)
                    .blur(radius: 28)
                    .offset(x: 34, y: -42)
                    .opacity(liveIndicatorPulse ? 0.88 : 0.48)
                    .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: liveIndicatorPulse)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 30, style: .continuous))
    }

    private func featuredLiveBadge(_ type: FeaturedLiveType) -> some View {
        Text(type == .empty ? "FEATURED LIVE" : "FEATURED LIVE")
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .tracking(0.5)
            .foregroundStyle(type == .empty ? FGColor.secondaryText(colorScheme) : FGColor.dangerRed)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                Capsule(style: .continuous)
                    .fill((type == .empty ? Color.primary : FGColor.dangerRed).opacity(colorScheme == .dark ? 0.13 : 0.08))
            )
    }

    @ViewBuilder
    private func featuredVenuePhoto(_ featured: FeaturedLive) -> some View {
        if let raw = featured.venuePhotoURL, let url = URL(string: raw) {
            DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08))
                    .overlay {
                        Image(systemName: "building.2.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
            }
            .frame(width: 58, height: 58)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.58), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.10), radius: 10, y: 5)
        }
    }

    private func featuredShouldShowSocialLine(_ featured: FeaturedLive, item: LiveFeedItem?) -> Bool {
        canShowPersonalLiveSections
            && (!featured.socialProfiles.isEmpty || (item?.energy.goingCount ?? 0) > 0 || (item?.energy.friendGoingCount ?? 0) > 0)
    }

    private func liveSocialPresenceLine(_ featured: FeaturedLive, item: LiveFeedItem?) -> some View {
        let profiles = featured.socialProfiles
        return HStack(spacing: 8) {
            if !profiles.isEmpty {
                GoingAvatarStack(profiles: profiles, viewerUserID: viewModel.currentUserAuthId)
            }

            Text(featuredSocialPresenceText(featured, item: item))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func featuredSocialPresenceText(_ featured: FeaturedLive, item: LiveFeedItem?) -> String {
        guard let item else {
            let count = featured.socialProfiles.count
            return count == 1 ? "1 fan going" : "\(count) fans going"
        }
        if let label = item.energy.socialPresenceLabel {
            return label
        }
        if let label = item.energy.friendPresenceLabel, item.energy.friendGoingCount > 0 {
            return label
        }
        if item.energy.goingCount > 0 {
            return item.energy.goingCount == 1 ? "1 fan going" : "\(item.energy.goingCount) fans going"
        }
        return liveSocialPresenceText(item)
    }

    private func liveSocialPresenceText(_ item: LiveFeedItem) -> String {
        if let label = item.energy.socialPresenceLabel {
            return label
        }
        if canShowPersonalLiveSections && item.energy.friendGoingCount > 0 {
            return item.energy.friendPresenceLabel ?? "\(item.energy.friendGoingCount) friends going"
        }
        if item.energy.commentCount > 0 {
            return item.energy.commentCount == 1 ? "1 fan chatting" : "\(item.energy.commentCount) fans chatting"
        }
        if item.energy.goingCount >= 8 {
            return "Crowd building"
        }
        if item.energy.goingCount > 0 {
            return item.energy.goingCount == 1 ? "1 fan going" : "\(item.energy.goingCount) fans going"
        }
        return item.energy.energySubtitle ?? "Live updates appear as fans go, chat, and react."
    }

    private func liveOperationalSubtitle(for item: LiveFeedItem) -> String {
        guard isBusinessLiveAudienceUser else {
            return item.energy.energySubtitle ?? "Watch party active"
        }
        if item.energy.isLiveNow {
            return "Watch party active"
        }
        if item.energy.startsSoon, let minutes = item.energy.minutesUntilStart {
            return "Starts in \(minutes) min"
        }
        if item.energy.goingCount >= 8 {
            return "Crowd building"
        }
        if item.energy.goingCount > 0 {
            return "Venue activity signal"
        }
        return "Venue activity signal"
    }

    private func liveEnergyForCurrentAudience(_ energy: FanGeoLiveEnergy) -> FanGeoLiveEnergy {
        guard isBusinessLiveAudienceUser else { return energy }
        return FanGeoLiveEnergy(
            isLiveNow: energy.isLiveNow,
            startsSoon: energy.startsSoon,
            minutesUntilStart: energy.minutesUntilStart,
            goingCount: energy.goingCount,
            commentCount: 0,
            friendGoingCount: 0,
            friendAvatarURLs: [],
            mutualTeamLabel: nil,
            energyLabel: energy.energyLabel,
            energySubtitle: businessLiveEnergySubtitle(for: energy),
            friendPresenceLabel: nil,
            friendProfiles: [],
            socialPresenceProfiles: [],
            socialPresenceLabel: nil
        )
    }

    private func businessLiveEnergySubtitle(for energy: FanGeoLiveEnergy) -> String? {
        if energy.isLiveNow {
            return "Watch party active"
        }
        if energy.startsSoon, let minutes = energy.minutesUntilStart {
            return "Starts in \(minutes) min"
        }
        if energy.goingCount >= 8 {
            return "Crowd building"
        }
        if energy.goingCount > 0 {
            return "Venue activity signal"
        }
        return energy.energyLabel == nil ? nil : "Venue activity signal"
    }

    private func liveFeaturedActions(_ featured: FeaturedLive) -> some View {
        HStack(spacing: 10) {
            Button {
                selectedTab = .discover
            } label: {
                liveFeaturedActionLabel("Open Map", systemImage: "map.fill", filled: true)
            }
            .buttonStyle(.plain)

            Button {
                selectedTab = .calendar
            } label: {
                liveFeaturedActionLabel("View Calendar", systemImage: "calendar", filled: false)
            }
            .buttonStyle(.plain)

            if viewModel.canFanUsePickupGamesUI {
                Button {
                    viewModel.calendarTabGameFilter = .pickupGames
                    selectedTab = .calendar
                } label: {
                    liveFeaturedActionLabel("Host Pickup Game", systemImage: "figure.run", filled: false)
                }
                .buttonStyle(.plain)
            }
        }
        .labelStyle(.titleAndIcon)
    }

    private func liveFeaturedActionLabel(_ title: String, systemImage: String, filled: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(filled ? Color.white : FGColor.primaryText(colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                Capsule(style: .continuous)
                    .fill(filled ? FGColor.accentGreen : Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
            )
    }

    private func liveFeaturedSurface(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 30, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.11) : Color.white.opacity(0.84))
            .overlay {
                RoundedRectangle(cornerRadius: 30, style: .continuous)
                    .strokeBorder(
                        FGColor.dangerRed.opacity(isActive ? (colorScheme == .dark ? 0.30 : 0.20) : 0.14),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.08), radius: 24, y: 14)
            .shadow(
                color: FGColor.dangerRed.opacity(isActive ? (liveIndicatorPulse ? 0.14 : 0.07) : 0),
                radius: isActive ? (liveIndicatorPulse ? 30 : 18) : 0,
                y: 0
            )
            .animation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true), value: liveIndicatorPulse)
    }

    private func liveGamesSection(matches: [LiveMatch], rankedItems: [LiveFeedItem]) -> some View {
        liveSection(title: "Live Games", subtitle: "Games happening now") {
            if viewModel.isLoadingLiveMatches && matches.isEmpty {
                liveGamesLoadingCard
            } else if matches.isEmpty {
                liveQuietEmptyLine("No live games nearby yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(matches) { match in
                        liveMatchCard(match, relatedItems: liveMatchRelatedItems(for: match, in: rankedItems))
                    }
                }
            }
        }
    }

    private var favoriteTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(from: favoriteTeamIDsRaw)
    }

    private func favoriteTeamsLiveItems(rankedItems: [LiveFeedItem]) -> [FavoriteTeamLiveItem] {
        favoriteTeams
            .compactMap { favoriteTeamLiveItem(for: $0, rankedItems: rankedItems) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
                }
                return lhs.score > rhs.score
            }
            .prefix(6)
            .map { $0 }
    }

    private func favoriteTeamLiveItem(for team: FavoriteTeam, rankedItems: [LiveFeedItem]) -> FavoriteTeamLiveItem? {
        let matchingMatches = viewModel.liveMatches
            .filter { liveMatchIsLiveOrStartingSoon($0) }
            .filter { favoriteTeamMatches(team, in: $0) }
            .sorted(by: favoriteTeamLiveMatchSort)
        let matchingVenueItems = rankedItems
            .filter { favoriteTeamMatches(team, in: $0.event) }
            .filter { item in
                item.energy.isLiveNow
                    || item.energy.startsSoon
                    || item.energy.goingCount > 0
                    || item.energy.friendGoingCount > 0
                    || item.energy.commentCount > 0
                    || item.vibeCount > 0
            }

        guard !matchingMatches.isEmpty || !matchingVenueItems.isEmpty else {
            return nil
        }

        let primaryMatch = matchingMatches.first
        let primaryVenueItem = matchingVenueItems.first
        let title = primaryMatch.map { "\($0.awayTeam) at \($0.homeTeam)" } ?? primaryVenueItem?.event.title ?? team.name
        let leagueSportText = favoriteTeamLeagueSportText(team: team, match: primaryMatch, item: primaryVenueItem)
        let liveNow = matchingMatches.contains { $0.matchStatus.isHappeningNow } || matchingVenueItems.contains { $0.energy.isLiveNow }
        let soonMinutes = favoriteTeamSoonMinutes(matches: matchingMatches, items: matchingVenueItems)
        let startsSoon = soonMinutes != nil || matchingVenueItems.contains { $0.energy.startsSoon }
        let statusText = favoriteTeamStatusText(isLiveNow: liveNow, soonMinutes: soonMinutes, match: primaryMatch)
        let nearbyVenueIDs = Set(matchingVenueItems.map(\.bar.id))
        let nearbyFanCount = matchingVenueItems.reduce(0) { $0 + $1.energy.goingCount }
        let friendCount = matchingVenueItems.reduce(0) { $0 + $1.energy.friendGoingCount }
        let activityCount = matchingVenueItems.reduce(0) { $0 + $1.energy.commentCount + $1.vibeCount }
        let startDate = primaryMatch?.startTime ?? primaryVenueItem?.event.date
        let score = favoriteTeamLiveScore(
            isLiveNow: liveNow,
            startsSoon: startsSoon,
            nearbyVenueCount: nearbyVenueIDs.count,
            nearbyFanCount: nearbyFanCount,
            friendGoingCount: friendCount,
            activityCount: activityCount
        )

        return FavoriteTeamLiveItem(
            id: team.id,
            team: team,
            title: title,
            leagueSportText: leagueSportText,
            statusText: statusText,
            isLiveNow: liveNow,
            startsSoon: startsSoon,
            nearbyFanCount: nearbyFanCount,
            nearbyVenueCount: nearbyVenueIDs.count,
            friendGoingCount: friendCount,
            activityCount: activityCount,
            score: score,
            startDate: startDate
        )
    }

    private func liveMatchIsLiveOrStartingSoon(_ match: LiveMatch) -> Bool {
        if match.matchStatus.isHappeningNow { return true }
        guard match.matchStatus == .scheduled else { return false }
        let secondsUntil = match.startTime.timeIntervalSince(Date())
        return secondsUntil > 0 && secondsUntil <= TimeInterval(FanGeoLiveEnergyTiming.startsSoonWindowMinutes * 60)
    }

    private func favoriteTeamLiveMatchSort(_ lhs: LiveMatch, _ rhs: LiveMatch) -> Bool {
        if lhs.matchStatus.isHappeningNow != rhs.matchStatus.isHappeningNow {
            return lhs.matchStatus.isHappeningNow
        }
        return lhs.startTime < rhs.startTime
    }

    private func favoriteTeamLeagueSportText(team: FavoriteTeam, match: LiveMatch?, item: LiveFeedItem?) -> String {
        let league = match?.league.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? item?.event.league.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? team.league
        let sport = match?.liveSportVisualType.displayLabel
            ?? trimmedSportLabel(item?.event.sport)
            ?? team.sport.chipTitle
        return [league, sport]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private func favoriteTeamSoonMinutes(matches: [LiveMatch], items: [LiveFeedItem]) -> Int? {
        let matchMinutes = matches
            .filter { $0.matchStatus == .scheduled }
            .compactMap { match -> Int? in
                let secondsUntil = match.startTime.timeIntervalSince(Date())
                guard secondsUntil > 0 else { return nil }
                return Int(ceil(secondsUntil / 60))
            }
        let itemMinutes = items.compactMap(\.energy.minutesUntilStart)
        return (matchMinutes + itemMinutes).min()
    }

    private func favoriteTeamStatusText(isLiveNow: Bool, soonMinutes: Int?, match: LiveMatch?) -> String {
        if isLiveNow {
            if let minute = match?.minute {
                return "LIVE \(minute)'"
            }
            return "LIVE NOW"
        }
        if let soonMinutes {
            return "Starts in \(soonMinutes) min"
        }
        if let match {
            return "Starts \(match.startTime.formatted(date: .omitted, time: .shortened))"
        }
        return "Starting soon"
    }

    private func favoriteTeamLiveScore(
        isLiveNow: Bool,
        startsSoon: Bool,
        nearbyVenueCount: Int,
        nearbyFanCount: Int,
        friendGoingCount: Int,
        activityCount: Int
    ) -> Int {
        (isLiveNow ? 100_000 : 0)
            + (startsSoon ? 60_000 : 0)
            + (friendGoingCount * 1_200)
            + (nearbyVenueCount * 500)
            + (nearbyFanCount * 140)
            + (activityCount * 90)
    }

    private func favoriteTeamMatches(_ team: FavoriteTeam, in match: LiveMatch) -> Bool {
        favoriteTeamMatches(
            team,
            values: [
                match.homeTeam,
                match.awayTeam,
                match.league,
                match.sport,
                match.liveSportVisualType.displayLabel
            ]
        )
    }

    private func favoriteTeamMatches(_ team: FavoriteTeam, in event: SportsEvent) -> Bool {
        favoriteTeamMatches(
            team,
            values: [
                event.title,
                event.league,
                event.sport,
                event.country
            ]
        )
    }

    private func favoriteTeamMatches(_ team: FavoriteTeam, values: [String]) -> Bool {
        let context = normalizedFavoriteTeamSearchText(values.joined(separator: " "))
        guard !context.isEmpty else { return false }
        let paddedContext = " \(context) "
        return favoriteTeamSearchAliases(for: team).contains { alias in
            paddedContext.contains(" \(alias) ")
        }
    }

    private func favoriteTeamSearchAliases(for team: FavoriteTeam) -> [String] {
        let normalizedName = normalizedFavoriteTeamSearchText(team.name)
        let tokens = normalizedName
            .split(separator: " ")
            .map(String.init)
            .filter { token in
                token.count >= 4 && !favoriteTeamGenericTokens.contains(token)
            }
        var aliases = [normalizedName]
        aliases.append(contentsOf: tokens)
        return aliases.reduce(into: [String]()) { unique, alias in
            if !alias.isEmpty && !unique.contains(alias) {
                unique.append(alias)
            }
        }
    }

    private var favoriteTeamGenericTokens: Set<String> {
        [
            "college",
            "football",
            "basketball",
            "hockey",
            "racing",
            "united",
            "city",
            "club",
            "sport",
            "sports"
        ]
    }

    private func normalizedFavoriteTeamSearchText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private var liveGamesLoadingCard: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text("Checking live games…")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Spacer(minLength: 0)
        }
        .padding(16)
        .background(liveCardSurface(cornerRadius: 20, highlighted: false))
    }

    private var liveGamesEmptyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("No live games right now.")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text("Check Starting Soon or open the map to find watch spots.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                Button {
                    selectedTab = .discover
                } label: {
                    Label("Open Map", systemImage: "map.fill")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(Capsule(style: .continuous).fill(FGColor.accentGreen))
                }
                .buttonStyle(.plain)

                Button {
                    selectedTab = .calendar
                } label: {
                    Label("View Calendar", systemImage: "calendar")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.07))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .background(liveCardSurface(cornerRadius: 22, highlighted: true))
    }

    private func liveMatchRelatedItems(for match: LiveMatch, in items: [LiveFeedItem]) -> [LiveFeedItem] {
        items.filter { item in
            let eventText = normalizedLiveAudienceText([
                item.event.title,
                item.event.league,
                item.event.sport
            ].joined(separator: " "))
            let home = normalizedLiveAudienceText(match.homeTeam)
            let away = normalizedLiveAudienceText(match.awayTeam)
            let league = normalizedLiveAudienceText(match.league)
            let sport = normalizedLiveAudienceText(match.sport)

            return (!home.isEmpty && eventText.contains(home))
                || (!away.isEmpty && eventText.contains(away))
                || (!league.isEmpty && eventText.contains(league) && !sport.isEmpty && eventText.contains(sport))
        }
    }

    private func liveMergedSocialProfiles(from items: [LiveFeedItem]) -> [UserProfileRow] {
        var seen: Set<UUID> = []
        return items.flatMap(\.energy.socialPresenceProfiles).compactMap { profile in
            guard let id = profile.id, !seen.contains(id) else { return nil }
            seen.insert(id)
            return profile
        }
    }

    private func liveMatchSocialPresenceText(relatedItems: [LiveFeedItem]) -> String {
        let friendCount = relatedItems.reduce(0) { $0 + $1.energy.friendGoingCount }
        let goingCount = relatedItems.reduce(0) { $0 + $1.energy.goingCount }
        if friendCount > 0 {
            return friendCount == 1 ? "1 friend going nearby" : "\(friendCount) friends going nearby"
        }
        return goingCount == 1 ? "1 fan going nearby" : "\(goingCount) fans going nearby"
    }

    private func normalizedLiveAudienceText(_ raw: String) -> String {
        raw
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func liveMatchCard(_ match: LiveMatch, relatedItems: [LiveFeedItem]) -> some View {
        let sportType = match.liveSportVisualType
        let accent = liveSportAccent(sportType)
        let artworkSportKey = sportType.artworkSportKey
        let socialProfiles = liveMergedSocialProfiles(from: relatedItems)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.13))
                    SportArtworkIconView(sport: artworkSportKey, diameter: 42)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        liveStatusPill(match, accent: accent)

                        Text(sportType.displayLabel)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(accent.opacity(colorScheme == .dark ? 0.18 : 0.10))
                            )

                        Text(match.league)
                            .font(FGTypography.metadata.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    Text("\(match.awayTeam) at \(match.homeTeam)")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)

                    HStack(spacing: 10) {
                        liveTeamScoreLine(team: match.awayTeam, score: match.scoreAway)
                        Text("·")
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                        liveTeamScoreLine(team: match.homeTeam, score: match.scoreHome)
                    }
                }

                Spacer(minLength: 0)
            }

            if canShowPersonalLiveSections && !socialProfiles.isEmpty {
                HStack(spacing: 8) {
                    GoingAvatarStack(profiles: socialProfiles, viewerUserID: viewModel.currentUserAuthId, diameter: 28)
                    Text(liveMatchSocialPresenceText(relatedItems: relatedItems))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 10) {
                Text("\(sportType.displayLabel) · Started \(match.startTime.formatted(date: .omitted, time: .shortened))")
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Button {
                    selectedTab = .discover
                } label: {
                    Text("Find Venues")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(accent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule(style: .continuous).fill(accent.opacity(colorScheme == .dark ? 0.16 : 0.10)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(liveCardSurface(cornerRadius: 22, highlighted: true))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(accent.opacity(colorScheme == .dark ? 0.46 : 0.28), lineWidth: 1)
        }
        .onAppear {
#if DEBUG
            let visual = SportFilterCatalog.resolve(artworkSportKey)
            print("[LiveSportIconMapping] id=\(match.id) normalized=\(match.sport) artworkKey=\(artworkSportKey) systemImage=\(visual.systemImage) label=\(sportType.displayLabel)")
            print("[LiveSportDetected] id=\(match.id) presentationType=\(sportType.rawValue) accent=\(accent)")
#endif
        }
    }

    private func liveStatusPill(_ match: LiveMatch, accent: Color) -> some View {
        let statusTint = match.matchStatus.isHappeningNow ? FGColor.dangerRed : accent
        return HStack(spacing: 5) {
            Circle()
                .fill(match.matchStatus.isHappeningNow ? FGColor.dangerRed : Color.white)
                .frame(width: 5, height: 5)
                .scaleEffect(match.matchStatus.isHappeningNow && liveIndicatorPulse ? 1.45 : 0.9)
                .opacity(match.matchStatus.isHappeningNow && liveIndicatorPulse ? 0.55 : 1.0)
                .shadow(color: statusTint.opacity(0.55), radius: match.matchStatus.isHappeningNow ? 4 : 0)
                .animation(
                    match.matchStatus.isHappeningNow
                        ? .easeInOut(duration: 0.95).repeatForever(autoreverses: true)
                        : .default,
                    value: liveIndicatorPulse
                )

            Text(liveStatusText(match))
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(statusTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(statusTint.opacity(colorScheme == .dark ? 0.18 : 0.11)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(statusTint.opacity(0.26), lineWidth: 1)
        }
        .accessibilityLabel(liveStatusText(match))
        .onAppear {
            guard match.matchStatus.isHappeningNow else { return }
            liveIndicatorPulse = true
            logLiveBadgeDebug()
        }
    }

    private func liveSportAccent(_ sportType: LiveSportVisualType) -> Color {
        switch sportType {
        case .soccer:
            return Color(red: 0.05, green: 0.55, blue: 0.28)
        case .basketball:
            return Color(red: 0.95, green: 0.45, blue: 0.12)
        case .hockey:
            return Color(red: 0.12, green: 0.45, blue: 0.92)
        case .baseball:
            return Color(red: 0.85, green: 0.15, blue: 0.18)
        case .nfl:
            return Color(red: 0.45, green: 0.32, blue: 0.18)
        case .tennis:
            return Color(red: 0.78, green: 0.68, blue: 0.06)
        case .golf:
            return Color(red: 0.18, green: 0.62, blue: 0.32)
        case .formula1:
            return Color(red: 0.92, green: 0.2, blue: 0.22)
        case .other:
            return FGColor.accentGreen
        }
    }

    private func liveStatusText(_ match: LiveMatch) -> String {
        if match.matchStatus == .halfTime {
            return "HT"
        }
        if let minute = match.minute {
            return "LIVE \(minute)'"
        }
        return "LIVE"
    }

    private func liveTeamScoreLine(team: String, score: Int) -> some View {
        HStack(spacing: 4) {
            Text(team)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
            Text("\(score)")
                .font(FGTypography.caption.monospacedDigit().weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
    }

    private func updateLiveAutoRefreshForCurrentState(immediatelyRefresh: Bool) {
        if shouldAutoRefreshLiveMatches {
            startLiveAutoRefresh(immediatelyRefresh: immediatelyRefresh)
        } else {
            stopLiveAutoRefresh()
        }
    }

    private func startLiveAutoRefresh(immediatelyRefresh: Bool) {
        if liveAutoRefreshTask != nil {
            if immediatelyRefresh {
                return
            }
            stopLiveAutoRefresh()
        }

        if immediatelyRefresh {
            refreshLiveMatches(forceRefresh: true)
        }

        liveAutoRefreshTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.liveAutoRefreshIntervalNanoseconds)
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }
                guard shouldAutoRefreshLiveMatches else {
                    stopLiveAutoRefresh()
                    break
                }
                guard !viewModel.isLoadingLiveMatches else { continue }

                refreshLiveMatches(forceRefresh: true)
            }
        }
    }

    private func stopLiveAutoRefresh() {
        liveAutoRefreshTask?.cancel()
        liveAutoRefreshTask = nil
    }

    private func refreshLiveMatches(forceRefresh: Bool) {
        viewModel.refreshLiveMatchesForLiveTab(forceRefresh: forceRefresh)
    }

    private func liveHappeningNowSection(items: [LiveFeedItem]) -> some View {
        liveSection(title: "Happening Now", subtitle: "The strongest live energy first") {
            if items.isEmpty {
                liveQuietEmptyLine("Nothing live nearby yet.")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            liveHappeningCard(item)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func liveStartingSoonSection(items: [LiveFeedItem]) -> some View {
        liveSection(title: "Starting Soon", subtitle: "Quick decisions before kickoff") {
            if items.isEmpty {
                liveQuietEmptyLine("No nearby starts in the next hour.")
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        liveStartingSoonRow(item)
                    }
                }
            }
        }
    }

    private func liveFriendsSection(items: [LiveFeedItem]) -> some View {
        liveSection(title: "Friends Going", subtitle: "Privacy-safe friend presence") {
            if items.isEmpty {
                liveQuietEmptyLine("No friends are visible on live plans yet.")
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        liveFriendRow(item)
                    }
                }
            }
        }
    }

    private func liveCompactSection(title: String, subtitle: String, items: [LiveFeedItem]) -> some View {
        liveSection(title: title, subtitle: subtitle) {
            if items.isEmpty {
                liveQuietEmptyLine("Live updates appear as fans go, chat, and react.")
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        liveSignalRow(item)
                    }
                }
            }
        }
    }

    private func liveSection<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(FGTypography.sectionTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(subtitle)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveHappeningCard(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            let profiles = item.energy.socialPresenceProfiles
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top) {
                    SportArtworkIconView(sport: item.event.sport, diameter: 42)
                    Spacer(minLength: 12)
                    liveDot
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.event.title)
                        .font(.system(size: 17, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)

                    Text(item.bar.name)
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                liveTokenWrap(item, limit: 4)

                if canShowPersonalLiveSections && !profiles.isEmpty {
                    liveAvatarProof(item)
                } else {
                    Text(liveOperationalSubtitle(for: item))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }
            }
            .padding(16)
            .frame(width: 258, alignment: .topLeading)
            .frame(minHeight: 210, alignment: .topLeading)
            .background(liveCardSurface(cornerRadius: 24, highlighted: true))
            .overlay(alignment: .bottomTrailing) {
                liveScorePill(item.score)
                    .padding(14)
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveStartingSoonRow(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            HStack(spacing: 12) {
                VStack(spacing: 2) {
                    Text(item.energy.minutesUntilStart.map { "\($0)" } ?? "Soon")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)
                    if item.energy.minutesUntilStart != nil {
                        Text("min")
                            .font(FGTypography.metadata)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                .frame(width: 50)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.event.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text("\(item.bar.name) · \(viewModel.displayTime(for: item.event))")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                liveInlineTokens(item)
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveFriendRow(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            HStack(spacing: 12) {
                GoingAvatarStack(profiles: item.energy.socialPresenceProfiles, viewerUserID: viewModel.currentUserAuthId)

                VStack(alignment: .leading, spacing: 4) {
                    Text(item.energy.socialPresenceLabel ?? item.energy.friendPresenceLabel ?? "\(item.energy.friendGoingCount) friends going")
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text("\(item.event.title) · \(item.bar.name)")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveSignalRow(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            HStack(spacing: 12) {
                SportArtworkIconView(sport: item.event.sport, diameter: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.event.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                    Text("\(item.bar.name) · \(viewModel.displayTime(for: item.event))")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                liveInlineTokens(item)
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveEmptyCard(_ message: String) -> some View {
        Text(message)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(liveCardSurface(cornerRadius: 20, highlighted: false))
    }

    private func liveQuietEmptyLine(_ message: String) -> some View {
        Text(message)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveCardSurface(cornerRadius: CGFloat, highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(highlighted ? 0.105 : 0.075) : Color.white.opacity(0.78))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        highlighted
                            ? FGColor.dangerRed.opacity(colorScheme == .dark ? 0.30 : 0.20)
                            : FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1 : 0.75),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: highlighted ? 18 : 10, y: highlighted ? 10 : 5)
            .shadow(color: FGColor.dangerRed.opacity(highlighted ? (colorScheme == .dark ? 0.12 : 0.06) : 0), radius: 22, y: 0)
    }

    private var liveDot: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(FGColor.dangerRed)
                .frame(width: 7, height: 7)
                .shadow(color: FGColor.dangerRed.opacity(0.65), radius: 5)
                .scaleEffect(liveIndicatorPulse ? 1.35 : 0.92)
                .opacity(liveIndicatorPulse ? 0.62 : 1.0)
                .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: liveIndicatorPulse)
            Text("LIVE NOW")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(FGColor.dangerRed)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(Capsule(style: .continuous).fill(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.16 : 0.10)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.dangerRed.opacity(0.24), lineWidth: 1)
        }
        .onAppear {
            logLiveBadgeDebug()
        }
    }

    private func liveTokenWrap(_ item: LiveFeedItem, limit: Int) -> some View {
        FGWrappingLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(Array(liveEnergyTokens(for: item).prefix(limit)), id: \.self) { token in
                liveToken(token)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveInlineTokens(_ item: LiveFeedItem) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(liveEnergyTokens(for: item).prefix(2)), id: \.self) { token in
                liveToken(token)
            }
        }
    }

    private func liveToken(_ token: String) -> some View {
        Text(token)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(liveTokenTint(token))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(liveTokenTint(token).opacity(colorScheme == .dark ? 0.16 : 0.10)))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(liveTokenTint(token).opacity(0.24), lineWidth: 1)
            }
    }

    private func liveAvatarProof(_ item: LiveFeedItem) -> some View {
        HStack(spacing: 8) {
            GoingAvatarStack(profiles: item.energy.socialPresenceProfiles, viewerUserID: viewModel.currentUserAuthId, diameter: 28)
            Text(item.energy.socialPresenceLabel ?? liveSocialPresenceText(item))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
        }
    }

    private func liveScorePill(_ score: Int) -> some View {
        Text("Energy \(score)")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(FGColor.accentGreen)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .background(Capsule(style: .continuous).fill(Color.black.opacity(colorScheme == .dark ? 0.30 : 0.06)))
    }

    private func liveTokenTint(_ token: String) -> Color {
        if token.contains("LIVE") { return FGColor.dangerRed }
        if token.contains("Crowd") { return FGColor.accentGreen }
        if token.contains("Friend") { return FGColor.accentBlue }
        if token.contains("Chatting") { return FGColor.accentGreen }
        if token.contains("Starts") { return Color.orange }
        if token.contains("Need") { return FGColor.accentBlue }
        return colorScheme == .dark ? Color.white.opacity(0.82) : FGColor.secondaryText(colorScheme)
    }

    private func liveEnergyTokens(for item: LiveFeedItem) -> [String] {
        var tokens: [String] = []
        if item.energy.isLiveNow {
            tokens.append("LIVE NOW")
        } else if item.energy.startsSoon {
            tokens.append("Starts Soon")
        }
        if item.energy.goingCount >= 8 {
            tokens.append("Crowd Building")
        }
        if canShowPersonalLiveSections && item.energy.friendGoingCount > 0 {
            tokens.append("Friends Going")
        }
        if canShowPersonalLiveSections && item.energy.commentCount > 0 {
            tokens.append("Fans Chatting")
        }
        return Array(tokens.reduce(into: [String]()) { unique, token in
            if !unique.contains(token) {
                unique.append(token)
            }
        }.prefix(4))
    }

    private func featuredLiveCard(
        rankedItems: [LiveFeedItem],
        matches: [LiveMatch],
        pickupGames: [PickupGameRow]
    ) -> FeaturedLive {
        var candidates: [FeaturedLive] = []

        if let item = rankedItems.first {
            candidates.append(featuredLive(for: item))
        }

        if let match = matches.first {
            candidates.append(featuredLive(for: match))
        }

        if canShowPersonalLiveSections, let pickup = strongestPickupGameNeedingPlayers(pickupGames) {
            candidates.append(featuredLive(for: pickup))
        }

        return candidates.sorted { $0.score > $1.score }.first ?? emptyFeaturedLive
    }

    private func featuredLive(for item: LiveFeedItem) -> FeaturedLive {
        let type = featuredType(for: item)
        let venueLine = "\(item.bar.name) · \(viewModel.displayTime(for: item.event))"
        let subtitleDetail = featuredLiveSubtitleDetail(for: item)
        let subtitle = [venueLine, subtitleDetail]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        let visibleProfiles = featuredVisibleProfiles(for: item)
        return FeaturedLive(
            type: type,
            title: item.event.title,
            subtitle: subtitle,
            tokens: liveEnergyTokens(for: item),
            score: item.score,
            source: .liveItem(item),
            eventID: item.venueEventID,
            venueID: item.bar.id,
            venuePhotoURL: featuredVenuePhotoURL(for: item.bar),
            socialProfiles: visibleProfiles,
            rawGoingProfilesCount: item.venueEventID.flatMap { viewModel.goingProfilesByVenueEventID[$0]?.count } ?? 0
        )
    }

    private func featuredLive(for match: LiveMatch) -> FeaturedLive {
        let sportType = match.liveSportVisualType
        return FeaturedLive(
            type: .liveGame,
            title: "\(match.awayTeam) at \(match.homeTeam)",
            subtitle: "\(sportType.displayLabel) is live now. Open the map to find the room with energy.",
            tokens: ["LIVE NOW"],
            score: 9_500,
            source: .liveMatch(match),
            eventID: nil,
            venueID: nil,
            venuePhotoURL: nil,
            socialProfiles: [],
            rawGoingProfilesCount: 0
        )
    }

    private func featuredLive(for pickup: PickupGameRow) -> FeaturedLive {
        let start = PickupGameModels.parseSupabaseTimestamptz(pickup.game_start_at)
        let timeText = start.map { $0.formatted(date: .omitted, time: .shortened) } ?? "soon"
        let openSlots = pickup.pickupOpenSlotsRemaining
        let playerText = openSlots == 1 ? "1 spot open" : "\(openSlots) spots open"
        return FeaturedLive(
            type: .pickupNeedsPlayers,
            title: pickup.title,
            subtitle: "\(pickup.sport) pickup at \(timeText). \(playerText) for fans nearby.",
            tokens: ["Need Players"],
            score: 3_200 + (pickup.approvedJoinCount * 140) + (openSlots <= 2 ? 500 : 0),
            source: .pickupGame(pickup),
            eventID: nil,
            venueID: nil,
            venuePhotoURL: nil,
            socialProfiles: [],
            rawGoingProfilesCount: 0
        )
    }

    private var emptyFeaturedLive: FeaturedLive {
        FeaturedLive(
            type: .empty,
            title: "Nothing major nearby yet.",
            subtitle: isBusinessLiveAudienceUser
                ? "Live games and nearby venue activity will appear here."
                : "As fans start going, chatting, and reacting, Live will light up.",
            tokens: [],
            score: 0,
            source: .empty,
            eventID: nil,
            venueID: nil,
            venuePhotoURL: nil,
            socialProfiles: [],
            rawGoingProfilesCount: 0
        )
    }

    private func featuredLiveSubtitleDetail(for item: LiveFeedItem) -> String? {
        if item.energy.isLiveNow {
            return "Watch party active"
        }
        if item.energy.startsSoon, let minutes = item.energy.minutesUntilStart {
            return "Starts in \(minutes) min"
        }
        if canShowPersonalLiveSections && item.energy.commentCount > 0 {
            return item.energy.commentCount == 1 ? "1 fan chatting" : "\(item.energy.commentCount) fans chatting"
        }
        if item.vibeCount > 0, let venueEventID = item.venueEventID {
            return topVibeText(for: venueEventID)
        }
        return nil
    }

    private func featuredVisibleProfiles(for item: LiveFeedItem) -> [UserProfileRow] {
        guard canShowPersonalLiveSections else { return [] }
        if !item.energy.socialPresenceProfiles.isEmpty {
            return item.energy.socialPresenceProfiles
        }
        guard let venueEventID = item.venueEventID else { return [] }
        return viewModel.goingProfiles(for: venueEventID)
    }

    private func featuredVenuePhotoURL(for bar: BarVenue) -> String? {
        ImageDisplayURL.forList(
            thumbnail: bar.coverPhotoThumbnailURL ?? bar.menuPhotoThumbnailURL,
            full: bar.coverPhotoURL ?? bar.menuPhotoURL
        )
    }

    private func featuredType(for item: LiveFeedItem) -> FeaturedLiveType {
        if item.energy.isLiveNow { return .liveGame }
        if canShowPersonalLiveSections && item.energy.friendGoingCount > 0 { return .friendsGoing }
        if canShowPersonalLiveSections && item.energy.commentCount > 0 { return .fansChatting }
        if item.energy.goingCount >= 8 { return .crowdBuilding }
        if item.energy.startsSoon { return .eventStartingSoon }
        return .crowdBuilding
    }

    private func strongestPickupGameNeedingPlayers(_ pickupGames: [PickupGameRow]) -> PickupGameRow? {
        pickupGames
            .filter { !$0.isPickupFullForDiscover && !$0.hasPickupGameStarted() && $0.pickupOpenSlotsRemaining > 0 }
            .sorted { lhs, rhs in
                let lhsScore = lhs.approvedJoinCount * 140 + (lhs.pickupOpenSlotsRemaining <= 2 ? 500 : 0)
                let rhsScore = rhs.approvedJoinCount * 140 + (rhs.pickupOpenSlotsRemaining <= 2 ? 500 : 0)
                if lhsScore == rhsScore {
                    let lhsStart = PickupGameModels.parseSupabaseTimestamptz(lhs.game_start_at) ?? .distantFuture
                    let rhsStart = PickupGameModels.parseSupabaseTimestamptz(rhs.game_start_at) ?? .distantFuture
                    return lhsStart < rhsStart
                }
                return lhsScore > rhsScore
            }
            .first
    }

    private var liveRankedItems: [LiveFeedItem] {
        let venues = viewModel.mapVisibleBars.isEmpty ? viewModel.bars : viewModel.mapVisibleBars
        var seen: Set<String> = []
        var items: [LiveFeedItem] = []

        for bar in venues {
            for event in viewModel.selectedDayEventsForMap(bar) {
                let venueEventID = viewModel.cachedVenueEventID(for: bar, gameTitle: event.title)
                let key = "\(bar.id.uuidString)-\(venueEventID?.uuidString ?? event.id.uuidString)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let energy = viewModel.liveEnergy(for: bar, event: event, friendUserIDs: acceptedFriendUserIDs)
                let vibeCount = venueEventID.map {
                    viewModel.venueEventVibeCounts[$0]?.values.reduce(0, +) ?? 0
                } ?? 0
                let topVibe = venueEventID.flatMap { topVibeText(for: $0) }
                let score = liveRankingScore(energy: energy, vibeCount: vibeCount)
                guard liveShouldInclude(energy: energy, vibeCount: vibeCount, score: score) else { continue }

                let item = LiveFeedItem(
                    id: key,
                    bar: bar,
                    event: event,
                    venueEventID: venueEventID,
                    energy: energy,
                    score: score,
                    vibeCount: vibeCount,
                    topVibeText: topVibe
                )
                logLiveRankedItem(item)
                items.append(item)
            }
        }

        return items.sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.event.date < rhs.event.date
            }
            return lhs.score > rhs.score
        }
    }

    private func liveShouldInclude(energy: FanGeoLiveEnergy, vibeCount: Int, score: Int) -> Bool {
        energy.isLiveNow
            || energy.startsSoon
            || (canShowPersonalLiveSections && energy.friendGoingCount > 0)
            || energy.goingCount > 0
            || (canShowPersonalLiveSections && energy.commentCount > 0)
            || vibeCount > 0
            || score >= 10
    }

    private func liveRankingScore(energy: FanGeoLiveEnergy, vibeCount: Int) -> Int {
        (energy.isLiveNow ? 10_000 : 0)
            + (energy.startsSoon ? 4_000 : 0)
            + (canShowPersonalLiveSections ? energy.friendGoingCount * 420 : 0)
            + (energy.goingCount * 42)
            + (canShowPersonalLiveSections ? energy.commentCount * 30 : 0)
            + (vibeCount * 24)
    }

    private func openLiveItem(_ item: LiveFeedItem) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            viewModel.selectedBar = item.bar
            viewModel.selectedEvent = item.event
            showVenueDetails = true
        }
    }

    private func openFeaturedLive(_ featured: FeaturedLive) {
        switch featured.source {
        case .liveItem(let item):
            openLiveItem(item)
        case .liveMatch:
            selectedTab = .discover
        case .pickupGame:
            viewModel.discoverMapContentMode = .pickupGames
            viewModel.calendarTabGameFilter = .pickupGames
            selectedTab = .discover
        case .empty:
            break
        }
    }

    @ViewBuilder
    private func liveVenueDetailSheet() -> some View {
        if let selectedBar = viewModel.selectedBar {
            let claimStatus = viewModel.venueOwnershipClaimStatus(for: selectedBar)
            let selectedDayGames = viewModel.selectedDayEventsForMap(selectedBar)
            let selectedVenueEvent = selectedEventForVenue(gamesToday: selectedDayGames)
            let ratingCount = viewModel.reviewCountDisplay(for: selectedBar)
            let supportedSports = venueSupportedSports(from: selectedDayGames)
            let displaySport = venueSportLabel(sportsSupported: supportedSports)
            let liveEnergy = selectedVenueEvent.map {
                viewModel.liveEnergy(for: selectedBar, event: $0, friendUserIDs: acceptedFriendUserIDs)
            } ?? viewModel.strongestLiveEnergy(
                for: selectedBar,
                events: selectedDayGames,
                friendUserIDs: acceptedFriendUserIDs
            )
            let displayedLiveEnergy = liveEnergy.map(liveEnergyForCurrentAudience)

            VenueDetailView(
                bar: selectedBar,
                selectedEvent: selectedVenueEvent,
                isFavorite: viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(selectedBar.id),
                goingCount: viewModel.displayedGoingCount(for: selectedBar),
                liveEnergy: displayedLiveEnergy,
                livePresenceViewerUserID: viewModel.currentUserAuthId,
                iconForSport: viewModel.iconForSport,
                mergedRating: viewModel.mergedDisplayRating(for: selectedBar),
                ratingCount: ratingCount,
                displaySport: displaySport,
                sportsSupported: supportedSports,
                hasGamesScheduledToday: !selectedDayGames.isEmpty,
                venueEventRows: viewModel.venueEventRows,
                isBusinessConfirmed: venueIsBusinessConfirmed(bar: selectedBar, claimStatus: claimStatus),
                onDirections: { viewModel.openDirections(to: selectedBar) },
                onCall: { viewModel.callVenue(selectedBar) },
                onFavorite: {
                    if viewModel.canFavoriteVenues {
                        viewModel.toggleFavorite(selectedBar)
                    } else if viewModel.isAuthenticatedForSocialFeatures {
                        viewModel.logBusinessUserGateBlocked(action: "favoriteVenue")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                    }
                },
                onAddressTap: { viewModel.openDirections(to: selectedBar) },
                onRateVenue: {
                    if viewModel.canRateVenues {
                        showVenueDetails = false
                        showVenueRatingSheet = true
                    } else if viewModel.isGuestDiscoverMode {
                        viewModel.discoverNavigateToAccountForUserAuth = true
                    } else if viewModel.isAuthenticatedForSocialFeatures {
                        viewModel.logBusinessUserGateBlocked(action: "rateVenue")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                    }
                },
                experience: viewModel.experience(for: selectedBar),
                coverPhotoURL: selectedBar.coverPhotoURL,
                menuPhotoURL: selectedBar.menuPhotoURL,
                onClaimThisBusiness: liveVenueClaimAction(for: selectedBar),
                showsBusinessOwnershipSection: viewModel.shouldShowVenueOwnershipClaimSection(for: selectedBar),
                businessClaimStatus: claimStatus,
                showsFanOnlyActionButtons: viewModel.isGuestDiscoverMode || viewModel.canUseFanSocialFeatures,
                onFanFeatureBlocked: { action in
                    viewModel.logBusinessUserGateBlocked(action: action)
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                },
                locksScheduledGameDetailsForGuest: viewModel.isGuestDiscoverMode,
                onGuestGameLoginCTA: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                }
            )
            .task {
                await viewModel.refreshApprovedVenueOwnershipState(for: selectedBar)
                await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "live_venue_detail_open")
                viewModel.logBusinessOwnerSessionFlags(context: "live_venue_detail_open")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func selectedEventForVenue(gamesToday: [SportsEvent]) -> SportsEvent? {
        guard let selectedEvent = viewModel.selectedEvent else { return nil }
        return gamesToday.first {
            $0.title == selectedEvent.title &&
            $0.sport == selectedEvent.sport &&
            Calendar.current.isDate($0.date, inSameDayAs: selectedEvent.date)
        }
    }

    private func venueIsBusinessConfirmed(bar: BarVenue, claimStatus: VenueOwnershipClaimStatus) -> Bool {
        guard bar.businessId != nil || bar.ownerEmail != nil else { return false }
        switch claimStatus {
        case .approved, .alreadyClaimedByOtherBusiness:
            return true
        case .unclaimed, .pendingReview, .rejected:
            return false
        }
    }

    private func venueSupportedSports(from gamesToday: [SportsEvent]) -> [String] {
        Array(Set(gamesToday.compactMap { trimmedSportLabel($0.sport) })).sorted()
    }

    private func venueSportLabel(sportsSupported: [String]) -> String? {
        if sportsSupported.count > 1 { return "Multi-sport" }
        if let sport = sportsSupported.first { return sport }
        return nil
    }

    private func trimmedSportLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func liveVenueClaimAction(for bar: BarVenue) -> ((BarVenue) async -> String?)? {
        guard viewModel.canSubmitVenueOwnershipClaim(for: bar) else { return nil }
        return { venue in
            await viewModel.submitVenueOwnershipClaimFromVenueDetail(bar: venue)
        }
    }

    private func topVibeText(for venueEventID: UUID) -> String? {
        let counts = viewModel.venueEventVibeCounts[venueEventID] ?? [:]

        guard let top = counts.max(by: { $0.value < $1.value }),
              top.value > 0 else {
            return nil
        }

        switch top.key {
        case "audio_on":
            return "Audio confirmed · \(top.value)"
        case "packed":
            return "Packed · \(top.value)"
        case "seats_open":
            return "Seats open · \(top.value)"
        case "specials":
            return "Specials · \(top.value)"
        case "tv_visible":
            return "TVs visible · \(top.value)"
        default:
            return nil
        }
    }

    private func logLiveFeedSnapshot(
        happeningNowCount: Int,
        startingSoonCount: Int,
        friendsGoingCount: Int
    ) {
#if DEBUG
        print("[LiveTabDebug] happeningNowCount=\(happeningNowCount)")
        print("[LiveTabDebug] startingSoonCount=\(startingSoonCount)")
        print("[LiveTabDebug] friendsGoingCount=\(friendsGoingCount)")
#endif
    }

    private func visibleLiveSectionCount(
        matches: [LiveMatch],
        happeningNow: [LiveFeedItem],
        startingSoon: [LiveFeedItem],
        friendsGoing: [LiveFeedItem],
        crowdBuilding: [LiveFeedItem],
        fansChatting: [LiveFeedItem]
    ) -> Int {
        [
            !matches.isEmpty,
            !happeningNow.isEmpty,
            !startingSoon.isEmpty,
            !friendsGoing.isEmpty,
            !crowdBuilding.isEmpty,
            !fansChatting.isEmpty
        ].filter { $0 }.count
    }

    private func logLivePolishSnapshot(featuredLive: FeaturedLive, visibleSectionCount: Int) {
#if DEBUG
        print("[LivePolishDebug] featuredLiveType=\(featuredLive.type.rawValue)")
        print("[LivePolishDebug] featuredLiveTitle=\(featuredLive.title)")
        print("[LivePolishDebug] visibleSectionCount=\(visibleSectionCount)")
        print("[LivePolishDebug] emptyStateMode=\(featuredLive.type == .empty ? "featured" : "quietSections")")
        print("[LivePolishDebug] energyTokens=\(featuredLive.tokens.joined(separator: "|"))")
        print("[LiveFeaturedDebug] featuredEventId=\(featuredLive.eventID?.uuidString.lowercased() ?? "nil")")
        print("[LiveFeaturedDebug] featuredVenueId=\(featuredLive.venueID?.uuidString.lowercased() ?? "nil")")
        print("[LiveFeaturedDebug] rawGoingProfilesCount=\(featuredLive.rawGoingProfilesCount)")
        print("[LiveFeaturedDebug] visibleGoingProfilesCount=\(featuredLive.socialProfiles.count)")
        print("[LiveFeaturedDebug] avatarUrls=\(featuredLive.socialProfiles.compactMap { ImageDisplayURL.forList(thumbnail: $0.avatar_thumbnail_url, full: $0.avatar_url) })")
        print("[LiveFeaturedDebug] venuePhotoUrl=\(featuredLive.venuePhotoURL ?? "nil")")
#endif
    }

    private func logLiveBadgeDebug() {
#if DEBUG
        print("[LiveBadgeDebug] liveNowStyle=red")
#endif
    }

    private func logLiveFeedRefresh(reason: String) {
#if DEBUG
        print("[LiveTabDebug] liveFeedRefresh=\(reason)")
#endif
    }

    private func logLiveAudienceDebug() {
#if DEBUG
        let hiddenSections = canShowPersonalLiveSections
            ? "none"
            : "Your Teams Live|Friends Going|Fans Chatting|Live Activity Sharing|favorite team momentum|friend avatar stacks|mutual friend presence|friend-based indicators"
        print("[LiveVisibilityDebug] isBusinessAccount=\(isBusinessLiveAudienceUser)")
        print("[LiveVisibilityDebug] hidingSocialLiveSections=\(!canShowPersonalLiveSections)")
        print("[LiveVisibilityDebug] renderingFanSections=\(canShowPersonalLiveSections)")
        print("[LiveAudienceDebug] isBusinessUser=\(isBusinessLiveAudienceUser)")
        print("[LiveAudienceDebug] hiddenPersonalLiveSections=\(hiddenSections)")
        print("[LiveAudienceDebug] regularUserPersonalLiveEnabled=\(canShowPersonalLiveSections)")
#endif
    }

    private func logLiveRankedItem(_ item: LiveFeedItem) {
#if DEBUG
        print("[LiveTabDebug] rankedVenueEvent=\(item.bar.name)|\(item.event.title)|score=\(item.score)")
#endif
    }
}

private struct FavoriteTeamsLiveSection: View {
    let items: [LiveScreen.FavoriteTeamLiveItem]
    let hasFavoriteTeams: Bool
    let onWatchNearby: (LiveScreen.FavoriteTeamLiveItem) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Your Teams Live")
                    .font(FGTypography.sectionTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text("Favorite teams with live, nearby, and social momentum.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            if items.isEmpty {
                Text("Favorite your teams to personalize Live.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(sectionSurface(highlighted: hasFavoriteTeams))
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        FavoriteTeamLiveCard(item: item) {
                            onWatchNearby(item)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionSurface(highlighted: Bool) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(colorScheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.78))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        highlighted
                            ? FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.16)
                            : FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 1 : 0.75),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 10, y: 5)
    }
}

private struct FavoriteTeamLiveCard: View {
    let item: LiveScreen.FavoriteTeamLiveItem
    let onWatchNearby: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onWatchNearby) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    teamBadge

                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 7) {
                            statusPill

                            Text(item.team.name)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(item.team.badgeColor)
                                .lineLimit(1)
                        }

                        Text(item.title)
                            .font(FGTypography.cardTitle)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)

                        Text(item.leagueSportText)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    Spacer(minLength: 0)
                }

                if !item.socialTokens.isEmpty {
                    FGWrappingLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                        ForEach(item.socialTokens, id: \.self) { token in
                            socialToken(token)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                HStack {
                    Spacer(minLength: 0)
                    Text("Watch Nearby")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Capsule(style: .continuous).fill(FGColor.accentGreen))
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardSurface)
            .overlay(alignment: .topTrailing) {
                Circle()
                    .fill(item.team.badgeColor.opacity(colorScheme == .dark ? 0.18 : 0.11))
                    .frame(width: 86, height: 86)
                    .blur(radius: 28)
                    .offset(x: 24, y: -34)
            }
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private var teamBadge: some View {
        ZStack {
            Circle()
                .fill(item.team.badgeColor.opacity(colorScheme == .dark ? 0.28 : 0.16))
            Text(item.team.initials)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(item.team.badgeColor)
                .minimumScaleFactor(0.72)
                .lineLimit(1)
        }
        .frame(width: 48, height: 48)
        .overlay {
            Circle()
                .strokeBorder(item.team.badgeColor.opacity(colorScheme == .dark ? 0.42 : 0.28), lineWidth: 1)
        }
    }

    private var statusPill: some View {
        let tint = item.isLiveNow ? FGColor.dangerRed : item.team.badgeColor
        return HStack(spacing: 5) {
            Circle()
                .fill(item.isLiveNow ? FGColor.dangerRed : Color.white)
                .frame(width: 5, height: 5)
            Text(item.statusText)
                .font(.caption2.weight(.bold))
        }
        .foregroundStyle(item.isLiveNow ? tint : Color.white)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule(style: .continuous).fill(item.isLiveNow ? tint.opacity(colorScheme == .dark ? 0.18 : 0.11) : tint))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(item.isLiveNow ? tint.opacity(0.26) : Color.clear, lineWidth: 1)
        }
    }

    private func socialToken(_ token: String) -> some View {
        Text(token)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(tokenTint(token))
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule(style: .continuous).fill(tokenTint(token).opacity(colorScheme == .dark ? 0.16 : 0.10)))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tokenTint(token).opacity(0.24), lineWidth: 1)
            }
    }

    private func tokenTint(_ token: String) -> Color {
        if token.contains("friend") { return FGColor.accentBlue }
        if token.contains("venue") { return item.team.badgeColor }
        if token.contains("crowd") { return FGColor.accentGreen }
        return colorScheme == .dark ? Color.white.opacity(0.84) : FGColor.secondaryText(colorScheme)
    }

    private var cardSurface: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [Color.white.opacity(0.105), item.team.badgeColor.opacity(0.10)]
                        : [Color.white.opacity(0.86), item.team.badgeColor.opacity(0.08)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(item.team.badgeColor.opacity(colorScheme == .dark ? 0.32 : 0.20), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.07), radius: 16, y: 8)
    }
}
