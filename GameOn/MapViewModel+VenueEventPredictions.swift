import Foundation
import Supabase

extension MapViewModel {
    func loadVenueEventPredictionSummaries(eventIDs: [UUID], forceRefresh: Bool = false) async {
        let uniqueIDs = Array(Set(eventIDs))
        guard !uniqueIDs.isEmpty else { return }
        let summaries = await VenueEventPredictionService.shared.fetchPredictionSummary(
            venueEventIds: uniqueIDs,
            forceRefresh: forceRefresh
        )
        for (eventID, summary) in summaries {
            venueEventPredictionSummaries[eventID] = summary
        }
    }

    func refreshVenueEventPredictionSummary(eventID: UUID) async {
        #if DEBUG
        print("[PredictionRealtimeDebug] aggregateRefreshStarted eventId=\(eventID.uuidString.lowercased())")
        #endif
        VenueEventPredictionService.shared.invalidate(eventID: eventID)
        await loadVenueEventPredictionSummaries(eventIDs: [eventID], forceRefresh: true)
        #if DEBUG
        print("[PredictionRealtimeDebug] aggregateRefreshSucceeded eventId=\(eventID.uuidString.lowercased())")
        #endif
    }

    @MainActor
    func prefetchVenuePredictionSummariesForVisibleBatch(eventIDs: [UUID]) async {
        let uniqueIDs = Array(Set(eventIDs))
        guard !uniqueIDs.isEmpty else { return }
        #if DEBUG
        print("[DiscoverSocialPerf] predictionBatchLoad=true")
        #endif
        await loadVenueEventPredictionSummaries(eventIDs: uniqueIDs)
    }

    func startVenueEventPredictionRealtime(for eventID: UUID) async {
        if venueEventPredictionRealtimeTasks[eventID] != nil || venueEventPredictionRealtimeChannels[eventID] != nil {
            #if DEBUG
            print("[PredictionRealtimeDebug] duplicateSubscriptionSkipped eventId=\(eventID.uuidString.lowercased())")
            #endif
            return
        }

        #if DEBUG
        print("[PredictionRealtimeDebug] subscribe eventId=\(eventID.uuidString.lowercased())")
        #endif

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let channel = supabase.channel("venue-event-predictions-\(eventID.uuidString.lowercased())")
            self.venueEventPredictionRealtimeChannels[eventID] = channel
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "venue_event_predictions",
                filter: .eq("venue_event_id", value: eventID.uuidString.lowercased())
            )

            do {
                try await channel.subscribeWithError()
                for await _ in changes {
                    if Task.isCancelled { break }
                    #if DEBUG
                    print("[PredictionRealtimeDebug] updateReceived eventId=\(eventID.uuidString.lowercased())")
                    #endif
                    self.scheduleVenueEventPredictionRealtimeRefresh(eventID: eventID)
                }
            } catch is CancellationError {
            } catch {
                #if DEBUG
                print("[PredictionRealtimeDebug] subscribeFailed eventId=\(eventID.uuidString.lowercased()) error=\(error.localizedDescription)")
                #endif
            }

            self.venueEventPredictionRealtimeRefreshTasks[eventID]?.cancel()
            self.venueEventPredictionRealtimeRefreshTasks[eventID] = nil
            self.venueEventPredictionRealtimeTasks[eventID] = nil
            if self.venueEventPredictionRealtimeChannels[eventID] === channel {
                self.venueEventPredictionRealtimeChannels[eventID] = nil
                await supabase.removeChannel(channel)
            }
        }
        venueEventPredictionRealtimeTasks[eventID] = task
    }

    func stopVenueEventPredictionRealtime(for eventID: UUID) async {
        let task = venueEventPredictionRealtimeTasks[eventID]
        let channel = venueEventPredictionRealtimeChannels[eventID]
        venueEventPredictionRealtimeRefreshTasks[eventID]?.cancel()
        venueEventPredictionRealtimeRefreshTasks[eventID] = nil
        venueEventPredictionRealtimeTasks[eventID] = nil
        venueEventPredictionRealtimeChannels[eventID] = nil
        task?.cancel()
        if let channel {
            await supabase.removeChannel(channel)
        }
    }

    private func scheduleVenueEventPredictionRealtimeRefresh(eventID: UUID) {
        venueEventPredictionRealtimeRefreshTasks[eventID]?.cancel()
        venueEventPredictionRealtimeRefreshTasks[eventID] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.refreshVenueEventPredictionSummary(eventID: eventID)
            if self.venueEventPredictionRealtimeRefreshTasks[eventID] != nil {
                self.venueEventPredictionRealtimeRefreshTasks[eventID] = nil
            }
        }
    }
}
