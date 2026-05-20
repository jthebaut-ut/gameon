import Foundation

extension MapViewModel {
    @MainActor
    func loadHomeCrowdFromProfile() async {
        guard let authId = currentUserAuthId else {
            currentUserHomeCrowdVenueId = nil
            currentUserHomeCrowdVenue = nil
            return
        }

        let loaded = await HomeCrowdService.loadSelfHomeCrowd(userId: authId)
        currentUserHomeCrowdVenueId = loaded.venueId
        currentUserHomeCrowdVenue = loaded.summary
    }

    func homeCrowdSummary(from bar: BarVenue) -> HomeCrowdVenueSummary {
        let thumb = ImageDisplayURL.canonicalStorageURLString(
            bar.coverPhotoThumbnailURL ?? bar.coverPhotoURL
        )
        return HomeCrowdVenueSummary(
            venueId: bar.id,
            name: bar.name,
            locationLabel: HomeCrowdLocationLabel.from(bar: bar),
            thumbnailURL: thumb.isEmpty ? nil : thumb
        )
    }

    @MainActor
    @discardableResult
    func setMyHomeCrowd(_ bar: BarVenue) async -> String? {
        guard canUseFanSocialFeatures, let _ = currentUserAuthId else {
            return "Sign in as a fan to set your Home Crowd."
        }

        do {
            let summary = try await HomeCrowdService.setMyHomeCrowd(venueId: bar.id)
            currentUserHomeCrowdVenueId = summary.venueId
            currentUserHomeCrowdVenue = summary
            return nil
        } catch {
            return "Couldn't set Home Crowd. Please try again."
        }
    }

    @MainActor
    @discardableResult
    func clearMyHomeCrowd() async -> String? {
        guard currentUserAuthId != nil else { return nil }

        do {
            try await HomeCrowdService.clearMyHomeCrowd()
            currentUserHomeCrowdVenueId = nil
            currentUserHomeCrowdVenue = nil
            return nil
        } catch {
            return "Couldn't remove Home Crowd. Please try again."
        }
    }

    func isHomeCrowdVenue(_ venueId: UUID) -> Bool {
        currentUserHomeCrowdVenueId == venueId
    }

    var hasHomeCrowdElsewhere: Bool {
        currentUserHomeCrowdVenueId != nil
    }

    @MainActor
    func focusDiscoverOnHomeCrowdVenue() {
        guard let venueId = currentUserHomeCrowdVenueId else { return }
        discoverFocusVenueId = venueId
    }
}
