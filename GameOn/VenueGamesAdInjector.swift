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
    static let venueGameInlineAdsEnabled = false
    private static let midFeedInsertionPosition = 4
    private static let recurringInsertionInterval = 8

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
        guard venueGameInlineAdsEnabled else {
#if DEBUG
            print("[VenueGameAdDebug] inlineAdsDisabledDueToStability=true")
            print("[VenueGameAdDebug] placement=venue.gamesFeed")
            print("[VenueGameAdDebug] gameCount=\(gameCount)")
            print("[VenueGameAdDebug] insertedAdIndexes=[]")
#endif
            return []
        }

        guard gameCount > 0 else {
            logPlan(gameCount: gameCount, positions: [])
            return []
        }

        let positions: [Int]
        if gameCount <= 3 {
            positions = [gameCount]
        } else if gameCount < 10 {
            positions = [min(midFeedInsertionPosition, gameCount)]
        } else {
            positions = stride(from: midFeedInsertionPosition, through: gameCount, by: recurringInsertionInterval)
                .map { $0 }
        }

        logPlan(gameCount: gameCount, positions: positions)
        return positions
    }

    private static func logPlan(gameCount: Int, positions: [Int]) {
#if DEBUG
        print("[VenueGameAdDebug] placement=venue.gamesFeed")
        print("[VenueGameAdDebug] gameCount=\(gameCount)")
        print("[VenueGameAdDebug] insertedAdIndexes=\(positions)")
#endif
    }
}

struct SponsoredVenueCardView: View {
    let slotIndex: Int
    var placement: String = "venue.gamesFeed"

    private enum InlineAdLoadState {
        case loading
        case loaded
        case failed
    }

    @State private var loadState: InlineAdLoadState = .loading

    var body: some View {
        GeometryReader { geometry in
            let layoutWidth = max(geometry.size.width, CompactNativeAdLayout.minimumRequestDimension)

            ZStack {
                sponsoredPlaceholder

                if loadState != .failed {
                    CompactNativeAdCard(
                        placement: placement,
                        hostTabRaw: "discover",
                        slotIndex: slotIndex,
                        layoutWidth: layoutWidth,
                        prefersLightChrome: true,
                        animatesLoadState: false,
                        onAdLoaded: {
                            loadState = .loaded
                            logLoadState(loaded: true, failed: nil)
                        },
                        onAdFailed: { error in
                            loadState = .failed
                            logLoadState(loaded: false, failed: error.localizedDescription)
                        }
                    )
                    .frame(height: CompactNativeAdLayout.preferredHeight)
                    .opacity(loadState == .loaded ? 1 : 0.01)
                    .allowsHitTesting(loadState == .loaded)
                    .accessibilityElement(children: .contain)
                }
            }
        }
        .frame(height: CompactNativeAdLayout.preferredHeight)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onAppear {
            logLoadState(loaded: loadState == .loaded, failed: loadState == .failed ? "previousFailure" : nil)
        }
    }

    private var sponsoredPlaceholder: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Sponsored")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                Text("FanGeo partner")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary.opacity(0.72))
            }

            Spacer(minLength: 0)

            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary.opacity(0.7))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: CompactNativeAdLayout.preferredHeight, alignment: .leading)
        .background(.ultraThinMaterial)
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Color.white.opacity(0.05))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.75)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(loadState == .loaded)
    }

    private func logLoadState(loaded: Bool, failed: String?) {
#if DEBUG
        print("[VenueGameAdDebug] placement=\(placement)")
        print("[VenueGameAdDebug] loaded=\(loaded)")
        print("[VenueGameAdDebug] failed=\(failed ?? "nil")")
#endif
    }
}
