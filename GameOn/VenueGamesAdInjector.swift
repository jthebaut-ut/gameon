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
#if DEBUG
        print("[VenueInlineAdDebug] gameCount=\(gameCount)")
#endif
        guard gameCount > 1 else {
#if DEBUG
            print("[VenueInlineAdDebug] inlineAdSuppressed reason=singleGame")
#endif
            return []
        }

        if gameCount <= compactFeedMaxGameCount {
            logInsertion(index: gameCount, mode: "afterLast")
            return [gameCount]
        }

        let positions = stride(from: recurringInsertionInterval, through: gameCount, by: recurringInsertionInterval)
            .map { $0 }
        for position in positions {
            logInsertion(index: position, mode: "interval")
        }
        return positions
    }

    private static func logInsertion(index: Int, mode: String) {
#if DEBUG
        print("[VenueInlineAdDebug] inlineAdInserted index=\(index)")
        print("[VenueInlineAdDebug] inlineAdMode=\(mode)")
#endif
    }
}

struct SponsoredVenueCardView: View {
    let slotIndex: Int

    private enum InlineAdLoadState {
        case loading
        case loaded
        case failed
    }

    @State private var loadState: InlineAdLoadState = .loading

    var body: some View {
        Group {
            switch loadState {
            case .loading, .loaded:
                CompactNativeAdCard(
                    placement: "venue.gamesFeed",
                    hostTabRaw: "discover",
                    slotIndex: slotIndex,
                    layoutWidth: 0,
                    prefersLightChrome: true,
                    onAdLoaded: {
                        withAnimation(.easeOut(duration: 0.2)) {
                            loadState = .loaded
                        }
#if DEBUG
                        print("[VenueInlineAdDebug] adLoaded=true")
                        print("[VenueInlineAdDebug] bannerDidReceiveAd=true")
#endif
                    },
                    onAdFailed: { error in
                        withAnimation(.easeOut(duration: 0.2)) {
                            loadState = .failed
                        }
#if DEBUG
                        print("[VenueInlineAdDebug] adFailed error=\(error.localizedDescription)")
                        print("[VenueInlineAdDebug] bannerDidFail error=\(error.localizedDescription)")
                        print("[VenueInlineAdDebug] hiddenDueToNoFill=true")
#endif
                    }
                )
                .frame(height: loadState == .loaded ? 98 : 0)
                .opacity(loadState == .loaded ? 1 : 0)
                .clipped()
                .allowsHitTesting(loadState == .loaded)
                .accessibilityElement(children: .contain)
                .onAppear {
#if DEBUG
                    let adUnitID = AdMobConfiguration.nativeAdUnitID
                    print("[VenueInlineAdDebug] deviceIsPhysical=\(!AdRuntimeDevice.isSimulator)")
                    print("[VenueInlineAdDebug] adUnitID=\(adUnitID)")
                    print("[VenueInlineAdDebug] adSize=native width=0 height=98")
                    print("[VenueInlineAdDebug] adLoadStarted=true")
                    print("[VenueInlineAdDebug] containerHiddenUntilLoaded=true")
                    print("[VenueInlineAdDebug] blackPlaceholderPrevented=true")
#endif
                }
            case .failed:
                EmptyView()
            }
        }
    }
}
