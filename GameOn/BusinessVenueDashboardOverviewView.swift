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
    let onNotifications: () -> Void
    let onMenu: () -> Void
    let onAddGame: () -> Void
    let onAddVenue: () -> Void
    let onTonightGames: () -> Void
    let onPredictions: () -> Void
    let onAnalytics: () -> Void
    let onCommentsReports: () -> Void
    let onViewAllGames: () -> Void

    private var hasManagedVenues: Bool {
        data.managedVenueCount > 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quickActions
            tonightSection
        }
        .onAppear {
#if DEBUG
            print("[BusinessDashboardCleanup] removedDarkFanLevelCard=true")
            print("[BusinessDashboardDebug] addVenueQuickActionVisible=true")
            print("[BusinessDashboardLayoutDebug] quickActionOrderUpdated=true")
#endif
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L10n.t("quick_actions", languageCode: appLanguageRaw))
                .font(FGTypography.cardTitle.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    BusinessVenueDashboardActionCard(title: L10n.t("add_venue", languageCode: appLanguageRaw), systemImage: "plus.circle.fill", tint: FGColor.accentBlue, action: handleAddVenueTapped)
                    if hasManagedVenues {
                        BusinessVenueDashboardActionCard(title: L10n.t("venue_details", languageCode: appLanguageRaw), systemImage: "photo.on.rectangle.angled", tint: FGColor.accentBlue, action: onAddGame)
                        BusinessVenueDashboardActionCard(title: L10n.t("manage_games", languageCode: appLanguageRaw), systemImage: "sportscourt", tint: FGColor.accentGreen, action: onTonightGames)
                        BusinessVenueDashboardActionCard(title: L10n.t("statistics", languageCode: appLanguageRaw), systemImage: "chart.bar.xaxis", tint: Color.orange, action: onAnalytics)
                        BusinessVenueDashboardActionCard(title: "Flagged Comments", systemImage: "exclamationmark.bubble", tint: Color.gray, action: onCommentsReports)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    private func handleAddVenueTapped() {
#if DEBUG
        print("[BusinessDashboardDebug] addVenueQuickActionTapped=true")
#endif
        onAddVenue()
    }

    private var tonightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(data.gameSectionContext.label.title(languageCode: appLanguageRaw))
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer()
                if hasManagedVenues {
                    Button(L10n.t("view_all", languageCode: appLanguageRaw), action: onViewAllGames)
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.accentBlue)
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
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
        }
        .onAppear(perform: logUpcomingLabelDebug)
    }

    private var emptyTonightState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hasManagedVenues ? data.gameSectionContext.label.title(languageCode: appLanguageRaw) : "No venue yet")
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(hasManagedVenues ? "Add a game to turn this dashboard into a live fan hub." : "Add your first venue to manage details and games.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Button(action: hasManagedVenues ? onTonightGames : handleAddVenueTapped) {
                Label(
                    hasManagedVenues ? L10n.t("manage_games", languageCode: appLanguageRaw) : L10n.t("add_venue", languageCode: appLanguageRaw),
                    systemImage: hasManagedVenues ? "sportscourt" : "plus.circle.fill"
                )
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(FGColor.brandGradient)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
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

private struct BusinessVenueDashboardActionCard: View {
    @Environment(\.colorScheme) private var colorScheme

    let title: String
    let systemImage: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: systemImage)
                    .font(.title3.weight(.bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(tint)
                    .frame(height: 24)

                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
            }
            .frame(width: 82, height: 92)
            .background(FGColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
            }
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.05), radius: 10, x: 0, y: 6)
        }
        .buttonStyle(.plain)
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
