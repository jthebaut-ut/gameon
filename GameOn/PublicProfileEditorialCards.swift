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
                                Color.white.opacity(colorScheme == .dark ? 0.12 : 0.98)
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

    /// No real-time activity feed on public profile yet — do not invent rows.
    static func activityTimeline(from data: PublicUserProfileData) -> [PublicProfileActivityRow] {
        _ = data
        return []
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
    /// Mock-style labels under Open To icons.
    var openToGridLabel: String {
        switch id {
        case FanOpenToSocialID.watchParties: return "Watch Parties"
        case FanOpenToSocialID.sportsBars: return "Sports Bars"
        case FanOpenToSocialID.meetLocalFans: return "Meeting Local Fans"
        default: return AppSportCatalog.displayLabel(forSportToken: id)
        }
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

    var body: some View {
        VStack(spacing: 10) {
            profileRow(left: favoriteTeamsSlot, right: .some(AnyView(PublicProfileGridOpenToCard(items: data.editorialOpenToItems))))

            PublicProfileGridMutualFansCard(
                count: data.mutualFansCount,
                avatars: data.mutualFanAvatars,
                sharedTeamNames: data.sharedTeamNames,
                sharedTeamsCount: data.sharedTeamsCount,
                favoriteTeams: data.favoriteTeams
            )
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func profileRow(left: PublicProfileGridSlot, right: PublicProfileGridSlot) -> some View {
        switch (left, right) {
        case (.none, .none):
            EmptyView()
        case let (.some(l), .some(r)):
            HStack(alignment: .top, spacing: 10) {
                l.frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
                r.frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
            }
        case let (.some(l), .none):
            l.frame(maxWidth: .infinity, alignment: .topLeading)
        case let (.none, .some(r)):
            r.frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var favoriteTeamsSlot: PublicProfileGridSlot {
        guard !data.favoriteTeams.isEmpty else { return .none }
        return .some(AnyView(PublicProfileGridFavoriteTeamsCard(teams: data.favoriteTeams)))
    }
}

private enum PublicProfileGridSlot {
    case none
    case some(AnyView)
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

// MARK: - Grid: Favorite teams

struct PublicProfileGridFavoriteTeamsCard: View {
    let teams: [FavoriteTeam]
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("FAVORITE TEAMS")
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.58, green: 0.36, blue: 0.92))
                .tracking(0.8)

            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(teams.prefix(6)) { team in
                    VStack(spacing: 6) {
                        FavoriteTeamLogoBadge(team: team, diameter: 52)
                        Text(team.shortCode?.isEmpty == false ? team.shortCode! : team.name)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
        .publicProfileEditorialCard(cornerRadius: 18)
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

            if items.isEmpty {
                Text("This fan hasn't shared what they're open to yet.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                LazyVGrid(columns: gridColumns, spacing: 6) {
                    ForEach(items) { item in
                        VStack(spacing: 5) {
                            Image(systemName: item.systemImage)
                                .font(.system(size: 30, weight: .semibold))
                                .foregroundStyle(item.tint)
                                .frame(height: 34)

                            Text(item.openToGridLabel)
                                .font(.system(size: 9, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.7)
                                .frame(minHeight: 24)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
        .publicProfileEditorialCard(cornerRadius: 18)
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
        .frame(maxWidth: .infinity, minHeight: 188, alignment: .topLeading)
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

// MARK: - Grid: Mutual fans

struct PublicProfileGridMutualFansCard: View {
    let count: Int
    let avatars: [PublicProfileMutualFanAvatar]
    let sharedTeamNames: [String]
    let sharedTeamsCount: Int
    let favoriteTeams: [FavoriteTeam]
    @Environment(\.colorScheme) private var colorScheme

    private var sectionTitle: String {
        if count > 0 { return "\(count) MUTUAL FANS" }
        if sharedTeamsCount > 0 { return "SHARED TEAMS" }
        return "MUTUAL FANS"
    }

    private var hasSocialProof: Bool {
        count > 0 || sharedTeamsCount > 0 || !sharedTeamNames.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sectionTitle)
                .font(.system(size: 9, weight: .heavy, design: .rounded))
                .foregroundStyle(Color(red: 0.58, green: 0.36, blue: 0.92))
                .tracking(0.8)

            if !hasSocialProof {
                Text("No mutual fans yet.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            } else {
                if count > 0 {
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
                        let shown = avatars.prefix(4).count
                        if count > shown {
                            Text("+\(count - shown)")
                                .font(.system(size: 11, weight: .bold, design: .rounded))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .frame(width: 34, height: 34)
                                .background(Circle().fill(FGColor.divider(colorScheme).opacity(0.6)))
                                .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                        }
                    }
                }

                if !sharedTeamLogos.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(sharedTeamLogos.prefix(4)) { team in
                            FavoriteTeamLogoBadge(team: team, diameter: 28)
                        }
                    }
                }

                if sharedTeamsCount > 0 {
                    Text(sharedTeamsCount == 1 ? "1 shared team" : "\(sharedTeamsCount) shared teams")
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.accentGreen)
                } else if !sharedTeamNames.isEmpty {
                    Text(sharedTeamNames.prefix(3).joined(separator: " · "))
                        .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }
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
