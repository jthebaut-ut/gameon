import Foundation
import Combine

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

@MainActor
final class VenueGameCardSnapshotStore: ObservableObject {
    @Published private(set) var goingSnapshots: [UUID: VenueGameCardGoingSnapshot] = [:]

    func snapshot(for eventID: UUID) -> VenueGameCardGoingSnapshot? {
#if DEBUG
        print("[VenueGameCardStoreDebug] snapshotStoreUsed eventId=\(eventID.uuidString.lowercased())")
#endif
        return goingSnapshots[eventID]
    }

    func setSnapshot(_ snapshot: VenueGameCardGoingSnapshot, for eventID: UUID) {
        goingSnapshots[eventID] = snapshot
#if DEBUG
        print("[VenueGameCardStoreDebug] snapshotStoreUpdated eventId=\(eventID.uuidString.lowercased())")
        print("[VenueGameCardStoreDebug] mapViewModelSnapshotPublishRemoved=true")
#endif
    }

    func reset() {
        goingSnapshots = [:]
    }
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
