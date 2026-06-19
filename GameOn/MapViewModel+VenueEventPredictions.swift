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
            #if DEBUG
            let oldSummary = venueEventPredictionSummaries[eventID]
            print("[RealtimeChainDebug] uiStateUpdated table=venue_event_predictions key=\(eventID.uuidString.lowercased()).totalCount oldValue=\(oldSummary?.totalCount ?? -1) newValue=\(summary.totalCount)")
            print("[RealtimeChainDebug] uiStateUpdated table=venue_event_predictions key=\(eventID.uuidString.lowercased()).winnerPercent oldValue=\(oldSummary?.winnerPercent ?? -1) newValue=\(summary.winnerPercent ?? -1)")
            #endif
            venueEventPredictionSummaries[eventID] = summary
        }
        guard !summaries.isEmpty else { return }
        NotificationCenter.default.post(
            name: .venueEventPredictionSummaryDidChange,
            object: nil,
            userInfo: [VenueEventPredictionSummaryChangeKey.eventIDs: Array(summaries.keys)]
        )
    }

    func refreshVenueEventPredictionSummary(eventID: UUID) async {
        #if DEBUG
        print("[RealtimeChainDebug] refreshStarted table=venue_event_predictions key=\(eventID.uuidString.lowercased())")
        print("[PredictionRealtimeDebug] aggregateRefreshStarted eventId=\(eventID.uuidString.lowercased())")
        #endif
        VenueEventPredictionService.shared.invalidate(eventID: eventID)
        await loadVenueEventPredictionSummaries(eventIDs: [eventID], forceRefresh: true)
        #if DEBUG
        print("[RealtimeChainDebug] refreshSucceeded table=venue_event_predictions key=\(eventID.uuidString.lowercased())")
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
                #if DEBUG
                print("[RealtimePublicationVerify] expected table=venue_event_predictions publication=supabase_realtime migration=20260731_0030")
                print("[RealtimeChainDebug] subscribeRequested table=venue_event_predictions channel=\(channel.topic) filter=venue_event_id.eq.\(eventID.uuidString.lowercased())")
                #endif
                try await channel.subscribeWithError()
                #if DEBUG
                print("[RealtimeChainDebug] subscribeReady table=venue_event_predictions channel=\(channel.topic)")
                #endif
                for await action in changes {
                    if Task.isCancelled { break }
                    #if DEBUG
                    let eventType: String
                    switch action {
                    case .insert: eventType = "insert"
                    case .update: eventType = "update"
                    case .delete: eventType = "delete"
                    }
                    print("[RealtimeChainDebug] eventReceived table=venue_event_predictions eventType=\(eventType) rowId=unknown subscribedEventId=\(eventID.uuidString.lowercased())")
                    print("[RealtimeChainDebug] eventMatchedCurrentView table=venue_event_predictions matched=true key=\(eventID.uuidString.lowercased()) reason=channelFilteredByVenueEventID")
                    print("[PredictionRealtimeDebug] updateReceived eventId=\(eventID.uuidString.lowercased())")
                    #endif
                    self.scheduleVenueEventPredictionRealtimeRefresh(eventID: eventID)
                }
            } catch is CancellationError {
            } catch {
                #if DEBUG
                print("[RealtimeChainDebug] subscribeFailed table=venue_event_predictions error=\(error.localizedDescription)")
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
        #if DEBUG
        print("[RealtimeChainDebug] refreshQueued table=venue_event_predictions reason=realtime_event key=\(eventID.uuidString.lowercased())")
        #endif
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
