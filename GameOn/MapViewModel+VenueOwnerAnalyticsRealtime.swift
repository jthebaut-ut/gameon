import Foundation
import Supabase

// MARK: - Venue owner analytics — Supabase Realtime
//
// **Today:** Postgres `INSERT`/`UPDATE`/`DELETE` on engagement tables → debounced refetch via existing REST
// loaders (`loadInterestCountsForVenueEventIDs`, `loadComments`, `loadVibes`). Aggregation stays client-side.
//
// **Later:** Swap ``applyVenueOwnerRealtimeEngagementRefresh(trackedEventIDs:)`` for a single RPC / Edge
// function or a `broadcast` payload while keeping the same subscription surface.

extension MapViewModel {

    func stopVenueOwnerAnalyticsRealtime() async {
        venueOwnerAnalyticsDebounceTask?.cancel()
        venueOwnerAnalyticsDebounceTask = nil

        if let task = venueOwnerAnalyticsRealtimeTask {
            task.cancel()
            _ = await task.result
            venueOwnerAnalyticsRealtimeTask = nil
        }

        if let ch = venueOwnerAnalyticsRealtimeChannel {
            await supabase.removeChannel(ch)
            venueOwnerAnalyticsRealtimeChannel = nil
        }
    }

    /// Subscribes to `venue_event_interests`, `venue_event_comments`, and `venue_event_vibes` for the given IDs.
    /// Call ``stopVenueOwnerAnalyticsRealtime()`` when leaving the analytics UI.
    func startVenueOwnerAnalyticsRealtime(trackedEventIDs: [UUID]) async {
        await stopVenueOwnerAnalyticsRealtime()

        let ids = Array(Set(trackedEventIDs)).sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty, isVenueOwnerLoggedIn else { return }

        venueOwnerAnalyticsRealtimeTask = Task { [weak self] in
            guard let self else { return }
            await self.runVenueOwnerAnalyticsRealtimeLoop(trackedEventIDs: ids)
        }
    }

    /// Recomputes in-memory engagement metrics from Supabase (used by realtime debounce and manual refresh).
    func applyVenueOwnerRealtimeEngagementRefresh(trackedEventIDs: [UUID]) async {
        guard !trackedEventIDs.isEmpty else { return }
        await loadInterestCountsForVenueEventIDs(trackedEventIDs)
        for id in trackedEventIDs {
            await loadComments(for: id)
            await loadVibes(for: id)
        }
    }

    // MARK: - Private

    private func scheduleDebouncedVenueOwnerAnalyticsRefresh(trackedEventIDs: [UUID]) {
        venueOwnerAnalyticsDebounceTask?.cancel()
        let snapshot = trackedEventIDs
        #if DEBUG
        print("[RealtimeChainDebug] refreshQueued table=venue_event_interests reason=owner_analytics_realtime trackedCount=\(snapshot.count)")
        print("[RealtimeChainDebug] refreshQueued table=venue_event_vibes reason=owner_analytics_realtime trackedCount=\(snapshot.count)")
        #endif
        venueOwnerAnalyticsDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            #if DEBUG
            print("[RealtimeChainDebug] refreshStarted table=venue_event_interests key=ownerAnalytics")
            print("[RealtimeChainDebug] refreshStarted table=venue_event_vibes key=ownerAnalytics")
            #endif
            await self.applyVenueOwnerRealtimeEngagementRefresh(trackedEventIDs: snapshot)
            #if DEBUG
            print("[RealtimeChainDebug] refreshSucceeded table=venue_event_interests key=ownerAnalytics")
            print("[RealtimeChainDebug] refreshSucceeded table=venue_event_vibes key=ownerAnalytics")
            #endif
        }
    }

    private func runVenueOwnerAnalyticsRealtimeLoop(trackedEventIDs: [UUID]) async {
        let ids = trackedEventIDs
        guard !Task.isCancelled else { return }

        let channel = supabase.channel("venue-owner-analytics")
        venueOwnerAnalyticsRealtimeChannel = channel

        let filter = RealtimePostgresFilter.in("venue_event_id", values: ids)

        let interestStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "venue_event_interests",
            filter: filter
        )
        let commentsStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "venue_event_comments",
            filter: filter
        )
        let vibesStream = channel.postgresChange(
            AnyAction.self,
            schema: "public",
            table: "venue_event_vibes",
            filter: filter
        )

        do {
            #if DEBUG
            print("[RealtimePublicationVerify] expected table=venue_event_interests publication=supabase_realtime migration=20260731_0030")
            print("[RealtimePublicationVerify] expected table=venue_event_vibes publication=supabase_realtime migration=20260731_0030")
            print("[RealtimeChainDebug] subscribeRequested table=venue_event_interests channel=\(channel.topic) filter=venue_event_id.in trackedCount=\(ids.count)")
            print("[RealtimeChainDebug] subscribeRequested table=venue_event_vibes channel=\(channel.topic) filter=venue_event_id.in trackedCount=\(ids.count)")
            #endif
            try await channel.subscribeWithError()
            #if DEBUG
            print("[RealtimeChainDebug] subscribeReady table=venue_event_interests channel=\(channel.topic)")
            print("[RealtimeChainDebug] subscribeReady table=venue_event_vibes channel=\(channel.topic)")
            #endif
        } catch {
            if venueOwnerAnalyticsRealtimeChannel === channel {
                venueOwnerAnalyticsRealtimeChannel = nil
            }
            #if DEBUG
            print("[RealtimeChainDebug] subscribeFailed table=venue_event_interests error=\(error.localizedDescription)")
            print("[RealtimeChainDebug] subscribeFailed table=venue_event_vibes error=\(error.localizedDescription)")
            #endif
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.consumeVenueOwnerRealtimeAnyStream(interestStream, tableName: "venue_event_interests", trackedEventIDs: ids)
            }
            group.addTask {
                await self.consumeVenueOwnerRealtimeAnyStream(commentsStream, tableName: "venue_event_comments", trackedEventIDs: ids)
            }
            group.addTask {
                await self.consumeVenueOwnerRealtimeAnyStream(vibesStream, tableName: "venue_event_vibes", trackedEventIDs: ids)
            }
        }
    }

    private func consumeVenueOwnerRealtimeAnyStream(_ stream: AsyncStream<AnyAction>, tableName: String, trackedEventIDs: [UUID]) async {
        for await action in stream {
            guard !Task.isCancelled else { break }
            #if DEBUG
            let eventType: String
            switch action {
            case .insert: eventType = "insert"
            case .update: eventType = "update"
            case .delete: eventType = "delete"
            }
            print("[RealtimeChainDebug] eventReceived table=\(tableName) eventType=\(eventType) rowId=unknown")
            print("[RealtimeChainDebug] eventMatchedCurrentView table=\(tableName) matched=unknown reason=ownerAnalyticsRefreshesTrackedEvents trackedCount=\(trackedEventIDs.count)")
            #endif
            await MainActor.run {
                self.scheduleDebouncedVenueOwnerAnalyticsRefresh(trackedEventIDs: trackedEventIDs)
            }
        }
    }
}
