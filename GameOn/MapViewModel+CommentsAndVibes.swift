import Foundation
import Supabase

// Venue-event social layer: vibe votes, threaded comments, reports, and moderation helpers for venue owners.

/// Task cancellation during overlapping loads is expected; do not log as ERROR.
private func logVenueEventSocialLoadError(_ prefix: String, loadCancelledTag: String, error: Error) {
    if error is CancellationError {
#if DEBUG
        print("[LoadCancelled] \(loadCancelledTag)")
        print("[CancellationHandlingDebug] ignoredCancellation context=\(loadCancelledTag)")
#endif
        return
    }
    print(prefix, error)
}

private enum VenueEventCommentsPagination {
    static let initialLimit = 100
    static let pageLimit = 50
    static let selectColumns = "id,venue_event_id,user_email,comment,created_at,is_moderation_hidden"
    static let previewLimit = 2
}

private enum CurrentUserCommentReportFlags {
    static let inQueryChunk = 80
}

private enum FanCommentLikesBatchLoad {
    static let inQueryChunk = 100

    static func chunked<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<Swift.min($0 + size, array.count)])
        }
    }
}

private enum VenueEventCommentsQuery {
    static func isoTimestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    static func keysetOlderThanOrFilter(createdAt: Date, commentId: UUID) -> String {
        let iso = isoTimestamp(createdAt)
        let uid = commentId.uuidString.lowercased()
        return "created_at.lt.\(iso),and(created_at.eq.\(iso),id.lt.\(uid))"
    }

    static func keysetNewerThanOrFilter(createdAt: Date, commentId: UUID) -> String {
        let iso = isoTimestamp(createdAt)
        let uid = commentId.uuidString.lowercased()
        return "created_at.gt.\(iso),and(created_at.eq.\(iso),id.gt.\(uid))"
    }
}

private enum FanChatLatencyDebugClock {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func localTime(_ date: Date = Date()) -> String {
        formatter.string(from: date)
    }

    static func elapsedMs(since start: CFAbsoluteTime?) -> String {
        guard let start else { return "nil" }
        return String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - start) * 1000)
    }
}

private enum FanUpdatesPrefetchTTL {
    static let comments: TimeInterval = 30
    static let vibes: TimeInterval = 20
}

private enum DiscoverVisibleSocialPrefetchConfig {
    static let maxVisibleEvents = 12
}

private enum FanChatAppLevelRealtimeConfig {
    static let maxTrackedEventIDs = 160
    static let filterChunkSize = 80
    static let resubscribeDebounceNs: UInt64 = 250_000_000
    static let countReconcileDebounceNs: UInt64 = 900_000_000

    static func chunked<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0 else { return [array] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<Swift.min($0 + size, array.count)])
        }
    }
}

private struct FanChatSheetRealtimeSubscribeTimeoutError: Error {}

private enum FanChatRealtimeFallbackConfig {
    static let recoveryDelayNs: [UInt64] = [750_000_000, 2_000_000_000, 5_000_000_000]
    static let fetchLimit = 40

    static func delayMs(for delayNs: UInt64) -> Int {
        Int(delayNs / 1_000_000)
    }
}

private enum FanChatRealtimeFirstPollingConfig {
    static let gracePeriodNs: UInt64 = 2_500_000_000
    static let fallbackPollIntervalNs: UInt64 = 2_500_000_000
    static let healthyPollIntervalNs: UInt64 = 8_000_000_000
    static let reactionRefreshMinimumInterval: TimeInterval = 20

    static var fallbackPollIntervalSeconds: String {
        String(format: "%.1f", Double(fallbackPollIntervalNs) / 1_000_000_000)
    }
}

private enum FanChatReactionRealtimeConfig {
    static let debounceNs: UInt64 = 250_000_000
    static let readyGraceNs: UInt64 = 2_000_000_000
    static let fallbackPollIntervalNs: UInt64 = 8_000_000_000
}

private struct FanChatCommentCursor {
    let createdAt: Date
    let id: UUID
}

private struct FanChatReceiverRefreshStats {
    let fetchedCount: Int
    let newRowsMerged: Int
    let latestServerIds: [String]
    let visibleCountAfterMerge: Int
}

extension MapViewModel {

    private func parseVenueEventCommentDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f1.date(from: raw) { return d }
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        return f2.date(from: raw)
    }

    private func fanChatDebugMilliseconds(from start: CFAbsoluteTime?, to end: CFAbsoluteTime? = nil) -> String {
        guard let start else { return "nil" }
        let finish = end ?? CFAbsoluteTimeGetCurrent()
        return String(format: "%.1f", (finish - start) * 1000)
    }

    private func logFanChatEndToEnd(
        venueEventID: UUID,
        row: VenueEventCommentRow,
        fallbackUsed: Bool,
        receivedAt: Date = Date()
    ) {
#if DEBUG
        guard let commentID = row.serverCommentID else { return }
        let serverCreatedAt = parseVenueEventCommentDate(row.created_at)
        let insertSuccess = venueEventCommentInsertSuccessTimesByServerID[commentID]
        let sendTapStart = venueEventCommentDebugSendTapTimesByServerID[commentID]
        let insertToRealtimeMs = fanChatDebugMilliseconds(from: insertSuccess)
        let insertToVisibleMs = serverCreatedAt.map {
            String(format: "%.1f", receivedAt.timeIntervalSince($0) * 1000)
        } ?? "nil"
        let channelName = "venue-event-comments-\(venueEventID.uuidString.lowercased())"
        let sender = currentUserAuthId?.uuidString.lowercased() ?? row.user_email ?? "unknown"
        DebugLogGate.debug("[FanChatEndToEndDebug] eventId=\(venueEventID.uuidString.lowercased()) senderUserId=\(sender) commentId=\(commentID.uuidString.lowercased()) sendTapToInsertMs=\(fanChatDebugMilliseconds(from: sendTapStart, to: insertSuccess)) insertToRealtimeMs=\(insertToRealtimeMs) insertToOtherDeviceVisibleMs=\(insertToVisibleMs) fallbackUsed=\(fallbackUsed) subscriptionReady=\(venueEventCommentsRealtimeReadyIDs.contains(venueEventID)) channelName=\(channelName)")
#endif
    }

    func debugFanChatTimingText(for comment: VenueEventCommentRow) -> String? {
#if DEBUG
        guard let commentID = comment.serverCommentID else { return nil }
        let sent = parseVenueEventCommentDate(comment.created_at)
        let received = venueEventCommentDebugReceivedDatesByServerID[commentID]
        guard sent != nil || received != nil else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm:ss.SSS"
        var parts: [String] = []
        if let sent {
            parts.append("sent \(formatter.string(from: sent))")
        }
        if let received {
            parts.append("received \(formatter.string(from: received))")
        }
        if let sent, let received {
            parts.append("delay \(String(format: "%.1fs", received.timeIntervalSince(sent)))")
        }
        if venueEventCommentDebugFallbackCommentIDs.contains(commentID) {
            parts.append("fallback")
        }
        return parts.joined(separator: "  ")
#else
        return nil
#endif
    }

    private func updatedCommentRow(_ row: VenueEventCommentRow, deliveryState: VenueEventCommentDeliveryState) -> VenueEventCommentRow {
        VenueEventCommentRow(
            id: row.id,
            venue_event_id: row.venue_event_id,
            user_email: row.user_email,
            comment: row.comment,
            created_at: row.created_at,
            is_moderation_hidden: row.is_moderation_hidden,
            delivery_state: deliveryState,
            upReactionCount: row.upReactionCount,
            downReactionCount: row.downReactionCount,
            viewerReaction: row.viewerReaction
        )
    }

    private func venueEventCommentRowWithCurrentReactionMetadata(_ row: VenueEventCommentRow) -> VenueEventCommentRow {
        guard let commentID = row.serverCommentID else { return row }
        return row.withReactionMetadata(
            upCount: venueEventCommentLikeCountsByID[commentID] ?? row.upReactionCount,
            downCount: venueEventCommentDownReactionCountsByID[commentID] ?? row.downReactionCount,
            viewerReaction: venueEventCommentViewerReactionsByID[commentID]
        )
    }

    private func matchingPendingCommentIndex(
        in list: [VenueEventCommentRow],
        venueEventID: UUID,
        email: String?,
        text: String?
    ) -> Int? {
        let normalizedEmail = OwnerBusinessEmail.normalized(email ?? "")
        let normalizedText = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedEmail.isEmpty, !normalizedText.isEmpty else { return nil }
        return list.indices.reversed().first { index in
            let candidate = list[index]
            guard candidate.venue_event_id == venueEventID else { return false }
            guard candidate.delivery_state != .sent else { return false }
            return OwnerBusinessEmail.normalized(candidate.user_email ?? "") == normalizedEmail
                && (candidate.comment ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == normalizedText
        }
    }

    @MainActor
    private func updateVenueEventCommentPreviewCount(
        for venueEventID: UUID,
        to count: Int
    ) {
        let nextCount = max(count, 0)
        venueEventCommentPreviewCounts[venueEventID] = nextCount
        #if DEBUG
        print("[VenueCommentRealtimeDebug] commentCountUpdated=\(nextCount) eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatLatencyDebug] previewCountUpdated eventId=\(venueEventID.uuidString.lowercased()) count=\(nextCount) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentLatencyLastSendTimeByEventID[venueEventID]))")
        #endif
    }

    @MainActor
    private func applyVenueEventCommentCountDelta(
        for venueEventID: UUID,
        delta: Int
    ) {
        let visibleCount = venueEventComments[venueEventID]?.filter { !$0.isHiddenFromThread && !$0.isFailedSend }.count ?? 0
        if let cachedCount = venueEventCommentPreviewCounts[venueEventID] {
            updateVenueEventCommentPreviewCount(for: venueEventID, to: cachedCount + delta)
        } else {
            updateVenueEventCommentPreviewCount(for: venueEventID, to: visibleCount)
        }
    }

    @MainActor
    private func mergeFanUpdatesPreviewComment(_ row: VenueEventCommentRow, for venueEventID: UUID) {
        guard !row.isHiddenFromThread else { return }
        var previews = venueEventCommentPreviews[venueEventID] ?? []
        if let serverID = row.serverCommentID,
           let existingIndex = previews.firstIndex(where: { $0.serverCommentID == serverID }) {
            previews[existingIndex] = row
        } else {
            previews.insert(row, at: 0)
        }
        venueEventCommentPreviews[venueEventID] = Array(previews.prefix(VenueEventCommentsPagination.previewLimit))
        fanUpdatesCommentPrefetchedAt[venueEventID] = Date()
    }

    @MainActor
    private func appendPendingVenueEventComment(_ row: VenueEventCommentRow, for venueEventID: UUID) {
        var list = venueEventComments[venueEventID] ?? []
        list.append(row)
        venueEventComments[venueEventID] = list
        applyVenueEventCommentCountDelta(for: venueEventID, delta: 1)
        #if DEBUG
        print("[VenueCommentRealtimeDebug] optimisticAppend tempId=\(row.id?.uuidString.lowercased() ?? "nil") eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatLatencyDebug] optimisticAppend eventId=\(venueEventID.uuidString.lowercased()) tempId=\(row.id?.uuidString.lowercased() ?? "nil") localTime=\(FanChatLatencyDebugClock.localTime())")
        print("[FanChatLatencyDebug] uiCommentListUpdated eventId=\(venueEventID.uuidString.lowercased()) count=\(list.count) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: row.id.flatMap { venueEventCommentLatencySendTimesByLocalID[$0] }))")
        #endif
    }

    @MainActor
    private func mergeIncomingVenueEventComment(
        _ row: VenueEventCommentRow,
        for venueEventID: UUID,
        preferredLocalID: UUID? = nil,
        source: String
    ) {
        let row = venueEventCommentRowWithCurrentReactionMetadata(row)
        guard !row.isHiddenFromThread else { return }
        var list = venueEventComments[venueEventID] ?? []
        if let serverID = row.serverCommentID,
           let existingSentIndex = list.firstIndex(where: { $0.serverCommentID == serverID }) {
            list[existingSentIndex] = row
            venueEventComments[venueEventID] = list
            mergeFanUpdatesPreviewComment(row, for: venueEventID)
            #if DEBUG
            print("[VenueCommentRealtimeDebug] deduped id=\(serverID.uuidString.lowercased()) eventId=\(venueEventID.uuidString.lowercased())")
            print("[FanChatLatencyDebug] dedupeApplied eventId=\(venueEventID.uuidString.lowercased()) commentId=\(serverID.uuidString.lowercased())")
            print("[FanChatLatencyDebug] uiCommentListUpdated eventId=\(venueEventID.uuidString.lowercased()) count=\(list.count) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentLatencySendTimesByServerID[serverID]))")
            if source == "realtime" || source == "realtime_fallback" || source == "receiver_refresh" {
                print("[FanChatReceiverDebug] realtimeIgnored reason=alreadyVisible commentId=\(serverID.uuidString.lowercased())")
            }
            #endif
            return
        }
        if let preferredLocalID,
           let localIndex = list.firstIndex(where: { $0.id == preferredLocalID && $0.delivery_state != .sent }) {
            list[localIndex] = row
            venueEventComments[venueEventID] = list
            mergeFanUpdatesPreviewComment(row, for: venueEventID)
            #if DEBUG
            if let serverID = row.serverCommentID {
                print("[FanChatLatencyDebug] dedupeApplied eventId=\(venueEventID.uuidString.lowercased()) commentId=\(serverID.uuidString.lowercased())")
            }
            print("[FanChatLatencyDebug] uiCommentListUpdated eventId=\(venueEventID.uuidString.lowercased()) count=\(list.count) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentLatencySendTimesByLocalID[preferredLocalID]))")
            #endif
            return
        }
        if let pendingIndex = matchingPendingCommentIndex(
            in: list,
            venueEventID: venueEventID,
            email: row.user_email,
            text: row.comment
        ) {
            list[pendingIndex] = row
            venueEventComments[venueEventID] = list
            mergeFanUpdatesPreviewComment(row, for: venueEventID)
            #if DEBUG
            if let serverID = row.serverCommentID {
                print("[FanChatLatencyDebug] dedupeApplied eventId=\(venueEventID.uuidString.lowercased()) commentId=\(serverID.uuidString.lowercased())")
                print("[FanChatLatencyDebug] uiCommentListUpdated eventId=\(venueEventID.uuidString.lowercased()) count=\(list.count) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentLatencySendTimesByServerID[serverID]))")
                if source == "realtime" || source == "realtime_fallback" || source == "receiver_refresh" {
                    print("[FanChatReceiverDebug] realtimeMergeApplied commentId=\(serverID.uuidString.lowercased())")
                }
            } else {
                print("[FanChatLatencyDebug] uiCommentListUpdated eventId=\(venueEventID.uuidString.lowercased()) count=\(list.count) elapsedMs=nil")
            }
            #endif
            return
        }
        list.append(row)
        venueEventComments[venueEventID] = list
        mergeFanUpdatesPreviewComment(row, for: venueEventID)
        applyVenueEventCommentCountDelta(for: venueEventID, delta: 1)
        #if DEBUG
        print("[GameChatPerf] \(source) append event=\(venueEventID) row=\(row.id?.uuidString ?? "nil")")
        print("[FanChatLatencyDebug] uiCommentListUpdated eventId=\(venueEventID.uuidString.lowercased()) count=\(list.count) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: row.serverCommentID.flatMap { venueEventCommentLatencySendTimesByServerID[$0] }))")
            if source == "realtime" || source == "realtime_fallback" || source == "receiver_refresh",
               let serverID = row.serverCommentID {
                print("[FanChatReceiverDebug] realtimeMergeApplied commentId=\(serverID.uuidString.lowercased())")
            }
        #endif
    }

    @MainActor
    private func markVenueEventCommentDeliveryState(
        venueEventID: UUID,
        localCommentID: UUID,
        state: VenueEventCommentDeliveryState
    ) {
        guard var list = venueEventComments[venueEventID],
              let index = list.firstIndex(where: { $0.id == localCommentID }) else { return }
        list[index] = updatedCommentRow(list[index], deliveryState: state)
        venueEventComments[venueEventID] = list
    }

    private func performVenueEventCommentInsert(
        venueEventID: UUID,
        localCommentID: UUID,
        commenterEmail: String,
        cleanText: String
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                #if DEBUG
                print("[VenueCommentRealtimeDebug] insertStarted=\(localCommentID.uuidString.lowercased()) eventId=\(venueEventID.uuidString.lowercased())")
                let insertStartedAt = CFAbsoluteTimeGetCurrent()
                venueEventCommentLatencyInsertStartTimesByLocalID[localCommentID] = insertStartedAt
                print("[FanChatLatencyDebug] insertStart eventId=\(venueEventID.uuidString.lowercased()) localTime=\(FanChatLatencyDebugClock.localTime())")
                #endif
                let newComment = VenueEventCommentInsert(
                    venue_event_id: venueEventID,
                    user_email: commenterEmail,
                    comment: cleanText
                )

                let row: VenueEventCommentRow = try await supabase
                    .from("venue_event_comments")
                    .insert(newComment)
                    .select(VenueEventCommentsPagination.selectColumns)
                    .single()
                    .execute()
                    .value

                RateLimitService.recordVenueEventCommentSend(venueEventId: venueEventID, body: cleanText)
                #if DEBUG
                print("[GameChatPerf] server insert completed event=\(venueEventID) local=\(localCommentID) server=\(row.id?.uuidString ?? "nil")")
                #endif
                #if DEBUG
                print("[VenueCommentRealtimeDebug] insertSucceeded serverId=\(row.id?.uuidString.lowercased() ?? "nil") tempId=\(localCommentID.uuidString.lowercased()) eventId=\(venueEventID.uuidString.lowercased())")
                if let serverID = row.serverCommentID,
                   let sendStartedAt = venueEventCommentLatencySendTimesByLocalID[localCommentID] {
                    venueEventCommentLatencySendTimesByServerID[serverID] = sendStartedAt
                    venueEventCommentInsertSuccessTimesByServerID[serverID] = CFAbsoluteTimeGetCurrent()
                    venueEventCommentDebugSendTapTimesByServerID[serverID] = sendStartedAt
                    venueEventCommentDebugReceivedDatesByServerID[serverID] = Date()
                }
                DebugLogGate.debug("[FanChatLatencyDebug] insertSuccess eventId=\(venueEventID.uuidString.lowercased()) serverId=\(row.id?.uuidString.lowercased() ?? "nil") elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentLatencyInsertStartTimesByLocalID[localCommentID]))")
                #endif
                mergeIncomingVenueEventComment(row, for: venueEventID, preferredLocalID: localCommentID, source: "insert")
                logFanChatEndToEnd(venueEventID: venueEventID, row: row, fallbackUsed: false)
                if let serverID = row.serverCommentID {
                    let subscriptionReady = venueEventCommentsRealtimeReadyIDs.contains(venueEventID)
                    #if DEBUG
                    if !subscriptionReady {
                        print("[FanChatReadyDebug] fastFallbackScheduled delayMs=750")
                    }
                    #endif
                    scheduleVenueEventCommentRecoveryBurst(
                        venueEventID: venueEventID,
                        expectedCommentID: serverID
                    )
                }
                if let email = row.user_email {
                    await loadUserProfilesForEmails([email])
                }
            } catch {
                #if DEBUG
                print("[GameChatPerf] send failed event=\(venueEventID) local=\(localCommentID) error=\(error)")
                print("[VenueCommentRealtimeDebug] insertFailed error=\(error) tempId=\(localCommentID.uuidString.lowercased()) eventId=\(venueEventID.uuidString.lowercased())")
                print("[FanChatLatencyDebug] insertFailure eventId=\(venueEventID.uuidString.lowercased()) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentLatencyInsertStartTimesByLocalID[localCommentID])) error=\(error.localizedDescription)")
                #endif
                markVenueEventCommentDeliveryState(
                    venueEventID: venueEventID,
                    localCommentID: localCommentID,
                    state: .failed
                )
                applyVenueEventCommentCountDelta(for: venueEventID, delta: -1)
            }
        }
    }

    private func hasActiveVenueEventCommentsRealtimeListener(for venueEventID: UUID) -> Bool {
        venueEventCommentsRealtimeTasks[venueEventID] != nil
            || venueEventCommentsRealtimeChannels[venueEventID] != nil
            || venueEventCommentsRealtimeListenerTokens[venueEventID] != nil
    }

    func fanChatRealtimeIsHealthy(for venueEventID: UUID) -> Bool {
        hasActiveVenueEventCommentsRealtimeListener(for: venueEventID)
            && venueEventCommentsRealtimeReadyIDs.contains(venueEventID)
    }

    private func markFanChatRealtimeHealth(
        for venueEventID: UUID,
        healthy: Bool,
        eventReceived: Bool = false
    ) {
        if healthy {
            venueEventCommentsRealtimeReadyIDs.insert(venueEventID)
            if eventReceived {
                venueEventCommentsRealtimeLastEventAt[venueEventID] = Date()
            }
        } else {
            venueEventCommentsRealtimeReadyIDs.remove(venueEventID)
            venueEventCommentsRealtimeLastEventAt[venueEventID] = nil
        }
        #if DEBUG
        print("[FanChatPerfDebug] realtimeHealthy=\(healthy)")
        #endif
    }

    func fanChatRealtimeGracePeriodNanoseconds() -> UInt64 {
        FanChatRealtimeFirstPollingConfig.gracePeriodNs
    }

    func fanChatFallbackPollIntervalNanoseconds() -> UInt64 {
        FanChatRealtimeFirstPollingConfig.fallbackPollIntervalNs
    }

    func fanChatHealthyPollIntervalNanoseconds() -> UInt64 {
        FanChatRealtimeFirstPollingConfig.healthyPollIntervalNs
    }

    private func venueEventCommentsRealtimeActiveIDs(excluding venueEventID: UUID? = nil) -> [UUID] {
        let all = Set(venueEventCommentsRealtimeTasks.keys)
            .union(venueEventCommentsRealtimeChannels.keys)
            .union(venueEventCommentsRealtimeListenerTokens.keys)
        if let venueEventID {
            return all.filter { $0 != venueEventID }
        }
        return Array(all)
    }

    func scheduleFanChatAppLevelRealtimeForLoadedVenueEvents() {
        let eventIDs = fanChatAppLevelTrackedVenueEventIDs()
        if eventIDs == fanChatAppLevelLastScheduleRequestedEventIDs {
#if DEBUG
            print("[PerfPhase1] fanChatRealtimeSkipped reason=sameTrackedIDs")
#endif
            return
        }
        if eventIDs == fanChatAppLevelRealtimeTrackedEventIDs,
           fanChatAppLevelRealtimeTask != nil,
           fanChatAppLevelRealtimeChannel != nil {
            fanChatAppLevelLastScheduleRequestedEventIDs = eventIDs
#if DEBUG
            print("[PerfPhase1] fanChatRealtimeSkipped reason=sameTrackedIDs")
#endif
            return
        }
        fanChatAppLevelLastScheduleRequestedEventIDs = eventIDs
        fanChatAppLevelRealtimeResubscribeTask?.cancel()
        fanChatAppLevelRealtimeResubscribeTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: FanChatAppLevelRealtimeConfig.resubscribeDebounceNs)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.startFanChatAppLevelRealtimeIfNeeded(eventIDs: eventIDs)
        }
    }

    func verifyFanChatRealtimeAfterForeground() async {
#if DEBUG
        RealtimeHealthDiagnostics.log("appForegroundReconnect=fan_chat")
#endif
        let trackedIDs = fanChatAppLevelTrackedVenueEventIDs()
        if !trackedIDs.isEmpty {
            let appRealtimeHealthy = fanChatAppLevelRealtimeTask != nil && fanChatAppLevelRealtimeChannel != nil
            if appRealtimeHealthy {
#if DEBUG
                RealtimeHealthDiagnostics.log("reconnectSkipped reason=fan_chat_app_channel_healthy")
#endif
            } else {
#if DEBUG
                let reason = (fanChatAppLevelRealtimeTask == nil || fanChatAppLevelRealtimeChannel == nil)
                    ? "fan_chat_app_missing_channel"
                    : "fan_chat_app_foreground_resubscribe"
                RealtimeHealthDiagnostics.log("reconnectDetected=\(reason)")
#endif
                await stopFanChatAppLevelRealtime()
                await startFanChatAppLevelRealtimeIfNeeded(eventIDs: trackedIDs)
            }
        }

        let activeSheetIDs = venueEventCommentsRealtimeActiveIDs()
        for eventID in activeSheetIDs {
            let sheetRealtimeHealthy = fanChatRealtimeIsHealthy(for: eventID)
#if DEBUG
            print("[FanChatPerfDebug] foregroundReconcile=true")
#endif
            _ = await fetchRecentVenueEventCommentsForRealtimeFallback(
                venueEventID: eventID,
                mergeSource: "foreground_reconcile",
                fetchOnlyNewerThanLatestKnown: true,
                reconcileExactCount: false
            )
            guard !sheetRealtimeHealthy else {
#if DEBUG
                RealtimeHealthDiagnostics.log("reconnectSkipped reason=fan_chat_sheet_channel_healthy channelName=venue-event-comments-\(eventID.uuidString.lowercased())")
#endif
                continue
            }
#if DEBUG
            let reason = venueEventCommentsRealtimeReadyIDs.contains(eventID)
                ? "fan_chat_sheet_foreground_resubscribe"
                : "fan_chat_sheet_not_ready"
            RealtimeHealthDiagnostics.log("reconnectDetected=\(reason) channelName=venue-event-comments-\(eventID.uuidString.lowercased())")
#endif
            await stopVenueEventCommentsRealtime(for: eventID)
            await startVenueEventCommentsRealtime(for: eventID)
        }
    }

    private func fanChatAppLevelTrackedVenueEventIDs() -> [UUID] {
        Array(Set(venueEventRows.compactMap(\.id)))
            .sorted { $0.uuidString < $1.uuidString }
            .prefix(FanChatAppLevelRealtimeConfig.maxTrackedEventIDs)
            .map { $0 }
    }

    private func startFanChatAppLevelRealtimeIfNeeded(eventIDs: [UUID]) async {
        let ids = Array(Set(eventIDs))
            .sorted { $0.uuidString < $1.uuidString }
            .prefix(FanChatAppLevelRealtimeConfig.maxTrackedEventIDs)
            .map { $0 }

        if ids == fanChatAppLevelRealtimeTrackedEventIDs,
           fanChatAppLevelRealtimeTask != nil,
           fanChatAppLevelRealtimeChannel != nil {
            return
        }

        await stopFanChatAppLevelRealtime()
        fanChatAppLevelRealtimeTrackedEventIDs = ids
        guard !ids.isEmpty else { return }

        fanChatAppLevelRealtimeTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runFanChatAppLevelRealtimeLoop(eventIDs: ids)
        }
    }

    private func stopFanChatAppLevelRealtime() async {
        fanChatAppLevelRealtimeResubscribeTask?.cancel()
        fanChatAppLevelRealtimeResubscribeTask = nil

        if let task = fanChatAppLevelRealtimeTask {
            task.cancel()
            _ = await task.result
            fanChatAppLevelRealtimeTask = nil
        }
        fanUpdatesStore.crowdReactionVibeRealtimeRefreshTask?.cancel()
        fanUpdatesStore.crowdReactionVibeRealtimeRefreshTask = nil

        if let channel = fanChatAppLevelRealtimeChannel {
            await supabase.removeChannel(channel)
            fanChatAppLevelRealtimeChannel = nil
        }
    }

    private func runFanChatAppLevelRealtimeLoop(eventIDs: [UUID]) async {
        let ids = Array(Set(eventIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty, !Task.isCancelled else { return }

        let channel = supabase.channel("venue-event-comments-app-\(UUID().uuidString.lowercased())")
        fanChatAppLevelRealtimeChannel = channel
        let subscribeStartedAt = CFAbsoluteTimeGetCurrent()

        let streams = FanChatAppLevelRealtimeConfig.chunked(
            ids,
            size: FanChatAppLevelRealtimeConfig.filterChunkSize
        ).map { chunk in
            channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "venue_event_comments",
                filter: RealtimePostgresFilter.in("venue_event_id", values: chunk)
            )
        }
        let vibeStreams = FanChatAppLevelRealtimeConfig.chunked(
            ids,
            size: FanChatAppLevelRealtimeConfig.filterChunkSize
        ).map { chunk in
            channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "venue_event_vibes",
                filter: RealtimePostgresFilter.in("venue_event_id", values: chunk)
            )
        }

        do {
            #if DEBUG
            let idList = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
            print("[FanChatRealtimeDelayDebug] appSubscribeStart eventIds=\(idList)")
            print("[FanChatRealtimeDelayDebug] filterMode=app_in")
            print("[RealtimePublicationVerify] expected table=venue_event_vibes publication=supabase_realtime migration=20260731_0030")
            print("[RealtimeChainDebug] subscribeRequested table=venue_event_vibes channel=\(channel.topic) filter=venue_event_id.in trackedCount=\(ids.count)")
            RealtimeHealthDiagnostics.log("channelName=\(channel.topic)")
            RealtimeHealthDiagnostics.log("subscribeStart=true channelName=\(channel.topic)")
            #endif
            try await channel.subscribeWithError()
            #if DEBUG
            print("[RealtimeChainDebug] subscribeReady table=venue_event_vibes channel=\(channel.topic)")
            print("[FanChatRealtimeFixDebug] appLevelSubscribe eventIds=\(idList)")
            print("[FanChatRealtimeDelayDebug] appSubscribeReady elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - subscribeStartedAt) * 1000))")
            RealtimeHealthDiagnostics.log("subscribeReady elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - subscribeStartedAt) * 1000)) channelName=\(channel.topic)")
            #endif
        } catch {
            if fanChatAppLevelRealtimeChannel === channel {
                fanChatAppLevelRealtimeChannel = nil
            }
#if DEBUG
            print("[RealtimeChainDebug] subscribeFailed table=venue_event_vibes error=\(error.localizedDescription)")
            RealtimeHealthDiagnostics.log("subscribeError=\(error.localizedDescription) channelName=\(channel.topic)")
#endif
            return
        }

        let tracked = Set(ids)
        await withTaskGroup(of: Void.self) { group in
            for stream in streams {
                group.addTask { [weak self] in
                    await self?.consumeFanChatAppLevelRealtimeStream(stream, trackedEventIDs: tracked)
                }
            }
            for stream in vibeStreams {
                group.addTask { [weak self] in
                    await self?.consumeCrowdReactionAppLevelRealtimeStream(stream, trackedEventIDs: ids)
                }
            }
        }

        if fanChatAppLevelRealtimeChannel === channel {
            fanChatAppLevelRealtimeChannel = nil
            await supabase.removeChannel(channel)
        }
    }

    private func consumeCrowdReactionAppLevelRealtimeStream(
        _ stream: AsyncStream<AnyAction>,
        trackedEventIDs: [UUID]
    ) async {
        for await action in stream {
            if Task.isCancelled { break }
#if DEBUG
            let eventType: String
            switch action {
            case .insert: eventType = "insert"
            case .update: eventType = "update"
            case .delete: eventType = "delete"
            }
            print("[RealtimeChainDebug] eventReceived table=venue_event_vibes eventType=\(eventType) rowId=unknown")
            print("[RealtimeChainDebug] eventMatchedCurrentView table=venue_event_vibes matched=unknown reason=existingListenerRefreshesTrackedEventsWithoutDecodingPayload trackedCount=\(trackedEventIDs.count)")
            print("[CrowdReactionDebug] realtimeReceived=true")
#endif
            scheduleCrowdReactionVibeRealtimeRefresh(eventIDs: trackedEventIDs)
        }
    }

    @MainActor
    private func scheduleCrowdReactionVibeRealtimeRefresh(eventIDs: [UUID]) {
        let ids = Array(Set(eventIDs))
        fanUpdatesStore.crowdReactionVibeRealtimeRefreshTask?.cancel()
        #if DEBUG
        print("[RealtimeChainDebug] refreshQueued table=venue_event_vibes reason=realtime_event trackedCount=\(ids.count)")
        #endif
        fanUpdatesStore.crowdReactionVibeRealtimeRefreshTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 300_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await withTaskGroup(of: Void.self) { group in
                for id in ids {
                    group.addTask { [weak self] in
                        await self?.loadVibes(for: id)
                    }
                }
            }
        }
    }

    private func consumeFanChatAppLevelRealtimeStream(
        _ stream: AsyncStream<InsertAction>,
        trackedEventIDs: Set<UUID>
    ) async {
        let decoder = JSONDecoder()
        for await insertion in stream {
            if Task.isCancelled { break }
            let row: VenueEventCommentRow
            do {
                row = try insertion.decodeRecord(as: VenueEventCommentRow.self, decoder: decoder)
            } catch {
                continue
            }
            guard let eventID = row.venue_event_id, trackedEventIDs.contains(eventID) else { continue }
            if hasActiveVenueEventCommentsRealtimeListener(for: eventID) {
                markFanChatRealtimeHealth(for: eventID, healthy: true, eventReceived: true)
            }
            if let commentID = row.serverCommentID {
                venueEventCommentRealtimeReceivedServerIDs.insert(commentID)
                venueEventCommentDebugReceivedDatesByServerID[commentID] = Date()
                #if DEBUG
                print("[FanChatRealtimeDelayDebug] realtimeReceivedAfterInsertMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentInsertSuccessTimesByServerID[commentID]))")
                RealtimeHealthDiagnostics.log("eventReceived table=venue_event_comments id=\(commentID.uuidString.lowercased()) elapsedSinceInsertMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentInsertSuccessTimesByServerID[commentID]))")
                #endif
            }
            applyFanChatAppLevelRealtimeInsert(row, for: eventID)
            if let email = row.user_email {
                await loadUserProfilesForEmails([email])
            }
        }
    }

    @MainActor
    private func applyFanChatAppLevelRealtimeInsert(_ row: VenueEventCommentRow, for venueEventID: UUID) {
        guard let commentID = row.serverCommentID else { return }
        #if DEBUG
        print("[FanChatRealtimeFixDebug] insertReceived eventId=\(venueEventID.uuidString.lowercased()) commentId=\(commentID.uuidString.lowercased())")
        #endif

        guard !row.isHiddenFromThread else { return }

        let cacheWasLoaded = venueEventComments.keys.contains(venueEventID)
        let cachedList = venueEventComments[venueEventID] ?? []
        let alreadyInCache = cachedList.contains { $0.serverCommentID == commentID || $0.id == commentID }
        let alreadyInPreview = (venueEventCommentPreviews[venueEventID] ?? []).contains {
            $0.serverCommentID == commentID || $0.id == commentID
        }

        if fanChatAppLevelSeenCommentIDs.contains(commentID), !alreadyInCache, !alreadyInPreview {
            #if DEBUG
            print("[FanChatReceiverDebug] realtimeIgnored reason=diagnosticSeenButNotVisibleFixed commentId=\(commentID.uuidString.lowercased())")
            #endif
        } else if fanChatAppLevelSeenCommentIDs.contains(commentID) {
            #if DEBUG
            print("[FanChatRealtimeFixDebug] duplicateIgnored commentId=\(commentID.uuidString.lowercased())")
            #endif
            return
        }
        fanChatAppLevelSeenCommentIDs.insert(commentID)

        if alreadyInCache || (alreadyInPreview && !cacheWasLoaded) {
            #if DEBUG
            print("[FanChatRealtimeFixDebug] duplicateIgnored commentId=\(commentID.uuidString.lowercased())")
            #endif
            scheduleFanChatCommentCountServerReconcile(for: venueEventID)
            return
        }

        let hasPendingLocalMatch = matchingPendingCommentIndex(
            in: cachedList,
            venueEventID: venueEventID,
            email: row.user_email,
            text: row.comment
        ) != nil
        let shouldPatchPreviewCount = !alreadyInPreview && !alreadyInCache && !hasPendingLocalMatch
#if DEBUG
        let applyStartedAt = CFAbsoluteTimeGetCurrent()
        RealtimeHealthDiagnostics.log("mainActorApplyStart=venue_event_comments id=\(commentID.uuidString.lowercased())")
#endif

        if cacheWasLoaded {
            mergeIncomingVenueEventComment(row, for: venueEventID, source: "app_realtime")
            #if DEBUG
            let count = venueEventComments[venueEventID]?.filter { !$0.isHiddenFromThread && !$0.isFailedSend }.count ?? 0
            print("[FanChatRealtimeFixDebug] cachePatched eventId=\(venueEventID.uuidString.lowercased()) count=\(count)")
            #endif
        } else {
            mergeFanUpdatesPreviewComment(row, for: venueEventID)
        }

        if shouldPatchPreviewCount {
            let nextCount = max(0, venueEventCommentPreviewCounts[venueEventID] ?? 0) + 1
            updateVenueEventCommentPreviewCount(for: venueEventID, to: nextCount)
            #if DEBUG
            print("[FanChatRealtimeFixDebug] previewCountPatched eventId=\(venueEventID.uuidString.lowercased()) count=\(nextCount)")
            #endif
        }

        scheduleFanChatCommentCountServerReconcile(for: venueEventID)
        logFanChatEndToEnd(venueEventID: venueEventID, row: row, fallbackUsed: false)
#if DEBUG
        RealtimeHealthDiagnostics.log("mainActorApplyEnd elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - applyStartedAt) * 1000)) table=venue_event_comments id=\(commentID.uuidString.lowercased())")
#endif
    }

    private func scheduleFanChatCommentCountServerReconcile(for venueEventID: UUID) {
        fanChatCommentCountReconcileTasks[venueEventID]?.cancel()
        #if DEBUG
        print("[FanChatRealtimeFixDebug] serverReconcileScheduled eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        fanChatCommentCountReconcileTasks[venueEventID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: FanChatAppLevelRealtimeConfig.countReconcileDebounceNs)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if let exactCount = await self.loadFanUpdatesExactVisibleCommentCount(for: venueEventID) {
                self.updateVenueEventCommentPreviewCount(for: venueEventID, to: exactCount)
            }
            self.fanChatCommentCountReconcileTasks[venueEventID] = nil
        }
    }

    private func subscribeVenueEventCommentsChannelWithTimeout(
        _ channel: RealtimeChannelV2,
        timeoutNs: UInt64 = 15_000_000_000
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await Task.detached(priority: .userInitiated) {
                    try await channel.subscribeWithError()
                }.value
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNs)
                throw FanChatSheetRealtimeSubscribeTimeoutError()
            }
            defer { group.cancelAll() }
            try await group.next()!
        }
    }

    private func scheduleVenueEventCommentRecoveryBurst(
        venueEventID: UUID,
        expectedCommentID: UUID
    ) {
        venueEventCommentRealtimeFallbackTasks[expectedCommentID]?.cancel()
        venueEventCommentRealtimeFallbackTasks[expectedCommentID] = Task { @MainActor [weak self] in
            defer { self?.venueEventCommentRealtimeFallbackTasks[expectedCommentID] = nil }
            for delayNs in FanChatRealtimeFallbackConfig.recoveryDelayNs {
                do {
                    try await Task.sleep(nanoseconds: delayNs)
                } catch {
                    return
                }
                guard let self, !Task.isCancelled else { return }
                guard self.hasActiveVenueEventCommentsRealtimeListener(for: venueEventID) else { return }
                guard !self.venueEventCommentRealtimeReceivedServerIDs.contains(expectedCommentID) else { return }

                let delayMs = FanChatRealtimeFallbackConfig.delayMs(for: delayNs)
                #if DEBUG
                print("[FanChatDeliveryDebug] realtimeLateUsingFetchRecovery eventId=\(venueEventID.uuidString.lowercased())")
                print("[FanChatDeliveryDebug] recoveryFetch delayMs=\(delayMs)")
                #endif
                _ = await self.fetchRecentVenueEventCommentsForRealtimeFallback(
                    venueEventID: venueEventID,
                    recoveryDelayMs: delayMs,
                    mergeSource: "realtime_fallback"
                )
            }
            if let self, !self.venueEventCommentRealtimeReceivedServerIDs.contains(expectedCommentID) {
                #if DEBUG
                print("[FanChatDeliveryDebug] realtimeStillDelayed eventId=\(venueEventID.uuidString.lowercased())")
                #endif
            }
        }
    }

    func scheduleOpenVenueEventCommentsRecoveryBurst(for venueEventID: UUID) {
        scheduleFanChatReceiverRefreshBurst(for: venueEventID, reason: "sheet_visible")
    }

    func cancelFanChatReceiverRefreshBurst(for venueEventID: UUID) {
        fanChatReceiverRefreshBurstTasks[venueEventID]?.cancel()
        fanChatReceiverRefreshBurstTasks[venueEventID] = nil
    }

    @discardableResult
    func manualRefreshFanUpdatesComments(for venueEventID: UUID) async -> Bool {
        let stats = await refreshFanUpdatesComments(
            for: venueEventID,
            mergeSource: "manual_refresh",
            debugTag: "FanChatManualRefreshDebug"
        )
        return stats != nil
    }

    @discardableResult
    func pullRefreshFanUpdatesComments(for venueEventID: UUID) async -> Bool {
        let stats = await refreshFanUpdatesComments(
            for: venueEventID,
            mergeSource: "pull_refresh",
            debugTag: "FanChatPullRefreshDebug"
        )
        return stats != nil
    }

    private func refreshFanUpdatesComments(
        for venueEventID: UUID,
        mergeSource: String,
        debugTag: String
    ) async -> FanChatReceiverRefreshStats? {
        if Task.isCancelled {
            logFanUpdatesRefreshCancelledSilentlyIfNeeded(debugTag: debugTag, venueEventID: venueEventID)
            return nil
        }

        guard !fanChatAutoRefreshInFlightIDs.contains(venueEventID) else {
            #if DEBUG
            print("[\(debugTag)] skipped reason=refreshInFlight")
            #endif
            return nil
        }

        fanChatAutoRefreshInFlightIDs.insert(venueEventID)
        defer { fanChatAutoRefreshInFlightIDs.remove(venueEventID) }

        #if DEBUG
        print("[\(debugTag)] started eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        let stats = await fetchRecentVenueEventCommentsForRealtimeFallback(
            venueEventID: venueEventID,
            mergeSource: mergeSource
        )
        if Task.isCancelled {
            logFanUpdatesRefreshCancelledSilentlyIfNeeded(debugTag: debugTag, venueEventID: venueEventID)
            return nil
        }
        await loadCurrentUserCommentReportFlags(for: venueEventID)
        if Task.isCancelled {
            logFanUpdatesRefreshCancelledSilentlyIfNeeded(debugTag: debugTag, venueEventID: venueEventID)
            return nil
        }
        await loadCommentReactions(for: venueEventID)
        if Task.isCancelled {
            logFanUpdatesRefreshCancelledSilentlyIfNeeded(debugTag: debugTag, venueEventID: venueEventID)
            return nil
        }
        #if DEBUG
        print("[\(debugTag)] merged count=\(stats?.newRowsMerged ?? 0) fetched=\(stats?.fetchedCount ?? 0) visible=\(stats?.visibleCountAfterMerge ?? 0)")
        print("[\(debugTag)] finished eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        return stats
    }

    private func logFanUpdatesRefreshCancelledSilentlyIfNeeded(debugTag: String, venueEventID: UUID) {
        #if DEBUG
        print("[CancellationHandlingDebug] ignoredCancellation context=\(debugTag)")
        if debugTag == "FanChatPullRefreshDebug" {
            print("[FanChatPullRefreshDebug] cancelledSilently eventId=\(venueEventID.uuidString.lowercased())")
        }
        #endif
    }

    @discardableResult
    func autoRefreshFanUpdatesComments(for venueEventID: UUID) async -> Bool {
        guard !fanChatAutoRefreshInFlightIDs.contains(venueEventID) else {
            #if DEBUG
            print("[FanChatAutoRefreshDebug] skipped reason=refreshInFlight")
            #endif
            return false
        }

        fanChatAutoRefreshInFlightIDs.insert(venueEventID)
        defer { fanChatAutoRefreshInFlightIDs.remove(venueEventID) }

        let stats = await fetchRecentVenueEventCommentsForRealtimeFallback(
            venueEventID: venueEventID,
            mergeSource: "auto_refresh",
            fetchOnlyNewerThanLatestKnown: true,
            reconcileExactCount: false
        )
        if (stats?.newRowsMerged ?? 0) > 0 {
            await loadCommentReactions(for: venueEventID)
        } else {
            await refreshCommentReactionsIfStale(
                for: venueEventID,
                minimumInterval: FanChatRealtimeFirstPollingConfig.reactionRefreshMinimumInterval,
                reason: "auto_refresh"
            )
        }
        #if DEBUG
        print("[FanChatAutoRefreshDebug] merged newRows=\(stats?.newRowsMerged ?? 0)")
        #endif
        return (stats?.newRowsMerged ?? 0) > 0
    }

    private func scheduleFanChatReceiverRefreshBurst(for venueEventID: UUID, reason: String) {
        fanChatReceiverRefreshBurstTasks[venueEventID]?.cancel()
        #if DEBUG
        if reason == "sheet_visible" {
            print("[FanChatReceiverDebug] sheetVisible eventId=\(venueEventID.uuidString.lowercased())")
        }
        print("[FanChatReceiverDebug] refreshBurstStarted eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        fanChatReceiverRefreshBurstTasks[venueEventID] = Task { @MainActor [weak self] in
            var totalNewRowsMerged = 0
            defer { self?.fanChatReceiverRefreshBurstTasks[venueEventID] = nil }
            do {
                try await Task.sleep(nanoseconds: FanChatRealtimeFirstPollingConfig.gracePeriodNs)
            } catch {
                return
            }
            for tick in 0...2 {
                guard let self, !Task.isCancelled else { return }
                guard self.hasActiveVenueEventCommentsRealtimeListener(for: venueEventID) else { return }
                if self.fanChatRealtimeIsHealthy(for: venueEventID) {
                    #if DEBUG
                    print("[FanChatPerfDebug] pollingSkipped reason=realtimeHealthy")
                    print("[FanChatPerfDebug] pollingMode=realtime")
                    #endif
                    return
                }

                #if DEBUG
                print("[FanChatReceiverDebug] refreshTick eventId=\(venueEventID.uuidString.lowercased()) tick=\(tick)")
                print("[FanChatPerfDebug] pollingMode=fallback")
                print("[FanChatPerfDebug] fallbackPollInterval=\(FanChatRealtimeFirstPollingConfig.fallbackPollIntervalSeconds)")
                #endif
                let stats = await self.fetchRecentVenueEventCommentsForRealtimeFallback(
                    venueEventID: venueEventID,
                    recoveryDelayMs: tick * Int(Double(FanChatRealtimeFirstPollingConfig.fallbackPollIntervalNs) / 1_000_000),
                    mergeSource: "receiver_refresh",
                    fetchOnlyNewerThanLatestKnown: true,
                    reconcileExactCount: false
                )
                totalNewRowsMerged += stats?.newRowsMerged ?? 0
                if tick == 2, totalNewRowsMerged == 0, stats?.fetchedCount == 0 {
                    #if DEBUG
                    print("[FanChatReceiverDebug] fetchMissingPostedComment possibleRLSOrFilterIssue=true")
                    #endif
                }
                do {
                    try await Task.sleep(nanoseconds: FanChatRealtimeFirstPollingConfig.fallbackPollIntervalNs)
                } catch {
                    return
                }
            }
        }
    }

    private func latestKnownServerCommentCursor(for venueEventID: UUID) -> FanChatCommentCursor? {
        (venueEventComments[venueEventID] ?? [])
            .compactMap { row -> FanChatCommentCursor? in
                guard let id = row.serverCommentID,
                      let createdAt = parseVenueEventCommentDate(row.created_at) else {
                    return nil
                }
                return FanChatCommentCursor(createdAt: createdAt, id: id)
            }
            .max { lhs, rhs in
                if lhs.createdAt != rhs.createdAt {
                    return lhs.createdAt < rhs.createdAt
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private func fetchRecentVenueEventCommentsForRealtimeFallback(
        venueEventID: UUID,
        recoveryDelayMs: Int? = nil,
        mergeSource: String = "realtime_fallback",
        fetchOnlyNewerThanLatestKnown: Bool = false,
        reconcileExactCount: Bool = true
    ) async -> FanChatReceiverRefreshStats? {
        do {
            #if DEBUG
            print("[FanChatReadyDebug] fallbackFetchStarted eventId=\(venueEventID.uuidString.lowercased())")
            #endif
            let existingCommentIDs = Set((venueEventComments[venueEventID] ?? []).compactMap(\.serverCommentID))
            let cursor = fetchOnlyNewerThanLatestKnown ? latestKnownServerCommentCursor(for: venueEventID) : nil
            let rowsRaw: [VenueEventCommentRow]
            let rows: [VenueEventCommentRow]
            if let cursor {
                rowsRaw = try await supabase
                    .from("venue_event_comments")
                    .select(VenueEventCommentsPagination.selectColumns)
                    .eq("venue_event_id", value: venueEventID)
                    .or("is_moderation_hidden.is.null,is_moderation_hidden.eq.false")
                    .or(VenueEventCommentsQuery.keysetNewerThanOrFilter(createdAt: cursor.createdAt, commentId: cursor.id))
                    .order("created_at", ascending: true)
                    .order("id", ascending: true)
                    .limit(FanChatRealtimeFallbackConfig.fetchLimit)
                    .execute()
                    .value
                rows = rowsRaw.filter { !$0.isHiddenFromThread }
            } else {
                rowsRaw = try await supabase
                    .from("venue_event_comments")
                    .select(VenueEventCommentsPagination.selectColumns)
                    .eq("venue_event_id", value: venueEventID)
                    .or("is_moderation_hidden.is.null,is_moderation_hidden.eq.false")
                    .order("created_at", ascending: false)
                    .order("id", ascending: false)
                    .limit(FanChatRealtimeFallbackConfig.fetchLimit)
                    .execute()
                    .value
                rows = Array(rowsRaw.filter { !$0.isHiddenFromThread }.reversed())
            }
            var mergedNewCount = 0
            for row in rows {
                if let commentID = row.serverCommentID {
                    if !existingCommentIDs.contains(commentID) {
                        mergedNewCount += 1
                    }
                    venueEventCommentDebugFallbackCommentIDs.insert(commentID)
                    venueEventCommentDebugReceivedDatesByServerID[commentID] = Date()
                }
                mergeIncomingVenueEventComment(row, for: venueEventID, source: mergeSource)
                logFanChatEndToEnd(venueEventID: venueEventID, row: row, fallbackUsed: true)
            }
            let visibleCountAfterMerge = venueEventComments[venueEventID]?.filter {
                !$0.isHiddenFromThread && !$0.isFailedSend
            }.count ?? 0
            let latestServerIds = rowsRaw.compactMap { $0.serverCommentID?.uuidString.lowercased() }
            #if DEBUG
            print("[FanChatReadyDebug] fallbackMerged count=\(rows.count)")
            if recoveryDelayMs != nil {
                print("[FanChatDeliveryDebug] recoveryMerged newCount=\(mergedNewCount)")
            }
            print("[FanChatReceiverDebug] fetchedCount=\(rows.count)")
            print("[FanChatReceiverDebug] newRowsMerged=\(mergedNewCount)")
            print("[FanChatReceiverDebug] latestServerIds=\(latestServerIds.prefix(6).joined(separator: ","))")
            print("[FanChatReceiverDebug] visibleCountAfterMerge=\(visibleCountAfterMerge)")
            print("[FanChatPerfDebug] recentCommentDeltaFetch count=\(rows.count)")
            #endif
            if reconcileExactCount, let exactCount = await loadFanUpdatesExactVisibleCommentCount(for: venueEventID) {
                updateVenueEventCommentPreviewCount(for: venueEventID, to: exactCount)
            }
            return FanChatReceiverRefreshStats(
                fetchedCount: rows.count,
                newRowsMerged: mergedNewCount,
                latestServerIds: latestServerIds,
                visibleCountAfterMerge: visibleCountAfterMerge
            )
        } catch {
            if error is CancellationError, mergeSource == "pull_refresh" {
                #if DEBUG
                print("[FanChatPullRefreshDebug] cancelledSilently eventId=\(venueEventID.uuidString.lowercased())")
                #endif
            }
            logVenueEventSocialLoadError("ERROR LOADING COMMENTS REALTIME FALLBACK:", loadCancelledTag: "comments_realtime_fallback", error: error)
            return nil
        }
    }

    func startVenueEventCommentsRealtime(for venueEventID: UUID) async {
        for otherEventID in venueEventCommentsRealtimeActiveIDs(excluding: venueEventID) {
            await stopVenueEventCommentsRealtime(for: otherEventID)
        }

        let channelName = "venue-event-comments-\(venueEventID.uuidString.lowercased())"
        let hasTask = venueEventCommentsRealtimeTasks[venueEventID] != nil
        let hasChannel = venueEventCommentsRealtimeChannels[venueEventID] != nil
        let hasToken = venueEventCommentsRealtimeListenerTokens[venueEventID] != nil
        if hasTask || hasChannel || hasToken {
            if hasTask {
                #if DEBUG
                print("[FanChatReadyDebug] readyState eventId=\(venueEventID.uuidString.lowercased()) ready=\(venueEventCommentsRealtimeReadyIDs.contains(venueEventID))")
                #endif
                return
            }
            let staleChannel = venueEventCommentsRealtimeChannels[venueEventID]
            #if DEBUG
            RealtimeHealthDiagnostics.log("reconnectDetected=fan_chat_sheet_stale_partial_channel channelName=\(channelName)")
            #endif
            venueEventCommentsRealtimeListenerTokens[venueEventID] = nil
            venueEventCommentsRealtimeTasks[venueEventID] = nil
            venueEventCommentsRealtimeChannels[venueEventID] = nil
            markFanChatRealtimeHealth(for: venueEventID, healthy: false)
            venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = nil
            if let staleChannel {
                await supabase.removeChannel(staleChannel)
            }
        }

        let listenerToken = UUID()
        venueEventCommentsRealtimeListenerTokens[venueEventID] = listenerToken
        markFanChatRealtimeHealth(for: venueEventID, healthy: false)
        venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        print("[GameChatPerf] starting listener event=\(venueEventID)")
        print("[VenueCommentRealtimeDebug] subscribe eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatRealtimeDelayDebug] sheetSubscribeStart eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatRealtimeDelayDebug] filterMode=sheet_eq")
        print("[FanChatReadyDebug] subscribeStart channelName=\(channelName)")
        print("[FanChatReadyDebug] readyState eventId=\(venueEventID.uuidString.lowercased()) ready=false")
        print("[FanChatPerfDebug] realtimeSubscribeStart")
        RealtimeHealthDiagnostics.log("channelName=\(channelName)")
        RealtimeHealthDiagnostics.log("subscribeStart=true channelName=\(channelName)")
        #endif

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let channel = supabase.channel(channelName)
            venueEventCommentsRealtimeChannels[venueEventID] = channel
            var shouldRestartAfterFailure = false
            let inserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "venue_event_comments",
                filter: .eq("venue_event_id", value: venueEventID.uuidString.lowercased())
            )

            do {
                try await subscribeVenueEventCommentsChannelWithTimeout(channel)
                markFanChatRealtimeHealth(for: venueEventID, healthy: true)
                #if DEBUG
                print("[GameChatPerf] realtime subscribed event=\(venueEventID)")
                print("[FanChatLatencyDebug] realtimeSubscribed eventId=\(venueEventID.uuidString.lowercased()) channel=\(channel.topic)")
                print("[FanChatRealtimeDelayDebug] sheetSubscribeReady eventId=\(venueEventID.uuidString.lowercased()) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentsRealtimeSubscribeStartedAt[venueEventID]))")
                print("[FanChatReadyDebug] subscribeReady channelName=\(channelName) elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentsRealtimeSubscribeStartedAt[venueEventID]))")
                print("[FanChatReadyDebug] readyState eventId=\(venueEventID.uuidString.lowercased()) ready=true")
                RealtimeHealthDiagnostics.log("subscribeReady elapsedMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentsRealtimeSubscribeStartedAt[venueEventID])) channelName=\(channel.topic)")
                print("[RealtimeRecoveryDebug] reconnectSucceeded channelName=\(channelName)")
                #endif
                scheduleFanChatReceiverRefreshBurst(for: venueEventID, reason: "realtime_reconnect")

                for await insertion in inserts {
                    if Task.isCancelled { break }
                    let row: VenueEventCommentRow
                    do {
                        row = try insertion.decodeRecord(as: VenueEventCommentRow.self, decoder: JSONDecoder())
                    } catch {
                        continue
                    }
                    #if DEBUG
                    print("[GameChatPerf] realtime received event=\(venueEventID) row=\(row.id?.uuidString ?? "nil")")
                    print("[VenueCommentRealtimeDebug] realtimeInsertReceived id=\(row.id?.uuidString.lowercased() ?? "nil") eventId=\(venueEventID.uuidString.lowercased())")
                    print("[FanChatLatencyDebug] realtimeInsertReceived eventId=\(venueEventID.uuidString.lowercased()) commentId=\(row.id?.uuidString.lowercased() ?? "nil") elapsedSinceSendMs=\(FanChatLatencyDebugClock.elapsedMs(since: row.serverCommentID.flatMap { self.venueEventCommentLatencySendTimesByServerID[$0] }))")
                    print("[FanChatReceiverDebug] realtimeInsertReceived eventId=\(venueEventID.uuidString.lowercased()) commentId=\(row.id?.uuidString.lowercased() ?? "nil") userId=\(row.user_email ?? "nil")")
                    #endif
                    if row.isHiddenFromThread {
                        #if DEBUG
                        print("[FanChatReceiverDebug] realtimeIgnored reason=hidden commentId=\(row.id?.uuidString.lowercased() ?? "nil")")
                        #endif
                        continue
                    }
                    if let commentID = row.serverCommentID {
                        markFanChatRealtimeHealth(for: venueEventID, healthy: true, eventReceived: true)
                        venueEventCommentRealtimeReceivedServerIDs.insert(commentID)
                        venueEventCommentDebugReceivedDatesByServerID[commentID] = Date()
                        #if DEBUG
                        print("[FanChatRealtimeDelayDebug] realtimeReceivedAfterInsertMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentInsertSuccessTimesByServerID[commentID]))")
                        RealtimeHealthDiagnostics.log("eventReceived table=venue_event_comments id=\(commentID.uuidString.lowercased()) elapsedSinceInsertMs=\(FanChatLatencyDebugClock.elapsedMs(since: venueEventCommentInsertSuccessTimesByServerID[commentID]))")
                        #endif
                    }
#if DEBUG
                    let applyStartedAt = CFAbsoluteTimeGetCurrent()
                    RealtimeHealthDiagnostics.log("mainActorApplyStart=venue_event_comments id=\(row.serverCommentID?.uuidString.lowercased() ?? "nil")")
#endif
                    mergeIncomingVenueEventComment(row, for: venueEventID, source: "realtime")
                    logFanChatEndToEnd(venueEventID: venueEventID, row: row, fallbackUsed: false)
#if DEBUG
                    RealtimeHealthDiagnostics.log("mainActorApplyEnd elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - applyStartedAt) * 1000)) table=venue_event_comments id=\(row.serverCommentID?.uuidString.lowercased() ?? "nil")")
#endif
                    if let email = row.user_email {
                        await loadUserProfilesForEmails([email])
                    }
                }
            } catch is CancellationError {
            } catch {
                #if DEBUG
                print("[GameChatPerf] realtime error event=\(venueEventID) error=\(error)")
                RealtimeHealthDiagnostics.log("subscribeError=\(error.localizedDescription) channelName=\(channel.topic)")
                if error is FanChatSheetRealtimeSubscribeTimeoutError {
                    print("[RealtimeRecoveryDebug] timeout channelName=\(channelName)")
                }
                print("[RealtimeRecoveryDebug] reconnectFailed channelName=\(channelName) error=\(error.localizedDescription)")
                #endif
                markFanChatRealtimeHealth(for: venueEventID, healthy: false)
                if venueEventCommentsRealtimeListenerTokens[venueEventID] == listenerToken {
                    venueEventCommentsRealtimeListenerTokens[venueEventID] = nil
                    venueEventCommentsRealtimeTasks[venueEventID] = nil
                    if venueEventCommentsRealtimeChannels[venueEventID] === channel {
                        venueEventCommentsRealtimeChannels[venueEventID] = nil
                    }
                    venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = nil
                    await supabase.removeChannel(channel)
                    shouldRestartAfterFailure = true
                    #if DEBUG
                    print("[RealtimeRecoveryDebug] staleChannelRemoved channelName=\(channelName)")
                    print("[FanChatReadyDebug] readyState eventId=\(venueEventID.uuidString.lowercased()) ready=false")
                    #endif
                }
            }

            if venueEventCommentsRealtimeListenerTokens[venueEventID] == listenerToken {
                await supabase.removeChannel(channel)
                if venueEventCommentsRealtimeChannels[venueEventID] === channel {
                    venueEventCommentsRealtimeChannels[venueEventID] = nil
                }
                venueEventCommentsRealtimeTasks[venueEventID] = nil
                venueEventCommentsRealtimeListenerTokens[venueEventID] = nil
                markFanChatRealtimeHealth(for: venueEventID, healthy: false)
                venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = nil
                #if DEBUG
                print("[FanChatReadyDebug] readyState eventId=\(venueEventID.uuidString.lowercased()) ready=false")
                #endif
            }
            if shouldRestartAfterFailure {
                Task { @MainActor [weak self] in
                    guard let self, !Task.isCancelled else { return }
                    #if DEBUG
                    print("[RealtimeRecoveryDebug] reconnectAttempt channelName=\(channelName) attempt=1")
                    #endif
                    await self.startVenueEventCommentsRealtime(for: venueEventID)
                }
            }
        }
        venueEventCommentsRealtimeTasks[venueEventID] = task
    }

    func stopVenueEventCommentsRealtime(for venueEventID: UUID) async {
        guard hasActiveVenueEventCommentsRealtimeListener(for: venueEventID) else { return }
        #if DEBUG
        print("[GameChatPerf] stopping listener event=\(venueEventID)")
        #endif

        let task = venueEventCommentsRealtimeTasks[venueEventID]
        let channel = venueEventCommentsRealtimeChannels[venueEventID]
        venueEventCommentsRealtimeListenerTokens[venueEventID] = nil
        venueEventCommentsRealtimeTasks[venueEventID] = nil
        venueEventCommentsRealtimeChannels[venueEventID] = nil
        markFanChatRealtimeHealth(for: venueEventID, healthy: false)
        venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = nil
        cancelFanChatReceiverRefreshBurst(for: venueEventID)
        #if DEBUG
        print("[FanChatReadyDebug] readyState eventId=\(venueEventID.uuidString.lowercased()) ready=false")
        #endif
        task?.cancel()
        if let channel {
            await supabase.removeChannel(channel)
        }
    }

    func removeAllVenueEventCommentsRealtimeListeners() async {
        let activeIDs = venueEventCommentsRealtimeActiveIDs()
        guard !activeIDs.isEmpty else { return }
        #if DEBUG
        print("[GameChatPerf] removing all listeners count=\(activeIDs.count)")
        #endif
        for venueEventID in activeIDs {
            await stopVenueEventCommentsRealtime(for: venueEventID)
        }
    }

    /// Whether the signed-in fan has a `comment_reports` row for this comment (local cache, hydrated from Supabase on comment load).
    func hasCurrentUserReportedComment(commentID: UUID?) -> Bool {
        guard let commentID else { return false }
        return commentIDsReportedByCurrentUser.contains(commentID)
    }

    /// Marks a comment as reported in memory so the flag UI updates immediately (also used when the insert hits the unique constraint).
    func markCommentReportedLocally(commentID: UUID) {
        commentIDsReportedByCurrentUser.insert(commentID)
    }

    func markCommentUnreportedLocally(commentID: UUID) {
        commentIDsReportedByCurrentUser.remove(commentID)
    }

    private func fetchModerationReportCountForComment(commentId: UUID) async -> Int? {
        struct Row: Decodable { let moderation_report_count: Int? }
        do {
            let rows: [Row] = try await supabase
                .from("venue_event_comments")
                .select("moderation_report_count")
                .eq("id", value: commentId.uuidString)
                .limit(1)
                .execute()
                .value
            return rows.first?.moderation_report_count
        } catch {
            return nil
        }
    }

    /// Loads `comment_reports` rows for the current auth email and visible comment ids so flags render as already reported after relaunch.
    func loadCurrentUserCommentReportFlags(for venueEventID: UUID) async {
        let ids = await MainActor.run {
            venueEventComments[venueEventID]?.compactMap(\.serverCommentID) ?? []
        }
        guard !ids.isEmpty else { return }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return
        }

        let reporterEmail = session.user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !reporterEmail.isEmpty else { return }

        var merged: Set<UUID> = []
        var start = 0
        while start < ids.count {
            let end = min(start + CurrentUserCommentReportFlags.inQueryChunk, ids.count)
            let chunk = Array(ids[start..<end])
            start = end

            do {
                let rows: [CommentReportRow] = try await supabase
                    .from("comment_reports")
                    .select("comment_id")
                    .eq("venue_event_id", value: venueEventID)
                    .eq("reporter_email", value: reporterEmail)
                    .in("comment_id", values: chunk)
                    .execute()
                    .value

                for row in rows {
                    if let cid = row.comment_id {
                        merged.insert(cid)
                    }
                }
            } catch {
                logVenueEventSocialLoadError(
                    "ERROR LOADING COMMENT REPORT FLAGS:",
                    loadCancelledTag: "comment_report_flags",
                    error: error
                )
            }
        }

        await MainActor.run {
            for cid in merged where commentIDsReportedByCurrentUser.insert(cid).inserted {}
        }
    }

    /// Batch-loads thumbs-up/down counts and current-user reaction state for visible fan update comments.
    private func visibleReactionCommentIDs(for venueEventID: UUID) -> [UUID] {
        Array(Set(venueEventComments[venueEventID]?.compactMap(\.serverCommentID) ?? []))
            .sorted { $0.uuidString < $1.uuidString }
    }

    private func venueEventIDForVisibleReactionComment(_ commentID: UUID) -> UUID? {
        venueEventComments.first { entry in
            entry.value.contains { $0.serverCommentID == commentID }
        }?.key
    }

    func syncVenueEventCommentReactionsRealtime(for venueEventID: UUID) async {
        let visibleCommentIDs = visibleReactionCommentIDs(for: venueEventID)
        #if DEBUG
        print("[FanChatReactionDebug] visibleCommentIds=\(visibleCommentIDs.map { $0.uuidString.lowercased() }.joined(separator: ","))")
        #endif
        guard !visibleCommentIDs.isEmpty else {
            await stopVenueEventCommentReactionsRealtime(for: venueEventID)
            return
        }
        venueEventCommentReactionRealtimeTrackedCommentIDs[venueEventID] = visibleCommentIDs
        startVenueEventCommentReactionFallbackReadinessWatchIfNeeded(for: venueEventID)
        if venueEventCommentReactionRealtimeTasks[venueEventID] != nil,
           venueEventCommentReactionRealtimeChannels[venueEventID] != nil {
            return
        }
        await startVenueEventCommentReactionsRealtime(for: venueEventID)
    }

    private func startVenueEventCommentReactionFallbackReadinessWatchIfNeeded(for venueEventID: UUID) {
        guard venueEventCommentReactionFallbackPollTasks[venueEventID] == nil else { return }
        venueEventCommentReactionFallbackPollTasks[venueEventID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.venueEventCommentReactionFallbackPollTasks[venueEventID] = nil }
            do {
                try await Task.sleep(nanoseconds: FanChatReactionRealtimeConfig.readyGraceNs)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            if !self.venueEventCommentReactionRealtimeReadyIDs.contains(venueEventID),
               !self.visibleReactionCommentIDs(for: venueEventID).isEmpty {
                #if DEBUG
                print("[FanChatReactionDebug] reactionRealtimeReady=false")
                print("[FanChatReactionDebug] fallbackReactionPollEnabled reason=realtimeNotReady")
                #endif
            }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: FanChatReactionRealtimeConfig.fallbackPollIntervalNs)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard !self.venueEventCommentReactionRealtimeReadyIDs.contains(venueEventID) else { continue }
                guard !self.visibleReactionCommentIDs(for: venueEventID).isEmpty else { continue }
                #if DEBUG
                print("[FanChatReactionDebug] fallbackReactionPoll=true")
                #endif
                await self.loadCommentReactions(for: venueEventID)
            }
        }
    }

    private func startVenueEventCommentReactionsRealtime(for venueEventID: UUID) async {
        await stopVenueEventCommentReactionsRealtime(for: venueEventID)
        let channelName = "venue-event-comment-reactions-\(venueEventID.uuidString.lowercased())"
        #if DEBUG
        print("[FanChatReactionDebug] reactionRealtimeSubscribeStart eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatReactionDebug] reactionRealtimeChannel=\(channelName)")
        print("[FanChatReactionDebug] realtimeSubscribeStart=true")
        #endif

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let channel = supabase.channel(channelName)
            self.venueEventCommentReactionRealtimeChannels[venueEventID] = channel

            let inserts = channel.postgresChange(
                InsertAction.self,
                schema: "public",
                table: "venue_event_comment_reactions"
            )
            let updates = channel.postgresChange(
                UpdateAction.self,
                schema: "public",
                table: "venue_event_comment_reactions"
            )
            let deletes = channel.postgresChange(
                DeleteAction.self,
                schema: "public",
                table: "venue_event_comment_reactions"
            )

            do {
                try await channel.subscribeWithError()
                self.venueEventCommentReactionRealtimeReadyIDs.insert(venueEventID)
                #if DEBUG
                print("[FanChatReactionDebug] realtimeReady=true")
                print("[FanChatReactionDebug] reactionRealtimeReady=true")
                #endif

                await withTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self] in
                        await self?.consumeFanChatReactionInsertStream(inserts)
                    }
                    group.addTask { [weak self] in
                        await self?.consumeFanChatReactionUpdateStream(updates)
                    }
                    group.addTask { [weak self] in
                        await self?.consumeFanChatReactionDeleteStream(deletes)
                    }
                }
            } catch is CancellationError {
            } catch {
                self.venueEventCommentReactionRealtimeReadyIDs.remove(venueEventID)
                #if DEBUG
                print("[FanChatReactionDebug] realtimeReady=false error=\(error.localizedDescription)")
                print("[FanChatReactionDebug] reactionRealtimeReady=false")
                #endif
            }

            self.venueEventCommentReactionRealtimeTasks[venueEventID] = nil
            if self.venueEventCommentReactionRealtimeChannels[venueEventID] === channel {
                self.venueEventCommentReactionRealtimeChannels[venueEventID] = nil
            }
            self.venueEventCommentReactionRealtimeReadyIDs.remove(venueEventID)
            self.venueEventCommentReactionRealtimeTrackedCommentIDs[venueEventID] = nil
            await supabase.removeChannel(channel)
        }
        venueEventCommentReactionRealtimeTasks[venueEventID] = task
    }

    func stopVenueEventCommentReactionsRealtime(for venueEventID: UUID) async {
        let task = venueEventCommentReactionRealtimeTasks[venueEventID]
        let channel = venueEventCommentReactionRealtimeChannels[venueEventID]
        venueEventCommentReactionRealtimeTasks[venueEventID] = nil
        venueEventCommentReactionRealtimeChannels[venueEventID] = nil
        venueEventCommentReactionRealtimeReadyIDs.remove(venueEventID)
        venueEventCommentReactionRealtimeTrackedCommentIDs[venueEventID] = nil
        task?.cancel()
        if let channel {
            await supabase.removeChannel(channel)
        }
    }

    func stopVenueEventCommentReactionRefresh(for venueEventID: UUID) async {
        await stopVenueEventCommentReactionsRealtime(for: venueEventID)
        venueEventCommentReactionFallbackPollTasks[venueEventID]?.cancel()
        venueEventCommentReactionFallbackPollTasks[venueEventID] = nil
        let visibleIDs = Set(visibleReactionCommentIDs(for: venueEventID))
        for commentID in visibleIDs {
            venueEventCommentReactionDebounceTasks[commentID]?.cancel()
            venueEventCommentReactionDebounceTasks[commentID] = nil
        }
    }

    private func consumeFanChatReactionInsertStream(
        _ stream: AsyncStream<InsertAction>
    ) async {
        let decoder = JSONDecoder()
        for await action in stream {
            guard !Task.isCancelled else { break }
            guard let row = try? action.decodeRecord(as: VenueEventCommentReactionRow.self, decoder: decoder),
                  let commentID = row.comment_id else { continue }
            handleFanChatReactionRealtimeEvent(type: "insert", commentID: commentID)
        }
    }

    private func consumeFanChatReactionUpdateStream(
        _ stream: AsyncStream<UpdateAction>
    ) async {
        let decoder = JSONDecoder()
        for await action in stream {
            guard !Task.isCancelled else { break }
            guard let row = try? action.decodeRecord(as: VenueEventCommentReactionRow.self, decoder: decoder),
                  let commentID = row.comment_id else { continue }
            handleFanChatReactionRealtimeEvent(type: "update", commentID: commentID)
        }
    }

    private func consumeFanChatReactionDeleteStream(
        _ stream: AsyncStream<DeleteAction>
    ) async {
        let decoder = JSONDecoder()
        for await action in stream {
            guard !Task.isCancelled else { break }
            guard let row = try? action.decodeOldRecord(as: VenueEventCommentReactionRow.self, decoder: decoder),
                  let commentID = row.comment_id else { continue }
            handleFanChatReactionRealtimeEvent(type: "delete", commentID: commentID)
        }
    }

    private func handleFanChatReactionRealtimeEvent(type: String, commentID: UUID) {
        let venueEventID = venueEventIDForVisibleReactionComment(commentID)
        #if DEBUG
        print("[FanChatReactionDebug] reactionRealtimeEvent type=\(type) commentId=\(commentID.uuidString.lowercased())")
        #endif
        guard let venueEventID else { return }
        venueEventCommentReactionDebounceTasks[commentID]?.cancel()
        venueEventCommentReactionDebounceTasks[commentID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: FanChatReactionRealtimeConfig.debounceNs)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.venueEventCommentReactionDebounceTasks[commentID] = nil
            await self.loadSingleCommentReactionSummary(commentID: commentID, venueEventID: venueEventID)
        }
    }

    private func loadSingleCommentReactionSummary(commentID: UUID, venueEventID: UUID) async {
        #if DEBUG
        print("[FanChatReactionDebug] targetedReactionSummaryRefresh commentId=\(commentID.uuidString.lowercased())")
        #endif
        let viewerUserID = try? await supabase.auth.session.user.id
        do {
            let rows: [VenueEventCommentReactionRow] = try await supabase
                .from("venue_event_comment_reactions")
                .select("comment_id,user_id,reaction_type")
                .eq("comment_id", value: commentID.uuidString)
                .execute()
                .value

            var upCount = 0
            var downCount = 0
            var viewerReaction: FanChatCommentReactionType?
            for row in rows {
                guard let reaction = fanChatCommentReactionType(from: row.reaction_type) else { continue }
                switch reaction {
                case .up: upCount += 1
                case .down: downCount += 1
                }
                if row.user_id == viewerUserID {
                    viewerReaction = reaction
                }
            }
            await MainActor.run {
                applySingleVenueEventCommentReactionMetadata(
                    venueEventID: venueEventID,
                    commentID: commentID,
                    upCount: upCount,
                    downCount: downCount,
                    viewerReaction: viewerReaction
                )
            }
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING FAN COMMENT REACTION SUMMARY:", loadCancelledTag: "fan_comment_reaction_summary", error: error)
        }
    }

    private func refreshCommentReactionsIfStale(
        for venueEventID: UUID,
        minimumInterval: TimeInterval,
        reason: String
    ) async {
        let now = Date()
        if let last = venueEventCommentReactionLastRefreshAt[venueEventID],
           now.timeIntervalSince(last) < minimumInterval {
            #if DEBUG
            print("[FanChatPerfDebug] reactionRefreshSkipped reason=tooFrequent")
            #endif
            return
        }
        #if DEBUG
        print("[FanChatReactionDebug] reactionSummaryRefresh reason=\(reason)")
        #endif
        await loadCommentReactions(for: venueEventID)
    }

    func loadCommentReactions(for venueEventID: UUID) async {
        venueEventCommentReactionLastRefreshAt[venueEventID] = Date()
        let ids = await MainActor.run {
            venueEventComments[venueEventID]?.compactMap(\.serverCommentID) ?? []
        }
        let uniqueIDs = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }

        print("[FanChatReactionDebug] reactionSummaryLoadStart eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatReactionDebug] commentCount=\(uniqueIDs.count)")

        guard !uniqueIDs.isEmpty else {
            await MainActor.run {
                applyVenueEventCommentReactionMetadata(
                    venueEventID: venueEventID,
                    upCounts: [:],
                    downCounts: [:],
                    viewerReactions: [:]
                )
            }
            print("[FanChatReactionDebug] reactionSummaryLoaded count=0")
            return
        }

        let userID: UUID
        do {
            userID = try await supabase.auth.session.user.id
        } catch {
            print("[FanChatReactionDebug] refreshError eventId=\(venueEventID.uuidString.lowercased()) error=\(error.localizedDescription)")
            await MainActor.run {
                applyVenueEventCommentReactionMetadata(
                    venueEventID: venueEventID,
                    upCounts: [:],
                    downCounts: [:],
                    viewerReactions: [:]
                )
            }
            print("[FanChatReactionDebug] reactionSummaryLoaded count=0")
            return
        }

        var upCounts: [UUID: Int] = [:]
        var downCounts: [UUID: Int] = [:]
        var viewerReactions: [UUID: FanChatCommentReactionType] = [:]

        do {
            for chunk in FanCommentLikesBatchLoad.chunked(uniqueIDs, size: FanCommentLikesBatchLoad.inQueryChunk) {
                let rows: [VenueEventCommentReactionRow] = try await supabase
                    .from("venue_event_comment_reactions")
                    .select("comment_id,user_id,reaction_type")
                    .in("comment_id", values: chunk)
                    .execute()
                    .value

                for row in rows {
                    guard let commentID = row.comment_id,
                          let reaction = fanChatCommentReactionType(from: row.reaction_type) else {
                        continue
                    }
                    switch reaction {
                    case .up:
                        upCounts[commentID, default: 0] += 1
                    case .down:
                        downCounts[commentID, default: 0] += 1
                    }
                    if row.user_id == userID {
                        viewerReactions[commentID] = reaction
                    }
                }
            }

            let totalReactions = upCounts.values.reduce(0, +) + downCounts.values.reduce(0, +)
            await MainActor.run {
                applyVenueEventCommentReactionMetadata(
                    venueEventID: venueEventID,
                    upCounts: upCounts,
                    downCounts: downCounts,
                    viewerReactions: viewerReactions
                )
            }

            print("[FanChatReactionDebug] migrationNeeded=false")
            print("[FanChatReactionDebug] legacyLikesMigrated=false")
            print("[FanChatReactionDebug] reactionSummaryLoaded count=\(totalReactions)")
        } catch {
            print("[FanChatReactionDebug] migrationNeeded=true")
            print("[FanChatReactionDebug] refreshError eventId=\(venueEventID.uuidString.lowercased()) error=\(error.localizedDescription)")
            await loadLegacyCommentLikesAsUpReactions(
                venueEventID: venueEventID,
                commentIDs: uniqueIDs,
                userID: userID,
                originalError: error
            )
        }
    }

    private func fanChatCommentReactionType(from raw: String?) -> FanChatCommentReactionType? {
        guard let raw else { return nil }
        return FanChatCommentReactionType(rawValue: raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private func loadLegacyCommentLikesAsUpReactions(
        venueEventID: UUID,
        commentIDs: [UUID],
        userID: UUID,
        originalError: Error
    ) async {
        var upCounts: [UUID: Int] = [:]
        var viewerReactions: [UUID: FanChatCommentReactionType] = [:]

        do {
            for chunk in FanCommentLikesBatchLoad.chunked(commentIDs, size: FanCommentLikesBatchLoad.inQueryChunk) {
                let rows: [VenueEventCommentLikeRow] = try await supabase
                    .from("venue_event_comment_likes")
                    .select("comment_id,user_id")
                    .in("comment_id", values: chunk)
                    .execute()
                    .value

                for row in rows {
                    guard let commentID = row.comment_id else { continue }
                    upCounts[commentID, default: 0] += 1
                    if row.user_id == userID {
                        viewerReactions[commentID] = .up
                    }
                }
            }

            let totalLegacyLikes = upCounts.values.reduce(0, +)
            await MainActor.run {
                applyVenueEventCommentReactionMetadata(
                    venueEventID: venueEventID,
                    upCounts: upCounts,
                    downCounts: [:],
                    viewerReactions: viewerReactions
                )
            }

            print("[FanChatReactionDebug] legacyLikesMigrated=false")
            print("[FanChatReactionDebug] reactionSummaryLoaded count=\(totalLegacyLikes)")
        } catch {
            print("[FanChatReactionDebug] legacyFallbackFailed eventId=\(venueEventID.uuidString.lowercased()) error=\(error.localizedDescription)")
            logVenueEventSocialLoadError(
                "ERROR LOADING FAN COMMENT REACTIONS:",
                loadCancelledTag: "fan_comment_reactions",
                error: originalError
            )
        }
    }

    @MainActor
    private func applyVenueEventCommentReactionMetadata(
        venueEventID: UUID,
        upCounts: [UUID: Int],
        downCounts: [UUID: Int],
        viewerReactions: [UUID: FanChatCommentReactionType]
    ) {
        let visibleIDs = Set(venueEventComments[venueEventID]?.compactMap(\.serverCommentID) ?? [])
        for id in visibleIDs {
            if venueEventCommentLikeWriteInFlightIDs.contains(id) {
                print("[FanChatReactionDebug] optimisticPreserved commentId=\(id.uuidString.lowercased())")
                continue
            }
            venueEventCommentLikeCountsByID[id] = upCounts[id] ?? 0
            venueEventCommentDownReactionCountsByID[id] = downCounts[id] ?? 0
            if let viewerReaction = viewerReactions[id] {
                venueEventCommentViewerReactionsByID[id] = viewerReaction
            } else {
                venueEventCommentViewerReactionsByID.removeValue(forKey: id)
            }
            if viewerReactions[id] == .up {
                venueEventCommentIDsLikedByCurrentUser.insert(id)
            } else {
                venueEventCommentIDsLikedByCurrentUser.remove(id)
            }
        }

        guard let rows = venueEventComments[venueEventID] else { return }
        venueEventComments[venueEventID] = rows.map { row in
            guard let commentID = row.serverCommentID else { return row }
            if venueEventCommentLikeWriteInFlightIDs.contains(commentID) {
                return row.withReactionMetadata(
                    upCount: venueEventCommentLikeCountsByID[commentID] ?? row.upReactionCount,
                    downCount: venueEventCommentDownReactionCountsByID[commentID] ?? row.downReactionCount,
                    viewerReaction: venueEventCommentViewerReactionsByID[commentID]
                )
            }
            return row.withReactionMetadata(
                upCount: venueEventCommentLikeCountsByID[commentID] ?? 0,
                downCount: venueEventCommentDownReactionCountsByID[commentID] ?? 0,
                viewerReaction: venueEventCommentViewerReactionsByID[commentID]
            )
        }
    }

    @MainActor
    private func applySingleVenueEventCommentReactionMetadata(
        venueEventID: UUID,
        commentID: UUID,
        upCount: Int,
        downCount: Int,
        viewerReaction: FanChatCommentReactionType?
    ) {
        if venueEventCommentLikeWriteInFlightIDs.contains(commentID) {
            print("[FanChatReactionDebug] optimisticPreserved commentId=\(commentID.uuidString.lowercased())")
            return
        }

        venueEventCommentLikeCountsByID[commentID] = upCount
        venueEventCommentDownReactionCountsByID[commentID] = downCount
        if let viewerReaction {
            venueEventCommentViewerReactionsByID[commentID] = viewerReaction
        } else {
            venueEventCommentViewerReactionsByID.removeValue(forKey: commentID)
        }
        if viewerReaction == .up {
            venueEventCommentIDsLikedByCurrentUser.insert(commentID)
        } else {
            venueEventCommentIDsLikedByCurrentUser.remove(commentID)
        }

        guard let rows = venueEventComments[venueEventID] else { return }
        venueEventComments[venueEventID] = rows.map { row in
            guard row.serverCommentID == commentID else { return row }
            return row.withReactionMetadata(
                upCount: upCount,
                downCount: downCount,
                viewerReaction: viewerReaction
            )
        }
    }

    @MainActor
    private func applyLocalVenueEventCommentReactionState(commentID: UUID, reaction: FanChatCommentReactionType?) {
        let previousReaction = venueEventCommentViewerReactionsByID[commentID]
        guard previousReaction != reaction else { return }

        if previousReaction == .up {
            venueEventCommentLikeCountsByID[commentID] = max(0, (venueEventCommentLikeCountsByID[commentID] ?? 0) - 1)
        } else if previousReaction == .down {
            venueEventCommentDownReactionCountsByID[commentID] = max(0, (venueEventCommentDownReactionCountsByID[commentID] ?? 0) - 1)
        }

        if reaction == .up {
            venueEventCommentLikeCountsByID[commentID] = (venueEventCommentLikeCountsByID[commentID] ?? 0) + 1
            venueEventCommentIDsLikedByCurrentUser.insert(commentID)
            venueEventCommentViewerReactionsByID[commentID] = .up
        } else if reaction == .down {
            venueEventCommentDownReactionCountsByID[commentID] = (venueEventCommentDownReactionCountsByID[commentID] ?? 0) + 1
            venueEventCommentIDsLikedByCurrentUser.remove(commentID)
            venueEventCommentViewerReactionsByID[commentID] = .down
        } else {
            venueEventCommentIDsLikedByCurrentUser.remove(commentID)
            venueEventCommentViewerReactionsByID.removeValue(forKey: commentID)
        }

        for venueEventID in venueEventComments.keys {
            guard let rows = venueEventComments[venueEventID],
                  rows.contains(where: { $0.serverCommentID == commentID }) else { continue }
            venueEventComments[venueEventID] = rows.map { row in
                guard row.serverCommentID == commentID else { return row }
                return row.withReactionMetadata(
                    upCount: venueEventCommentLikeCountsByID[commentID] ?? 0,
                    downCount: venueEventCommentDownReactionCountsByID[commentID] ?? 0,
                    viewerReaction: venueEventCommentViewerReactionsByID[commentID]
                )
            }
        }
    }

    /// Inserts, updates, or removes the signed-in user's up/down reaction for a fan update comment.
    func toggleCommentReaction(commentId: UUID, type: FanChatCommentReactionType) async {
        print("[FanChatReactionDebug] reactionTapped type=\(type.rawValue)")

        guard canUseFanSocialFeatures else {
            logBusinessUserGateBlocked(action: "toggleCommentReaction")
            return
        }

        let userID: UUID
        do {
            userID = try await supabase.auth.session.user.id
        } catch {
            #if DEBUG
            print("[FanChatReactionDebug] toggle failed comment_id=\(commentId.uuidString.lowercased()) error=\(error)")
            #endif
            return
        }

        guard !venueEventCommentLikeWriteInFlightIDs.contains(commentId) else { return }

        let previousReaction = venueEventCommentViewerReactionsByID[commentId]
        let nextReaction: FanChatCommentReactionType? = previousReaction == type ? nil : type
        let previousUpCount = venueEventCommentLikeCountsByID[commentId] ?? 0
        let previousDownCount = venueEventCommentDownReactionCountsByID[commentId] ?? 0
        let previousLikedIDs = venueEventCommentIDsLikedByCurrentUser
        let previousViewerReactions = venueEventCommentViewerReactionsByID
        let previousRows = venueEventComments

        venueEventCommentLikeWriteInFlightIDs.insert(commentId)
        applyLocalVenueEventCommentReactionState(commentID: commentId, reaction: nextReaction)
        #if DEBUG
        print("[FanChatReactionDebug] optimisticReactionApplied type=\(nextReaction?.rawValue ?? "none")")
        #endif

        do {
            if let nextReaction {
                if previousReaction == nil {
                    let insert = VenueEventCommentReactionInsert(
                        comment_id: commentId,
                        user_id: userID,
                        reaction_type: nextReaction.rawValue
                    )

                    do {
                        try await supabase
                            .from("venue_event_comment_reactions")
                            .insert(insert)
                            .execute()
                    } catch {
                        guard Self.isCommentLikeUniqueViolation(error) else { throw error }
                        let update = VenueEventCommentReactionUpdate(
                            reaction_type: nextReaction.rawValue,
                            updated_at: VenueEventCommentsQuery.isoTimestamp(Date())
                        )
                        try await supabase
                            .from("venue_event_comment_reactions")
                            .update(update)
                            .eq("comment_id", value: commentId.uuidString)
                            .eq("user_id", value: userID.uuidString)
                            .execute()
                    }
                } else {
                    let update = VenueEventCommentReactionUpdate(
                        reaction_type: nextReaction.rawValue,
                        updated_at: VenueEventCommentsQuery.isoTimestamp(Date())
                    )
                    try await supabase
                        .from("venue_event_comment_reactions")
                        .update(update)
                        .eq("comment_id", value: commentId.uuidString)
                        .eq("user_id", value: userID.uuidString)
                        .execute()
                }
                print("[FanChatReactionDebug] reactionUpserted type=\(nextReaction.rawValue)")
            } else {
                try await supabase
                    .from("venue_event_comment_reactions")
                    .delete()
                    .eq("comment_id", value: commentId.uuidString)
                    .eq("user_id", value: userID.uuidString)
                    .execute()
                print("[FanChatReactionDebug] reactionRemoved type=\(type.rawValue)")
            }

            venueEventCommentLikeWriteInFlightIDs.remove(commentId)
            let affectedVenueEventIDs = venueEventComments.compactMap { entry in
                entry.value.contains { $0.serverCommentID == commentId } ? entry.key : nil
            }
            for venueEventID in affectedVenueEventIDs {
                await loadSingleCommentReactionSummary(commentID: commentId, venueEventID: venueEventID)
            }
        } catch {
            venueEventCommentLikeCountsByID[commentId] = previousUpCount
            venueEventCommentDownReactionCountsByID[commentId] = previousDownCount
            venueEventCommentIDsLikedByCurrentUser = previousLikedIDs
            venueEventCommentViewerReactionsByID = previousViewerReactions
            venueEventComments = previousRows
            venueEventCommentLikeWriteInFlightIDs.remove(commentId)

            #if DEBUG
            print("[FanChatReactionDebug] optimisticReactionRolledBack reason=\(error.localizedDescription)")
            print("[FanChatReactionDebug] toggle failed comment_id=\(commentId.uuidString.lowercased()) error=\(error)")
            #endif
        }
    }

    func toggleCommentLike(commentId: UUID) async {
        await toggleCommentReaction(commentId: commentId, type: .up)
    }

    private static func isCommentReportUniqueViolation(_ error: Error) -> Bool {
        if let pe = error as? PostgrestError, pe.code == "23505" {
            return true
        }
        let blob = "\(error.localizedDescription) \(String(describing: error))".lowercased()
        if blob.contains("23505") || blob.contains("duplicate key") || blob.contains("unique constraint") {
            return true
        }
        if let pe = error as? PostgrestError {
            let detail = "\(pe.message) \(pe.detail ?? "") \(pe.hint ?? "")".lowercased()
            if detail.contains("duplicate") || detail.contains("unique") || detail.contains("23505") {
                return true
            }
        }
        return false
    }

    private static func isCommentLikeUniqueViolation(_ error: Error) -> Bool {
        if let pe = error as? PostgrestError, pe.code == "23505" {
            return true
        }
        let blob = "\(error.localizedDescription) \(String(describing: error))".lowercased()
        if blob.contains("23505") || blob.contains("duplicate key") || blob.contains("unique constraint") {
            return true
        }
        if let pe = error as? PostgrestError {
            let detail = "\(pe.message) \(pe.detail ?? "") \(pe.hint ?? "")".lowercased()
            if detail.contains("duplicate") || detail.contains("unique") || detail.contains("23505") {
                return true
            }
        }
        return false
    }

    // Fetches aggregate vibe tallies and the current user’s selections for one event.
    func loadVibes(for venueEventID: UUID) async {
        do {
            #if DEBUG
            let previousCounts = await MainActor.run { venueEventVibeCounts[venueEventID] ?? [:] }
            let previousTotal = previousCounts.values.reduce(0, +)
            print("[RealtimeChainDebug] refreshStarted table=venue_event_vibes key=\(venueEventID.uuidString.lowercased())")
            #endif
            let rows: [VenueEventVibeRow] = try await supabase
                .from("venue_event_vibes")
                .select("venue_event_id,user_email,vibe_type")
                .eq("venue_event_id", value: venueEventID.uuidString)
                .execute()
                .value

            var counts: [String: Int] = [:]
            var myVibes: Set<String> = []

            let email = await strictNormalizedSessionEmailForSocialTables()
                ?? OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)

            for row in rows {
                guard let rawVibe = row.vibe_type else { continue }
                let vibe = VenueCrowdReactionCatalog.normalizedCountKey(for: rawVibe)

                counts[vibe, default: 0] += 1

                if OwnerBusinessEmail.normalized(row.user_email ?? "") == email {
                    myVibes.insert(rawVibe)
                }
            }

            await MainActor.run {
                venueEventVibeCounts[venueEventID] = counts
                myVenueEventVibes[venueEventID] = myVibes
                fanUpdatesVibePrefetchedAt[venueEventID] = Date()
#if DEBUG
                let newTotal = counts.values.reduce(0, +)
                print("[RealtimeChainDebug] uiStateUpdated table=venue_event_vibes key=\(venueEventID.uuidString.lowercased()).totalVibes oldValue=\(previousTotal) newValue=\(newTotal)")
                for reaction in VenueCrowdReactionCatalog.reactions {
                    let key = VenueCrowdReactionCatalog.countKey(for: reaction.id)
                    if let count = counts[key] {
                        print("[CrowdReactionDebug] countUpdated=\(reaction.id):\(count)")
                    }
                }
#endif
            }

            #if DEBUG
            print("[RealtimeChainDebug] refreshSucceeded table=venue_event_vibes key=\(venueEventID.uuidString.lowercased())")
            #endif
            DebugLogGate.debug("LOADED VIBES: \(counts)")

        } catch {
            #if DEBUG
            print("[RealtimeChainDebug] refreshFailed table=venue_event_vibes error=\(error.localizedDescription)")
            #endif
            logVenueEventSocialLoadError("ERROR LOADING VIBES:", loadCancelledTag: "vibes", error: error)
        }
    }

    private func loadVibesBatch(for venueEventIDs: [UUID]) async {
        guard !venueEventIDs.isEmpty else { return }
        do {
            let rows: [VenueEventVibeRow] = try await supabase
                .from("venue_event_vibes")
                .select("venue_event_id,user_email,vibe_type")
                .in("venue_event_id", values: venueEventIDs.map { $0.uuidString.lowercased() })
                .execute()
                .value

            let email = await strictNormalizedSessionEmailForSocialTables()
                ?? OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)

            var countsByEventID: [UUID: [String: Int]] = [:]
            var myVibesByEventID: [UUID: Set<String>] = [:]
            for row in rows {
                guard let eventID = row.venue_event_id, let rawVibe = row.vibe_type else { continue }
                let vibe = VenueCrowdReactionCatalog.normalizedCountKey(for: rawVibe)
                countsByEventID[eventID, default: [:]][vibe, default: 0] += 1
                if OwnerBusinessEmail.normalized(row.user_email ?? "") == email {
                    myVibesByEventID[eventID, default: []].insert(rawVibe)
                }
            }

            await MainActor.run {
                let now = Date()
                for eventID in venueEventIDs {
                    venueEventVibeCounts[eventID] = countsByEventID[eventID] ?? [:]
                    myVenueEventVibes[eventID] = myVibesByEventID[eventID] ?? []
                    fanUpdatesVibePrefetchedAt[eventID] = now
#if DEBUG
                    for reaction in VenueCrowdReactionCatalog.reactions {
                        let key = VenueCrowdReactionCatalog.countKey(for: reaction.id)
                        if let count = countsByEventID[eventID]?[key] {
                            print("[CrowdReactionDebug] countUpdated=\(reaction.id):\(count)")
                        }
                    }
#endif
                }
            }
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING VIBES BATCH:", loadCancelledTag: "vibes_batch", error: error)
        }
    }

    func addCrowdReaction(for venueEventID: UUID, reactionID: String) async {
        guard canUseFanSocialFeatures else {
            logBusinessUserGateBlocked(action: "crowdReaction")
            return
        }
        let email = await strictNormalizedSessionEmailForSocialTables()
            ?? OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)

        guard OwnerBusinessEmail.isValidStrict(email) else {
            DebugLogGate.debug("LOGIN REQUIRED TO ADD CROWD REACTION")
            return
        }

        let countKey = VenueCrowdReactionCatalog.countKey(for: reactionID)
        let storageValue = VenueCrowdReactionCatalog.storageValue(for: reactionID)
        let previousCounts = venueEventVibeCounts[venueEventID] ?? [:]

        venueEventVibeCounts[venueEventID, default: [:]][countKey, default: 0] += 1
#if DEBUG
        print("[CrowdReactionDebug] reactionTapped=\(reactionID)")
        print("[CrowdReactionDebug] countUpdated=\(venueEventVibeCounts[venueEventID]?[countKey] ?? 0)")
#endif

        do {
            let insert = VenueEventVibeInsert(
                venue_event_id: venueEventID,
                user_email: email,
                vibe_type: storageValue
            )

            try await supabase
                .from("venue_event_vibes")
                .insert(insert)
                .execute()

            await loadVibes(for: venueEventID)
        } catch {
            venueEventVibeCounts[venueEventID] = previousCounts
            print("ERROR ADDING CROWD REACTION:", error)
        }
    }

    // Inserts or deletes a single vibe row for the signed-in user or venue owner.
    func toggleVibe(for venueEventID: UUID, vibeType: String) async {
        guard canUseFanSocialFeatures else {
            logBusinessUserGateBlocked(action: "toggleVibe")
            return
        }
        let email = await strictNormalizedSessionEmailForSocialTables()
            ?? OwnerBusinessEmail.normalized(!currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail)

        guard OwnerBusinessEmail.isValidStrict(email) else {
            DebugLogGate.debug("LOGIN REQUIRED TO VOTE VIBE")
            return
        }

        let inFlightKey = "\(venueEventID.uuidString)|\(vibeType)"
        guard !venueEventVibeWriteInFlightKeys.contains(inFlightKey) else { return }

        let alreadySelected = myVenueEventVibes[venueEventID]?.contains(vibeType) ?? false
        let previousCounts = venueEventVibeCounts[venueEventID] ?? [:]
        let previousMyVibes = myVenueEventVibes[venueEventID] ?? []

        venueEventVibeWriteInFlightKeys.insert(inFlightKey)
        applyLocalVenueEventVibeState(venueEventID: venueEventID, vibeType: vibeType, isSelected: !alreadySelected)

        do {
            if alreadySelected {
                try await supabase
                    .from("venue_event_vibes")
                    .delete()
                    .eq("venue_event_id", value: venueEventID.uuidString)
                    .eq("user_email", value: email)
                    .eq("vibe_type", value: vibeType)
                    .execute()
            } else {
                let insert = VenueEventVibeInsert(
                    venue_event_id: venueEventID,
                    user_email: email,
                    vibe_type: vibeType
                )

                try await supabase
                    .from("venue_event_vibes")
                    .insert(insert)
                    .execute()
            }

            venueEventVibeWriteInFlightKeys.remove(inFlightKey)
            await loadVibes(for: venueEventID)

        } catch {
            venueEventVibeCounts[venueEventID] = previousCounts
            myVenueEventVibes[venueEventID] = previousMyVibes
            venueEventVibeWriteInFlightKeys.remove(inFlightKey)
            print("ERROR TOGGLING VIBE:", error)
        }
    }

    private func applyLocalVenueEventVibeState(venueEventID: UUID, vibeType: String, isSelected: Bool) {
        var counts = venueEventVibeCounts[venueEventID] ?? [:]
        var myVibes = myVenueEventVibes[venueEventID] ?? []

        if isSelected {
            myVibes.insert(vibeType)
            counts[vibeType, default: 0] += 1
        } else {
            myVibes.remove(vibeType)
            let nextCount = max(0, (counts[vibeType] ?? 0) - 1)
            if nextCount == 0 {
                counts.removeValue(forKey: vibeType)
            } else {
                counts[vibeType] = nextCount
            }
        }

        venueEventVibeCounts[venueEventID] = counts
        myVenueEventVibes[venueEventID] = myVibes
    }

    /// Loads the first page of fan updates (newest first server-side, stored unsorted; views sort for display).
    func loadComments(for venueEventID: UUID) async {
        _ = await loadCommentsFirstPage(for: venueEventID)
    }

    func fanUpdatesDisplayCommentCount(for venueEventID: UUID) -> Int {
        if let exact = venueEventCommentPreviewCounts[venueEventID] {
            return exact
        }
        return venueEventComments[venueEventID]?.count ?? 0
    }

    @MainActor
    func prefetchFanUpdatesCardSocialData(for venueEventID: UUID) {
        prefetchCommentsForFanUpdatesCardIfNeeded(venueEventID: venueEventID)
        prefetchVibesForFanUpdatesCardIfNeeded(venueEventID: venueEventID)
        prefetchGoingProfilesForFanUpdatesCardIfNeeded(venueEventID: venueEventID)
    }

    @MainActor
    func prefetchVisibleDiscoverSocialData(eventIDs: [UUID], predictionEventIDs: [UUID]) {
        let visibleEventIDs = orderedUniqueVenueEventIDs(eventIDs, limit: DiscoverVisibleSocialPrefetchConfig.maxVisibleEvents)
        let visiblePredictionEventIDs = orderedUniqueVenueEventIDs(predictionEventIDs, limit: DiscoverVisibleSocialPrefetchConfig.maxVisibleEvents)
        guard !visibleEventIDs.isEmpty || !visiblePredictionEventIDs.isEmpty else {
            #if DEBUG
            print("[DiscoverSocialPerf] visibleBatchSkipped reason=empty")
            #endif
            return
        }

        let batchKey = discoverVisibleSocialPrefetchKey(
            eventIDs: visibleEventIDs,
            predictionEventIDs: visiblePredictionEventIDs
        )
        if let existing = discoverVisibleSocialPrefetchTasksByKey[batchKey] {
            #if DEBUG
            print("[DiscoverSocialPerf] coalescedExistingBatch=true")
            print("[DiscoverSocialPerf] visibleBatchSkipped reason=inFlight")
            #endif
            Task { await existing.value }
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.discoverVisibleSocialPrefetchTasksByKey[batchKey] = nil
                #if DEBUG
                print("[DiscoverSocialPerf] visibleBatchCompleted")
                #endif
            }

            #if DEBUG
            print("[DiscoverSocialPerf] visibleBatchStarted count=\(visibleEventIDs.count)")
            #endif

            async let commentsAndVibes: Void = self.prefetchFanUpdatesPreviewBatchForVisibleEvents(eventIDs: visibleEventIDs)
            async let goingProfiles: Void = self.prefetchGoingProfilesForVisibleEventBatchIfNeeded(eventIDs: visibleEventIDs)
            async let predictions: Void = self.prefetchVenuePredictionSummariesForVisibleBatch(eventIDs: visiblePredictionEventIDs)
            _ = await (commentsAndVibes, goingProfiles, predictions)
        }
        discoverVisibleSocialPrefetchTasksByKey[batchKey] = task
    }

    @MainActor
    private func orderedUniqueVenueEventIDs(_ ids: [UUID], limit: Int) -> [UUID] {
        var seen: Set<UUID> = []
        var ordered: [UUID] = []
        ordered.reserveCapacity(min(ids.count, limit))
        for id in ids {
            guard !seen.contains(id) else { continue }
            seen.insert(id)
            ordered.append(id)
            if ordered.count >= limit { break }
        }
        return ordered
    }

    @MainActor
    private func discoverVisibleSocialPrefetchKey(eventIDs: [UUID], predictionEventIDs: [UUID]) -> String {
        let socialKey = eventIDs.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
        let predictionKey = predictionEventIDs.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
        return "social:\(socialKey)|prediction:\(predictionKey)"
    }

    @MainActor
    private func prefetchFanUpdatesPreviewBatchForVisibleEvents(eventIDs: [UUID]) async {
        let commentIDs = eventIDs.filter { id in
            !(fanUpdatesPrefetchIsFresh(fanUpdatesCommentPrefetchedAt[id], ttl: FanUpdatesPrefetchTTL.comments) &&
              venueEventCommentPreviewCounts[id] != nil)
        }
        let vibeIDs = eventIDs.filter { id in
            !(fanUpdatesPrefetchIsFresh(fanUpdatesVibePrefetchedAt[id], ttl: FanUpdatesPrefetchTTL.vibes) &&
              venueEventVibeCounts[id] != nil)
        }

        async let comments: Void = loadFanUpdatesPreviewBatch(for: commentIDs)
        async let vibes: Void = loadVibesBatch(for: vibeIDs)
        _ = await (comments, vibes)
    }

    @MainActor
    func prefetchCommentsForFanUpdatesCardIfNeeded(venueEventID: UUID) {
        if let task = fanUpdatesCommentPrefetchTasks[venueEventID] {
            Task { await task.value }
            return
        }
        if fanUpdatesPrefetchIsFresh(fanUpdatesCommentPrefetchedAt[venueEventID], ttl: FanUpdatesPrefetchTTL.comments),
           venueEventCommentPreviewCounts[venueEventID] != nil {
            #if DEBUG
            print("[FanUpdatesPreviewDebug] preview cache hit eventId=\(venueEventID.uuidString.lowercased())")
            #endif
            return
        }

        fanUpdatesCommentPrefetchTasks[venueEventID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fanUpdatesCommentPrefetchTasks[venueEventID] = nil }
            #if DEBUG
            print("[FanUpdatesPreviewDebug] skipped heavy preload eventId=\(venueEventID.uuidString.lowercased())")
            #endif
            await self.loadFanUpdatesPreview(for: venueEventID)
        }
    }

    @MainActor
    func prefetchVibesForFanUpdatesCardIfNeeded(venueEventID: UUID) {
        if let task = fanUpdatesVibePrefetchTasks[venueEventID] {
            Task { await task.value }
            return
        }
        if fanUpdatesPrefetchIsFresh(fanUpdatesVibePrefetchedAt[venueEventID], ttl: FanUpdatesPrefetchTTL.vibes),
           venueEventVibeCounts[venueEventID] != nil {
            return
        }

        fanUpdatesVibePrefetchTasks[venueEventID] = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.fanUpdatesVibePrefetchTasks[venueEventID] = nil }
            await self.loadVibes(for: venueEventID)
        }
    }

    @MainActor
    private func fanUpdatesPrefetchIsFresh(_ date: Date?, ttl: TimeInterval) -> Bool {
        guard let date else { return false }
        return Date().timeIntervalSince(date) < ttl
    }

    /// Lightweight card-only preload: exact visible count + latest preview rows, no report flags/enrichment/pagination.
    func loadFanUpdatesPreview(for venueEventID: UUID) async {
        #if DEBUG
        print("[FanUpdatesPreviewDebug] lightweight preload eventId=\(venueEventID.uuidString.lowercased())")
        #endif
        async let count: Int? = loadFanUpdatesExactVisibleCommentCount(for: venueEventID)
        async let previews: [VenueEventCommentRow] = loadFanUpdatesPreviewRows(for: venueEventID)
        let (exactCount, previewRows) = await (count, previews)

        await MainActor.run {
            if let exactCount {
                updateVenueEventCommentPreviewCount(for: venueEventID, to: exactCount)
            }
            venueEventCommentPreviews[venueEventID] = previewRows
            fanUpdatesCommentPrefetchedAt[venueEventID] = Date()
        }
    }

    private func loadFanUpdatesPreviewBatch(for venueEventIDs: [UUID]) async {
        guard !venueEventIDs.isEmpty else { return }
        do {
            let rowsRaw: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .in("venue_event_id", values: venueEventIDs.map { $0.uuidString.lowercased() })
                .or("is_moderation_hidden.is.null,is_moderation_hidden.eq.false")
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .execute()
                .value

            let rows = rowsRaw.filter { !$0.isHiddenFromThread }
            var counts: [UUID: Int] = [:]
            var previews: [UUID: [VenueEventCommentRow]] = [:]
            for row in rows {
                guard let eventID = row.venue_event_id else { continue }
                counts[eventID, default: 0] += 1
                if (previews[eventID]?.count ?? 0) < VenueEventCommentsPagination.previewLimit {
                    previews[eventID, default: []].append(row)
                }
            }

            await MainActor.run {
                let now = Date()
                for eventID in venueEventIDs {
                    updateVenueEventCommentPreviewCount(for: eventID, to: counts[eventID] ?? 0)
                    venueEventCommentPreviews[eventID] = previews[eventID] ?? []
                    fanUpdatesCommentPrefetchedAt[eventID] = now
                }
            }
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING FAN UPDATES PREVIEW BATCH:", loadCancelledTag: "fan_updates_preview_batch", error: error)
        }
    }

    private func loadFanUpdatesExactVisibleCommentCount(for venueEventID: UUID) async -> Int? {
        do {
            let response = try await supabase
                .from("venue_event_comments")
                .select("id", head: true, count: .exact)
                .eq("venue_event_id", value: venueEventID)
                .or("is_moderation_hidden.is.null,is_moderation_hidden.eq.false")
                .execute()
            let count = response.count ?? 0
            #if DEBUG
            print("[FanUpdatesPreviewDebug] exact count loaded eventId=\(venueEventID.uuidString.lowercased()) count=\(count)")
            #endif
            return count
        } catch {
            #if DEBUG
            print("[FanUpdatesPreviewDebug] count fallback eventId=\(venueEventID.uuidString.lowercased())")
            #endif
            return nil
        }
    }

    private func loadFanUpdatesPreviewRows(for venueEventID: UUID) async -> [VenueEventCommentRow] {
        do {
            let rows: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .or("is_moderation_hidden.is.null,is_moderation_hidden.eq.false")
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(VenueEventCommentsPagination.previewLimit)
                .execute()
                .value
            return rows.filter { !$0.isHiddenFromThread }
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING FAN UPDATES PREVIEW:", loadCancelledTag: "fan_updates_preview", error: error)
            return []
        }
    }

    /// Keyset-paginated first page. Returns `true` if older rows may exist (page was full).
    func loadCommentsFirstPage(for venueEventID: UUID, logFullSheetLoad: Bool = false) async -> Bool {
        #if DEBUG
        if logFullSheetLoad {
            print("[FanUpdatesPreviewDebug] full sheet load eventId=\(venueEventID.uuidString.lowercased())")
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        do {
            let rowsRaw: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(VenueEventCommentsPagination.initialLimit)
                .execute()
                .value

            let rows = rowsRaw.filter { !$0.isHiddenFromThread }

            await MainActor.run {
                let current = venueEventComments[venueEventID] ?? []
                let serverIDs = Set(rows.compactMap(\.serverCommentID))
                let unsentLocalRows = current.filter { comment in
                    guard comment.delivery_state != .sent else { return false }
                    guard let matchedServerID = comment.serverCommentID else { return true }
                    return !serverIDs.contains(matchedServerID)
                }
                venueEventComments[venueEventID] = rows + unsentLocalRows
                let cachedCount = venueEventCommentPreviewCounts[venueEventID] ?? 0
                let visibleUnsentCount = unsentLocalRows.filter { !$0.isFailedSend && !$0.isHiddenFromThread }.count
                updateVenueEventCommentPreviewCount(
                    for: venueEventID,
                    to: max(cachedCount, rows.count + visibleUnsentCount)
                )
                fanUpdatesCommentPrefetchedAt[venueEventID] = Date()
            }

            await loadCurrentUserCommentReportFlags(for: venueEventID)
            await loadCommentReactions(for: venueEventID)

            let hasMore = rowsRaw.count >= VenueEventCommentsPagination.initialLimit
            #if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("[VenueCommentsPagination] initial: \(String(format: "%.1f", ms))ms rows=\(rows.count) limit=\(VenueEventCommentsPagination.initialLimit) hasMore=\(hasMore)")
            #endif
            return hasMore
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING COMMENTS:", loadCancelledTag: "comments", error: error)
            await MainActor.run {
                venueEventComments[venueEventID] = []
            }
            return false
        }
    }

    /// Older fan updates before `(beforeCreatedAt, beforeId)` in `(created_at DESC, id DESC)` order. Returns whether more may exist.
    func loadOlderVenueComments(for venueEventID: UUID, beforeCreatedAt: Date, beforeId: UUID) async -> Bool {
        #if DEBUG
        let t0 = CFAbsoluteTimeGetCurrent()
        #endif
        do {
            let rowsRaw: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .or(VenueEventCommentsQuery.keysetOlderThanOrFilter(createdAt: beforeCreatedAt, commentId: beforeId))
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(VenueEventCommentsPagination.pageLimit)
                .execute()
                .value

            let rows = rowsRaw.filter { !$0.isHiddenFromThread }

            await MainActor.run {
                var list = venueEventComments[venueEventID] ?? []
                var existing = Set(list.compactMap(\.serverCommentID))
                for row in rows {
                    guard let rid = row.serverCommentID, !existing.contains(rid) else { continue }
                    list.append(row)
                    existing.insert(rid)
                }
                venueEventComments[venueEventID] = list
            }

            await loadCurrentUserCommentReportFlags(for: venueEventID)
            await loadCommentReactions(for: venueEventID)

            let hasMore = rowsRaw.count >= VenueEventCommentsPagination.pageLimit
            #if DEBUG
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            print("[VenueCommentsPagination] older page: \(String(format: "%.1f", ms))ms rows=\(rowsRaw.count) hasMore=\(hasMore)")
            #endif
            return hasMore
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING OLDER COMMENTS:", loadCancelledTag: "comments", error: error)
            return true
        }
    }

    /// Inserts a comment as the active authenticated session email. Returns `nil` on success, or a user-facing error string.
    func addComment(to venueEventID: UUID, text: String) async -> String? {
        let cleanText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanText.isEmpty else { return nil }
        guard canUseFanSocialFeatures else {
            logBusinessUserGateBlocked(action: "postVenueEventComment")
            return BusinessFanGateCopy.commentsViewOnlyForBusiness
        }
        guard let commenterEmail = await strictNormalizedSessionEmailForSocialTables() else {
            DebugLogGate.debug("LOGIN REQUIRED TO COMMENT")
            return "Sign in to post an update."
        }

        if ModerationService.containsProfanity(cleanText) {
            return ModerationService.profanityRejectionUserMessage()
        }

        if let limit = RateLimitService.checkVenueEventCommentSend(venueEventId: venueEventID, body: cleanText) {
            return limit
        }

        let localCommentID = UUID()
        let createdAt = VenueEventCommentsQuery.isoTimestamp(Date())
        let localRow = VenueEventCommentRow(
            id: localCommentID,
            venue_event_id: venueEventID,
            user_email: commenterEmail,
            comment: cleanText,
            created_at: createdAt,
            is_moderation_hidden: false,
            delivery_state: .pending
        )

        #if DEBUG
        print("[GameChatPerf] send tapped event=\(venueEventID) local=\(localCommentID) len=\(cleanText.count)")
        print("[GameChatPerf] optimistic append event=\(venueEventID) local=\(localCommentID)")
        let sendStartedAt = CFAbsoluteTimeGetCurrent()
        venueEventCommentLatencySendTimesByLocalID[localCommentID] = sendStartedAt
        venueEventCommentLatencyLastSendTimeByEventID[venueEventID] = sendStartedAt
        venueEventCommentDebugSendTapDatesByLocalID[localCommentID] = Date()
        print("[FanChatLatencyDebug] sendTapped eventId=\(venueEventID.uuidString.lowercased()) localTime=\(FanChatLatencyDebugClock.localTime())")
        print("[FanChatLatencyDebug] currentFlow eventId=\(venueEventID.uuidString.lowercased()) optimisticUI=yes realtime=yes polling=no manualReloadAfterInsert=no")
        DebugLogGate.debug("[FanChatRealtimeDelayDebug] sendWhileSubscriptionReady=\(venueEventCommentsRealtimeReadyIDs.contains(venueEventID))")
        DebugLogGate.debug("[FanChatReadyDebug] sendWithReadyState eventId=\(venueEventID.uuidString.lowercased()) ready=\(venueEventCommentsRealtimeReadyIDs.contains(venueEventID))")
        #endif

        await MainActor.run {
            appendPendingVenueEventComment(localRow, for: venueEventID)
        }
        performVenueEventCommentInsert(
            venueEventID: venueEventID,
            localCommentID: localCommentID,
            commenterEmail: commenterEmail,
            cleanText: cleanText
        )
        return nil
    }

    func retryCommentSend(_ comment: VenueEventCommentRow) async -> String? {
        guard let venueEventID = comment.venue_event_id,
              let localCommentID = comment.id,
              let cleanText = comment.comment?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cleanText.isEmpty else {
            return "Couldn’t retry that update."
        }
        guard let commenterEmail = await strictNormalizedSessionEmailForSocialTables() else {
            return "Sign in to post an update."
        }
        if let limit = RateLimitService.checkVenueEventCommentSend(venueEventId: venueEventID, body: cleanText) {
            return limit
        }
        await MainActor.run {
            markVenueEventCommentDeliveryState(
                venueEventID: venueEventID,
                localCommentID: localCommentID,
                state: .pending
            )
        }
        #if DEBUG
        print("[GameChatPerf] retry tapped event=\(venueEventID) local=\(localCommentID)")
        #endif
        performVenueEventCommentInsert(
            venueEventID: venueEventID,
            localCommentID: localCommentID,
            commenterEmail: commenterEmail,
            cleanText: cleanText
        )
        return nil
    }

    func deleteComment(_ comment: VenueEventCommentRow) async {
        guard let id = comment.serverCommentID else { return }

        do {
            try await supabase
                .from("venue_event_comments")
                .delete()
                .eq("id", value: id.uuidString)
                .execute()

            if let venueEventID = comment.venue_event_id {
                await MainActor.run {
                    venueEventComments[venueEventID]?.removeAll { $0.id == id }
                    applyVenueEventCommentCountDelta(for: venueEventID, delta: -1)
                }
            }

            DebugLogGate.debug("COMMENT DELETED")

        } catch {
            print("ERROR DELETING COMMENT:", error)
            if let venueEventID = comment.venue_event_id {
                await loadComments(for: venueEventID)
            }
        }
    }

    // Venue-owner dashboard: loads `comment_reports` for events scoped to the selected venue (`venue_id`) when set, otherwise legacy `owner_email`.
    func loadReportedCommentsForMyVenue() async {
        do {
            let myVenueEvents: [VenueEventRow]
            if let vid = ownerVenueDatabaseId {
#if DEBUG
                print("[BusinessPhaseB3] using venue_id path screen=loadReportedCommentsForMyVenue")
#endif
                myVenueEvents = try await supabase
                    .from("venue_events")
                    .select()
                    .eq("venue_id", value: vid.uuidString.lowercased())
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            } else {
                let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
                guard OwnerBusinessEmail.isValidStrict(ownerEmail) else { return }
#if DEBUG
                print("[BusinessPhaseB3] using owner_email fallback screen=loadReportedCommentsForMyVenue")
#endif
                myVenueEvents = try await supabase
                    .from("venue_events")
                    .select()
                    .eq("owner_email", value: ownerEmail)
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            }

            let myVenueEventIDs = myVenueEvents.compactMap { $0.id }

            guard !myVenueEventIDs.isEmpty else {
                await MainActor.run {
                    reportedComments = []
                    reportedCommentDisplays = []
                }
                return
            }

            let reports: [CommentReportRow] = try await supabase
                .from("comment_reports")
                .select()
                .in("venue_event_id", values: myVenueEventIDs)
                .order("created_at", ascending: false)
                .execute()
                .value

            await buildReportedCommentDisplays(from: reports)

            DebugLogGate.debug("LOADED MY VENUE REPORTS: \(reports.count)")

        } catch {
            print("ERROR LOADING MY VENUE REPORTS:", error)
        }
    }

    func buildReportedCommentDisplays(from reports: [CommentReportRow]) async {
        do {
            let commentIDs = reports.compactMap { $0.comment_id }

            let comments: [VenueEventCommentRow] = commentIDs.isEmpty ? [] : try await supabase
                .from("venue_event_comments")
                .select()
                .in("id", values: commentIDs)
                .execute()
                .value

            let commentsByID: [UUID: VenueEventCommentRow] = Dictionary(
                uniqueKeysWithValues: comments.compactMap { comment in
                    guard let id = comment.serverCommentID else { return nil }
                    return (id, comment)
                }
            )

            let venueEventIDs = comments.compactMap { $0.venue_event_id }

            let venueEvents: [VenueEventRow] = venueEventIDs.isEmpty ? [] : try await supabase
                .from("venue_events")
                .select()
                .in("id", values: venueEventIDs)
                .eq("admin_status", value: "active")
                .execute()
                .value

            let venueEventsByID: [UUID: VenueEventRow] = Dictionary(
                uniqueKeysWithValues: venueEvents.compactMap { event in
                    guard let id = event.id else { return nil }
                    return (id, event)
                }
            )

            let emails = Array(Set(
                comments.compactMap { $0.user_email } +
                reports.compactMap { $0.reporter_email }
            ))

            let profiles: [UserProfileRow] = emails.isEmpty ? [] : try await supabase
                .from("user_profiles")
                .select()
                .in("email", values: emails)
                .eq("admin_status", value: "active")
                .execute()
                .value

            let profilesByEmail: [String: UserProfileRow] = Dictionary(
                uniqueKeysWithValues: profiles.compactMap { profile in
                    guard let email = profile.email else { return nil }
                    return (email, profile)
                }
            )

            let displays = reports.map { report -> ReportedCommentDisplay in
                let comment = report.comment_id.flatMap { commentsByID[$0] }
                let venueEvent = comment?.venue_event_id.flatMap { venueEventsByID[$0] }

                return ReportedCommentDisplay(
                    reportID: report.id,
                    commentID: report.comment_id,
                    commentText: comment?.comment ?? "Comment not found",
                    reporterEmail: report.reporter_email ?? "Unknown",
                    reporterName: {
                        guard let email = report.reporter_email else { return "Unknown" }
                        return profilesByEmail[email]?.display_name ?? email
                    }(),
                    reportedAt: report.created_at ?? "",
                    commenterName: {
                        guard let email = comment?.user_email else { return "Unknown user" }
                        return profilesByEmail[email]?.display_name ?? email
                    }(),
                    commenterAvatarURL: {
                        guard let email = comment?.user_email else { return "" }
                        return profilesByEmail[email]?.avatar_url ?? ""
                    }(),
                    venueName: venueEvent?.venue_name ?? "Unknown venue",
                    eventTitle: venueEvent?.event_title ?? "Unknown game"
                )
            }

            await MainActor.run {
                self.reportedComments = reports
                self.reportedCommentDisplays = displays
            }

        } catch {
            print("ERROR BUILDING REPORT DISPLAYS:", error)
        }
    }

    func loadReportedComments() async {
        do {
            let reports: [CommentReportRow] = try await supabase
                .from("comment_reports")
                .select()
                .order("created_at", ascending: false)
                .execute()
                .value

            await buildReportedCommentDisplays(from: reports)

            DebugLogGate.debug("LOADED COMMENT REPORTS: \(reports.count)")

        } catch {
            print("ERROR LOADING COMMENT REPORTS:", error)
        }
    }

    /// Returns `true` when the comment should show as reported (insert succeeded or duplicate unique constraint).
    @discardableResult
    func reportComment(_ comment: VenueEventCommentRow, reason: String = "reported") async -> Bool {
        guard let commentID = comment.serverCommentID,
              let venueEventID = comment.venue_event_id else {
            DebugLogGate.debug("NO VALID COMMENT OR EVENT ID")
            return false
        }

        do {
            let session = try await supabase.auth.session
            let reporterEmail = session.user.email ?? ""

            guard !reporterEmail.isEmpty else {
                DebugLogGate.debug("NO AUTH SESSION EMAIL")
                return false
            }

            DebugLogGate.debug("REPORTER EMAIL FROM SESSION: \(reporterEmail)")

            let report = CommentReportInsert(
                comment_id: commentID,
                venue_event_id: venueEventID,
                reporter_email: reporterEmail,
                reason: reason
            )

            try await supabase
                .from("comment_reports")
                .insert(report)
                .execute()

            DebugLogGate.debug("COMMENT REPORTED")

            markCommentReportedLocally(commentID: commentID)

#if DEBUG
            print("[CommentReport] report added comment=\(commentID.uuidString)")
#endif
            let activeAfterInsert = await fetchModerationReportCountForComment(commentId: commentID) ?? 0
#if DEBUG
            print("[CommentReport] active count=\(activeAfterInsert)")
            print(
                "[CommentReport] auto-hide threshold reached=\(activeAfterInsert >= ModerationService.hiddenAfterReportsThreshold)"
            )
#endif

            await applyCommentModerationAutoHide(commentId: commentID, venueEventID: venueEventID)

            return true

        } catch {
            if Self.isCommentReportUniqueViolation(error) {
                markCommentReportedLocally(commentID: commentID)
#if DEBUG
                let activeDup = await fetchModerationReportCountForComment(commentId: commentID) ?? 0
                print("[CommentReport] active count=\(activeDup)")
                print(
                    "[CommentReport] auto-hide threshold reached=\(activeDup >= ModerationService.hiddenAfterReportsThreshold)"
                )
#endif
                return true
            }
            print("ERROR REPORTING COMMENT:", error)
            return false
        }
    }

    /// Deletes the signed-in fan's `comment_reports` row only (unflag). DB trigger recomputes ``moderation_report_count``.
    @discardableResult
    func unreportComment(_ comment: VenueEventCommentRow) async -> Bool {
        guard let commentID = comment.serverCommentID else {
            return false
        }

        do {
            let session = try await supabase.auth.session
            let reporterEmail = session.user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            guard !reporterEmail.isEmpty else {
                return false
            }

            try await supabase
                .from("comment_reports")
                .delete()
                .eq("comment_id", value: commentID.uuidString)
                .eq("reporter_email", value: reporterEmail)
                .execute()

            markCommentUnreportedLocally(commentID: commentID)

#if DEBUG
            print("[CommentReport] report removed comment=\(commentID.uuidString)")
#endif
            let activeAfterDelete = await fetchModerationReportCountForComment(commentId: commentID) ?? 0
#if DEBUG
            print("[CommentReport] active count=\(activeAfterDelete)")
            print(
                "[CommentReport] auto-hide threshold reached=\(activeAfterDelete >= ModerationService.hiddenAfterReportsThreshold)"
            )
#endif

            return true
        } catch {
#if DEBUG
            print("[CommentReport] unreport failed:", error)
#endif
            return false
        }
    }

    /// After a new report row, DB trigger bumps ``moderation_report_count`` and may set ``is_moderation_hidden``. Refresh local thread and queue one-shot admin email via Edge Function.
    private func applyCommentModerationAutoHide(commentId: UUID, venueEventID: UUID) async {
        do {
            struct Row: Decodable {
                let id: UUID?
                let is_moderation_hidden: Bool?
                let moderation_report_count: Int?
            }
            let rows: [Row] = try await supabase
                .from("venue_event_comments")
                .select("id,is_moderation_hidden,moderation_report_count")
                .eq("id", value: commentId.uuidString)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first,
                  row.is_moderation_hidden == true,
                  let count = row.moderation_report_count,
                  count >= ModerationService.hiddenAfterReportsThreshold
            else { return }

            await MainActor.run {
                venueEventComments[venueEventID]?.removeAll { $0.id == commentId }
                applyVenueEventCommentCountDelta(for: venueEventID, delta: -1)
            }

            ModerationService().notifyCommentModerationAlertBestEffort(commentId: commentId)
        } catch {
#if DEBUG
            print("[Moderation] applyCommentModerationAutoHide:", error)
#endif
        }
    }

    /// Report a venue listing (abuse, misinformation, etc.). Requires signed-in fan session.
    func reportVenue(venueId: UUID, category: ModerationReportCategory, details: String?) async throws {
        try await ModerationService().reportVenue(venueId: venueId, category: category, details: details)
    }

    func deleteReportedComment(_ report: ReportedCommentDisplay) async {
        guard let commentID = report.commentID else {
            DebugLogGate.debug("NO COMMENT ID TO DELETE")
            return
        }

        do {
            try await supabase
                .from("venue_event_comments")
                .delete()
                .eq("id", value: commentID.uuidString)
                .execute()

            try await supabase
                .from("comment_reports")
                .delete()
                .eq("comment_id", value: commentID.uuidString)
                .execute()

            await MainActor.run {
                reportedComments.removeAll { $0.comment_id == commentID }
                reportedCommentDisplays.removeAll { $0.commentID == commentID }
            }

            DebugLogGate.debug("REPORTED COMMENT AND REPORTS DELETED")

        } catch {
            print("ERROR DELETING REPORTED COMMENT:", error)
        }
    }

    func dismissCommentReport(_ report: ReportedCommentDisplay) async {
        guard let commentID = report.commentID else {
            DebugLogGate.debug("NO COMMENT ID TO DISMISS REPORT")
            return
        }

        do {
            try await supabase
                .from("comment_reports")
                .delete()
                .eq("comment_id", value: commentID.uuidString)
                .execute()

            await MainActor.run {
                reportedComments.removeAll { $0.comment_id == commentID }
                reportedCommentDisplays.removeAll { $0.commentID == commentID }
            }

            DebugLogGate.debug("COMMENT REPORT DISMISSED")

        } catch {
            print("ERROR DISMISSING COMMENT REPORT:", error)
        }
    }
}
