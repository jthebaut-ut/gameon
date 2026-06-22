import Foundation
#if canImport(UIKit)
import UIKit
#endif

extension MapViewModel {
    private static let discoverAnnouncementFetchTTL: TimeInterval = 5 * 60
    /// Minimum interval between Discover-tab-visible network refreshes during tab switching.
    private static let discoverAnnouncementTabVisibleMinimumInterval: TimeInterval = 60

    func refreshDiscoverBannerAnnouncement(force: Bool = false) async {
        if let inFlight = discoverAnnouncementFetchTask {
            await inFlight.value
            discoverAnnouncementFetchTask = nil
            if !force {
                return
            }
        }

        if !force,
           let lastDiscoverAnnouncementFetchAt,
           Date().timeIntervalSince(lastDiscoverAnnouncementFetchAt) < Self.discoverAnnouncementFetchTTL {
            applyDiscoverBannerSelectionFromCache()
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.runDiscoverBannerAnnouncementFetch(force: force)
        }
        discoverAnnouncementFetchTask = task
        await task.value
        discoverAnnouncementFetchTask = nil
    }

    @MainActor
    func noteAnnouncementsAppBackgrounded() {
        announcementsAppWasBackgrounded = true
    }

    @MainActor
    func refreshDiscoverBannerAnnouncementOnAppForeground() async {
        await refreshDiscoverBannerAnnouncement(force: true)
        announcementsAppWasBackgrounded = false
    }

    @MainActor
    func refreshDiscoverBannerAnnouncementForDiscoverTabVisible() async {
        if announcementsAppWasBackgrounded {
            await refreshDiscoverBannerAnnouncementFromNetwork(reason: "appForegroundAfterBackground")
            announcementsAppWasBackgrounded = false
            return
        }

        let now = Date()
        let elapsedSinceTabVisibleRefresh = lastDiscoverTabVisibleAnnouncementRefreshAt.map {
            now.timeIntervalSince($0)
        } ?? .infinity

        guard elapsedSinceTabVisibleRefresh >= Self.discoverAnnouncementTabVisibleMinimumInterval else {
            applyDiscoverBannerSelectionFromCache()
#if DEBUG
            print(
                "[AnnouncementDebug] discoverTabRefreshSkipped reason=tabVisibleMinimumInterval " +
                "elapsed=\(Int(elapsedSinceTabVisibleRefresh))s dismissedCached=\(hasLocallyDismissedCachedDiscoverBannerCandidate)"
            )
#endif
            return
        }

        await refreshDiscoverBannerAnnouncementFromNetwork(reason: "discoverTabVisible")
    }

    @MainActor
    func dismissDiscoverBannerAnnouncement(_ announcement: FanGeoAnnouncement) {
        FanGeoAnnouncementDismissStore.dismiss(announcement)
        applyDiscoverBannerSelectionFromCache()
    }

    @MainActor
    func handleDiscoverBannerAnnouncementCTA(
        _ announcement: FanGeoAnnouncement,
        currentTabRaw: String = "discover"
    ) {
        let action = announcement.trimmedCTAAction
        guard !action.isEmpty else { return }

        FanGeoAnnouncementCTAAction.perform(
            action,
            promotedVenueId: announcement.promotedVenueId
        ) { outcome in
            switch outcome {
            case .openExternalURL(let url):
#if canImport(UIKit)
                UIApplication.shared.open(url)
#endif
                dismissDiscoverBannerAnnouncement(announcement)

            case .openVenue(let venueId):
                discoverFocusVenueId = nil
                discoverFocusVenueId = venueId
                if currentTabRaw != "discover" {
                    requestedMainTabRaw = "discover"
                }
                dismissDiscoverBannerAnnouncement(announcement)

            case .navigateToTab(let tabRaw):
                if tabRaw == currentTabRaw {
                    dismissDiscoverBannerAnnouncement(announcement)
                    return
                }
                requestedMainTabRaw = tabRaw
                dismissDiscoverBannerAnnouncement(announcement)
            }
        }
    }

    @MainActor
    func applyDiscoverBannerSelectionFromCache() {
        let isBusiness = isBusinessAudienceForAnnouncements
        let userLocation = announcementUserLocationForGeoTargeting
        var eligible: [FanGeoAnnouncement] = []
        for candidate in cachedDiscoverBannerCandidates {
            let reason = FanGeoAnnouncement.discoverSelectionExclusionReason(
                for: candidate,
                isBusinessUser: isBusiness,
                userLocation: userLocation
            )
#if DEBUG
            FanGeoAnnouncement.logDiscoverAnnouncementEvaluation(
                row: candidate,
                phase: "selection",
                included: reason == nil,
                reason: reason,
                isBusinessUser: isBusiness,
                userLocation: userLocation
            )
#endif
            guard reason == nil else { continue }
            eligible.append(candidate)
        }
        discoverBannerAnnouncements = eligible.sorted(by: FanGeoAnnouncement.discoverCarouselSort)
    }

    var announcementUserLocationForGeoTargeting: FanGeoAnnouncementUserLocation {
        FanGeoAnnouncementUserLocation(
            country: currentUserHomeCountry,
            region: currentUserHomeRegion,
            city: currentUserHomeCity
        )
    }

    var isBusinessAudienceForAnnouncements: Bool {
        currentUserIsBusinessAccount
            || isVenueOwnerLoggedIn
            || hasAuthenticatedVenueOwnerSession
            || venueOwnerMode
    }

    @MainActor
    private func refreshDiscoverBannerAnnouncementFromNetwork(reason: String) async {
        let fetchStartedAt = lastDiscoverAnnouncementFetchAt
        await refreshDiscoverBannerAnnouncement(force: true)
        if lastDiscoverAnnouncementFetchAt != fetchStartedAt {
            lastDiscoverTabVisibleAnnouncementRefreshAt = Date()
        }
#if DEBUG
        print(
            "[AnnouncementDebug] discoverTabNetworkRefresh reason=\(reason) " +
            "networkFetchUpdated=\(lastDiscoverAnnouncementFetchAt != fetchStartedAt)"
        )
#endif
    }

    private var hasLocallyDismissedCachedDiscoverBannerCandidate: Bool {
        cachedDiscoverBannerCandidates.contains { FanGeoAnnouncementDismissStore.isDismissed($0) }
    }

    @MainActor
    private func runDiscoverBannerAnnouncementFetch(force: Bool = false) async {
        let previousCached = cachedDiscoverBannerCandidates
        let previousIDs = Set(previousCached.map(\.id))

        guard let rows = await FanGeoAnnouncementService().fetchDiscoverBannerCandidates() else {
#if DEBUG
            print("[AnnouncementDebug] fetchFailed preservingCachedCount=\(cachedDiscoverBannerCandidates.count) force=\(force)")
#endif
            applyDiscoverBannerSelectionFromCache()
            return
        }

        let newIDs = Set(rows.map(\.id))
        let removedIDs = previousIDs.subtracting(newIDs)
#if DEBUG
        for removedID in removedIDs {
            if let removed = previousCached.first(where: { $0.id == removedID }) {
                FanGeoAnnouncement.logDiscoverAnnouncementEvaluation(
                    row: removed,
                    phase: "cacheExcluded",
                    included: false,
                    reason: "missingFromServer"
                )
            } else {
                print(
                    "[AnnouncementDebug] phase=cacheExcluded included=false reason=missingFromServer " +
                    "id=\(removedID.uuidString.lowercased())"
                )
            }
        }
#endif

        cachedDiscoverBannerCandidates = rows
        lastDiscoverAnnouncementFetchAt = Date()
        pruneSponsoredVenueCache(keepingAnnouncementIDs: newIDs)
        applyDiscoverBannerSelectionFromCache()
        refreshSponsoredPromotedVenueCacheFromLoadedBars()
        prefetchSponsoredPromotedVenuesIfNeeded(for: rows)
#if DEBUG
        let visibleCount = discoverBannerAnnouncements.count
        print(
            "[AnnouncementDebug] fetchComplete cached=\(rows.count) visibleCount=\(visibleCount) " +
            "removedFromCache=\(removedIDs.count) audience=\(isBusinessAudienceForAnnouncements ? "business" : "fan") force=\(force)"
        )
        for (index, announcement) in discoverBannerAnnouncements.enumerated() {
            print(
                "[AnnouncementDebug] carousel[\(index)] id=\(announcement.id.uuidString.lowercased()) " +
                "title=\(announcement.trimmedTitle) sponsored=\(announcement.isSponsoredDiscoverPromotion) " +
                "promotionType=\(announcement.normalizedPromotionType)"
            )
        }
#endif
    }

    @MainActor
    private func pruneSponsoredVenueCache(keepingAnnouncementIDs: Set<UUID>) {
        let keepVenueIDs = Set(
            cachedDiscoverBannerCandidates
                .filter { keepingAnnouncementIDs.contains($0.id) }
                .compactMap(\.promotedVenueId)
        )

        let prunedBars = sponsoredPromotedVenueBarsByID.filter { keepVenueIDs.contains($0.key) }
        if prunedBars.count != sponsoredPromotedVenueBarsByID.count {
            sponsoredPromotedVenueBarsByID = prunedBars
        }

        let prunedLocations = sponsoredPromotedVenueLocationByID.filter { keepVenueIDs.contains($0.key) }
        if prunedLocations.count != sponsoredPromotedVenueLocationByID.count {
            sponsoredPromotedVenueLocationByID = prunedLocations
        }
    }

    var announcementAudienceSelectionKey: String {
        let geo = announcementUserLocationForGeoTargeting.selectionKey
        let audience = isBusinessAudienceForAnnouncements ? "business" : "fan"
        return "\(audience)|\(geo)"
    }

    @MainActor
    func sponsoredAnnouncementChipMetadata(for announcement: FanGeoAnnouncement, now: Date = Date()) -> DiscoverSponsoredAnnouncementChipMetadata {
        guard announcement.isSponsoredDiscoverPromotion else { return .empty }

        refreshSponsoredPromotedVenueCacheFromLoadedBars()

        var eventDate: Date?
        if let venueId = announcement.promotedVenueId {
            eventDate = nextUpcomingVenueEventDate(for: venueId, now: now)
            if let bar = barVenueForPromotedVenueID(venueId) {
                return sponsoredMetadata(from: bar, eventDate: eventDate)
            }
            if let name = venueNameFromEventRows(for: venueId) {
                let resolvedLocation = locationFields(
                    targetCity: announcement.targetCity,
                    targetState: announcement.targetState
                )
                return DiscoverSponsoredAnnouncementChipMetadata(
                    eventDate: eventDate,
                    venueCity: resolvedLocation.city,
                    venueState: resolvedLocation.state,
                    venueAddress: nil,
                    venueName: name
                )
            }
        }

        let resolvedLocation = locationFields(
            targetCity: announcement.targetCity,
            targetState: announcement.targetState
        )
        return DiscoverSponsoredAnnouncementChipMetadata(
            eventDate: eventDate,
            venueCity: resolvedLocation.city,
            venueState: resolvedLocation.state,
            venueAddress: nil,
            venueName: nil
        )
    }

    @MainActor
    func refreshSponsoredPromotedVenueCacheFromLoadedBars() {
        let promotedIDs = Set(
            discoverBannerAnnouncements.compactMap(\.promotedVenueId)
                + cachedDiscoverBannerCandidates.compactMap(\.promotedVenueId)
        )
        guard !promotedIDs.isEmpty else { return }

        var updated = sponsoredPromotedVenueBarsByID
        var updatedLocations = sponsoredPromotedVenueLocationByID
        for venueId in promotedIDs {
            if updated[venueId] == nil, let bar = inMemoryBarMatchingPromotedVenueID(venueId) {
                updated[venueId] = bar
            }
            if updatedLocations[venueId] == nil {
                let bar = updated[venueId] ?? inMemoryBarMatchingPromotedVenueID(venueId)
                if let bar {
                    updatedLocations[venueId] = locationFields(for: bar)
                }
            }
        }
        if updated != sponsoredPromotedVenueBarsByID {
            sponsoredPromotedVenueBarsByID = updated
        }
        if updatedLocations != sponsoredPromotedVenueLocationByID {
            sponsoredPromotedVenueLocationByID = updatedLocations
        }
    }

    @MainActor
    private func prefetchSponsoredPromotedVenuesIfNeeded(for announcements: [FanGeoAnnouncement]) {
        sponsoredPromotedVenuePrefetchTask?.cancel()

        let venueIDs = Set(
            announcements.compactMap { announcement -> UUID? in
                guard announcement.isSponsoredDiscoverPromotion else { return nil }
                return announcement.promotedVenueId
            }
        )
        guard !venueIDs.isEmpty else { return }

        let missingIDs = venueIDs.filter { venueId in
            let hasBar = sponsoredPromotedVenueBarsByID[venueId] != nil || inMemoryBarMatchingPromotedVenueID(venueId) != nil
            let hasLocation = sponsoredPromotedVenueLocationByID[venueId] != nil
            return !hasBar || !hasLocation
        }
        guard !missingIDs.isEmpty else { return }

        sponsoredPromotedVenuePrefetchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var updated = self.sponsoredPromotedVenueBarsByID
            var updatedLocations = self.sponsoredPromotedVenueLocationByID
            for venueId in missingIDs {
                guard !Task.isCancelled else { return }
                if let package = await self.fetchPromotedVenuePackage(id: venueId) {
                    if updated[venueId] == nil {
                        updated[venueId] = package.bar
                    }
                    updatedLocations[venueId] = package.location
                }
            }
            guard !Task.isCancelled else { return }
            if updated != self.sponsoredPromotedVenueBarsByID {
                self.sponsoredPromotedVenueBarsByID = updated
            }
            if updatedLocations != self.sponsoredPromotedVenueLocationByID {
                self.sponsoredPromotedVenueLocationByID = updatedLocations
            }
        }
    }

    @MainActor
    private func fetchPromotedVenuePackage(id: UUID) async -> (bar: BarVenue, location: DiscoverSponsoredVenueLocationFields)? {
        guard let row = await fetchVenueRowByIdForDiscover(id: id) else { return nil }
        let (mapped, _) = DiscoverVenueLoadAssembler.buildMappedBars(venueRows: [row], fetchedVenueEventRows: [])
        guard let bar = mapped.first else { return nil }
        let location = locationFields(
            venueCity: row.city,
            venueState: row.state ?? row.region,
            venueAddress: row.formatted_address ?? row.address ?? bar.address
        )
        return (bar, location)
    }

    @MainActor
    private func locationFields(
        venueCity: String? = nil,
        venueState: String? = nil,
        venueAddress: String? = nil,
        targetCity: String? = nil,
        targetState: String? = nil
    ) -> DiscoverSponsoredVenueLocationFields {
        DiscoverSponsoredAnnouncementChipFormatter.resolveLocationFields(
            venueCity: venueCity,
            venueState: venueState,
            venueAddress: venueAddress,
            targetCity: targetCity,
            targetState: targetState
        )
    }

    @MainActor
    private func locationFields(for bar: BarVenue) -> DiscoverSponsoredVenueLocationFields {
        let cached = sponsoredPromotedVenueLocationByID[bar.id]
        return locationFields(
            venueCity: cached?.city,
            venueState: cached?.state,
            venueAddress: bar.address
        )
    }

    @MainActor
    private func barVenueForPromotedVenueID(_ venueId: UUID) -> BarVenue? {
        if let cached = sponsoredPromotedVenueBarsByID[venueId] {
            return cached
        }
        return inMemoryBarMatchingPromotedVenueID(venueId)
    }

    @MainActor
    private func inMemoryBarMatchingPromotedVenueID(_ venueId: UUID) -> BarVenue? {
        bars.first(where: { $0.id == venueId })
            ?? mapVisibleBars.first(where: { $0.id == venueId })
            ?? filteredBars.first(where: { $0.id == venueId })
    }

    @MainActor
    private func sponsoredMetadata(from bar: BarVenue, eventDate: Date?) -> DiscoverSponsoredAnnouncementChipMetadata {
        let resolvedLocation = locationFields(for: bar)
        let address = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)

        return DiscoverSponsoredAnnouncementChipMetadata(
            eventDate: eventDate,
            venueCity: resolvedLocation.city,
            venueState: resolvedLocation.state,
            venueAddress: address.isEmpty ? nil : address,
            venueName: name.isEmpty ? nil : name,
            venueSecondaryPhotoURL: bar.menuPhotoURL,
            venueSecondaryPhotoThumbnailURL: bar.menuPhotoThumbnailURL
        )
    }

    @MainActor
    private func venueNameFromEventRows(for venueId: UUID) -> String? {
        for row in venueEventRows where row.venue_id == venueId {
            let name = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !name.isEmpty { return name }
        }
        return nil
    }

    @MainActor
    private func nextUpcomingVenueEventDate(for venueId: UUID, now: Date) -> Date? {
        let upcomingDates = venueEventRows.compactMap { row -> Date? in
            guard row.venue_id == venueId else { return nil }
            if let scheduledStart = row.scheduled_start_at?.trimmingCharacters(in: .whitespacesAndNewlines),
               !scheduledStart.isEmpty,
               let parsed = SupabaseTimestampParsing.parseTimestamptz(scheduledStart) {
                return parsed
            }
            if let eventDateRaw = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines),
               !eventDateRaw.isEmpty,
               let parsed = SupabaseTimestampParsing.parseTimestamptz(eventDateRaw) {
                return parsed
            }
            return nil
        }
        .filter { $0 >= now }

        return upcomingDates.min()
    }
}
