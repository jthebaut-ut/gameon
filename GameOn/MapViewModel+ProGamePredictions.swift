import Foundation
import Supabase

extension MapViewModel {
    func loadProGamePredictionSummaries(proGameIds: [String], forceRefresh: Bool = false) async {
        let uniqueIDs = Array(Set(proGameIds.filter { !$0.isEmpty }))
        guard !uniqueIDs.isEmpty else { return }
        let summaries = await ProGamePredictionService.shared.fetchPredictionSummary(
            proGameIds: uniqueIDs,
            forceRefresh: forceRefresh
        )
        for (proGameID, summary) in summaries {
            proGamePredictionSummaries[proGameID] = summary
        }
    }

    func refreshProGamePredictionSummary(proGameId: String) async {
        ProGamePredictionService.shared.invalidate(proGameID: proGameId)
        await loadProGamePredictionSummaries(proGameIds: [proGameId], forceRefresh: true)
    }

    func prefetchProGamePredictionSummaries(for games: [SavedProGame]) async {
        let ids = games.filter(\.supportsProGamePredictions).map(\.stableKey)
        guard !ids.isEmpty else { return }
        await loadProGamePredictionSummaries(proGameIds: ids)
    }

    func clearProGamePredictionState(proGameId: String) async {
        await stopProGamePredictionRealtime(for: proGameId)
        proGamePredictionSummaries.removeValue(forKey: proGameId)
        ProGamePredictionService.shared.invalidate(proGameID: proGameId)
    }

    func deleteProGamePredictionsForUnsave(proGameId: String) async {
        do {
            try await ProGamePredictionService.shared.deleteAllPredictionsForUser(proGameId: proGameId)
        } catch {
#if DEBUG
            print("[ProGamePredictionDebug] deleteOnUnsaveFailed id=\(proGameId) error=\(error.localizedDescription)")
#endif
        }
        await clearProGamePredictionState(proGameId: proGameId)
    }

    func startProGamePredictionRealtime(for proGameId: String) async {
        if proGamePredictionRealtimeTasks[proGameId] != nil || proGamePredictionRealtimeChannels[proGameId] != nil {
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            let channel = supabase.channel("pro-game-predictions-\(proGameId)")
            self.proGamePredictionRealtimeChannels[proGameId] = channel
            let changes = channel.postgresChange(
                AnyAction.self,
                schema: "public",
                table: "pro_game_predictions",
                filter: .eq("pro_game_id", value: proGameId)
            )

            do {
                try await channel.subscribeWithError()
                for await _ in changes {
                    if Task.isCancelled { break }
                    self.scheduleProGamePredictionRealtimeRefresh(proGameId: proGameId)
                }
            } catch is CancellationError {
            } catch {
#if DEBUG
                print("[ProGamePredictionDebug] realtimeSubscribeFailed id=\(proGameId) error=\(error.localizedDescription)")
#endif
            }

            self.proGamePredictionRealtimeRefreshTasks[proGameId]?.cancel()
            self.proGamePredictionRealtimeRefreshTasks[proGameId] = nil
            self.proGamePredictionRealtimeTasks[proGameId] = nil
            if self.proGamePredictionRealtimeChannels[proGameId] === channel {
                self.proGamePredictionRealtimeChannels[proGameId] = nil
                await supabase.removeChannel(channel)
            }
        }
        proGamePredictionRealtimeTasks[proGameId] = task
    }

    func stopProGamePredictionRealtime(for proGameId: String) async {
        let task = proGamePredictionRealtimeTasks[proGameId]
        let channel = proGamePredictionRealtimeChannels[proGameId]
        proGamePredictionRealtimeRefreshTasks[proGameId]?.cancel()
        proGamePredictionRealtimeRefreshTasks[proGameId] = nil
        proGamePredictionRealtimeTasks[proGameId] = nil
        proGamePredictionRealtimeChannels[proGameId] = nil
        task?.cancel()
        if let channel {
            await supabase.removeChannel(channel)
        }
    }

    private func scheduleProGamePredictionRealtimeRefresh(proGameId: String) {
        proGamePredictionRealtimeRefreshTasks[proGameId]?.cancel()
        proGamePredictionRealtimeRefreshTasks[proGameId] = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            await self.refreshProGamePredictionSummary(proGameId: proGameId)
            self.proGamePredictionRealtimeRefreshTasks[proGameId] = nil
        }
    }
}
