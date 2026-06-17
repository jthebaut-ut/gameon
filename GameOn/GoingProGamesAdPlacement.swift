import Foundation

enum GoingProGamesAdSection: String, Hashable {
    case savedGames
    case favoriteTeamGames
    case businessMyTeams
}

struct GoingNativeAdSlot: Hashable, Identifiable {
    let slotIndex: Int
    let section: GoingProGamesAdSection
    let insertedAfterCardPosition: Int

    var id: String {
        "going-pro-native-\(section.rawValue)-\(slotIndex)-after-\(insertedAfterCardPosition)"
    }
}

enum GoingSavedProGameFeedItem: Identifiable {
    case game(SavedProGame)
    case nativeAd(GoingNativeAdSlot)

    var id: String {
        switch self {
        case .game(let game):
            return "going-saved-game-\(game.stableKey)"
        case .nativeAd(let slot):
            return slot.id
        }
    }
}

enum GoingFavoriteTeamProGameFeedItem: Identifiable {
    case game(FavoriteTeamProGame)
    case nativeAd(GoingNativeAdSlot)

    var id: String {
        switch self {
        case .game(let item):
            return "going-favorite-team-game-\(item.game.stableKey)"
        case .nativeAd(let slot):
            return slot.id
        }
    }
}

enum GoingBusinessMyTeamFeedItem: Identifiable {
    case savedGame(SavedProGame)
    case autoGame(FavoriteTeamProGame)
    case nativeAd(GoingNativeAdSlot)

    var id: String {
        switch self {
        case .savedGame(let game):
            return "going-business-saved-game-\(game.stableKey)"
        case .autoGame(let item):
            return "going-business-auto-game-\(item.game.stableKey)"
        case .nativeAd(let slot):
            return slot.id
        }
    }
}

struct GoingProGamesAdPlan {
    let savedGamesItems: [GoingSavedProGameFeedItem]
    let favoriteTeamItems: [GoingFavoriteTeamProGameFeedItem]
    let businessMyTeamsItems: [GoingBusinessMyTeamFeedItem]

    static let empty = GoingProGamesAdPlan(
        savedGamesItems: [],
        favoriteTeamItems: [],
        businessMyTeamsItems: []
    )
}

enum GoingProGamesAdPlacement {
    /// Venue comments use 0–1; chat inbox uses 2.
    static let baseNativeAdSlotIndex = 3
    /// Minimum cards in a section before that section may show a native ad.
    static let minimumCardCount = 6
    /// Insert the native ad immediately after this 1-based card index (after the 6th card).
    static let cardsBeforeFirstAd = 6
    /// Hard cap across Saved Games + Favorite Team Games + Business My Teams combined.
    static let maxAdsInProTab = 2

    /// Builds the full Going → Pro feed ad plan with section priority:
    /// 1. Saved Games, 2. Favorite Team Games, 3. Business My Teams (leftover budget only).
    static func plan(
        savedGames: [SavedProGame],
        favoriteTeamGames: [FavoriteTeamProGame],
        businessMyTeamSavedGames: [SavedProGame] = [],
        businessMyTeamAutoGames: [FavoriteTeamProGame] = []
    ) -> GoingProGamesAdPlan {
        let savedPositions = insertionPositions(
            cardCount: savedGames.count,
            maxAdsToInsert: min(1, maxAdsInProTab)
        )
        let savedItems = savedGamesFeedItems(
            games: savedGames,
            positions: savedPositions,
            startingSlotIndex: baseNativeAdSlotIndex
        )

        let favoriteBudget = max(0, maxAdsInProTab - savedPositions.count)
        let favoritePositions = insertionPositions(
            cardCount: favoriteTeamGames.count,
            maxAdsToInsert: min(1, favoriteBudget)
        )
        let favoriteItems = favoriteTeamGamesFeedItems(
            games: favoriteTeamGames,
            positions: favoritePositions,
            startingSlotIndex: baseNativeAdSlotIndex + savedPositions.count
        )

        let businessBudget = max(0, maxAdsInProTab - savedPositions.count - favoritePositions.count)
        let businessCombinedCount = businessMyTeamSavedGames.count + businessMyTeamAutoGames.count
        let businessPositions = insertionPositions(
            cardCount: businessCombinedCount,
            maxAdsToInsert: min(1, businessBudget)
        )
        let businessItems = businessMyTeamsFeedItems(
            savedGames: businessMyTeamSavedGames,
            autoGames: businessMyTeamAutoGames,
            positions: businessPositions,
            startingSlotIndex: baseNativeAdSlotIndex + savedPositions.count + favoritePositions.count
        )

        logPlan(
            savedCount: savedGames.count,
            favoriteCount: favoriteTeamGames.count,
            businessCount: businessCombinedCount,
            savedPositions: savedPositions,
            favoritePositions: favoritePositions,
            businessPositions: businessPositions
        )

        return GoingProGamesAdPlan(
            savedGamesItems: savedItems,
            favoriteTeamItems: favoriteItems,
            businessMyTeamsItems: businessItems
        )
    }

    /// Returns at most one insertion point per section: immediately after the 6th card.
    /// Never inserts before the first card. Requires at least `minimumCardCount` cards.
    static func insertionPositions(cardCount: Int, maxAdsToInsert: Int) -> [Int] {
        guard maxAdsToInsert > 0 else { return [] }
        guard cardCount >= minimumCardCount else { return [] }
        guard cardCount >= cardsBeforeFirstAd else { return [] }
        return [cardsBeforeFirstAd]
    }

    private static func savedGamesFeedItems(
        games: [SavedProGame],
        positions: [Int],
        startingSlotIndex: Int
    ) -> [GoingSavedProGameFeedItem] {
        guard !positions.isEmpty else {
            return games.map { .game($0) }
        }

        let positionsByCard = Set(positions)
        var items: [GoingSavedProGameFeedItem] = []
        items.reserveCapacity(games.count + positions.count)

        var slotOrdinal = 0
        for (index, game) in games.enumerated() {
            items.append(.game(game))
            let cardPosition = index + 1
            guard positionsByCard.contains(cardPosition) else { continue }
            items.append(
                .nativeAd(
                    GoingNativeAdSlot(
                        slotIndex: startingSlotIndex + slotOrdinal,
                        section: .savedGames,
                        insertedAfterCardPosition: cardPosition
                    )
                )
            )
            slotOrdinal += 1
        }
        return items
    }

    private static func favoriteTeamGamesFeedItems(
        games: [FavoriteTeamProGame],
        positions: [Int],
        startingSlotIndex: Int
    ) -> [GoingFavoriteTeamProGameFeedItem] {
        guard !positions.isEmpty else {
            return games.map { .game($0) }
        }

        let positionsByCard = Set(positions)
        var items: [GoingFavoriteTeamProGameFeedItem] = []
        items.reserveCapacity(games.count + positions.count)

        var slotOrdinal = 0
        for (index, game) in games.enumerated() {
            items.append(.game(game))
            let cardPosition = index + 1
            guard positionsByCard.contains(cardPosition) else { continue }
            items.append(
                .nativeAd(
                    GoingNativeAdSlot(
                        slotIndex: startingSlotIndex + slotOrdinal,
                        section: .favoriteTeamGames,
                        insertedAfterCardPosition: cardPosition
                    )
                )
            )
            slotOrdinal += 1
        }
        return items
    }

    private static func businessMyTeamsFeedItems(
        savedGames: [SavedProGame],
        autoGames: [FavoriteTeamProGame],
        positions: [Int],
        startingSlotIndex: Int
    ) -> [GoingBusinessMyTeamFeedItem] {
        guard !positions.isEmpty else {
            var items = savedGames.map { GoingBusinessMyTeamFeedItem.savedGame($0) }
            items.append(contentsOf: autoGames.map { GoingBusinessMyTeamFeedItem.autoGame($0) })
            return items
        }

        let positionsByCard = Set(positions)
        var items: [GoingBusinessMyTeamFeedItem] = []
        let combinedCount = savedGames.count + autoGames.count
        items.reserveCapacity(combinedCount + positions.count)

        var slotOrdinal = 0
        var cardPosition = 0

        for game in savedGames {
            cardPosition += 1
            items.append(.savedGame(game))
            if positionsByCard.contains(cardPosition) {
                items.append(
                    .nativeAd(
                        GoingNativeAdSlot(
                            slotIndex: startingSlotIndex + slotOrdinal,
                            section: .businessMyTeams,
                            insertedAfterCardPosition: cardPosition
                        )
                    )
                )
                slotOrdinal += 1
            }
        }

        for autoGame in autoGames {
            cardPosition += 1
            items.append(.autoGame(autoGame))
            if positionsByCard.contains(cardPosition) {
                items.append(
                    .nativeAd(
                        GoingNativeAdSlot(
                            slotIndex: startingSlotIndex + slotOrdinal,
                            section: .businessMyTeams,
                            insertedAfterCardPosition: cardPosition
                        )
                    )
                )
                slotOrdinal += 1
            }
        }

        return items
    }

    private static func logPlan(
        savedCount: Int,
        favoriteCount: Int,
        businessCount: Int,
        savedPositions: [Int],
        favoritePositions: [Int],
        businessPositions: [Int]
    ) {
        guard AdDiagnostics.enabled else { return }
        print("[GoingProAdDebug] placement=going.proGamesFeed")
        print("[GoingProAdDebug] savedGamesCount=\(savedCount)")
        print("[GoingProAdDebug] favoriteTeamGamesCount=\(favoriteCount)")
        print("[GoingProAdDebug] businessMyTeamsCount=\(businessCount)")
        print("[GoingProAdDebug] savedInsertionPositions=\(savedPositions)")
        print("[GoingProAdDebug] favoriteInsertionPositions=\(favoritePositions)")
        print("[GoingProAdDebug] businessInsertionPositions=\(businessPositions)")
        print("[GoingProAdDebug] maxAdsInProTab=\(maxAdsInProTab)")
        print("[GoingProAdDebug] cardsBeforeFirstAd=\(cardsBeforeFirstAd)")
        print("[GoingProAdDebug] minimumCardCount=\(minimumCardCount)")
    }
}
