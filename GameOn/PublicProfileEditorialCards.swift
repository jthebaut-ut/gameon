import SwiftUI

// MARK: - Design chrome

extension View {
    func publicProfileEditorialCard(cornerRadius: CGFloat = 22) -> some View {
        modifier(PublicProfileEditorialCardModifier(cornerRadius: cornerRadius))
    }
}

private struct PublicProfileEditorialCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: colorScheme == .dark
                                        ? [Color.white.opacity(0.10), Color.white.opacity(0.04)]
                                        : [Color.white.opacity(0.92), Color.white.opacity(0.78)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.95),
                                        Color.white.opacity(0.35)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.85
                            )
                    }
                    .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.06), radius: 14, y: 8)
                    .shadow(color: FGColor.accentBlue.opacity(0.04), radius: 18, y: 4)
            }
    }
}

struct PublicProfileEditorialSectionTitle: View {
    let title: String
    let subtitle: String?
    let accent: Color
    @Environment(\.colorScheme) private var colorScheme

    init(_ title: String, subtitle: String? = nil, accent: Color = FGColor.accentBlue) {
        self.title = title
        self.subtitle = subtitle
        self.accent = accent
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(accent.opacity(0.92))
                .textCase(.uppercase)
                .tracking(1.1)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
    }
}

// MARK: - Derived presentation (no extra network)

enum PublicProfileOpenToCategory: String, CaseIterable {
    case watch = "Watch"
    case play = "Play"
    case social = "Social"
}

struct PublicProfileGamedayStatus: Equatable {
    let title: String
    let subtitle: String?
    let badge: String?
    let systemImage: String
    let gradient: [Color]
}

struct PublicProfileActivityRow: Identifiable, Equatable {
    let id: String
    let icon: String
    let tint: Color
    let text: String
}

/// Placeholder for future favorite-sports-moment backend.
struct PublicProfileSportsMoment: Equatable {
    let headline: String
    let yearLabel: String?
    let imageURL: String?
}

enum PublicProfileContentBuilder {
    static let maxPublicOpenToItems = 6

    static func gamedayStatus(from data: PublicUserProfileData, colorScheme: ColorScheme) -> PublicProfileGamedayStatus? {
        let openIDs = Set(data.openToItems.map(\.id))

        if openIDs.contains(FanOpenToSocialID.watchParties) || openIDs.contains(FanOpenToSocialID.sportsBars) {
            let team = data.favoriteTeams.first
            let subtitle = team.map { "Routing for \($0.shortCode ?? $0.name)" }
            return PublicProfileGamedayStatus(
                title: openIDs.contains(FanOpenToSocialID.sportsBars) ? "Bar Hopping" : "Watching Tonight",
                subtitle: subtitle,
                badge: team?.sport.chipTitle,
                systemImage: openIDs.contains(FanOpenToSocialID.sportsBars) ? "wineglass.fill" : "tv.fill",
                gradient: [Color(red: 0.18, green: 0.42, blue: 0.92), Color(red: 0.42, green: 0.22, blue: 0.88)]
            )
        }

        let hasPickupSport = openIDs.contains { id in
            FanOpenToCatalog.definition(id: id)?.isSocial == false
        }
        if hasPickupSport || data.pickupHostedCount > 0 || data.pickupJoinedCount > 0 {
            return PublicProfileGamedayStatus(
                title: "Looking for Pickup",
                subtitle: data.pickupHostedCount > 0 ? "Hosts local runs" : "Ready to join a run",
                badge: "PLAY",
                systemImage: "sportscourt.fill",
                gradient: [FGColor.accentGreen, Color(red: 0.12, green: 0.58, blue: 0.48)]
            )
        }

        if !data.venueCards.isEmpty {
            let venue = data.venueCards[0]
            return PublicProfileGamedayStatus(
                title: "At the Stadium",
                subtitle: venue.venueName,
                badge: venue.cityLabel.isEmpty ? nil : venue.cityLabel,
                systemImage: "building.2.fill",
                gradient: [Color(red: 0.58, green: 0.36, blue: 0.92), Color(red: 0.32, green: 0.22, blue: 0.72)]
            )
        }

        if openIDs.contains(FanOpenToSocialID.meetLocalFans) {
            return PublicProfileGamedayStatus(
                title: data.mutualFansCount > 2 ? "Packed Crowd" : "Bar Hopping",
                subtitle: data.mutualFansCount > 0 ? "\(data.mutualFansCount) mutual fans nearby" : "Open to meet fans",
                badge: "SOCIAL",
                systemImage: "person.3.fill",
                gradient: [Color(red: 0.98, green: 0.55, blue: 0.28), Color(red: 0.92, green: 0.28, blue: 0.42)]
            )
        }

        return nil
    }

    static func groupedOpenTo(_ items: [PublicProfileOpenToItem]) -> [(PublicProfileOpenToCategory, [PublicProfileOpenToItem])] {
        let limited = Array(items.prefix(maxPublicOpenToItems))
        return PublicProfileOpenToCategory.allCases.compactMap { category in
            let bucket = limited.filter { $0.openToCategory == category }
            return bucket.isEmpty ? nil : (category, bucket)
        }
    }

    static func activityTimeline(from data: PublicUserProfileData) -> [PublicProfileActivityRow] {
        var rows: [PublicProfileActivityRow] = []

        for venue in data.venueCards.prefix(2) {
            rows.append(
                PublicProfileActivityRow(
                    id: "venue-\(venue.id)",
                    icon: "mappin.and.ellipse",
                    tint: Color(red: 0.58, green: 0.36, blue: 0.92),
                    text: "Regular at \(venue.venueName)"
                )
            )
        }

        if data.pickupJoinedCount > 0 {
            rows.append(
                PublicProfileActivityRow(
                    id: "pickup-join",
                    icon: "basketball.fill",
                    tint: FavoriteTeamSport.basketball.accentColor,
                    text: "Joined local pickup games"
                )
            )
        } else if data.pickupHostedCount > 0 {
            rows.append(
                PublicProfileActivityRow(
                    id: "pickup-host",
                    icon: "figure.run.circle.fill",
                    tint: FGColor.accentGreen,
                    text: "Hosts pickup games in the area"
                )
            )
        }

        if data.sharedTeamsCount > 0 {
            let label = data.sharedTeamsCount == 1 ? "1 shared favorite team" : "\(data.sharedTeamsCount) shared favorite teams"
            rows.append(
                PublicProfileActivityRow(
                    id: "shared-teams",
                    icon: "star.circle.fill",
                    tint: FGColor.accentBlue,
                    text: label
                )
            )
        }

        for highlight in data.socialHighlightLabels where !rows.contains(where: { $0.text == highlight }) {
            rows.append(
                PublicProfileActivityRow(
                    id: "highlight-\(highlight.hashValue)",
                    icon: "sparkles",
                    tint: FGColor.accentGreen,
                    text: highlight
                )
            )
        }

        return Array(rows.prefix(4))
    }

    static func sportsMoment(from data: PublicUserProfileData) -> PublicProfileSportsMoment? {
        _ = data
        return nil
    }

    static func homeCrowdVenue(from data: PublicUserProfileData) -> PublicProfileVenueCard? {
        data.venueCards.first
    }

    static func venuesExcludingHomeCrowd(from data: PublicUserProfileData) -> [PublicProfileVenueCard] {
        guard data.venueCards.count > 1 else { return [] }
        return Array(data.venueCards.dropFirst())
    }
}

extension PublicProfileOpenToItem {
    var editorialShortTitle: String {
        if isSocial {
            switch id {
            case FanOpenToSocialID.watchParties: return "Watch"
            case FanOpenToSocialID.sportsBars: return "Bars"
            case FanOpenToSocialID.meetLocalFans: return "Fans"
            default: return title
            }
        }
        let short = AppSportCatalog.displayLabel(forSportToken: id)
        if short.count <= 10 { return short }
        return String(short.prefix(8))
    }

    var openToCategory: PublicProfileOpenToCategory {
        if isSocial {
            switch id {
            case FanOpenToSocialID.watchParties, FanOpenToSocialID.sportsBars:
                return .watch
            default:
                return .social
            }
        }
        return .play
    }
}

extension PublicUserProfileData {
    var editorialOpenToItems: [PublicProfileOpenToItem] {
        Array(openToItems.prefix(PublicProfileContentBuilder.maxPublicOpenToItems))
    }
}

// MARK: - Two-column grid (mock layout)

struct PublicProfileTwoColumnGrid: View {
    let data: PublicUserProfileData
    let colorScheme: ColorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 10),
        GridItem(.flexible(), spacing: 10)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            if let homeVenue = PublicProfileContentBuilder.homeCrowdVenue(from: data) {
                PublicProfileGridHomeCrowdCard(
                    venue: homeVenue,
                    mutualFansCount: data.mutualFansCount,
                    mutualAvatars: data.mutualFanAvatars,
                    memberSinceLabel: data.memberSinceLabel
                )
            }

            if let gameday = PublicProfileContentBuilder.gamedayStatus(from: data, colorScheme: colorScheme) {
                PublicProfileGridGamedayCard(status: gameday, favoriteTeams: data.favoriteTeams)
            }

            if !venuesForGrid.isEmpty {
                PublicProfileGridVenuesCard(venues: venuesForGrid, totalCount: data.venueCount)
            }

            if !data.editorialOpenToItems.isEmpty {
                PublicProfileGridOpenToCard(items: data.editorialOpenToItems)
            }

            let activity = PublicProfileContentBuilder.activityTimeline(from: data)
            if !activity.isEmpty {
                PublicProfileGridActivityCard(rows: activity)
            }

            if data.mutualFansCount > 0 {
                PublicProfileGridMutualFansCard(
                    count: data.mutualFansCount,
                    avatars: data.mutualFanAvatars,
                    sharedTeamNames: data.sharedTeamNames,
                    sharedTeamsCount: data.sharedTeamsCount,
                    favoriteTeams: data.favoriteTeams
                )
            }
        }
    }

    private var venuesForGrid: [PublicProfileVenueCard] {
        let extra = PublicProfileContentBuilder.venuesExcludingHomeCrowd(from: data)
        if !extra.isEmpty { return extra }
        if PublicProfileContentBuilder.homeCrowdVenue(from: data) != nil { return [] }
        return data.venueCards
    }
}

// MARK: - Hero header

struct PublicProfileEditorialHero: View {
    let data: PublicUserProfileData
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                avatar

                VStack(alignment: .leading, spacing: 5) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(data.displayName)
                            .font(.system(size: 22, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.8)

                        if data.reputation.privileges.isVerifiedOrganizer {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color(red: 0.58, green: 0.36, blue: 0.92))
                        }
                    }

                    Text(data.publicHandleLine)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    if !data.reputation.profileSubtitle.isEmpty {
                        Text(data.reputation.profileSubtitle)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(Color(red: 0.58, green: 0.36, blue: 0.92).opacity(0.92))
                            .lineLimit(2)
                    }

                    if !data.favoriteTeams.isEmpty {
                        favoriteTeamsStrip
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(spacing: 8) {
                    if data.mutualFansCount > 0 {
                        PublicProfileHeroStatCard(
                            value: "\(data.mutualFansCount)",
                            label: data.mutualFansCount == 1 ? "Mutual fan" : "Mutual fans",
                            icon: "person.2.fill",
                            tint: Color(red: 0.58, green: 0.36, blue: 0.92)
                        )
                    }
                    PublicProfileHeroStatCard(
                        value: data.reputation.title,
                        label: "Fan reputation",
                        icon: data.reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "bolt.heart.fill",
                        tint: FGColor.accentGreen
                    )
                }
                .frame(width: 108)
            }

            if let bio = data.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.86))
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .publicProfileEditorialCard(cornerRadius: 22)
    }

    private var avatar: some View {
        UserAvatarView(
            avatarThumbnailURL: data.avatarThumbnailURL,
            avatarURL: data.avatarURL ?? "",
            avatarDisplayRefreshToken: UUID(),
            displayName: data.displayName,
            email: "",
            size: 76,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [FGColor.accentBlue, FGColor.accentGreen],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2.5
                )
        }
        .overlay(alignment: .bottomTrailing) {
            Circle()
                .fill(FGColor.accentGreen)
                .frame(width: 14, height: 14)
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                .offset(x: 2, y: 2)
        }
    }

    private var favoriteTeamsStrip: some View {
        HStack(spacing: 4) {
            ForEach(data.favoriteTeams.prefix(5)) { team in
                FavoriteTeamLogoBadge(team: team, diameter: 26)
            }
            if data.favoriteTeams.count > 5 {
                Text("+\(data.favoriteTeams.count - 5)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(FGColor.divider(colorScheme).opacity(0.5)))
            }
        }
    }
}

struct PublicProfileHeroStatCard: View {
    let value: String
    let label: String
    let icon: String
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(tint)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.96))
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme).opacity(0.85), lineWidth: 0.75)
                }
        }
    }
}

// MARK: - Grid: Home crowd

struct PublicProfileGridHomeCrowdCard: View {
    let venue: PublicProfileVenueCard
    let mutualFansCount: Int
    let mutualAvatars: [PublicProfileMutualFanAvatar]
    let memberSinceLabel: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            venueHeroImage
                .frame(height: 188)
                .clipped()

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 5) {
                Text("HOME CROWD")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(Color(red: 0.78, green: 0.62, blue: 1.0))
                    .tracking(0.8)

                Text(venue.venueName)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(regularLine)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.88))
                    .lineLimit(1)

                if mutualFansCount > 0 {
                    HStack(spacing: 6) {
                        overlappingAvatars
                        Text("+\(max(0, mutualFansCount - min(mutualAvatars.count, 4)))")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.22)))
                    }
                    .padding(.top, 2)
                }
            }
            .padding(10)
        }
        .frame(maxWidth: .infinity, minHeight: 188)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.white.opacity(0.25), lineWidth: 0.75)
        }
        .shadow(color: Color.black.opacity(0.10), radius: 10, y: 5)
    }

    private var regularLine: String {
        if let memberSinceLabel {
            let year = memberSinceLabel.replacingOccurrences(of: "Member since ", with: "")
            return "Regular • Since \(year)"
        }
        return "Favorite spot"
    }

    @ViewBuilder
    private var venueHeroImage: some View {
        if let urlString = venue.thumbnailURL, let url = URL(string: urlString) {
            DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                venuePlaceholder
            }
        } else {
            venuePlaceholder
        }
    }

    private var venuePlaceholder: some View {
        LinearGradient(
            colors: [
                Color(red: 0.58, green: 0.36, blue: 0.92),
                Color(red: 0.22, green: 0.38, blue: 0.88)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "building.2.fill")
                .font(.system(size: 42, weight: .semibold))
                .foregroundStyle(.white.opacity(0.35))
        }
    }

    private var overlappingAvatars: some View {
        HStack(spacing: -8) {
            ForEach(mutualAvatars.prefix(3)) { fan in
                UserAvatarView(
                    avatarThumbnailURL: fan.avatarURL,
                    avatarURL: fan.avatarURL ?? "",
                    avatarDisplayRefreshToken: UUID(),
                    displayName: fan.displayName,
                    email: "",
                    size: 24,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: .white
                )
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
            }
        }
    }
}

// MARK: - Grid: Gameday

struct PublicProfileGridGamedayCard: View {
    let status: PublicProfileGamedayStatus
    let favoriteTeams: [FavoriteTeam]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("GAMEDAY STATUS")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.35, green: 0.78, blue: 0.48))
                .tracking(0.8)

            Text(status.title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(2)

            if let subtitle = status.subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(2)
            }

            Spacer(minLength: 4)

            HStack {
                if let team = favoriteTeams.first {
                    FavoriteTeamLogoBadge(team: team, diameter: 36)
                } else {
                    Image(systemName: status.systemImage)
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer(minLength: 0)
            }

            if let badge = status.badge, !badge.isEmpty {
                Label(badge, systemImage: "mappin.circle.fill")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: status.gradient, startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .shadow(color: status.gradient.first?.opacity(0.28) ?? .clear, radius: 10, y: 5)
    }
}

// MARK: - Grid: Open To

struct PublicProfileGridOpenToCard: View {
    let items: [PublicProfileOpenToItem]
    @Environment(\.colorScheme) private var colorScheme

    private let gridColumns = [
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6),
        GridItem(.flexible(), spacing: 6)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("OPEN TO")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.98, green: 0.55, blue: 0.22))
                .tracking(0.8)

            LazyVGrid(columns: gridColumns, spacing: 8) {
                ForEach(items) { item in
                    VStack(spacing: 6) {
                        Image(systemName: item.systemImage)
                            .font(.system(size: 26, weight: .semibold))
                            .foregroundStyle(item.tint)
                            .frame(height: 30)

                        Text(item.openToGridLabel)
                            .font(.system(size: 8.5, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.75)
                            .frame(minHeight: 22)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .publicProfileEditorialCard(cornerRadius: 18)
    }
}

extension PublicProfileOpenToItem {
    var openToGridLabel: String {
        if isSocial { return title }
        return AppSportCatalog.displayLabel(forSportToken: id)
    }
}

// MARK: - Grid: Venues visited

struct PublicProfileGridVenuesCard: View {
    let venues: [PublicProfileVenueCard]
    let totalCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VENUES VISITED")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.58, green: 0.36, blue: 0.92))
                .tracking(0.8)

            HStack(spacing: 8) {
                ForEach(venues.prefix(3)) { venue in
                    venueTile(venue)
                }
                let shown = min(3, venues.count)
                if totalCount > shown {
                    moreBubble(count: totalCount - shown)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .publicProfileEditorialCard(cornerRadius: 18)
    }

    private func venueTile(_ venue: PublicProfileVenueCard) -> some View {
        VStack(spacing: 5) {
            venueImage(venue)
                .frame(width: 56, height: 56)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(FGColor.divider(colorScheme), lineWidth: 0.75))

            Text(venue.venueName)
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(width: 62)
        }
        .frame(maxWidth: .infinity)
    }

    private func moreBubble(count: Int) -> some View {
        VStack(spacing: 5) {
            Text("+\(count)")
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 56, height: 56)
                .background(Circle().fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08)))
            Text("more")
                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
        }
    }

    @ViewBuilder
    private func venueImage(_ venue: PublicProfileVenueCard) -> some View {
        if let urlString = venue.thumbnailURL, let url = URL(string: urlString) {
            DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                venuePlaceholder
            }
        } else {
            venuePlaceholder
        }
    }

    private var venuePlaceholder: some View {
        LinearGradient(
            colors: [FGColor.accentBlue.opacity(0.35), FGColor.accentGreen.opacity(0.28)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .overlay {
            Image(systemName: "building.2.fill")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
        }
    }

}

// MARK: - Grid: Recent activity

struct PublicProfileGridActivityCard: View {
    let rows: [PublicProfileActivityRow]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("RECENT ACTIVITY")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.accentGreen)
                .tracking(0.8)

            VStack(spacing: 0) {
                ForEach(Array(rows.prefix(3).enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: row.icon)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(row.tint)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(row.tint.opacity(0.14)))

                        Text(row.text)
                            .font(.system(size: 10.5, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 6)

                    if index < min(rows.count, 3) - 1 {
                        Divider().opacity(0.45)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .publicProfileEditorialCard(cornerRadius: 18)
    }
}

// MARK: - Grid: Mutual fans

struct PublicProfileGridMutualFansCard: View {
    let count: Int
    let avatars: [PublicProfileMutualFanAvatar]
    let sharedTeamNames: [String]
    let sharedTeamsCount: Int
    let favoriteTeams: [FavoriteTeam]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(count) MUTUAL FANS")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.58, green: 0.36, blue: 0.92))
                .tracking(0.8)

            HStack(spacing: -10) {
                ForEach(avatars.prefix(4)) { fan in
                    UserAvatarView(
                        avatarThumbnailURL: fan.avatarURL,
                        avatarURL: fan.avatarURL ?? "",
                        avatarDisplayRefreshToken: UUID(),
                        displayName: fan.displayName,
                        email: "",
                        size: 34,
                        fallbackStyle: .lightOnWhiteChrome,
                        imagePlaceholderTint: FGColor.accentBlue
                    )
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                }
                if count > avatars.prefix(4).count {
                    Text("+\(count - avatars.prefix(4).count)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(FGColor.divider(colorScheme).opacity(0.6)))
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                }
            }

            if !sharedTeamLogos.isEmpty {
                HStack(spacing: 4) {
                    ForEach(sharedTeamLogos.prefix(3)) { team in
                        FavoriteTeamLogoBadge(team: team, diameter: 26)
                    }
                }
            }

            if sharedTeamsCount > 0 {
                Text(sharedTeamsCount == 1 ? "1 shared team" : "\(sharedTeamsCount) shared teams")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.accentGreen)
            } else if !sharedTeamNames.isEmpty {
                Text(sharedTeamNames.prefix(2).joined(separator: " · "))
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .publicProfileEditorialCard(cornerRadius: 18)
    }

    private var sharedTeamLogos: [FavoriteTeam] {
        let codes = Set(sharedTeamNames.map { $0.uppercased() })
        return favoriteTeams.filter { team in
            let code = (team.shortCode ?? "").uppercased()
            let name = team.name.uppercased()
            return codes.contains(code) || codes.contains(name) || sharedTeamNames.contains(where: { name.contains($0.uppercased()) })
        }
    }

}

// MARK: - Action bar

struct PublicProfileSocialActionBar: View {
    let friendState: PublicProfileFriendButtonState
    let showsPoke: Bool
    let isFriendActionInFlight: Bool
    let pokeTitle: String
    let pokeIcon: String
    let pokeForeground: Color
    let pokeBackground: Color
    let pokeBorder: Color
    let isPokeDisabled: Bool
    let isPokeInFlight: Bool
    let onFriendAction: () -> Void
    let onPoke: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 10) {
            if friendState != .hidden {
                friendButton
            }
            if showsPoke {
                pokeButton
            }
        }
    }

    @ViewBuilder
    private var friendButton: some View {
        switch friendState {
        case .hidden:
            EmptyView()
        case .messageFriend:
            actionCapsule(title: "Message", icon: "message.fill", filled: true, disabled: isFriendActionInFlight, action: onFriendAction)
        case .requestFriendship:
            actionCapsule(title: "Add Friend", icon: "person.badge.plus", filled: true, disabled: isFriendActionInFlight, action: onFriendAction)
        case .friendshipRequested:
            actionCapsule(title: "Requested", icon: "clock.fill", filled: false, disabled: true, action: {})
        }
    }

    private var pokeButton: some View {
        Button(action: onPoke) {
            HStack(spacing: 6) {
                Image(systemName: pokeIcon)
                    .font(.system(size: 13, weight: .bold))
                Text(pokeTitle)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .foregroundStyle(pokeForeground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(pokeBackground)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(pokeBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .disabled(isPokeDisabled || isPokeInFlight)
        .opacity(isPokeDisabled ? 0.65 : 1)
    }

    private func actionCapsule(title: String, icon: String, filled: Bool, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .foregroundStyle(filled ? .white : FGColor.accentGreen)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(filled ? FGColor.accentGreen : FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.10))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
