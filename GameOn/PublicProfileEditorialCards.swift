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

        if openIDs.contains("watch_parties") || openIDs.contains("soccer_matches") {
            let team = data.favoriteTeams.first
            let subtitle = team.map { "Routing for \($0.shortCode ?? $0.name)" }
            return PublicProfileGamedayStatus(
                title: openIDs.contains("watch_parties") ? "Watching Tonight" : "Match Day Mode",
                subtitle: subtitle,
                badge: team?.sport.chipTitle,
                systemImage: "tv.fill",
                gradient: [Color(red: 0.18, green: 0.42, blue: 0.92), Color(red: 0.42, green: 0.22, blue: 0.88)]
            )
        }

        if openIDs.contains(where: { $0.hasPrefix("pickup_") || $0 == "running_fitness" || $0 == "combat_sports" || $0 == "racing" })
            || data.pickupHostedCount > 0 || data.pickupJoinedCount > 0 {
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

        if openIDs.contains("meet_local_fans") {
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
        switch id {
        case "watch_parties": return "Watch"
        case "soccer_matches": return "Matches"
        case "pickup_basketball": return "Hoop"
        case "pickup_soccer": return "Soccer"
        case "pickup_football": return "Football"
        case "pickup_baseball": return "Diamond"
        case "pickup_tennis": return "Tennis"
        case "pickup_golf": return "Golf"
        case "pickup_hockey": return "Hockey"
        case "running_fitness": return "Run"
        case "combat_sports": return "Combat"
        case "racing": return "Race"
        case "meet_local_fans": return "Fans"
        default:
            return title.split(separator: " ").first.map(String.init) ?? title
        }
    }

    var openToCategory: PublicProfileOpenToCategory {
        switch id {
        case "watch_parties", "soccer_matches":
            return .watch
        case "meet_local_fans":
            return .social
        default:
            return .play
        }
    }
}

extension PublicUserProfileData {
    var editorialOpenToItems: [PublicProfileOpenToItem] {
        Array(openToItems.prefix(PublicProfileContentBuilder.maxPublicOpenToItems))
    }
}

// MARK: - Hero header

struct PublicProfileEditorialHero: View {
    let data: PublicUserProfileData
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                avatar
                VStack(alignment: .leading, spacing: 6) {
                    Text(data.displayName)
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.8)

                    Text(data.publicHandleLine)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    if !data.favoriteTeams.isEmpty {
                        favoriteTeamsStrip
                    }

                    PublicProfilePremiumReputationPill(reputation: data.reputation)
                        .padding(.top, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let bio = data.bio, !bio.isEmpty {
                Text(bio)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.88))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let memberSince = data.memberSinceLabel {
                Text(memberSince)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .padding(18)
        .background(heroBackground)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.65), lineWidth: 0.85)
        }
        .shadow(color: Color.black.opacity(0.07), radius: 20, y: 10)
    }

    private var avatar: some View {
        UserAvatarView(
            avatarThumbnailURL: data.avatarThumbnailURL,
            avatarURL: data.avatarURL ?? "",
            avatarDisplayRefreshToken: UUID(),
            displayName: data.displayName,
            email: "",
            size: 92,
            fallbackStyle: .lightOnWhiteChrome,
            imagePlaceholderTint: FGColor.accentBlue
        )
        .overlay {
            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [FGColor.accentBlue, FGColor.accentGreen, Color.white.opacity(0.9)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 3
                )
        }
        .shadow(color: FGColor.accentBlue.opacity(0.22), radius: 12, y: 6)
    }

    private var favoriteTeamsStrip: some View {
        HStack(spacing: 5) {
            ForEach(data.favoriteTeams.prefix(5)) { team in
                FavoriteTeamLogoBadge(team: team, diameter: 28)
            }
            if data.favoriteTeams.count > 5 {
                Text("+\(data.favoriteTeams.count - 5)")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .padding(.top, 2)
    }

    private var heroBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.10 : 0.98),
                    Color(red: 0.94, green: 0.97, blue: 1.0).opacity(colorScheme == .dark ? 0.08 : 0.92),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.06 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Circle()
                .fill(FGColor.accentBlue.opacity(0.08))
                .frame(width: 160, height: 160)
                .offset(x: 120, y: -50)
            Circle()
                .fill(FGColor.accentGreen.opacity(0.07))
                .frame(width: 120, height: 120)
                .offset(x: -80, y: 60)
        }
    }
}

struct PublicProfilePremiumReputationPill: View {
    let reputation: FanReputationProfile
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: reputation.privileges.isVerifiedOrganizer ? "checkmark.seal.fill" : "bolt.heart.fill")
                .font(.system(size: 10, weight: .bold))
            Text(reputation.title.uppercased())
                .font(.system(size: 10, weight: .heavy, design: .rounded))
                .tracking(0.7)
        }
        .foregroundStyle(
            LinearGradient(
                colors: [Color(red: 0.12, green: 0.62, blue: 0.42), FGColor.accentGreen],
                startPoint: .leading,
                endPoint: .trailing
            )
        )
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background {
            Capsule(style: .continuous)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.92))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.accentGreen.opacity(0.35), lineWidth: 0.85)
                }
        }
        .shadow(color: FGColor.accentGreen.opacity(0.12), radius: 6, y: 3)
    }
}

// MARK: - Gameday status

struct PublicProfileGamedayStatusCard: View {
    let status: PublicProfileGamedayStatus
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 52, height: 52)
                Image(systemName: status.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(status.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                if let subtitle = status.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.88))
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let badge = status.badge, !badge.isEmpty {
                Text(badge.uppercased())
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.2)))
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: status.gradient,
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: status.gradient.first?.opacity(0.35) ?? .clear, radius: 16, y: 8)
        }
    }
}

// MARK: - Home crowd

struct PublicProfileHomeCrowdCard: View {
    let venue: PublicProfileVenueCard
    let mutualFansCount: Int
    let mutualAvatars: [PublicProfileMutualFanAvatar]
    let memberSinceLabel: String?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            venueHeroImage
                .frame(height: 148)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            LinearGradient(
                colors: [.clear, Color.black.opacity(0.72)],
                startPoint: .center,
                endPoint: .bottom
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))

            VStack(alignment: .leading, spacing: 6) {
                PublicProfileEditorialSectionTitle("Home Crowd", accent: .white.opacity(0.92))

                Text(venue.venueName)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)

                HStack(spacing: 8) {
                    if let memberSinceLabel {
                        Label(memberSinceLabel.replacingOccurrences(of: "Member since ", with: "Regular since "), systemImage: "calendar")
                    } else {
                        Label("Regular", systemImage: "heart.fill")
                    }
                }
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.88))

                if mutualFansCount > 0 {
                    HStack(spacing: 8) {
                        overlappingAvatars
                        Text(mutualLabel)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                            .foregroundStyle(.white.opacity(0.92))
                    }
                    .padding(.top, 2)
                }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 18, y: 10)
    }

    private var mutualLabel: String {
        mutualFansCount == 1 ? "1 mutual fan here" : "\(mutualFansCount) mutual fans"
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
        HStack(spacing: -10) {
            ForEach(mutualAvatars.prefix(4)) { fan in
                UserAvatarView(
                    avatarThumbnailURL: fan.avatarURL,
                    avatarURL: fan.avatarURL ?? "",
                    avatarDisplayRefreshToken: UUID(),
                    displayName: fan.displayName,
                    email: "",
                    size: 28,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: .white
                )
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
            }
        }
    }
}

// MARK: - Personality

struct PublicProfilePersonalityCard: View {
    let tags: [String]
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 8)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PublicProfileEditorialSectionTitle("Fan Personality", subtitle: "Their vibe on game day")

            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.94))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(FGColor.accentBlue.opacity(0.28), lineWidth: 0.85)
                                }
                        }
                }
            }
        }
        .padding(14)
        .publicProfileEditorialCard()
    }
}

// MARK: - Open To

struct PublicProfileOpenToEditorialCard: View {
    let items: [PublicProfileOpenToItem]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PublicProfileEditorialSectionTitle("Open To", subtitle: "What they're down for")

            ForEach(PublicProfileContentBuilder.groupedOpenTo(items), id: \.0.rawValue) { category, bucket in
                VStack(alignment: .leading, spacing: 8) {
                    Text(category.rawValue.uppercased())
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .tracking(0.9)

                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10),
                            GridItem(.flexible(), spacing: 10)
                        ],
                        spacing: 10
                    ) {
                        ForEach(bucket) { item in
                            VStack(spacing: 8) {
                                Image(systemName: item.systemImage)
                                    .font(.system(size: 28, weight: .semibold))
                                    .foregroundStyle(item.tint)
                                    .frame(height: 32)

                                Text(item.editorialShortTitle)
                                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(openToCellBackground(item))
                        }
                    }
                }
            }
        }
        .padding(14)
        .publicProfileEditorialCard()
    }

    private func openToCellBackground(_ item: PublicProfileOpenToItem) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        item.tint.opacity(colorScheme == .dark ? 0.24 : 0.16),
                        Color.white.opacity(colorScheme == .dark ? 0.06 : 0.94)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(item.tint.opacity(0.32), lineWidth: 0.85)
            }
    }
}

// MARK: - Sports moment placeholder

struct PublicProfileSportsMomentCard: View {
    let moment: PublicProfileSportsMoment
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublicProfileEditorialSectionTitle("Favorite Sports Moment")
            Text(moment.headline)
                .font(.system(size: 15, weight: .bold, design: .rounded))
            if let year = moment.yearLabel {
                Text(year)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }
        }
        .padding(14)
        .publicProfileEditorialCard()
    }
}

// MARK: - Venues visited

struct PublicProfileVenuesVisitedCard: View {
    let venues: [PublicProfileVenueCard]
    let totalCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PublicProfileEditorialSectionTitle("Venues Visited", subtitle: "Where they've been")

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(venues.prefix(4)) { venue in
                        venueTile(venue)
                    }
                    if totalCount > venues.count {
                        moreTile(count: totalCount - venues.count)
                    }
                }
            }
        }
        .padding(14)
        .publicProfileEditorialCard()
    }

    private func venueTile(_ venue: PublicProfileVenueCard) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            venueImage(venue)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(venue.venueName)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)

            if !venue.cityLabel.isEmpty {
                Text(venue.cityLabel)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .lineLimit(1)
                    .frame(width: 88, alignment: .leading)
            }
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

    private func moreTile(count: Int) -> some View {
        VStack {
            Text("+\(count)")
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.accentBlue)
            Text("more")
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
        }
        .frame(width: 88, height: 88)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.08))
        }
    }
}

// MARK: - Recent activity

struct PublicProfileRecentActivityCard: View {
    let rows: [PublicProfileActivityRow]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PublicProfileEditorialSectionTitle("Recent Activity")

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: row.icon)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(row.tint)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(row.tint.opacity(0.14)))

                        Text(row.text)
                            .font(.system(size: 12.5, weight: .medium, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)

                    if index < rows.count - 1 {
                        Divider()
                            .padding(.leading, 36)
                            .opacity(0.55)
                    }
                }
            }
        }
        .padding(14)
        .publicProfileEditorialCard()
    }
}

// MARK: - Mutual fans (premium)

struct PublicProfileMutualFansEditorialCard: View {
    let count: Int
    let avatars: [PublicProfileMutualFanAvatar]
    let sharedTeamNames: [String]
    let sharedTeamsCount: Int
    let favoriteTeams: [FavoriteTeam]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PublicProfileEditorialSectionTitle("Mutual Fans", subtitle: "Fans you both know")

            HStack(alignment: .center, spacing: 14) {
                overlappingAvatars
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(count) mutual")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("fans in common")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }

            if !sharedTeamLogos.isEmpty {
                HStack(spacing: 6) {
                    ForEach(sharedTeamLogos.prefix(4)) { team in
                        FavoriteTeamLogoBadge(team: team, diameter: 32)
                    }
                    if sharedTeamsCount > sharedTeamLogos.count {
                        Text("+\(sharedTeamsCount - sharedTeamLogos.count)")
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                    }
                }
            } else if !sharedTeamNames.isEmpty {
                Text(sharedTeamNames.prefix(3).joined(separator: " · "))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            if sharedTeamsCount > 0 {
                Text(sharedTeamsCount == 1 ? "You follow the same team" : "Shared fan energy across \(sharedTeamsCount) teams")
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.accentGreen)
            }
        }
        .padding(14)
        .publicProfileEditorialCard()
    }

    private var sharedTeamLogos: [FavoriteTeam] {
        let codes = Set(sharedTeamNames.map { $0.uppercased() })
        return favoriteTeams.filter { team in
            let code = (team.shortCode ?? "").uppercased()
            let name = team.name.uppercased()
            return codes.contains(code) || codes.contains(name) || sharedTeamNames.contains(where: { name.contains($0.uppercased()) })
        }
    }

    private var overlappingAvatars: some View {
        HStack(spacing: -12) {
            ForEach(avatars.prefix(5)) { fan in
                UserAvatarView(
                    avatarThumbnailURL: fan.avatarURL,
                    avatarURL: fan.avatarURL ?? "",
                    avatarDisplayRefreshToken: UUID(),
                    displayName: fan.displayName,
                    email: "",
                    size: 40,
                    fallbackStyle: .lightOnWhiteChrome,
                    imagePlaceholderTint: FGColor.accentBlue
                )
                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2.5))
                .shadow(color: Color.black.opacity(0.08), radius: 4, y: 2)
            }
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
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
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
            .padding(.vertical, 14)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(filled ? FGColor.accentGreen : FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.10))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }
}
