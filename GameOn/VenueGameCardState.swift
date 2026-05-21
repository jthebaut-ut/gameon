import Foundation

struct VenueGameCardInput: Equatable, Hashable {
    let venueEventID: UUID
    let barID: UUID
    let title: String
    let date: Date
    let sport: String
    let eventTime: String
    let homeTeam: String?
    let awayTeam: String?
    let scheduledStartAt: Date?
}

struct VenueGameCardMiniStats: Equatable {
    let vibeCounts: [String: Int]
    let selectedVibes: Set<String>
    let topVibeText: String?
    let trendingScore: Int
}

enum VenueGameCardReconcileStatus: Equatable {
    case idle
    case optimistic
    case reconciling
    case failed(String)
}

struct VenueGameCardGoingSnapshot {
    let isCurrentUserGoing: Bool
    let goingCount: Int
    let goingAvatarProfiles: [UserProfileRow]
    let reconcileStatus: VenueGameCardReconcileStatus
    let lastGoingUpdatedAt: Date?
    let lastAvatarUpdatedAt: Date?
}

struct VenueGameCardState {
    let input: VenueGameCardInput
    let isCurrentUserGoing: Bool
    let goingCount: Int
    let goingAvatarProfiles: [UserProfileRow]
    let predictionSummary: VenueEventPredictionSummary?
    let fanChatCount: Int
    let miniStats: VenueGameCardMiniStats
    let liveEnergy: FanGeoLiveEnergy
    let isLoading: Bool
    let reconcileStatus: VenueGameCardReconcileStatus
    let lastGoingUpdatedAt: Date?
    let lastAvatarUpdatedAt: Date?
    let lastFanChatUpdatedAt: Date?
    let lastMiniStatsUpdatedAt: Date?
    let lastPredictionUpdatedAt: Date?
}
