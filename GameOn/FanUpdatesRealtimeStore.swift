import Combine
import Foundation
import Supabase

@MainActor
final class FanUpdatesRealtimeStore: ObservableObject {
    @Published var venueEventComments: [UUID: [VenueEventCommentRow]] = [:]
    @Published var commentIDsReportedByCurrentUser: Set<UUID> = []
    @Published var venueEventVibeCounts: [UUID: [String: Int]] = [:]
    @Published var myVenueEventVibes: [UUID: Set<String>] = [:]
    @Published var venueEventCommentPreviewCounts: [UUID: Int] = [:]
    @Published var venueEventCommentPreviews: [UUID: [VenueEventCommentRow]] = [:]
    @Published var venueEventCommentLikeCountsByID: [UUID: Int] = [:]
    @Published var venueEventCommentDownReactionCountsByID: [UUID: Int] = [:]
    @Published var venueEventCommentIDsLikedByCurrentUser: Set<UUID> = []
    @Published var venueEventCommentViewerReactionsByID: [UUID: FanChatCommentReactionType] = [:]

    var venueEventCommentsRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    var venueEventCommentsRealtimeChannels: [UUID: RealtimeChannelV2] = [:]
    var venueEventCommentsRealtimeListenerTokens: [UUID: UUID] = [:]
    var venueEventCommentsRealtimeReadyIDs: Set<UUID> = []
    var venueEventCommentsRealtimeSubscribeStartedAt: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentRealtimeReceivedServerIDs: Set<UUID> = []
    var venueEventCommentRealtimeFallbackTasks: [UUID: Task<Void, Never>] = [:]
    var fanChatReceiverRefreshBurstTasks: [UUID: Task<Void, Never>] = [:]
    var fanChatAutoRefreshInFlightIDs: Set<UUID> = []
    var fanChatAppLevelRealtimeTask: Task<Void, Never>?
    var fanChatAppLevelRealtimeChannel: RealtimeChannelV2?
    var fanChatAppLevelRealtimeTrackedEventIDs: [UUID] = []
    var fanChatAppLevelLastScheduleRequestedEventIDs: [UUID] = []
    var fanChatAppLevelRealtimeResubscribeTask: Task<Void, Never>?
    var fanChatAppLevelSeenCommentIDs: Set<UUID> = []
    var fanChatCommentCountReconcileTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesCommentPrefetchTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesVibePrefetchTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesCommentPrefetchedAt: [UUID: Date] = [:]
    var fanUpdatesVibePrefetchedAt: [UUID: Date] = [:]
    var venueEventVibeWriteInFlightKeys: Set<String> = []
    var venueEventCommentLikeWriteInFlightIDs: Set<UUID> = []

    var venueEventCommentInsertSuccessTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentDebugSendTapDatesByLocalID: [UUID: Date] = [:]
    var venueEventCommentDebugSendTapTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentDebugReceivedDatesByServerID: [UUID: Date] = [:]
    var venueEventCommentDebugFallbackCommentIDs: Set<UUID> = []
    var venueEventCommentLatencySendTimesByLocalID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentLatencySendTimesByServerID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentLatencyLastSendTimeByEventID: [UUID: CFAbsoluteTime] = [:]
    var venueEventCommentLatencyInsertStartTimesByLocalID: [UUID: CFAbsoluteTime] = [:]

    init() {
        DebugLogGate.debug("[FanUpdatesRealtimeStoreDebug] initialized")
    }
}
