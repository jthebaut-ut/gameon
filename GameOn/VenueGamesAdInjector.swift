import SwiftUI

enum VenueGamesFeedItem: Identifiable, Equatable {
    case game(SportsEvent)
    case sponsored(slotIndex: Int, afterGamePosition: Int)

    var id: String {
        switch self {
        case .game(let event):
            return "venue-game-\(event.id.uuidString)"
        case .sponsored(let slotIndex, let afterGamePosition):
            return "venue-sponsored-\(slotIndex)-after-\(afterGamePosition)"
        }
    }
}

enum VenueGamesAdInjector {
    private static let compactFeedMaxGameCount = 4
    private static let compactFeedInsertionPosition = 2
    private static let recurringInsertionInterval = 5

    static func listItems(for games: [SportsEvent]) -> [VenueGamesFeedItem] {
        let insertionPositions = insertedAfterGamePositions(gameCount: games.count)
        guard !insertionPositions.isEmpty else {
            return games.map { .game($0) }
        }

        var items: [VenueGamesFeedItem] = []
        items.reserveCapacity(games.count + insertionPositions.count)

        var nextInsertionIndex = insertionPositions.startIndex
        for (index, game) in games.enumerated() {
            let gamePosition = index + 1
            items.append(.game(game))

            guard nextInsertionIndex < insertionPositions.endIndex,
                  insertionPositions[nextInsertionIndex] == gamePosition else {
                continue
            }

            let slotIndex = insertionPositions.distance(from: insertionPositions.startIndex, to: nextInsertionIndex)
            items.append(.sponsored(slotIndex: slotIndex, afterGamePosition: gamePosition))
            nextInsertionIndex = insertionPositions.index(after: nextInsertionIndex)
        }

        return items
    }

    static func insertedAfterGamePositions(gameCount: Int) -> [Int] {
        guard gameCount >= compactFeedInsertionPosition else { return [] }

        if gameCount <= compactFeedMaxGameCount {
            return [compactFeedInsertionPosition]
        }

        return stride(from: recurringInsertionInterval, through: gameCount, by: recurringInsertionInterval)
            .map { $0 }
    }
}

struct SponsoredVenueCardView: View {
    let slotIndex: Int
    let onViewVenue: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var nativeAdLoaded = false
    @State private var nativeAdFailed = false

    var body: some View {
        ZStack {
            fallbackCard
                .opacity(nativeAdLoaded ? 0 : 1)

            if !nativeAdFailed {
                CompactNativeAdCard(
                    slotIndex: slotIndex,
                    layoutWidth: 0,
                    onAdLoaded: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            nativeAdLoaded = true
                        }
                    },
                    onAdFailed: { _ in
                        withAnimation(.easeOut(duration: 0.2)) {
                            nativeAdFailed = true
                            nativeAdLoaded = false
                        }
                    }
                )
                .opacity(nativeAdLoaded ? 1 : 0)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }

    private var fallbackCard: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.12))

                Image(systemName: "sportscourt.fill")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 4) {
                Text("Sponsored")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.07))
                    )

                Text("Featured Sports Venue")
                    .font(.headline)
                    .fontWeight(.bold)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)

                Text("Big crowd tonight")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Button {
                onViewVenue()
            } label: {
                Text("View Venue")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        Capsule(style: .continuous)
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.10))
                    )
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(.ultraThinMaterial)

                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.05))
            }
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
        )
    }
}
