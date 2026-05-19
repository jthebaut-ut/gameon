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
                VStack(spacing: 6) {
                    Image(systemName: item.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(item.tint)
                        .frame(height: 26)

                    Text(item.title)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
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
                            avatarDisplayRefreshToken: UUID(),
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

// MARK: - Personality pills

struct PublicProfilePersonalityPills: View {
    let tags: [String]
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 6)
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [FGColor.accentBlue, FGColor.accentBlue.opacity(0.78)],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .overlay {
                                    Capsule(style: .continuous)
                                        .strokeBorder(FGColor.accentBlue.opacity(0.45), lineWidth: 0.75)
                                }
                        }
                }
            }
        }
    }
}
