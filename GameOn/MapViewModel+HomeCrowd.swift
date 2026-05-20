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

    func homeCrowdSummary(from bar: BarVenue, setAt: Date = Date()) -> HomeCrowdVenueSummary {
        let thumb = ImageDisplayURL.canonicalStorageURLString(
            bar.coverPhotoThumbnailURL ?? bar.coverPhotoURL
        )
        let priorCount = currentUserHomeCrowdVenue?.fanCount ?? 0
        let optimisticCount = max(1, priorCount == 0 ? 1 : priorCount)
        return HomeCrowdVenueSummary(
            venueId: bar.id,
            name: bar.name,
            locationLabel: HomeCrowdLocationLabel.from(bar: bar),
            thumbnailURL: thumb.isEmpty ? nil : thumb,
            setAtRaw: ISO8601DateFormatter().string(from: setAt),
            fanCount: optimisticCount,
            fanAvatars: currentUserHomeCrowdVenue?.fanAvatars ?? []
        )
    }

    @MainActor
    @discardableResult
    func setMyHomeCrowd(_ bar: BarVenue) async -> String? {
        guard canUseFanSocialFeatures, currentUserAuthId != nil else {
            return "Sign in as a fan to set your Home Crowd."
        }

        let previousId = currentUserHomeCrowdVenueId
        let previousSummary = currentUserHomeCrowdVenue
        let venueId = bar.id
        let optimistic = homeCrowdSummary(from: bar)
        print("[HomeCrowd] optimisticSet venueId=\(venueId.uuidString.lowercased())")
        currentUserHomeCrowdVenueId = venueId
        currentUserHomeCrowdVenue = optimistic

        do {
            let summary = try await HomeCrowdService.setMyHomeCrowd(venueId: venueId)
            currentUserHomeCrowdVenueId = summary.venueId
            currentUserHomeCrowdVenue = summary
            publicProfileHomeCrowdRevision &+= 1
            if let authId = currentUserAuthId {
                _ = await HomeCrowdService.verifySelfHomeCrowdVenueId(userId: authId)
            }
            print("[HomeCrowd] rpcSuccess venueId=\(venueId.uuidString.lowercased())")
            return nil
        } catch {
            let reason = error.localizedDescription
            print("[HomeCrowd] rollback venueId=\(venueId.uuidString.lowercased()) reason=\(reason)")
            currentUserHomeCrowdVenueId = previousId
            currentUserHomeCrowdVenue = previousSummary
            showSocialActionToast("Couldn't update Home Crowd.")
            return "Couldn't update Home Crowd."
        }
    }

    @MainActor
    @discardableResult
    func clearMyHomeCrowd() async -> String? {
        guard currentUserAuthId != nil else { return nil }

        let previousId = currentUserHomeCrowdVenueId
        let previousSummary = currentUserHomeCrowdVenue
        let clearedId = previousId?.uuidString.lowercased() ?? "nil"
        print("[HomeCrowd] optimisticClear venueId=\(clearedId)")
        currentUserHomeCrowdVenueId = nil
        currentUserHomeCrowdVenue = nil

        do {
            try await HomeCrowdService.clearMyHomeCrowd()
            publicProfileHomeCrowdRevision &+= 1
            print("[HomeCrowd] rpcSuccess venueId=cleared")
            return nil
        } catch {
            let reason = error.localizedDescription
            print("[HomeCrowd] rollback venueId=\(clearedId) reason=\(reason)")
            currentUserHomeCrowdVenueId = previousId
            currentUserHomeCrowdVenue = previousSummary
            showSocialActionToast("Couldn't update Home Crowd.")
            return "Couldn't update Home Crowd."
        }
    }

    /// Hero quick toggle: set this venue (replacing any prior) or clear when already selected.
    @MainActor
    func toggleHomeCrowd(for bar: BarVenue) async {
        guard canUseFanSocialFeatures else {
            showSocialActionToast("Sign in as a fan to set your Home Crowd.")
            return
        }

        let venueId = bar.id
        let wasSelected = currentUserHomeCrowdVenueId == venueId
        print("[HomeCrowd] toggleTap venueId=\(venueId.uuidString.lowercased()) selected=\(!wasSelected)")

        if wasSelected {
            _ = await clearMyHomeCrowd()
        } else {
            _ = await setMyHomeCrowd(bar)
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

    @MainActor
    func openDiscoverToChooseHomeCrowd() {
        requestDiscoverTabForHomeCrowd = true
    }
}
