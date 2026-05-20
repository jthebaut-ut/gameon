import Foundation

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
        VenueEventPredictionService.shared.invalidate(eventID: eventID)
        await loadVenueEventPredictionSummaries(eventIDs: [eventID], forceRefresh: true)
    }
}
