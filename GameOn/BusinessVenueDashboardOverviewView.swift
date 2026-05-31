import SwiftUI

struct BusinessVenueDashboardData: Equatable {
    let venueName: String
    let locationLine: String
    let isVerified: Bool
    let managedVenueCount: Int
    let venuePhotoURL: String?
    let venuePhotoThumbnailURL: String?
    let fansGoing: Int
    let activeChats: Int
    let predictions: Int
    let atmosphereRating: String
    let gameSectionContext: BusinessVenueDashboardGameSectionContext
    let games: [BusinessVenueDashboardGameItem]
    let approvedVenues: [BusinessVenueDashboardApprovedVenueItem]
    let pendingVenues: [BusinessVenueDashboardPendingVenueItem]
}

struct BusinessVenueDashboardGameSectionContext: Equatable {
    let label: BusinessVenueDashboardGameSectionLabel
    let nearestGameDate: Date?
    let upcomingCount: Int
}

enum BusinessVenueDashboardGameSectionLabel: String, Equatable {
    case tonightAtYourVenue
    case tomorrowAtYourVenue
    case upcomingAtYourVenue
    case upcomingGames
    case noUpcomingGames

    func title(languageCode: String) -> String {
        switch self {
        case .tonightAtYourVenue:
            return L10n.t("tonight_at_your_venue", languageCode: languageCode)
        case .tomorrowAtYourVenue:
            return "Tomorrow at your venue"
        case .upcomingAtYourVenue:
            return "Upcoming at your venue"
        case .upcomingGames:
            return "Upcoming games"
        case .noUpcomingGames:
            return "No upcoming games"
        }
    }
}

enum BusinessVenueDashboardGameSectionResolver {
    static func resolve(
        gameDates: [Date],
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> BusinessVenueDashboardGameSectionContext {
        let today = calendar.startOfDay(for: now)
        let upcomingDates = gameDates
            .filter { calendar.startOfDay(for: $0) >= today }
            .sorted()
        let nearest = upcomingDates.first
        let label: BusinessVenueDashboardGameSectionLabel
        if upcomingDates.isEmpty {
            label = .noUpcomingGames
        } else if upcomingDates.count > 1 {
            label = .upcomingGames
        } else if let nearest, calendar.isDate(nearest, inSameDayAs: now) {
            label = .tonightAtYourVenue
        } else if let nearest, calendar.isDateInTomorrow(nearest) {
            label = .tomorrowAtYourVenue
        } else {
            label = .upcomingAtYourVenue
        }
        return BusinessVenueDashboardGameSectionContext(
            label: label,
            nearestGameDate: nearest,
            upcomingCount: upcomingDates.count
        )
    }
}

struct BusinessVenueDashboardGameItem: Identifiable, Equatable {
    let id: UUID
    let title: String
    let subtitle: String
    let timeText: String
    let sportIconName: String
    let goingCount: Int
    let energyLabel: String
    let energyTint: Color
}

struct BusinessVenueDashboardApprovedVenueItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let locationLine: String
    let approvedDateText: String
    let venuePhotoURL: String?
    let venuePhotoThumbnailURL: String?
    let isPlanLocked: Bool
}

struct BusinessVenueDashboardPendingVenueItem: Identifiable, Equatable {
    let id: UUID
    let name: String
    let submittedDateText: String
}

enum BusinessVenueDashboardGameDateTimeFormatter {
    static func compactLabel(
        startDate: Date?,
        eventDateRaw: String?,
        eventTimeRaw: String?,
        timeZoneOption: TimeZoneOption,
        calendar: Calendar = .current,
        now: Date = Date()
    ) -> String {
        var displayCalendar = calendar
        displayCalendar.timeZone = CompactGameTimeFormatter.timeZone(for: timeZoneOption)
        let timeText = startDate.map {
            CompactGameTimeFormatter.timeWithZone(for: $0, timeZoneOption: timeZoneOption)
        } ?? CompactGameTimeFormatter.timeWithZone(rawTime: eventTimeRaw, timeZoneOption: timeZoneOption)

        guard let date = startDate ?? parseEventDate(eventDateRaw, calendar: displayCalendar) else {
            return timeText
        }

        return "\(dayLabel(for: date, calendar: displayCalendar, now: now)) • \(timeText)"
    }

    private static func dayLabel(for date: Date, calendar: Calendar, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) {
            return "Today"
        }

        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }

        let today = calendar.startOfDay(for: now)
        let targetDay = calendar.startOfDay(for: date)
        let daysAhead = calendar.dateComponents([.day], from: today, to: targetDay).day
        if let daysAhead, (2...6).contains(daysAhead) {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }

        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func parseEventDate(_ raw: String?, calendar: Calendar) -> Date? {
        let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: String(value.prefix(10)))
    }
}

struct BusinessVenueDashboardOverviewView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let data: BusinessVenueDashboardData
    let businessId: UUID?
    let businessUsageStatus: BusinessVenueGamePostingStatus?
    var activeVenueSelectionSubtitle: String? = nil
    var activeVenueSelectionNotice: String? = nil
    var activeVenueSelectionFootnote: String? = nil
    let onNotifications: () -> Void
    let onMenu: () -> Void
    let onAddGame: () -> Void
    let onAddVenue: () -> Void
    let onTonightGames: () -> Void
    let onPredictions: () -> Void
    let onAnalytics: () -> Void
    let onUsage: () -> Void
    let favoriteTeamsCount: Int
    let onManageFavoriteTeams: () -> Void
    var onActiveVenueSelection: (() -> Void)?
    let onCommentsReports: () -> Void
    let onViewAllGames: () -> Void
    let onRefreshVenues: () -> Void
    let onRefreshPendingVenue: (BusinessVenueDashboardPendingVenueItem) async -> Bool
    let onResendPendingVenue: (BusinessVenueDashboardPendingVenueItem) async -> Bool
    let onCancelPendingVenue: (BusinessVenueDashboardPendingVenueItem) async -> Bool
    let showsManagedVenuesSection: Bool
    let isStatisticsProActive: Bool
    let isAddVenueAllowed: Bool
    let isHostedGameAllowed: Bool
    var isVenueHydrationReady: Bool = true
    var venueHydrationReason: String = "ready"

    private var hasManagedVenues: Bool {
        data.managedVenueCount > 0
    }

    private var venueActionLoadingSubtitle: String? {
        isVenueHydrationReady ? nil : "Loading"
    }

    private var statisticsAccessGranted: Bool {
        businessUsageStatus?.statisticsAccessGranted ?? isStatisticsProActive
    }

    private var proGold: Color {
        Color(red: 0.86, green: 0.63, blue: 0.22)
    }

    private var usageQuickActionState: BusinessUsageQuickActionState {
        BusinessUsageQuickActionState(status: businessUsageStatus)
    }

    private var upcomingGamesTitle: String {
        let venueName = data.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !venueName.isEmpty else { return "Upcoming games" }
        return "Upcoming games at \(venueName)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quickActions
            tonightSection
            if showsManagedVenuesSection {
                managedVenuesSection
            }
        }
        .onAppear {
#if DEBUG
            print("[BusinessDashboardCleanup] removedDarkFanLevelCard=true")
            print("[BusinessDashboardDebug] addVenueQuickActionVisible=true")
            print("[BusinessDashboardLayoutDebug] quickActionOrderUpdated=true")
            logBusinessUsageStatusDebug()
#endif
        }
        .onChange(of: businessUsageStatus) { _, _ in
            logBusinessUsageStatusDebug()
        }
        .onChange(of: businessId) { _, _ in
            logBusinessUsageStatusDebug()
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("quick_actions", languageCode: appLanguageRaw))
                .font(FGTypography.cardTitle.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    BusinessVenueDashboardActionCard(
                        title: "Usage",
                        systemImage: "chart.line.uptrend.xyaxis",
                        tint: usageQuickActionState.tint,
                        badgeText: usageQuickActionState.badgeText,
                        action: onUsage
                    )
                    if let activeVenueSelectionSubtitle {
                        BusinessVenueDashboardActionCard(
                            title: "Active Venues",
                            subtitle: activeVenueSelectionSubtitle,
                            systemImage: "checkmark.seal",
                            tint: FGColor.accentGreen,
                            badgeText: nil,
                            isPremium: false,
                            isLimited: false,
                            action: { onActiveVenueSelection?() }
                        )
                    }
                    BusinessVenueDashboardActionCard(
                        title: L10n.t("add_venue", languageCode: appLanguageRaw),
                        subtitle: addVenueAccessSubtitle,
                        systemImage: isAddVenueAllowed ? "plus.circle.fill" : "lock.fill",
                        tint: isAddVenueAllowed ? FGColor.accentBlue : Color.gray,
                        badgeText: nil,
                        isPremium: false,
                        isLimited: !isAddVenueAllowed,
                        action: handleAddVenueTapped
                    )
                    if hasManagedVenues {
                        BusinessVenueDashboardActionCard(
                            title: L10n.t("venue_details", languageCode: appLanguageRaw),
                            subtitle: venueActionLoadingSubtitle,
                            systemImage: isVenueHydrationReady ? "photo.on.rectangle.angled" : "hourglass",
                            tint: isVenueHydrationReady ? FGColor.accentBlue : Color.gray,
                            isLimited: !isVenueHydrationReady,
                            action: { performHydratedVenueAction("venueDetails", action: onAddGame) }
                        )
                        BusinessVenueDashboardActionCard(
                            title: L10n.t("manage_games", languageCode: appLanguageRaw),
                            subtitle: isVenueHydrationReady ? "Scheduled games" : "Loading",
                            systemImage: isVenueHydrationReady ? "sportscourt" : "hourglass",
                            tint: isVenueHydrationReady ? FGColor.accentGreen : Color.gray,
                            badgeText: nil,
                            isPremium: false,
                            isLimited: !isVenueHydrationReady,
                            action: {
                                performHydratedVenueAction("manageGames", action: onTonightGames)
                            }
                        )
                        BusinessVenueDashboardActionCard(
                            title: L10n.t("statistics", languageCode: appLanguageRaw),
                            subtitle: statisticsAccessGranted ? nil : "Pro",
                            systemImage: statisticsAccessGranted ? "chart.bar.xaxis" : "lock.fill",
                            tint: proGold,
                            badgeText: "PRO",
                            isPremium: true,
                            isLimited: !statisticsAccessGranted,
                            action: onAnalytics
                        )
                    }
                    BusinessVenueDashboardActionCard(
                        title: "Favorite Teams",
                        subtitle: favoriteTeamsQuickActionSubtitle,
                        systemImage: "star.circle.fill",
                        tint: FGColor.accentBlue,
                        badgeText: nil,
                        isPremium: false,
                        isLimited: false,
                        action: onManageFavoriteTeams
                    )
                    BusinessVenueDashboardActionCard(
                        title: "Flagged Comments",
                        subtitle: "Review reports",
                        systemImage: "exclamationmark.bubble",
                        tint: FGColor.accentYellow,
                        badgeText: nil,
                        isPremium: false,
                        isLimited: false,
                        action: onCommentsReports
                    )
                }
                .padding(.vertical, 3)
            }

            if let activeVenueSelectionNotice {
                activeVenueSelectionInfoBanner(activeVenueSelectionNotice, tint: FGColor.accentBlue)
            } else if let activeVenueSelectionFootnote {
                activeVenueSelectionInfoBanner(activeVenueSelectionFootnote, tint: FGColor.accentGreen)
            }
        }
    }

    private var addVenueAccessSubtitle: String? {
        guard businessUsageStatus != nil else { return "Checking access..." }
        return isAddVenueAllowed ? nil : "Limit reached"
    }

    private var favoriteTeamsQuickActionSubtitle: String {
        if favoriteTeamsCount == 0 { return "No teams" }
        if favoriteTeamsCount == 1 { return "1 team" }
        return "\(favoriteTeamsCount) teams"
    }

    private func activeVenueSelectionInfoBanner(_ message: String, tint: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
            Text(message)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(tint.opacity(colorScheme == .dark ? 0.15 : 0.08))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func handleAddVenueTapped() {
#if DEBUG
        print("[BusinessDashboardDebug] addVenueQuickActionTapped=true allowed=\(isAddVenueAllowed)")
#endif
        onAddVenue()
    }

    private func performHydratedVenueAction(_ actionName: String, action: () -> Void) {
        guard isVenueHydrationReady else {
#if DEBUG
            print("[BusinessProfileHydrationDebug] blockedEarlyTap action=\(actionName) reason=\(venueHydrationReason)")
#endif
            return
        }
        action()
    }

    private func logBusinessUsageStatusDebug() {
#if DEBUG
        let state = usageQuickActionState
        let activeVenueLimit = businessUsageStatus.map { $0.activeVenueLimit.map(String.init) ?? "unlimited" } ?? "unknown"
        let monthlyHostedGameLimit = businessUsageStatus.map { $0.monthlyHostedGameLimit.map(String.init) ?? "unlimited" } ?? "unknown"
        print("[BusinessUsageStatusDebug] businessId=\(businessId?.uuidString.lowercased() ?? "nil")")
        print("[BusinessUsageStatusDebug] isBusinessPro=\(businessUsageStatus?.isBusinessPro.description ?? "unknown")")
        print("[BusinessUsageStatusDebug] activeVenueCount=\(businessUsageStatus.map { String($0.activeVenueCount) } ?? "unknown")")
        print("[BusinessUsageStatusDebug] activeVenueLimit=\(activeVenueLimit)")
        print("[BusinessUsageStatusDebug] hostedGamesThisMonth=\(businessUsageStatus.map { String($0.monthlyHostedGameCount) } ?? "unknown")")
        print("[BusinessUsageStatusDebug] hostedGamesUsedThisCycle=\(businessUsageStatus.flatMap { $0.hostedGamesUsedThisCycle }.map(String.init) ?? "unknown")")
        print("[BusinessUsageStatusDebug] monthlyHostedGameLimit=\(monthlyHostedGameLimit)")
        print("[BusinessUsageStatusDebug] nextResetAt=\(businessUsageStatus?.nextResetAt ?? "unknown")")
        print("[BusinessUsageStatusDebug] usageStatusColor=\(state.usageStatusColor)")
        print("[BusinessUsageStatusDebug] reason=\(state.reason)")
#endif
    }

    private var tonightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(upcomingGamesTitle)
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                Spacer()
                if hasManagedVenues {
                    Button {
                        performHydratedVenueAction("manageGames", action: onViewAllGames)
                    } label: {
                        Text(L10n.t("view_all", languageCode: appLanguageRaw))
                    }
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(isVenueHydrationReady ? FGColor.accentBlue : Color.gray)
                }
            }

            VStack(spacing: 0) {
                if data.games.isEmpty {
                    emptyTonightState
                } else {
                    ForEach(Array(data.games.prefix(3).enumerated()), id: \.element.id) { index, game in
                        BusinessVenueDashboardGameRow(game: game)
                        if index < min(data.games.count, 3) - 1 {
                            Divider()
                                .overlay(FGColor.divider(colorScheme))
                                .padding(.leading, 54)
                        }
                    }
                }
            }
            .background(FGColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.78), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.05), radius: 12, y: 6)
        }
        .onAppear(perform: logUpcomingLabelDebug)
    }

    private var managedVenuesSection: some View {
        Group {
            if isVenueHydrationReady {
                managedVenuesReadySection
            } else {
                managedVenuesLoadingPlaceholder
            }
        }
        .onAppear {
            logBusinessManagedVenuesSectionRendered()
        }
        .onChange(of: managedVenuesHitTestingDebugToken) { _, _ in
            logBusinessManagedVenuesSectionRendered()
        }
    }

    private var managedVenuesReadySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Managed venues")
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text("\(data.approvedVenues.count) total")
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FGColor.secondaryText(colorScheme).opacity(colorScheme == .dark ? 0.16 : 0.08))
                    .clipShape(Capsule(style: .continuous))
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 14) {
                venueStatusGroup(
                    title: "Approved venues",
                    emptyText: "No approved venues yet",
                    tint: FGColor.accentGreen
                ) {
                    ForEach(data.approvedVenues) { venue in
                        approvedVenueRow(venue)
                    }
                }

                Divider()
                    .overlay(FGColor.divider(colorScheme))

                venueStatusGroup(
                    title: "Pending venues",
                    emptyText: "No pending venues",
                    tint: .orange
                ) {
                    ForEach(data.pendingVenues) { venue in
                        pendingVenueRow(venue)
                    }
                }
            }
            .padding(12)
            .background(FGColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.78), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.05), radius: 12, y: 6)
        }
        .allowsHitTesting(false)
    }

    private var managedVenuesLoadingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Managed venues")
                .font(FGTypography.cardTitle.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text("Loading venues...")
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(FGColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.65), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }

    private var managedVenuesHitTestingDebugToken: String {
        let activeCount = data.approvedVenues.filter { !$0.isPlanLocked }.count
        let lockedCount = data.approvedVenues.filter(\.isPlanLocked).count
        return "\(data.approvedVenues.count)|\(activeCount)|\(lockedCount)"
    }

    private func logBusinessManagedVenuesSectionRendered() {
#if DEBUG
        let count = data.approvedVenues.count
        let activeCount = data.approvedVenues.filter { !$0.isPlanLocked }.count
        let lockedCount = data.approvedVenues.filter(\.isPlanLocked).count
        print("[BusinessManagedVenuesDebug] sectionRendered count=\(count) activeCount=\(activeCount) lockedCount=\(lockedCount) hydrationReady=\(isVenueHydrationReady)")
#endif
    }

    @ViewBuilder
    private func venueStatusGroup<Content: View>(
        title: String,
        emptyText: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(tint)
                    .frame(width: 7, height: 7)
                Text(title)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .textCase(.uppercase)
            }

            if (title == "Approved venues" && data.approvedVenues.isEmpty)
                || (title == "Pending venues" && data.pendingVenues.isEmpty) {
                Text(emptyText)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.vertical, 4)
            } else {
                content()
            }
        }
    }

    private func approvedVenueRow(_ venue: BusinessVenueDashboardApprovedVenueItem) -> some View {
        let tint = venue.isPlanLocked ? Color.gray : FGColor.accentGreen
        return HStack(alignment: .center, spacing: 12) {
            venueThumbnail(venue)
                .opacity(venue.isPlanLocked ? 0.45 : 1)

            VStack(alignment: .leading, spacing: 5) {
                Text(venue.name)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(venue.isPlanLocked ? FGColor.secondaryText(colorScheme) : FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text(venue.locationLine.isEmpty ? venue.approvedDateText : venue.locationLine)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                Text(venue.isPlanLocked ? BusinessLimitCopy.planLockedVenueSubtitle : venue.approvedDateText)
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(venue.isPlanLocked ? Color.gray : FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            statusPill(venue.isPlanLocked ? "Inactive" : "Active", tint: tint)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(venue.isPlanLocked ? Color.gray.opacity(colorScheme == .dark ? 0.12 : 0.08) : FGAdaptiveSurface.cardElevated)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tint.opacity(venue.isPlanLocked ? 0.22 : 0.28), lineWidth: 1)
        }
        .opacity(venue.isPlanLocked ? 0.72 : 1)
    }

    private func venueThumbnail(_ venue: BusinessVenueDashboardApprovedVenueItem) -> some View {
        let rawURL = (venue.venuePhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? (venue.venuePhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        return ZStack {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))

            if let rawURL, let url = URL(string: rawURL) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(image):
                        image
                            .resizable()
                            .scaledToFill()
                    case .failure:
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(FGColor.accentBlue)
                    case .empty:
                        ProgressView()
                            .tint(FGColor.accentBlue)
                    @unknown default:
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                }
            } else {
                Image(systemName: venue.isPlanLocked ? "lock.fill" : "building.2.fill")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(venue.isPlanLocked ? Color.gray : FGColor.accentBlue)
            }
        }
        .frame(width: 54, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private func pendingVenueRow(_ venue: BusinessVenueDashboardPendingVenueItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            statusIcon(systemName: "hourglass.circle.fill", tint: .orange)
            VStack(alignment: .leading, spacing: 3) {
                Text(venue.name)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text("Pending approval • \(venue.submittedDateText)")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
            statusPill("Pending", tint: .orange)
        }
        .padding(.vertical, 4)
    }

    private func statusIcon(systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.caption.weight(.bold))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
    }

    private func statusPill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
            .clipShape(Capsule(style: .continuous))
    }

    private var emptyTonightState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasManagedVenues ? "No upcoming games at \(data.venueName)" : "No venue yet")
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(hasManagedVenues ? "Add a game to turn this dashboard into a live fan hub." : "Add your first venue to manage details and games.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Button {
                if hasManagedVenues {
                    performHydratedVenueAction("manageGames", action: onTonightGames)
                } else {
                    handleAddVenueTapped()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: hasManagedVenues && !isVenueHydrationReady ? "hourglass" : (hasManagedVenues ? "sportscourt" : "plus.circle.fill"))
                        .font(.caption.weight(.bold))
                        .imageScale(.medium)
                    Text(hasManagedVenues ? L10n.t("manage_games", languageCode: appLanguageRaw) : L10n.t("add_venue", languageCode: appLanguageRaw))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(FGColor.brandGradient)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func logUpcomingLabelDebug() {
#if DEBUG
        let nearest = data.gameSectionContext.nearestGameDate.map { $0.formatted(date: .numeric, time: .shortened) } ?? "none"
        print("[VenueUpcomingLabelDebug] nearestGameDate=\(nearest)")
        print("[VenueUpcomingLabelDebug] resolvedLabel=\(data.gameSectionContext.label.title(languageCode: appLanguageRaw))")
        print("[VenueUpcomingLabelDebug] upcomingCount=\(data.gameSectionContext.upcomingCount)")
#endif
    }

}

private struct BusinessUsageQuickActionState {
    let tint: Color
    let badgeText: String?
    let usageStatusColor: String
    let reason: String

    init(status: BusinessVenueGamePostingStatus?) {
        guard let status else {
            tint = FGColor.accentBlue
            badgeText = nil
            usageStatusColor = "neutral"
            reason = "loading_unknown"
            return
        }

        if status.isBusinessPro {
            tint = FGColor.accentGreen
            badgeText = "OK"
            usageStatusColor = "green"
            reason = "business_pro_unlimited"
            return
        }

        let activeVenueLimit = max(1, status.activeVenueLimit ?? status.venueLimit)
        let monthlyHostedGameLimit = max(1, status.monthlyHostedGameLimit ?? status.monthlyHostLimit)
        let venueLimitReached = status.activeVenueCount >= activeVenueLimit
        let hostedGameLimitReached = status.hostedGamesUsedForDisplay >= monthlyHostedGameLimit

        if venueLimitReached || hostedGameLimitReached {
            tint = FGColor.dangerRed
            badgeText = "Limit"
            usageStatusColor = "red"
            switch (venueLimitReached, hostedGameLimitReached) {
            case (true, true):
                reason = "venue_and_hosted_game_limits_reached"
            case (true, false):
                reason = "active_venue_limit_reached"
            case (false, true):
                reason = "monthly_hosted_game_limit_reached"
            case (false, false):
                reason = "within_limits"
            }
        } else {
            tint = FGColor.accentGreen
            badgeText = "OK"
            usageStatusColor = "green"
            reason = "within_limits"
        }
    }
}

private struct BusinessVenueDashboardActionCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    var subtitle: String? = nil
    let systemImage: String
    let tint: Color
    var badgeText: String? = nil
    var isPremium: Bool = false
    var isLimited: Bool = false
    let action: () -> Void

    private var proGoldDeep: Color {
        Color(red: 0.52, green: 0.35, blue: 0.11)
    }

    private var proGlyphInk: Color {
        Color(red: 0.08, green: 0.06, blue: 0.025)
    }

    var body: some View {
        Button {
            action()
        } label: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: subtitle == nil ? 10 : 7) {
                    Image(systemName: systemImage)
                        .font(.title3.weight(.bold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(isLimited ? tint.opacity(0.78) : tint)
                        .frame(height: 24)

                    VStack(spacing: 2) {
                        Text(title)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)

                        if let subtitle {
                            Text(subtitle)
                                .font(.system(size: 8.8, weight: .heavy, design: .rounded))
                                .foregroundStyle(tint.opacity(colorScheme == .dark ? 0.96 : 0.90))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.74)
                        }
                    }
                }
                .padding(.top, badgeText == nil ? 0 : 4)

                if let badgeText {
                    Text(badgeText)
                        .font(.system(size: 8, weight: .heavy, design: .rounded))
                        .foregroundStyle(proGlyphInk.opacity(0.94))
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color(red: 1.0, green: 0.84, blue: 0.42),
                                            tint
                                        ],
                                        startPoint: .topLeading,
                                        endPoint: .bottomTrailing
                                    )
                                )
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(proGoldDeep.opacity(0.34), lineWidth: 0.7)
                        }
                        .offset(x: 7, y: -7)
                }
            }
            .frame(width: isPremium ? 88 : 82, height: isPremium ? 98 : 92)
            .background(actionCardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(actionCardStroke, lineWidth: isPremium ? 1.1 : 1)
            }
            .shadow(
                color: isPremium
                    ? tint.opacity(colorScheme == .dark ? 0.18 : 0.12)
                    : .black.opacity(colorScheme == .dark ? 0.16 : 0.05),
                radius: isPremium ? 11 : 10,
                x: 0,
                y: 6
            )
            .opacity(isLimited ? 0.86 : 1)
        }
        .buttonStyle(.plain)
        .accessibilityHint(isLimited ? (isPremium ? "Business Pro required" : "Limit reached or venue locked") : "")
    }

    private var actionCardBackground: some ShapeStyle {
        if isPremium {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        tint.opacity(colorScheme == .dark ? 0.20 : 0.12),
                        FGColor.cardBackground(colorScheme)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        return AnyShapeStyle(FGColor.cardBackground(colorScheme))
    }

    private var actionCardStroke: Color {
        isPremium ? tint.opacity(colorScheme == .dark ? 0.42 : 0.30) : FGColor.divider(colorScheme)
    }
}

private struct BusinessVenueDashboardGameRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let game: BusinessVenueDashboardGameItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: game.sportIconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(game.timeText)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)

                    if !game.subtitle.isEmpty {
                        Text("•")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                        Text(game.subtitle)
                            .font(.caption2)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Label(String(format: L10n.t("going_count_format", languageCode: appLanguageRaw), "\(game.goingCount)"), systemImage: "person.2")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                Text(game.energyLabel)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(game.energyTint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(game.energyTint.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .clipShape(Capsule())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
    }
}
