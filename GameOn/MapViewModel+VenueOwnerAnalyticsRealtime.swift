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
        venueOwnerAnalyticsDebounceTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: 380_000_000)
            guard !Task.isCancelled else { return }
            await self.applyVenueOwnerRealtimeEngagementRefresh(trackedEventIDs: snapshot)
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
            try await channel.subscribeWithError()
        } catch {
            if venueOwnerAnalyticsRealtimeChannel === channel {
                venueOwnerAnalyticsRealtimeChannel = nil
            }
            return
        }

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                await self.consumeVenueOwnerRealtimeAnyStream(interestStream, trackedEventIDs: ids)
            }
            group.addTask {
                await self.consumeVenueOwnerRealtimeAnyStream(commentsStream, trackedEventIDs: ids)
            }
            group.addTask {
                await self.consumeVenueOwnerRealtimeAnyStream(vibesStream, trackedEventIDs: ids)
            }
        }
    }

    private func consumeVenueOwnerRealtimeAnyStream(_ stream: AsyncStream<AnyAction>, trackedEventIDs: [UUID]) async {
        for await _ in stream {
            guard !Task.isCancelled else { break }
            await MainActor.run {
                self.scheduleDebouncedVenueOwnerAnalyticsRefresh(trackedEventIDs: trackedEventIDs)
            }
        }
    }
}
