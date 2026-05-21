import SwiftUI

// MARK: - Sheet layout (public fan profile)

enum PublicProfileSheetLayout {
    /// Vertical gap between hero, actions, and stacked cards.
    static let sectionSpacing: CGFloat = 14
    /// Vertical gap between Home Crowd, Open To, and Mutual Fans cards.
    static let gridCardSpacing: CGFloat = 14
    /// Default editorial card corner (hero, grid shells).
    static let editorialCardRadius: CGFloat = 24
    /// Grid section card corners (Open To, Mutual Fans).
    static let gridCardRadius: CGFloat = 20

    @MainActor
    static func horizontalPadding(screenWidth: CGFloat? = nil) -> CGFloat {
        let resolvedWidth = screenWidth ?? currentWindowSceneScreenWidth()
        return resolvedWidth <= 375 ? 20 : 22
    }

    @MainActor
    private static func currentWindowSceneScreenWidth() -> CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?
            .screen
            .bounds
            .width
            ?? UIApplication.shared.connectedScenes
                .compactMap { ($0 as? UIWindowScene)?.screen.bounds.width }
                .first
            ?? 393
    }
}

// MARK: - Design chrome

extension View {
    func publicProfileEditorialCard(cornerRadius: CGFloat = PublicProfileSheetLayout.editorialCardRadius) -> some View {
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

    static func homeCrowd(from data: PublicUserProfileData) -> HomeCrowdVenueSummary? {
        data.homeCrowd
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

    var primaryFavoriteTeam: FavoriteTeam? {
        explicitPrimaryFavoriteTeam ?? favoriteTeams.first
    }

    var explicitPrimaryFavoriteTeam: FavoriteTeam? {
        if let primaryFavoriteTeamID,
           let team = favoriteTeams.first(where: { $0.id == primaryFavoriteTeamID }) {
            return team
        }
        return nil
    }

    var trophyTeamFallbackUsed: Bool {
        explicitPrimaryFavoriteTeam == nil && !favoriteTeams.isEmpty
    }

    var orderedFavoriteTeamsForPublicProfile: [FavoriteTeam] {
        guard let primary = primaryFavoriteTeam else { return favoriteTeams }
        return [primary] + favoriteTeams.filter { $0.id != primary.id }
    }

}

// MARK: - Two-column grid (mock layout)

struct PublicProfileTwoColumnGrid: View {
    let data: PublicUserProfileData
    let colorScheme: ColorScheme

    var body: some View {
        VStack(spacing: PublicProfileSheetLayout.gridCardSpacing) {
            HomeCrowdProfileCardView(
                summary: PublicProfileContentBuilder.homeCrowd(from: data),
                isSelfProfile: false
            )
            .frame(maxWidth: .infinity)

            PublicProfileGridOpenToCard(items: data.editorialOpenToItems)
                .frame(maxWidth: .infinity)

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
}

// MARK: - Hero header

private struct PublicProfileHeroWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PublicProfileEditorialHero: View {
    let data: PublicUserProfileData
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var containerWidth: CGFloat = 0

    private var avatarDiameter: CGFloat {
        Self.resolvedAvatarDiameter(containerWidth: containerWidth)
    }

    private var statColumnWidth: CGFloat {
        guard containerWidth > 0 else { return 96 }
        return min(104, max(88, containerWidth * 0.26))
    }

    private var trimmedBio: String {
        data.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private var displayBio: String {
        if trimmedBio.isEmpty {
            return "I am FanGeo's biggest fan."
        }
        return trimmedBio
    }

    private var isDefaultBio: Bool {
        trimmedBio.isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                avatar(diameter: avatarDiameter)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(data.displayName)
                            .font(.system(size: 21, weight: .bold, design: .rounded))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)
                            .minimumScaleFactor(0.82)

                        if data.reputation.privileges.isVerifiedOrganizer {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 13, weight: .bold))
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

                    if let primaryTeam = data.primaryFavoriteTeam {
                        heroPrimaryFavoriteTeam(primaryTeam)
                            .padding(.top, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 4)

                heroStatColumn
                    .frame(width: statColumnWidth)
            }

            Text(displayBio)
                .font(.system(size: 13, weight: .medium, design: .rounded))
                .foregroundStyle(
                    FGColor.mutedText(colorScheme).opacity(isDefaultBio ? 0.88 : 0.94)
                )
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 2)
                .onAppear {
#if DEBUG
                    print("[ProfileBioDebug] identityCardDisplayedBio=\(trimmedBio)")
                    print("[ProfileBioDebug] usingFallbackBio=\(isDefaultBio)")
#endif
                }

            if let memberSince = data.memberSinceLabel, !memberSince.isEmpty {
                heroMemberSinceRow(memberSince)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 2)
            }
        }
        .padding(16)
        .background {
            GeometryReader { geo in
                Color.clear
                    .preference(key: PublicProfileHeroWidthKey.self, value: geo.size.width)
            }
        }
        .onPreferenceChange(PublicProfileHeroWidthKey.self) { containerWidth = $0 }
        .publicProfileEditorialCard(cornerRadius: PublicProfileSheetLayout.editorialCardRadius)
        .onAppear {
#if DEBUG
            print("[PublicProfileFavoriteTeamsDebug] trophyTeamDisplayed=\(data.primaryFavoriteTeam?.id ?? "none")")
            print("[PublicProfileFavoriteTeamsDebug] trophyTeamFullNameVisible=\(data.primaryFavoriteTeam != nil)")
            print("[PublicProfileFavoriteTeamsDebug] trophyTeamFallbackUsed=\(data.trophyTeamFallbackUsed)")
#endif
        }
    }

    private var heroStatColumn: some View {
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
    }

    private func heroPrimaryFavoriteTeam(_ team: FavoriteTeam) -> some View {
        HStack(spacing: 9) {
            ZStack {
                Circle()
                    .fill(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.18 : 0.13))
                    .frame(width: 34, height: 34)
                    .overlay {
                        Circle()
                            .strokeBorder(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: 1)
                    }
                Image(systemName: "trophy.fill")
                    .font(.system(size: 15, weight: .heavy))
                    .foregroundStyle(FGColor.accentYellow)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t("my_team", languageCode: appLanguageRaw))
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.accentYellow.opacity(0.96))
                    .textCase(.uppercase)
                    .tracking(0.7)
                    .lineLimit(1)

                Text(team.name)
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Capsule(style: .continuous)
                .fill(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1)
                }
        }
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] userFacingPrimaryLabel=MyTeam")
            print("[FavoriteTeamsDebug] primaryTeamDisplayUpdated=true")
#endif
        }
        .shadow(color: FGColor.accentYellow.opacity(colorScheme == .dark ? 0.20 : 0.12), radius: 9, y: 3)
    }

    private func heroMemberSinceRow(_ label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.92))
            Text(label)
                .font(.system(size: 11.5, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
    }

    private func avatar(diameter: CGFloat) -> some View {
        let borderWidth = max(2.5, diameter * 0.025)

        return UserAvatarView(
            avatarThumbnailURL: data.avatarThumbnailURL,
            avatarURL: data.avatarURL ?? "",
            avatarDisplayRefreshToken: UUID(),
            displayName: data.displayName,
            email: "",
            size: diameter,
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
                    lineWidth: borderWidth
                )
        }
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.28 : 0.18), radius: diameter * 0.12, y: diameter * 0.05)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.10), radius: diameter * 0.08, y: diameter * 0.04)
        .frame(width: diameter, height: diameter)
    }

    /// ~30% of hero width, clamped for premium anchor on phone / SE-safe compact floor.
    static func resolvedAvatarDiameter(containerWidth: CGFloat) -> CGFloat {
        guard containerWidth > 0 else { return 120 }
        let scaled = containerWidth * 0.30
        return min(132, max(100, scaled))
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

// MARK: - Grid: Favorite teams

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
        .publicProfileEditorialCard(cornerRadius: PublicProfileSheetLayout.gridCardRadius)
    }
}

// MARK: - Favorite Teams

struct PublicProfileFavoriteTeamsCard: View {
    let data: PublicUserProfileData
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    private var shownTeams: [FavoriteTeam] {
        data.orderedFavoriteTeamsForPublicProfile
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                PublicProfileEditorialSectionTitle(
                    L10n.t("favorite_teams", languageCode: appLanguageRaw),
                    subtitle: shownTeams.isEmpty ? "Teams this fan follows" : "\(shownTeams.count) selected",
                    accent: FGColor.accentGreen
                )
                Spacer(minLength: 0)
                Image(systemName: "trophy.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.accentYellow.opacity(0.92))
            }

            if shownTeams.isEmpty {
                emptyFavoriteTeamsState
            } else {
                VStack(spacing: 8) {
                    ForEach(shownTeams) { team in
                        favoriteTeamRow(team, isPrimary: team.id == data.primaryFavoriteTeam?.id)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .publicProfileEditorialCard(cornerRadius: PublicProfileSheetLayout.gridCardRadius)
        .onAppear {
#if DEBUG
            print("[PublicProfileFavoriteTeamsDebug] favoriteTeamsCardCount=\(shownTeams.count)")
            print("[PublicProfileFavoriteTeamsDebug] favoriteTeamsSectionPlacedBelowActions=true")
            print("[PublicProfileFavoriteTeamsDebug] trophyTeamFallbackUsed=\(data.trophyTeamFallbackUsed)")
#endif
        }
    }

    private func favoriteTeamRow(_ team: FavoriteTeam, isPrimary: Bool) -> some View {
        let rowFill = isPrimary
            ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.10 : 0.06)
            : team.badgeColor.opacity(colorScheme == .dark ? 0.14 : 0.08)
        let sportAccent = sportAccentColor(for: team.sport.chipTitle)

        return HStack(spacing: 10) {
            FavoriteTeamLogoBadge(team: team, diameter: 34)

            VStack(alignment: .leading, spacing: 1) {
                Text(team.name)
                    .font(.system(size: 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                publicFavoriteTeamSportBadge(team)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isPrimary {
                HStack(spacing: 4) {
                    Image(systemName: "trophy.fill")
                        .font(.system(size: 11, weight: .heavy))
                    Text(L10n.t("my_team", languageCode: appLanguageRaw))
                        .font(.system(size: 10, weight: .heavy, design: .rounded))
                }
                .foregroundStyle(FGColor.accentYellow.opacity(0.96))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background {
                    Capsule(style: .continuous)
                        .fill(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.16 : 0.10))
                }
            } else {
                Image(systemName: "trophy")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.72))
            }
        }
        .padding(9)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(rowFill)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(
                            isPrimary
                                ? FGColor.accentYellow.opacity(colorScheme == .dark ? 0.30 : 0.20)
                                : team.badgeColor.opacity(colorScheme == .dark ? 0.24 : 0.14),
                            lineWidth: 1
                        )
                }
        }
        .overlay(alignment: .topLeading) {
            publicFavoriteTeamSportAccent(color: sportAccent)
        }
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] sportAccentRendered sport=\(team.sport.chipTitle)")
            print("[FavoriteTeamsDebug] sportAccentColorApplied=true")
#endif
        }
    }

    private func publicFavoriteTeamSportAccent(color: Color) -> some View {
        VStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            color.opacity(colorScheme == .dark ? 0.52 : 0.40),
                            color.opacity(colorScheme == .dark ? 0.16 : 0.11),
                            Color.clear
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(height: 2)
            Spacer(minLength: 0)
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func publicFavoriteTeamSportBadge(_ team: FavoriteTeam) -> some View {
        HStack(spacing: 5) {
            Text(sportIcon(for: team.sport.chipTitle))
                .font(.system(size: 12))
            Text(team.sport.chipTitle)
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(team.badgeColor.opacity(colorScheme == .dark ? 0.13 : 0.08))
        }
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] sportIconRendered sport=\(team.sport.chipTitle)")
            print("[FavoriteTeamsDebug] favoriteTeamCardSportIconVisible=true")
#endif
        }
    }

    private var emptyFavoriteTeamsState: some View {
        HStack(spacing: 10) {
            Image(systemName: "trophy")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.72))
            Text("No favorite teams shared yet.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(.vertical, 10)
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
        .publicProfileEditorialCard(cornerRadius: PublicProfileSheetLayout.gridCardRadius)
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
        .publicProfileEditorialCard(cornerRadius: PublicProfileSheetLayout.gridCardRadius)
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
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

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
            actionCapsule(title: L10n.t("message", languageCode: appLanguageRaw), icon: "message.fill", filled: true, disabled: isFriendActionInFlight, action: onFriendAction)
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
