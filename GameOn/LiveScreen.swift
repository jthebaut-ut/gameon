import CoreLocation
import SwiftUI

struct LiveScreen: View {
    private static let liveAutoRefreshIntervalNanoseconds: UInt64 = 15_000_000_000

    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
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
    @State private var liveGamesSportFilter: LiveSportVisualType?
    @State private var liveWatchSpotsPresentation: LiveWatchSpotsPresentation?

    private struct LiveWatchSpotsPresentation: Identifiable {
        let id: String
        let items: [LiveFeedItem]
    }

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

    init(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        selectedTab: Binding<MainTabView.AppTab>
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
        _chatViewModel = ObservedObject(wrappedValue: chatViewModel)
        _selectedTab = selectedTab
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

    private var liveCalendarToday: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var displayedLiveMatches: [LiveMatch] {
        viewModel.liveTabLiveMatchesDisplayed(searchQuery: "", sportFilter: liveGamesSportFilter, calendarDay: liveCalendarToday)
    }

    private var liveGamesSportFilterOptions: [LiveSportVisualType] {
        let present = Set(
            viewModel.liveTabLiveMatchesDisplayed(searchQuery: "", sportFilter: nil, calendarDay: liveCalendarToday)
                .map(\.liveSportVisualType)
        )
        return LiveSportVisualType.allCases.filter { present.contains($0) }
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
            .sheet(item: $liveWatchSpotsPresentation) { presentation in
                liveWatchSpotsSheet(items: presentation.items)
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
        let rankedItems = liveRankedItems(for: liveCalendarToday)
        let venuesAndPickupToday = venuesAndPickupTodayRows(from: rankedItems)
        let friendsGoing = showPersonalLiveSections ? Array(rankedItems.filter { $0.energy.friendGoingCount > 0 }.prefix(6)) : []
        let crowdBuilding = Array(rankedItems.filter { $0.energy.goingCount >= 8 && !$0.energy.isLiveNow }.prefix(6))
        let fansChatting = showPersonalLiveSections ? Array(rankedItems.filter { $0.energy.commentCount > 0 }.prefix(6)) : []
        let favoriteTeamItems = showPersonalLiveSections ? favoriteTeamsLiveItems(rankedItems: rankedItems) : []
        let visibleSectionCount = visibleLiveSectionCount(
            matches: displayedLiveMatches,
            venuesAndPickupToday: venuesAndPickupToday,
            friendsGoing: friendsGoing,
            crowdBuilding: crowdBuilding,
            fansChatting: fansChatting
        )
        let _: Void = logLiveFeedSnapshot(
            venuesAndPickupTodayCount: venuesAndPickupToday.count,
            friendsGoingCount: friendsGoing.count
        )
        let _: Void = logFanUpdatesStoreMigrationDebug()
        let _: Void = logLivePolishSnapshot(visibleSectionCount: visibleSectionCount)

        return ZStack {
            liveBackground

            ScrollViewReader { scrollProxy in
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 22) {
                        liveHeroHeader(totalCount: rankedItems.count)

                        liveSummaryChips(
                            liveNowCount: liveSummaryLiveNowCount(
                                matches: displayedLiveMatches,
                                venuesAndPickup: venuesAndPickupToday
                            ),
                            todayCount: venuesAndPickupToday.count,
                            friendsCount: friendsGoing.count,
                            showFriendsChip: showPersonalLiveSections,
                            scrollToSection: { section in
                                scrollToLiveSection(section, proxy: scrollProxy)
                            }
                        )

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
                            .id(LiveScrollSection.liveGames.rawValue)
                        liveVenuesAndPickupTodaySection(rows: venuesAndPickupToday)
                            .id(LiveScrollSection.today.rawValue)
                        if showPersonalLiveSections {
                            liveFriendsSection(items: friendsGoing)
                                .id(LiveScrollSection.friends.rawValue)
                        }
                        liveCrowdBuildingSection(items: crowdBuilding)
                        if showPersonalLiveSections {
                            liveFansChattingSection(items: fansChatting)
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
        }
        .ignoresSafeArea()
    }

    private func scrollToLiveSection(_ section: LiveScrollSection, proxy: ScrollViewProxy) {
        withAnimation(.spring(response: 0.38, dampingFraction: 0.86)) {
            proxy.scrollTo(section.rawValue, anchor: .top)
        }
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
        VStack(alignment: .leading, spacing: 6) {
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
            return "Scores, venues, and fan activity — organized for a quick scan."
        }
        return totalCount > 0
            ? "Tap a section below to jump in."
            : "Your live feed fills in as games and fans get active."
    }

    private func liveSummaryLiveNowCount(
        matches: [LiveMatch],
        venuesAndPickup: [LiveVenuesPickupRow]
    ) -> Int {
        matches.count + venuesAndPickup.filter(\.isLiveNow).count
    }

    private func liveSummaryChips(
        liveNowCount: Int,
        todayCount: Int,
        friendsCount: Int,
        showFriendsChip: Bool,
        scrollToSection: @escaping (LiveScrollSection) -> Void
    ) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Button {
                    scrollToSection(.liveGames)
                } label: {
                    liveSummaryChip(title: "Live now", count: liveNowCount, accent: FGColor.dangerRed, icon: "dot.radiowaves.left.and.right")
                }
                .buttonStyle(LiveSummaryChipButtonStyle())

                Button {
                    scrollToSection(.today)
                } label: {
                    liveSummaryChip(title: "Today", count: todayCount, accent: FGColor.accentGreen, icon: "calendar")
                }
                .buttonStyle(LiveSummaryChipButtonStyle())

                if showFriendsChip {
                    Button {
                        scrollToSection(.friends)
                    } label: {
                        liveSummaryChip(title: "Friends", count: friendsCount, accent: FGColor.accentBlue, icon: "person.2.fill")
                    }
                    .buttonStyle(LiveSummaryChipButtonStyle())
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
    }

    private func liveSummaryChip(title: String, count: Int, accent: Color, icon: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption.weight(.bold))
                .foregroundStyle(accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text("\(count)")
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(accent.opacity(colorScheme == .dark ? 0.14 : 0.09))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(accent.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Scrolls to the \(title) section")
    }

    private enum LiveScrollSection: String {
        case liveGames = "live-games-section"
        case today = "today-section"
        case friends = "friends-section"
    }

    private enum LivePanelKind {
        case liveGames
        case venuesPickup
        case friendsGoing
        case crowdBuilding
        case fansChatting

        var icon: String {
            switch self {
            case .liveGames: return "sportscourt.fill"
            case .venuesPickup: return "mappin.and.ellipse"
            case .friendsGoing: return "person.2.fill"
            case .crowdBuilding: return "flame.fill"
            case .fansChatting: return "bubble.left.and.bubble.right.fill"
            }
        }

        func accentColor(colorScheme: ColorScheme) -> Color {
            switch self {
            case .liveGames:
                return FGColor.dangerRed
            case .venuesPickup:
                return FGColor.accentGreen
            case .friendsGoing:
                return FGColor.accentBlue
            case .crowdBuilding:
                return Color(red: 0.95, green: 0.52, blue: 0.14)
            case .fansChatting:
                return Color(red: 0.22, green: 0.62, blue: 0.78)
            }
        }

        func panelFill(colorScheme: ColorScheme) -> Color {
            let accent = accentColor(colorScheme: colorScheme)
            return accent.opacity(colorScheme == .dark ? 0.10 : 0.07)
        }

        func panelStroke(colorScheme: ColorScheme) -> Color {
            accentColor(colorScheme: colorScheme).opacity(colorScheme == .dark ? 0.22 : 0.14)
        }
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

    private func liveGamesSection(matches: [LiveMatch], rankedItems: [LiveFeedItem]) -> some View {
        livePanelSection(
            kind: .liveGames,
            title: "Live Games",
            subtitle: "Pro scores on TV right now"
        ) {
            if !liveGamesSportFilterOptions.isEmpty {
                liveGamesSportFilterBar
            }
            if viewModel.isLoadingLiveMatches && matches.isEmpty {
                liveGamesLoadingCard
            } else if matches.isEmpty {
                liveSectionEmptyState(
                    liveGamesSportFilter == nil
                        ? "No live pro games right now"
                        : "No live \(liveGamesSportFilter!.filterChipLabel) games right now"
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(matches) { match in
                        liveMatchCard(match, relatedItems: liveMatchRelatedItems(for: match, in: rankedItems))
                    }
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.86), value: liveGamesSportFilter)
            }
        }
    }

    private var liveGamesSportFilterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                SportFilterChip(
                    sport: "All",
                    isSelected: liveGamesSportFilter == nil,
                    preferSystemSymbol: true
                ) {
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                        liveGamesSportFilter = nil
                    }
                }
                ForEach(liveGamesSportFilterOptions, id: \.self) { sport in
                    SportFilterChip(
                        sport: sport.sportFilterCatalogKey,
                        displayTitle: sport.filterChipLabel,
                        isSelected: liveGamesSportFilter == sport,
                        preferSystemSymbol: true
                    ) {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.84)) {
                            liveGamesSportFilter = sport
                        }
                    }
                }
            }
            .padding(.horizontal, 1)
            .padding(.vertical, 2)
        }
        .scrollClipDisabled()
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: liveGamesSportFilter)
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
        FavoriteTeamLiveMatcher.matchesLiveMatch(team, homeTeam: match.homeTeam, awayTeam: match.awayTeam)
    }

    private func favoriteTeamMatches(_ team: FavoriteTeam, in event: SportsEvent) -> Bool {
        FavoriteTeamLiveMatcher.matchesVenueEventTitle(team, title: event.title)
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
                Text("Check Venues & Pickup Games Today or open the map to find watch spots.")
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

    private func liveFindVenuesDedupedRelatedItems(_ items: [LiveFeedItem]) -> [LiveFeedItem] {
        var seenBarIDs: Set<UUID> = []
        return items.filter { item in
            guard !seenBarIDs.contains(item.bar.id) else { return false }
            seenBarIDs.insert(item.bar.id)
            return true
        }
    }

    private func liveFindVenuesSortedRelatedItems(_ items: [LiveFeedItem]) -> (items: [LiveFeedItem], sortedByDistance: Bool) {
        let deduped = liveFindVenuesDedupedRelatedItems(items)
        guard let userCoordinate = viewModel.currentUserLocation,
              CLLocationCoordinate2DIsValid(userCoordinate) else {
            return (deduped, false)
        }
        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        let sorted = deduped.sorted { lhs, rhs in
            let lhsMeters = liveFindVenuesDistanceMeters(from: userLocation, to: lhs.bar.coordinate)
            let rhsMeters = liveFindVenuesDistanceMeters(from: userLocation, to: rhs.bar.coordinate)
            switch (lhsMeters, rhsMeters) {
            case let (l?, r?):
                if l == r { return lhs.bar.name.localizedCaseInsensitiveCompare(rhs.bar.name) == .orderedAscending }
                return l < r
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                return lhs.bar.name.localizedCaseInsensitiveCompare(rhs.bar.name) == .orderedAscending
            }
        }
        return (sorted, true)
    }

    private func liveFindVenuesDistanceMeters(from userLocation: CLLocation, to coordinate: CLLocationCoordinate2D) -> Double? {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return userLocation.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    private func liveFindVenuesDistanceText(for bar: BarVenue) -> String? {
        let trimmed = bar.distance.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        guard let userCoordinate = viewModel.currentUserLocation,
              CLLocationCoordinate2DIsValid(userCoordinate) else { return nil }
        let userLocation = CLLocation(latitude: userCoordinate.latitude, longitude: userCoordinate.longitude)
        guard let meters = liveFindVenuesDistanceMeters(from: userLocation, to: bar.coordinate) else { return nil }
        let miles = meters / 1609.34
        guard miles >= 0.05 else { return nil }
        if miles < 10 { return String(format: "%.1f mi", miles) }
        return String(format: "%.0f mi", miles)
    }

    private func liveFindVenuesFallbackButtonTitle(for sportType: LiveSportVisualType) -> String {
        switch sportType {
        case .soccer:
            return "Find Soccer Bars"
        case .basketball:
            return "Find Basketball Bars"
        case .hockey:
            return "Find Hockey Bars"
        case .baseball:
            return "Find Baseball Bars"
        case .nfl:
            return "Find Football Bars"
        case .tennis:
            return "Find Tennis Bars"
        case .golf:
            return "Find Golf Bars"
        case .formula1, .other:
            return "Open Map"
        }
    }

    private func liveFindVenuesDiscoverSportFilter(for sportType: LiveSportVisualType) -> String? {
        switch sportType {
        case .soccer:
            return "Soccer"
        case .basketball:
            return "NBA"
        case .hockey:
            return "NHL"
        case .baseball:
            return "Baseball"
        case .nfl:
            return "NFL"
        case .tennis:
            return "Tennis"
        case .golf:
            return "Golf"
        case .formula1, .other:
            return nil
        }
    }

    private func liveFindVenuesTapped(match: LiveMatch, relatedItems: [LiveFeedItem]) {
        let sorted = liveFindVenuesSortedRelatedItems(relatedItems)
#if DEBUG
        print("[LiveFindVenues] tapped match=\(match.id)")
        print("[LiveFindVenues] related_count=\(sorted.items.count)")
        print("[LiveFindVenues] sorted_by_distance=\(sorted.sortedByDistance)")
#endif
        if sorted.items.isEmpty {
            liveFindVenuesOpenDiscoverFallback(sportType: match.liveSportVisualType)
        } else {
            liveWatchSpotsPresentation = LiveWatchSpotsPresentation(id: match.id, items: sorted.items)
        }
    }

    private func liveFindVenuesOpenDiscoverFallback(sportType: LiveSportVisualType) {
        let sportFilter = liveFindVenuesDiscoverSportFilter(for: sportType)
#if DEBUG
        print("[LiveFindVenues] fallback_sport_filter=\(sportFilter ?? "nil")")
#endif
        viewModel.discoverMapContentMode = .venues
        if let sportFilter {
            viewModel.sportChanged(to: sportFilter)
        }
        selectedTab = .discover
    }

    private func liveFindVenuesOpenVenue(_ item: LiveFeedItem) {
#if DEBUG
        print("[LiveFindVenues] opened_venue=\(item.bar.id.uuidString.lowercased()) name=\(item.bar.name)")
#endif
        liveWatchSpotsPresentation = nil
        openLiveItem(item)
    }

    @ViewBuilder
    private func liveWatchSpotsSheet(items: [LiveFeedItem]) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        Button {
                            liveFindVenuesOpenVenue(item)
                        } label: {
                            liveWatchSpotsRow(item)
                        }
                        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
            .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
            .navigationTitle("Watch spots for this game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        liveWatchSpotsPresentation = nil
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func liveWatchSpotsRow(_ item: LiveFeedItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            SportArtworkIconView(sport: item.event.sport, diameter: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.bar.name)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                if !item.bar.address.isEmpty {
                    Text(item.bar.address)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                Text(item.event.title)
                    .font(FGTypography.metadata)
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let distance = liveFindVenuesDistanceText(for: item.bar) {
                Text(distance)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(liveCardSurface(cornerRadius: 18, highlighted: false))
    }

    private func liveMatchCard(_ match: LiveMatch, relatedItems: [LiveFeedItem]) -> some View {
        let sportType = match.liveSportVisualType
        let accent = sportType.catalogAccent
        let catalogSportKey = sportType.sportFilterCatalogKey
        let watchSpotItems = liveFindVenuesSortedRelatedItems(relatedItems).items
        let hasWatchSpots = !watchSpotItems.isEmpty
        let findVenuesButtonTitle = hasWatchSpots
            ? "Find Venues"
            : liveFindVenuesFallbackButtonTitle(for: sportType)
        let socialProfiles = liveMergedSocialProfiles(from: relatedItems)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.13))
                    SportArtworkIconView(sport: catalogSportKey, diameter: 42, preferSystemSymbol: true)
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        liveStatusPill(match, accent: accent)

                        Text(sportType.filterChipLabel)
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
                    liveFindVenuesTapped(match: match, relatedItems: relatedItems)
                } label: {
                    Text(findVenuesButtonTitle)
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
        .background(liveCardSurface(cornerRadius: 22, highlighted: match.matchStatus.isHappeningNow))
        .overlay {
            if match.matchStatus.isHappeningNow {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1)
            } else {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(accent.opacity(colorScheme == .dark ? 0.46 : 0.28), lineWidth: 1)
            }
        }
        .onAppear {
#if DEBUG
            let visual = sportType.catalogVisual
            print("[LiveSportIconMapping] id=\(match.id) normalized=\(match.sport) catalogKey=\(catalogSportKey) systemImage=\(visual.systemImage) label=\(sportType.filterChipLabel)")
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

    private enum LiveVenuesPickupRow: Identifiable {
        case venue(LiveFeedItem)
        case pickup(PickupGameRow)

        var id: String {
            switch self {
            case .venue(let item):
                return "venue-\(item.id)"
            case .pickup(let row):
                return "pickup-\(row.id.uuidString)"
            }
        }

        var isLiveNow: Bool {
            switch self {
            case .venue(let item):
                return item.energy.isLiveNow
            case .pickup(let row):
                return row.hasPickupGameStarted()
            }
        }

    }

    private func liveVenuesAndPickupTodaySection(rows: [LiveVenuesPickupRow]) -> some View {
        livePanelSection(
            kind: .venuesPickup,
            title: "Venues & Pickup Games Today",
            subtitle: "Watch parties, pickup runs, and plans near you"
        ) {
            if rows.isEmpty {
                liveSectionEmptyState("No venues or pickup games today")
            } else {
                let liveRows = rows.filter(\.isLiveNow)
                let otherRows = rows.filter { !$0.isLiveNow }
                VStack(alignment: .leading, spacing: 12) {
                    if !liveRows.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: 12) {
                                ForEach(liveRows) { row in
                                    liveVenuesPickupCompactCard(row)
                                        .frame(width: 272)
                                }
                            }
                            .padding(.horizontal, 1)
                            .padding(.vertical, 2)
                        }
                        .scrollClipDisabled()
                    }
                    if !otherRows.isEmpty {
                        VStack(spacing: 10) {
                            ForEach(otherRows) { row in
                                switch row {
                                case .venue(let item):
                                    liveVenuesPickupVenueRow(item)
                                case .pickup(let pickup):
                                    liveVenuesPickupPickupRow(pickup)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func liveVenuesPickupCompactCard(_ row: LiveVenuesPickupRow) -> some View {
        switch row {
        case .venue(let item):
            Button {
                openLiveItem(item)
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SportArtworkIconView(sport: item.event.sport, diameter: 36)
                        Spacer(minLength: 0)
                        livePillBadge
                    }
                    Text(item.event.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text(item.bar.name)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(liveCardSurface(cornerRadius: 18, highlighted: true))
            }
            .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
        case .pickup(let pickup):
            Button {
                viewModel.discoverMapContentMode = .pickupGames
                viewModel.calendarTabGameFilter = .pickupGames
                selectedTab = .discover
            } label: {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SportArtworkIconView(sport: pickup.sport, diameter: 36)
                        Spacer(minLength: 0)
                        livePillBadge
                    }
                    Text(pickup.title)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text("\(pickup.sport) pickup · \(pickupStartDisplay(for: pickup))")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(liveCardSurface(cornerRadius: 18, highlighted: true))
            }
            .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
        }
    }

    private func venuesAndPickupTodayRows(from rankedItems: [LiveFeedItem]) -> [LiveVenuesPickupRow] {
        var rows: [LiveVenuesPickupRow] = []
        var seenVenueKeys: Set<String> = []

        for item in rankedItems {
            guard venuesAndPickupVenueQualifies(item) else { continue }
            guard !seenVenueKeys.contains(item.id) else { continue }
            seenVenueKeys.insert(item.id)
            rows.append(.venue(item))
        }

        for pickup in pickupGamesForLiveToday() {
            rows.append(.pickup(pickup))
        }

        return rows
            .sorted { lhs, rhs in
                let l = venuesAndPickupSortScore(lhs)
                let r = venuesAndPickupSortScore(rhs)
                if l == r { return lhs.id < rhs.id }
                return l > r
            }
            .prefix(16)
            .map { $0 }
    }

    private func venuesAndPickupSortScore(_ row: LiveVenuesPickupRow) -> Int {
        switch row {
        case .venue(let item):
            return item.score
                + (item.energy.isLiveNow ? 20_000 : 0)
                + (item.energy.startsSoon ? 5_000 : 0)
        case .pickup(let pickup):
            let userBoost = isPickupUserRelevant(pickup) ? 8_000 : 0
            let liveBoost = pickup.hasPickupGameStarted() ? 20_000 : 0
            return userBoost + liveBoost + pickup.approvedJoinCount * 140
        }
    }

    private func venuesAndPickupVenueQualifies(_ item: LiveFeedItem) -> Bool {
        if item.energy.isLiveNow || item.energy.startsSoon { return true }
        if item.energy.goingCount > 0 { return true }
        if canShowPersonalLiveSections && item.energy.friendGoingCount > 0 { return true }
        if canShowPersonalLiveSections && item.energy.commentCount > 0 { return true }
        if item.vibeCount > 0 { return true }
        return false
    }

    private func pickupGamesForLiveToday() -> [PickupGameRow] {
        let cal = Calendar.current
        return viewModel.pickupGamesForDiscoverMap.filter { row in
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return false }
            return cal.isDate(start, inSameDayAs: liveCalendarToday)
        }
    }

    private func isPickupUserRelevant(_ row: PickupGameRow) -> Bool {
        guard let me = viewModel.currentUserAuthId else { return false }
        if row.creator_user_id == me { return true }
        if viewModel.myPickupGamesForSettings.contains(where: { $0.id == row.id }) { return true }
        if viewModel.myPickupGameJoinRequestCards.contains(where: { $0.pickupGameId == row.id }) { return true }
        return false
    }

    private func liveVenuesPickupVenueRow(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            HStack(alignment: .top, spacing: 12) {
                SportArtworkIconView(sport: item.event.sport, diameter: 42)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if item.energy.isLiveNow {
                            livePillBadge
                        } else if item.energy.startsSoon, let minutes = item.energy.minutesUntilStart {
                            Text("Starts in \(minutes) min")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(FGColor.accentGreen)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(item.event.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text(item.bar.name)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                    liveInlineTokens(item)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: item.energy.isLiveNow))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func liveVenuesPickupPickupRow(_ row: PickupGameRow) -> some View {
        let isLive = row.hasPickupGameStarted()
        return Button {
            viewModel.discoverMapContentMode = .pickupGames
            viewModel.calendarTabGameFilter = .pickupGames
            selectedTab = .discover
        } label: {
            HStack(alignment: .top, spacing: 12) {
                SportArtworkIconView(sport: row.sport, diameter: 42)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if isLive {
                            livePillBadge
                        }
                        if isPickupUserRelevant(row) {
                            Text(userPickupRelevanceLabel(row))
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(FGColor.accentBlue)
                        }
                        Spacer(minLength: 0)
                    }
                    Text(row.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text("\(row.sport) pickup · \(pickupStartDisplay(for: row))")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                    Text(row.lookingForPlayersLine)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(liveCardSurface(cornerRadius: 20, highlighted: isLive))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
    }

    private func userPickupRelevanceLabel(_ row: PickupGameRow) -> String {
        guard let me = viewModel.currentUserAuthId else { return "Your game" }
        if row.creator_user_id == me { return "You host" }
        if viewModel.myPickupGamesForSettings.contains(where: { $0.id == row.id }) { return "You host" }
        if viewModel.myPickupGameJoinRequestCards.contains(where: { $0.pickupGameId == row.id }) { return "You joined" }
        return "Your game"
    }

    private func pickupStartDisplay(for row: PickupGameRow) -> String {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return "Today" }
        return start.formatted(date: .omitted, time: .shortened)
    }

    private func liveFriendsSection(items: [LiveFeedItem]) -> some View {
        livePanelSection(
            kind: .friendsGoing,
            title: "Friends Going",
            subtitle: "Where people you know are headed"
        ) {
            if items.isEmpty {
                liveSectionEmptyState("Friends' plans will appear here")
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(items) { item in
                            liveFriendCompactCard(item)
                                .frame(width: 260)
                        }
                    }
                    .padding(.horizontal, 1)
                    .padding(.vertical, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func liveCrowdBuildingSection(items: [LiveFeedItem]) -> some View {
        livePanelSection(
            kind: .crowdBuilding,
            title: "Crowd Building",
            subtitle: isBusinessLiveAudienceUser ? "Venues gaining momentum" : "Games fans are piling into"
        ) {
            if items.isEmpty {
                liveSectionEmptyState("Crowd momentum shows up here")
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        liveSignalRow(item)
                    }
                }
            }
        }
    }

    private func liveFansChattingSection(items: [LiveFeedItem]) -> some View {
        livePanelSection(
            kind: .fansChatting,
            title: "Fans Chatting",
            subtitle: "Active threads at venues"
        ) {
            if items.isEmpty {
                liveSectionEmptyState("Chat activity shows up here")
            } else {
                VStack(spacing: 10) {
                    ForEach(items) { item in
                        liveSignalRow(item)
                    }
                }
            }
        }
    }

    private func livePanelSection<Content: View>(
        kind: LivePanelKind,
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let accent = kind.accentColor(colorScheme: colorScheme)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: kind.icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(kind.panelFill(colorScheme: colorScheme))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(kind.panelStroke(colorScheme: colorScheme), lineWidth: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func liveSectionEmptyState(_ message: String) -> some View {
        Text(message)
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
    }

    private func liveFriendCompactCard(_ item: LiveFeedItem) -> some View {
        Button {
            openLiveItem(item)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                GoingAvatarStack(
                    profiles: item.energy.socialPresenceProfiles,
                    viewerUserID: viewModel.currentUserAuthId,
                    diameter: 32
                )
                Text(item.energy.socialPresenceLabel ?? item.energy.friendPresenceLabel ?? "Friends going")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text("\(item.event.title) · \(item.bar.name)")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
                if item.energy.isLiveNow {
                    livePillBadge
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(liveCardSurface(cornerRadius: 18, highlighted: item.energy.isLiveNow))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: true))
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
            .fill(liveCardFill(highlighted: highlighted))
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

    private func liveCardFill(highlighted: Bool) -> Color {
        if highlighted {
            return colorScheme == .dark
                ? Color(red: 0.20, green: 0.07, blue: 0.07).opacity(0.42)
                : Color(red: 1.0, green: 0.96, blue: 0.96)
        }
        return colorScheme == .dark ? Color.white.opacity(0.075) : Color.white.opacity(0.78)
    }

    private var livePillBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(FGColor.dangerRed)
                .frame(width: 6, height: 6)
                .scaleEffect(liveIndicatorPulse ? 1.25 : 0.92)
                .opacity(liveIndicatorPulse ? 0.7 : 1.0)
                .animation(.easeInOut(duration: 0.95).repeatForever(autoreverses: true), value: liveIndicatorPulse)
            Text("LIVE")
                .font(.system(size: 10, weight: .bold, design: .rounded))
        }
        .foregroundStyle(FGColor.dangerRed)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.16 : 0.10)))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.dangerRed.opacity(0.24), lineWidth: 1)
        }
        .onAppear {
            liveIndicatorPulse = true
        }
    }

    private var liveDot: some View {
        livePillBadge
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

    private func liveRankedItems(for day: Date) -> [LiveFeedItem] {
        let venues = viewModel.mapVisibleBars.isEmpty ? viewModel.bars : viewModel.mapVisibleBars
        let cal = Calendar.current
        var seen: Set<String> = []
        var items: [LiveFeedItem] = []

        for bar in venues {
            let dayEvents = viewModel.events.filter { event in
                cal.isDate(event.date, inSameDayAs: day) && bar.games.contains(event.title)
            }
            for event in dayEvents {
                let venueEventID = viewModel.cachedVenueEventID(for: bar, gameTitle: event.title)
                if let venueEventID,
                   let row = viewModel.venueEventRows.first(where: { $0.id == venueEventID }),
                   !VenueGameExpiration.isActiveOnDiscoverSurfaces(row: row) {
                    continue
                }
                let key = "\(bar.id.uuidString)-\(venueEventID?.uuidString ?? event.id.uuidString)"
                guard !seen.contains(key) else { continue }
                seen.insert(key)

                let energy = viewModel.liveEnergy(for: bar, event: event, friendUserIDs: acceptedFriendUserIDs)
                let vibeCount = venueEventID.map {
                    fanUpdatesStore.venueEventVibeCounts[$0]?.values.reduce(0, +) ?? 0
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
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]

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

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] LiveScreenVibeReadsStore=true")
#endif
    }

    private func logLiveFeedSnapshot(
        venuesAndPickupTodayCount: Int,
        friendsGoingCount: Int
    ) {
#if DEBUG
        print("[LiveTabDebug] venuesAndPickupTodayCount=\(venuesAndPickupTodayCount)")
        print("[LiveTabDebug] friendsGoingCount=\(friendsGoingCount)")
#endif
    }

    private func visibleLiveSectionCount(
        matches: [LiveMatch],
        venuesAndPickupToday: [LiveVenuesPickupRow],
        friendsGoing: [LiveFeedItem],
        crowdBuilding: [LiveFeedItem],
        fansChatting: [LiveFeedItem]
    ) -> Int {
        [
            !matches.isEmpty,
            !venuesAndPickupToday.isEmpty,
            !friendsGoing.isEmpty,
            !crowdBuilding.isEmpty,
            !fansChatting.isEmpty
        ].filter { $0 }.count
    }

    private func logLivePolishSnapshot(visibleSectionCount: Int) {
#if DEBUG
        print("[LivePolishDebug] visibleSectionCount=\(visibleSectionCount)")
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

    private var headerAccent: Color {
        Color(red: 0.96, green: 0.78, blue: 0.18)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(headerAccent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                        .frame(width: 40, height: 40)
                    Image(systemName: "star.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(headerAccent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Your Teams Live")
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Favorite teams with live, nearby, and social momentum.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if items.isEmpty {
                Text(
                    hasFavoriteTeams
                        ? "No favorite teams live right now"
                        : "Favorite your teams to personalize Live."
                )
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

private struct LiveSummaryChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeInOut(duration: 0.14), value: configuration.isPressed)
    }
}
