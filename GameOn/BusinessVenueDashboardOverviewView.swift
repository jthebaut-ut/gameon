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
    let games: [BusinessVenueDashboardGameItem]
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

struct BusinessVenueDashboardOverviewView: View {
    @Environment(\.colorScheme) private var colorScheme

    let data: BusinessVenueDashboardData
    let onNotifications: () -> Void
    let onMenu: () -> Void
    let onAddGame: () -> Void
    let onTonightGames: () -> Void
    let onPredictions: () -> Void
    let onAnalytics: () -> Void
    let onCommentsReports: () -> Void
    let onViewAllGames: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            venueHeader
            liveEnergyHero
            dashboardMetricStrip
            quickActions
            tonightSection
            performanceSection
        }
    }

    private var venueHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            venueAvatar

            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(data.venueName)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)

                    if data.isVerified {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                }

                Text(data.locationLine)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                HStack(spacing: 7) {
                    dashboardPill("Business owner", tint: FGColor.businessGreen)
                    dashboardPill(data.managedVenueCount == 1 ? "1 managed venue" : "\(data.managedVenueCount) managed venues", tint: FGColor.mutedText(colorScheme))
                }
            }

            Spacer(minLength: 8)

            headerIconButton(systemImage: "bell", action: onNotifications)
            headerIconButton(systemImage: "line.3.horizontal", action: onMenu)
        }
    }

    private var liveEnergyHero: some View {
        ZStack(alignment: .bottomLeading) {
            heroBackground

            LinearGradient(
                colors: [
                    Color.black.opacity(colorScheme == .dark ? 0.58 : 0.42),
                    Color.black.opacity(0.05)
                ],
                startPoint: .bottomLeading,
                endPoint: .topTrailing
            )

            VStack(alignment: .leading, spacing: 10) {
                Text("LIVE NOW")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(FGColor.dangerRed)
                    .clipShape(Capsule())

                VStack(alignment: .leading, spacing: 6) {
                    Text(liveEnergyTitle)
                        .font(.title2.weight(.black))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    Text(liveEnergySubtitle)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(1)
                }
            }
            .padding(18)
        }
        .frame(height: 188)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 18, x: 0, y: 10)
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.45), lineWidth: 1)
        }
    }

    private var dashboardMetricStrip: some View {
        HStack(spacing: 0) {
            dashboardMetric(systemImage: "person.3.fill", value: "\(data.fansGoing)", title: "Fans going", tint: FGColor.accentGreen)
            metricDivider
            dashboardMetric(systemImage: "bubble.left.and.bubble.right.fill", value: "\(data.activeChats)", title: "Active chats", tint: FGColor.accentBlue)
            metricDivider
            dashboardMetric(systemImage: "target", value: "\(data.predictions)", title: "Predictions", tint: FGColor.accentYellow)
            metricDivider
            dashboardMetric(systemImage: "star.fill", value: data.atmosphereRating, title: "Atmosphere", tint: FGColor.accentYellow)
        }
        .padding(.vertical, 12)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 12, x: 0, y: 6)
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick actions")
                .font(FGTypography.cardTitle.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    BusinessVenueDashboardActionCard(title: "Venue Details", systemImage: "photo.on.rectangle.angled", tint: FGColor.accentBlue, action: onAddGame)
                    BusinessVenueDashboardActionCard(title: "Manage Games", systemImage: "sportscourt", tint: FGColor.accentGreen, action: onTonightGames)
                    BusinessVenueDashboardActionCard(title: "Statistics", systemImage: "chart.bar.xaxis", tint: Color.orange, action: onAnalytics)
                    BusinessVenueDashboardActionCard(title: "Flagged Comments", systemImage: "exclamationmark.bubble", tint: Color.gray, action: onCommentsReports)
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var tonightSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Tonight at your venue")
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer()
                Button("View all", action: onViewAllGames)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
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
    }

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("This week's performance")
                .font(FGTypography.cardTitle.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(spacing: 0) {
                dashboardMetric(systemImage: "person.3.fill", value: "\(data.fansGoing)", title: "Total fans", tint: FGColor.accentGreen)
                dashboardMetric(systemImage: "bubble.left.and.bubble.right.fill", value: "\(data.activeChats)", title: "New chats", tint: FGColor.accentBlue)
                dashboardMetric(systemImage: "target", value: "\(data.predictions)", title: "Predictions", tint: FGColor.accentYellow)
                dashboardMetric(systemImage: "star.fill", value: data.atmosphereRating, title: "Avg. atmosphere", tint: FGColor.accentYellow)
            }

            lightweightMomentumChart
        }
        .padding(16)
        .background(FGColor.cardBackground(colorScheme))
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private var venueAvatar: some View {
        ZStack {
            Circle()
                .fill(FGColor.accentBlue.opacity(0.15))

            if let url = resolvedPhotoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        Image(systemName: "building.2.fill")
                            .font(.title2.weight(.bold))
                            .foregroundStyle(FGColor.accentBlue)
                    }
                }
            } else {
                Image(systemName: "building.2.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
            }
        }
        .frame(width: 68, height: 68)
        .clipShape(Circle())
    }

    private var heroBackground: some View {
        Group {
            if let url = resolvedPhotoURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        heroFallbackGradient
                    }
                }
            } else {
                heroFallbackGradient
            }
        }
    }

    private var heroFallbackGradient: some View {
        LinearGradient(
            colors: [
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.58 : 0.72),
                FGColor.businessGreen.opacity(colorScheme == .dark ? 0.44 : 0.56),
                Color.black.opacity(colorScheme == .dark ? 0.38 : 0.22)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var resolvedPhotoURL: URL? {
        let raw = ImageDisplayURL.forDetail(
            thumbnail: data.venuePhotoThumbnailURL,
            full: data.venuePhotoURL
        )
        return raw.flatMap(URL.init(string:))
    }

    private var liveEnergyTitle: String {
        if data.fansGoing >= 30 || data.activeChats >= 12 {
            return "Your venue is popping!"
        }
        if data.fansGoing >= 10 || data.activeChats >= 4 {
            return "Crowd momentum is building"
        }
        return "Tonight starts here"
    }

    private var liveEnergySubtitle: String {
        let gameWord = data.games.count == 1 ? "game" : "games"
        return "\(data.fansGoing) fans - \(data.games.count) \(gameWord) - \(energySummary)"
    }

    private var energySummary: String {
        if data.fansGoing >= 30 || data.activeChats >= 12 { return "High energy" }
        if data.fansGoing >= 10 || data.activeChats >= 4 { return "Building" }
        return "Normal"
    }

    private var metricDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme))
            .frame(width: 1, height: 44)
    }

    private func dashboardMetric(systemImage: String, value: String, title: String, tint: Color) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(tint)
                Text(value)
                    .font(.headline.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity)
    }

    private func dashboardPill(_ title: String, tint: Color) -> some View {
        Text(title)
            .font(.caption2.weight(.bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.10))
            .clipShape(Capsule())
    }

    private func headerIconButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .frame(width: 38, height: 38)
                .background(FGColor.cardBackground(colorScheme))
                .clipShape(Circle())
                .overlay {
                    Circle().strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var emptyTonightState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No games scheduled tonight")
                .font(FGTypography.cardTitle)
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text("Add a game to turn this dashboard into a live fan hub.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
            Button(action: onTonightGames) {
                Label("Manage Games", systemImage: "sportscourt")
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

    private var lightweightMomentumChart: some View {
        let values = momentumValues
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule(style: .continuous)
                    .fill(FGColor.accentBlue.opacity(0.28 + (Double(value) * 0.06)))
                    .frame(height: CGFloat(18 + value * 6))
            }
        }
        .frame(height: 72, alignment: .bottom)
        .padding(.horizontal, 4)
        .background(
            LinearGradient(
                colors: [FGColor.accentBlue.opacity(0.10), Color.clear],
                startPoint: .bottom,
                endPoint: .top
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var momentumValues: [Int] {
        let base = max(1, min(8, data.fansGoing / 6 + data.activeChats / 4 + data.predictions / 10))
        return [1, 2, 3, 2, 4, 3, 5, 4, 5, 4, 5, base, min(8, base + 1), min(8, base + 2)]
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

    let game: BusinessVenueDashboardGameItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: game.sportIconName)
                .font(.title2.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 34, height: 34)

            VStack(alignment: .leading, spacing: 3) {
                Text(game.timeText)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.accentBlue)
                Text(game.title)
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text(game.subtitle)
                    .font(.caption2)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                Label("\(game.goingCount) going", systemImage: "person.2")
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
