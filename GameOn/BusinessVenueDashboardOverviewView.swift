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
    let onAddVenue: () -> Void
    let onTonightGames: () -> Void
    let onPredictions: () -> Void
    let onAnalytics: () -> Void
    let onCommentsReports: () -> Void
    let onViewAllGames: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            quickActions
            tonightSection
        }
        .onAppear {
#if DEBUG
            print("[BusinessDashboardCleanup] removedDarkFanLevelCard=true")
            print("[BusinessDashboardDebug] addVenueQuickActionVisible=true")
#endif
        }
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
                    BusinessVenueDashboardActionCard(title: "Add Venue", systemImage: "plus.circle.fill", tint: FGColor.accentBlue, action: handleAddVenueTapped)
                }
                .padding(.vertical, 2)
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
