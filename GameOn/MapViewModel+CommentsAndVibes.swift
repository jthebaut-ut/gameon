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
            likeCount: row.likeCount,
            isLikedByCurrentUser: row.isLikedByCurrentUser
        )
    }

    private func venueEventCommentRowWithCurrentLikeMetadata(_ row: VenueEventCommentRow) -> VenueEventCommentRow {
        guard let commentID = row.serverCommentID else { return row }
        return row.withLikeMetadata(
            likeCount: venueEventCommentLikeCountsByID[commentID] ?? row.likeCount,
            isLikedByCurrentUser: venueEventCommentIDsLikedByCurrentUser.contains(commentID)
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
        let row = venueEventCommentRowWithCurrentLikeMetadata(row)
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
#if DEBUG
            let reason = (fanChatAppLevelRealtimeTask == nil || fanChatAppLevelRealtimeChannel == nil)
                ? "fan_chat_app_missing_channel"
                : "fan_chat_app_foreground_resubscribe"
            RealtimeHealthDiagnostics.log("reconnectDetected=\(reason)")
#endif
            await stopFanChatAppLevelRealtime()
            await startFanChatAppLevelRealtimeIfNeeded(eventIDs: trackedIDs)
        }

        let activeSheetIDs = venueEventCommentsRealtimeActiveIDs()
        for eventID in activeSheetIDs {
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

        do {
            #if DEBUG
            let idList = ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
            print("[FanChatRealtimeDelayDebug] appSubscribeStart eventIds=\(idList)")
            print("[FanChatRealtimeDelayDebug] filterMode=app_in")
            RealtimeHealthDiagnostics.log("channelName=\(channel.topic)")
            RealtimeHealthDiagnostics.log("subscribeStart=true channelName=\(channel.topic)")
            #endif
            try await channel.subscribeWithError()
            #if DEBUG
            print("[FanChatRealtimeFixDebug] appLevelSubscribe eventIds=\(idList)")
            print("[FanChatRealtimeDelayDebug] appSubscribeReady elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - subscribeStartedAt) * 1000))")
            RealtimeHealthDiagnostics.log("subscribeReady elapsedMs=\(String(format: "%.1f", (CFAbsoluteTimeGetCurrent() - subscribeStartedAt) * 1000)) channelName=\(channel.topic)")
            #endif
        } catch {
            if fanChatAppLevelRealtimeChannel === channel {
                fanChatAppLevelRealtimeChannel = nil
            }
#if DEBUG
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
        }

        if fanChatAppLevelRealtimeChannel === channel {
            fanChatAppLevelRealtimeChannel = nil
            await supabase.removeChannel(channel)
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
        await loadCommentLikes(for: venueEventID)
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
            mergeSource: "auto_refresh"
        )
        // Refresh like counts for all visible sheet comments every tick (not only when new rows merge).
        await loadCommentLikes(for: venueEventID)
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
            for tick in 0...5 {
                if tick > 0 {
                    do {
                        try await Task.sleep(nanoseconds: 1_000_000_000)
                    } catch {
                        return
                    }
                }
                guard let self, !Task.isCancelled else { return }
                guard self.hasActiveVenueEventCommentsRealtimeListener(for: venueEventID) else { return }

                #if DEBUG
                print("[FanChatReceiverDebug] refreshTick eventId=\(venueEventID.uuidString.lowercased()) tick=\(tick)")
                #endif
                let stats = await self.fetchRecentVenueEventCommentsForRealtimeFallback(
                    venueEventID: venueEventID,
                    recoveryDelayMs: tick * 1_000,
                    mergeSource: "receiver_refresh"
                )
                totalNewRowsMerged += stats?.newRowsMerged ?? 0
                if tick == 5, totalNewRowsMerged == 0, stats?.fetchedCount == 0 {
                    #if DEBUG
                    print("[FanChatReceiverDebug] fetchMissingPostedComment possibleRLSOrFilterIssue=true")
                    #endif
                }
            }
        }
    }

    private func fetchRecentVenueEventCommentsForRealtimeFallback(
        venueEventID: UUID,
        recoveryDelayMs: Int? = nil,
        mergeSource: String = "realtime_fallback"
    ) async -> FanChatReceiverRefreshStats? {
        do {
            #if DEBUG
            print("[FanChatReadyDebug] fallbackFetchStarted eventId=\(venueEventID.uuidString.lowercased())")
            #endif
            let existingCommentIDs = Set((venueEventComments[venueEventID] ?? []).compactMap(\.serverCommentID))
            let rowsRaw: [VenueEventCommentRow] = try await supabase
                .from("venue_event_comments")
                .select(VenueEventCommentsPagination.selectColumns)
                .eq("venue_event_id", value: venueEventID)
                .or("is_moderation_hidden.is.null,is_moderation_hidden.eq.false")
                .order("created_at", ascending: false)
                .order("id", ascending: false)
                .limit(FanChatRealtimeFallbackConfig.fetchLimit)
                .execute()
                .value

            let rows = rowsRaw.filter { !$0.isHiddenFromThread }.reversed()
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
            #endif
            if let exactCount = await loadFanUpdatesExactVisibleCommentCount(for: venueEventID) {
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
            venueEventCommentsRealtimeReadyIDs.remove(venueEventID)
            venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = nil
            if let staleChannel {
                await supabase.removeChannel(staleChannel)
            }
        }

        let listenerToken = UUID()
        venueEventCommentsRealtimeListenerTokens[venueEventID] = listenerToken
        venueEventCommentsRealtimeReadyIDs.remove(venueEventID)
        venueEventCommentsRealtimeSubscribeStartedAt[venueEventID] = CFAbsoluteTimeGetCurrent()
        #if DEBUG
        print("[GameChatPerf] starting listener event=\(venueEventID)")
        print("[VenueCommentRealtimeDebug] subscribe eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatRealtimeDelayDebug] sheetSubscribeStart eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatRealtimeDelayDebug] filterMode=sheet_eq")
        print("[FanChatReadyDebug] subscribeStart channelName=\(channelName)")
        print("[FanChatReadyDebug] readyState eventId=\(venueEventID.uuidString.lowercased()) ready=false")
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
                venueEventCommentsRealtimeReadyIDs.insert(venueEventID)
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
                venueEventCommentsRealtimeReadyIDs.remove(venueEventID)
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
                venueEventCommentsRealtimeReadyIDs.remove(venueEventID)
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
        venueEventCommentsRealtimeReadyIDs.remove(venueEventID)
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

    /// Batch-loads like counts and current-user liked state for visible fan update comments.
    func loadCommentLikes(for venueEventID: UUID) async {
        let ids = await MainActor.run {
            venueEventComments[venueEventID]?.compactMap(\.serverCommentID) ?? []
        }
        let uniqueIDs = Array(Set(ids)).sorted { $0.uuidString < $1.uuidString }

        print("[FanChatLikesDebug] refreshStart eventId=\(venueEventID.uuidString.lowercased())")
        print("[FanChatLikesDebug] commentCount=\(uniqueIDs.count)")

        guard !uniqueIDs.isEmpty else {
            await MainActor.run {
                applyVenueEventCommentLikeMetadata(
                    venueEventID: venueEventID,
                    counts: [:],
                    likedIDs: []
                )
            }
            print("[FanChatLikesDebug] likesLoaded count=0")
            print("[FanChatLikesDebug] likedByViewer count=0")
            return
        }

        let userID: UUID
        do {
            userID = try await supabase.auth.session.user.id
        } catch {
            print("[FanChatLikesDebug] refreshError eventId=\(venueEventID.uuidString.lowercased()) error=\(error.localizedDescription)")
            await MainActor.run {
                applyVenueEventCommentLikeMetadata(
                    venueEventID: venueEventID,
                    counts: [:],
                    likedIDs: []
                )
            }
            print("[FanChatLikesDebug] likesLoaded count=0")
            print("[FanChatLikesDebug] likedByViewer count=0")
            return
        }

        var counts: [UUID: Int] = [:]
        var likedIDs: Set<UUID> = []

        do {
            for chunk in FanCommentLikesBatchLoad.chunked(uniqueIDs, size: FanCommentLikesBatchLoad.inQueryChunk) {
                let rows: [VenueEventCommentLikeRow] = try await supabase
                    .from("venue_event_comment_likes")
                    .select("comment_id,user_id")
                    .in("comment_id", values: chunk)
                    .execute()
                    .value

                for row in rows {
                    guard let commentID = row.comment_id else { continue }
                    counts[commentID, default: 0] += 1
                    if row.user_id == userID {
                        likedIDs.insert(commentID)
                    }
                }
            }

            let totalLikes = counts.values.reduce(0, +)
            await MainActor.run {
                applyVenueEventCommentLikeMetadata(
                    venueEventID: venueEventID,
                    counts: counts,
                    likedIDs: likedIDs
                )
            }

            print("[FanChatLikesDebug] likesLoaded count=\(totalLikes)")
            print("[FanChatLikesDebug] likedByViewer count=\(likedIDs.count)")
        } catch {
            print("[FanChatLikesDebug] refreshError eventId=\(venueEventID.uuidString.lowercased()) error=\(error.localizedDescription)")
            logVenueEventSocialLoadError(
                "ERROR LOADING FAN COMMENT LIKES:",
                loadCancelledTag: "fan_comment_likes",
                error: error
            )
        }
    }

    @MainActor
    private func applyVenueEventCommentLikeMetadata(
        venueEventID: UUID,
        counts: [UUID: Int],
        likedIDs: Set<UUID>
    ) {
        let visibleIDs = Set(venueEventComments[venueEventID]?.compactMap(\.serverCommentID) ?? [])
        for id in visibleIDs {
            if venueEventCommentLikeWriteInFlightIDs.contains(id) {
                print("[FanChatLikesDebug] optimisticPreserved commentId=\(id.uuidString.lowercased())")
                continue
            }
            venueEventCommentLikeCountsByID[id] = counts[id] ?? 0
            if likedIDs.contains(id) {
                venueEventCommentIDsLikedByCurrentUser.insert(id)
            } else {
                venueEventCommentIDsLikedByCurrentUser.remove(id)
            }
        }

        guard let rows = venueEventComments[venueEventID] else { return }
        venueEventComments[venueEventID] = rows.map { row in
            guard let commentID = row.serverCommentID else { return row }
            if venueEventCommentLikeWriteInFlightIDs.contains(commentID) {
                return row.withLikeMetadata(
                    likeCount: venueEventCommentLikeCountsByID[commentID] ?? row.likeCount,
                    isLikedByCurrentUser: venueEventCommentIDsLikedByCurrentUser.contains(commentID)
                )
            }
            return row.withLikeMetadata(
                likeCount: venueEventCommentLikeCountsByID[commentID] ?? 0,
                isLikedByCurrentUser: venueEventCommentIDsLikedByCurrentUser.contains(commentID)
            )
        }
    }

    @MainActor
    private func applyLocalVenueEventCommentLikeState(commentID: UUID, isLiked: Bool) {
        let currentCount = venueEventCommentLikeCountsByID[commentID] ?? 0
        venueEventCommentLikeCountsByID[commentID] = isLiked ? currentCount + 1 : max(0, currentCount - 1)
        if isLiked {
            venueEventCommentIDsLikedByCurrentUser.insert(commentID)
        } else {
            venueEventCommentIDsLikedByCurrentUser.remove(commentID)
        }

        for venueEventID in venueEventComments.keys {
            guard let rows = venueEventComments[venueEventID],
                  rows.contains(where: { $0.serverCommentID == commentID }) else { continue }
            venueEventComments[venueEventID] = rows.map { row in
                guard row.serverCommentID == commentID else { return row }
                return row.withLikeMetadata(
                    likeCount: venueEventCommentLikeCountsByID[commentID] ?? 0,
                    isLikedByCurrentUser: venueEventCommentIDsLikedByCurrentUser.contains(commentID)
                )
            }
        }
    }

    /// Inserts or deletes the signed-in user's like row for a fan update comment.
    func toggleCommentLike(commentId: UUID) async {
        #if DEBUG
        print("[FanCommentLikes] toggle start comment_id=\(commentId.uuidString.lowercased())")
        #endif

        guard canUseFanSocialFeatures else {
            logBusinessUserGateBlocked(action: "toggleCommentLike")
            return
        }

        let userID: UUID
        do {
            userID = try await supabase.auth.session.user.id
        } catch {
            #if DEBUG
            print("[FanCommentLikes] toggle failed comment_id=\(commentId.uuidString.lowercased()) error=\(error)")
            #endif
            return
        }

        guard !venueEventCommentLikeWriteInFlightIDs.contains(commentId) else { return }

        let wasLiked = venueEventCommentIDsLikedByCurrentUser.contains(commentId)
        let previousCount = venueEventCommentLikeCountsByID[commentId] ?? 0
        let previousLikedIDs = venueEventCommentIDsLikedByCurrentUser
        let previousRows = venueEventComments

        venueEventCommentLikeWriteInFlightIDs.insert(commentId)
        applyLocalVenueEventCommentLikeState(commentID: commentId, isLiked: !wasLiked)

        do {
            if wasLiked {
                try await supabase
                    .from("venue_event_comment_likes")
                    .delete()
                    .eq("comment_id", value: commentId.uuidString)
                    .eq("user_id", value: userID.uuidString)
                    .execute()
            } else {
                let insert = VenueEventCommentLikeInsert(
                    comment_id: commentId,
                    user_id: userID
                )

                try await supabase
                    .from("venue_event_comment_likes")
                    .insert(insert)
                    .execute()
            }

            venueEventCommentLikeWriteInFlightIDs.remove(commentId)

            #if DEBUG
            print("[FanCommentLikes] toggle success comment_id=\(commentId.uuidString.lowercased()) liked=\(!wasLiked)")
            #endif
        } catch {
            if !wasLiked, Self.isCommentLikeUniqueViolation(error) {
                venueEventCommentLikeWriteInFlightIDs.remove(commentId)
                #if DEBUG
                print("[FanCommentLikes] toggle success comment_id=\(commentId.uuidString.lowercased()) liked=true")
                #endif
                return
            }

            venueEventCommentLikeCountsByID[commentId] = previousCount
            venueEventCommentIDsLikedByCurrentUser = previousLikedIDs
            venueEventComments = previousRows
            venueEventCommentLikeWriteInFlightIDs.remove(commentId)

            #if DEBUG
            print("[FanCommentLikes] toggle failed comment_id=\(commentId.uuidString.lowercased()) error=\(error)")
            #endif
        }
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
                guard let vibe = row.vibe_type else { continue }

                counts[vibe, default: 0] += 1

                if OwnerBusinessEmail.normalized(row.user_email ?? "") == email {
                    myVibes.insert(vibe)
                }
            }

            await MainActor.run {
                venueEventVibeCounts[venueEventID] = counts
                myVenueEventVibes[venueEventID] = myVibes
                fanUpdatesVibePrefetchedAt[venueEventID] = Date()
            }

            DebugLogGate.debug("LOADED VIBES: \(counts)")

        } catch {
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
                guard let eventID = row.venue_event_id, let vibe = row.vibe_type else { continue }
                countsByEventID[eventID, default: [:]][vibe, default: 0] += 1
                if OwnerBusinessEmail.normalized(row.user_email ?? "") == email {
                    myVibesByEventID[eventID, default: []].insert(vibe)
                }
            }

            await MainActor.run {
                let now = Date()
                for eventID in venueEventIDs {
                    venueEventVibeCounts[eventID] = countsByEventID[eventID] ?? [:]
                    myVenueEventVibes[eventID] = myVibesByEventID[eventID] ?? []
                    fanUpdatesVibePrefetchedAt[eventID] = now
                }
            }
        } catch {
            logVenueEventSocialLoadError("ERROR LOADING VIBES BATCH:", loadCancelledTag: "vibes_batch", error: error)
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
            await loadCommentLikes(for: venueEventID)

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
            await loadCommentLikes(for: venueEventID)

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
