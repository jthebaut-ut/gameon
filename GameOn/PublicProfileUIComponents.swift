import SwiftUI

// MARK: - Glass chrome

extension View {
    func publicProfileCompactGlass() -> some View {
        fanGeoGlassCard(cornerRadius: 18)
    }
}

struct PublicProfileSectionLabel: View {
    let title: String
    let accent: Color
  @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Text(title)
            .font(.system(size: 9.5, weight: .bold, design: .rounded))
            .foregroundStyle(accent.opacity(0.95))
            .textCase(.uppercase)
            .tracking(0.65)
    }
}

struct FanGeoSportBadgeView: View {
    enum Style {
        case profile
    }

    let sport: String
    var size: CGFloat = 48
    var style: Style = .profile

    @Environment(\.colorScheme) private var colorScheme

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    private var normalizedSport: String {
        sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        let colors = palette
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            colors.highlight,
                            colors.primary,
                            colors.shadow
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay(alignment: .topLeading) {
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.30))
                        .frame(width: size * 0.58, height: size * 0.58)
                        .blur(radius: size * 0.16)
                        .offset(x: -size * 0.10, y: -size * 0.16)
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.28 : 0.78),
                                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.20)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: max(0.75, size * 0.025)
                        )
                }

            Image(systemName: visual.systemImage)
                .font(.system(size: size * 0.43, weight: .bold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(colors.glyph)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.24 : 0.16), radius: 1.5, y: 1)
                .frame(width: size * 0.68, height: size * 0.68)
                .accessibilityHidden(true)
        }
        .frame(width: size, height: size)
        .shadow(color: colors.primary.opacity(colorScheme == .dark ? 0.34 : 0.24), radius: size * 0.18, y: size * 0.08)
        .accessibilityLabel(sport)
    }

    private var palette: (highlight: Color, primary: Color, shadow: Color, glyph: Color) {
        let sport = normalizedSport
        if sport.contains("soccer") || sport.contains("mls") {
            return (
                Color(red: 0.20, green: 0.88, blue: 0.48),
                Color(red: 0.05, green: 0.58, blue: 0.30),
                Color(red: 0.03, green: 0.30, blue: 0.22),
                .white
            )
        }
        if sport.contains("basketball") || sport.contains("nba") {
            return (
                Color(red: 1.00, green: 0.70, blue: 0.28),
                Color(red: 0.95, green: 0.40, blue: 0.12),
                Color(red: 0.54, green: 0.20, blue: 0.08),
                .white
            )
        }
        if sport.contains("football") || sport.contains("nfl") {
            return (
                Color(red: 0.78, green: 0.52, blue: 0.30),
                Color(red: 0.46, green: 0.28, blue: 0.14),
                Color(red: 0.24, green: 0.14, blue: 0.08),
                .white
            )
        }
        if sport.contains("baseball") || sport.contains("mlb") {
            return (
                Color(red: 1.00, green: 0.93, blue: 0.88),
                Color(red: 0.88, green: 0.22, blue: 0.24),
                Color(red: 0.45, green: 0.08, blue: 0.12),
                .white
            )
        }
        if sport.contains("tennis") {
            return (
                Color(red: 1.00, green: 0.94, blue: 0.20),
                Color(red: 0.62, green: 0.78, blue: 0.12),
                Color(red: 0.22, green: 0.48, blue: 0.20),
                Color(red: 0.05, green: 0.16, blue: 0.10)
            )
        }
        if sport.contains("hockey") || sport.contains("nhl") {
            return (
                Color(red: 0.68, green: 0.92, blue: 1.00),
                Color(red: 0.18, green: 0.50, blue: 0.92),
                Color(red: 0.08, green: 0.20, blue: 0.46),
                .white
            )
        }
        if sport.contains("golf") {
            return (
                Color(red: 0.38, green: 0.86, blue: 0.58),
                Color(red: 0.10, green: 0.54, blue: 0.40),
                Color(red: 0.06, green: 0.28, blue: 0.38),
                .white
            )
        }
        if sport.contains("pickleball") {
            return (
                Color(red: 0.30, green: 0.88, blue: 0.72),
                Color(red: 0.12, green: 0.66, blue: 0.44),
                Color(red: 0.04, green: 0.34, blue: 0.30),
                .white
            )
        }
        if sport.contains("volleyball") {
            return (
                Color(red: 0.52, green: 0.80, blue: 1.00),
                Color(red: 0.18, green: 0.46, blue: 0.92),
                Color(red: 0.96, green: 0.70, blue: 0.22),
                .white
            )
        }
        if sport.contains("running") || sport.contains("fitness") {
            return (
                Color(red: 0.56, green: 0.56, blue: 1.00),
                Color(red: 0.42, green: 0.30, blue: 0.86),
                Color(red: 0.14, green: 0.28, blue: 0.62),
                .white
            )
        }
        return (
            visual.accent.opacity(colorScheme == .dark ? 0.95 : 0.86),
            visual.accent,
            FGColor.accentBlue.opacity(0.72),
            .white
        )
    }
}

// MARK: - Open To chips

struct PublicProfileOpenToChipGrid: View {
    let items: [PublicProfileOpenToItem]
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                openToChipCard(item)
            }
        }
    }

    private func openToChipCard(_ item: PublicProfileOpenToItem) -> some View {
        VStack(spacing: 6) {
            if item.isSocial {
                Image(systemName: item.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(height: 44)
            } else {
                FanGeoSportBadgeView(sport: item.id, size: 44, style: .profile)
            }

            Text(item.title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            item.tint.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            Color.white.opacity(colorScheme == .dark ? 0.05 : 0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(item.tint.opacity(0.35), lineWidth: 0.85)
                }
        }
    }
}

/// Account profile Open To preview with per-card quick remove.
struct SelfProfileOpenToPreviewGrid: View {
    let items: [PublicProfileOpenToItem]
    let onRemove: (PublicProfileOpenToItem) -> Void
    let onAdd: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items) { item in
                ZStack(alignment: .topTrailing) {
                    openToChipCard(item)

                    removeOpenToButton(item: item)
                        .padding(5)
                }
            }

            addOpenToButton
        }
    }

    private func openToChipCard(_ item: PublicProfileOpenToItem) -> some View {
        VStack(spacing: 6) {
            if item.isSocial {
                Image(systemName: item.systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(item.tint)
                    .frame(height: 44)
            } else {
                FanGeoSportBadgeView(sport: item.id, size: 44, style: .profile)
            }

            Text(item.title)
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 9)
        .padding(.horizontal, 4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            item.tint.opacity(colorScheme == .dark ? 0.22 : 0.14),
                            Color.white.opacity(colorScheme == .dark ? 0.05 : 0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(item.tint.opacity(0.35), lineWidth: 0.85)
                }
        }
    }

    private func removeOpenToButton(item: PublicProfileOpenToItem) -> some View {
        Button {
            onRemove(item)
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 7.5, weight: .bold))
                .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.92))
                .frame(width: 20, height: 20)
                .background {
                    Circle()
                        .fill(Color.black.opacity(colorScheme == .dark ? 0.32 : 0.10))
                        .overlay {
                            Circle()
                                .strokeBorder(
                                    Color.white.opacity(colorScheme == .dark ? 0.22 : 0.65),
                                    lineWidth: 0.75
                                )
                        }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Remove \(item.title) from Open To")
    }

    private var addOpenToButton: some View {
        Button(action: onAdd) {
            VStack(spacing: 6) {
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .frame(height: 44)

                Text("Add")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10),
                                Color.white.opacity(colorScheme == .dark ? 0.05 : 0.88)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.30 : 0.24), lineWidth: 0.85)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add Open To")
    }
}

// MARK: - Mutual fans

struct PublicProfileMutualFansCard: View {
    let count: Int
    let avatars: [PublicProfileMutualFanAvatar]
    let sharedTeamNames: [String]
    let sharedTeamsCount: Int
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublicProfileSectionLabel(title: "Mutual Fans", accent: Color(red: 0.58, green: 0.36, blue: 0.92))

            Text("\(count) mutual fans")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            if !avatars.isEmpty {
                HStack(spacing: -8) {
                    ForEach(avatars.prefix(4)) { fan in
                        UserAvatarView(
                            avatarThumbnailURL: fan.avatarURL,
                            avatarURL: fan.avatarURL ?? "",
                            avatarDisplayRefreshToken: UserAvatarView.stableRefreshToken(
                                userId: fan.userId,
                                thumbnailURL: fan.avatarURL,
                                avatarURL: fan.avatarURL
                            ),
                            displayName: fan.displayName,
                            email: "",
                            size: 30,
                            fallbackStyle: .lightOnWhiteChrome,
                            imagePlaceholderTint: FGColor.accentBlue
                        )
                        .overlay(Circle().strokeBorder(Color.white, lineWidth: 1.5))
                    }
                }
            }

            if !sharedTeamNames.isEmpty {
                Text(sharedTeamNames.prefix(4).joined(separator: " • "))
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }

            if sharedTeamsCount > 0 {
                Text(sharedTeamsCount == 1 ? "1 shared team" : "\(sharedTeamsCount) shared teams")
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.accentGreen)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .publicProfileCompactGlass()
    }
}

// MARK: - Venues

struct PublicProfileVenuePillsRow: View {
    let venues: [PublicProfileVenueCard]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            PublicProfileSectionLabel(title: "Favorite Venues", accent: Color(red: 0.58, green: 0.36, blue: 0.92))

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(venues.prefix(3)) { venue in
                        HStack(spacing: 8) {
                            venueThumb(venue)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(venue.venueName)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                    .lineLimit(1)
                                if !venue.cityLabel.isEmpty {
                                    Text(venue.cityLabel)
                                        .font(.system(size: 9, weight: .medium, design: .rounded))
                                        .foregroundStyle(FGColor.mutedText(colorScheme))
                                }
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background {
                            Capsule(style: .continuous)
                                .fill(Color.white.opacity(colorScheme == .dark ? 0.06 : 0.78))
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: 0.75)
                                }
                        }
                    }
                }
            }
        }
        .padding(10)
        .publicProfileCompactGlass()
    }

    private func venueThumb(_ venue: PublicProfileVenueCard) -> some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(FGColor.accentBlue)
            .frame(width: 32, height: 32)
            .background(Circle().fill(FGColor.accentBlue.opacity(0.12)))
    }
}
