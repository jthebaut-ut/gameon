import CoreLocation
import Foundation
import Supabase

private enum DiscoverVenueGameDateFormatting {
    static let sqlDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = TimeZone.current
        return f
    }()
}

private let discoverVenueBusinessEmbedSelectSuffix =
    ",businesses!venues_business_id_fkey(owner_email,admin_status)"

private let discoverVenueRowSelectColumns =
    "id,owner_email,business_id,venue_identity_key,origin_type,admin_status,supporter_country,venue_name,address,address_line1,address_line2,city,state,zip_code,region,postal_code,country,formatted_address,phone,website,description,features," +
    "screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,latitude,longitude," +
    "cover_photo_url,menu_photo_url,cover_photo_thumbnail_url,menu_photo_thumbnail_url" +
    discoverVenueBusinessEmbedSelectSuffix

private enum DiscoverVenueFastPinSelect {
    nonisolated static let columns =
        "id,venue_name,address,address_line1,address_line2,city,state,zip_code,region,postal_code,country,formatted_address,latitude,longitude,owner_email,business_id,origin_type,admin_status,supporter_country,features,screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,venue_identity_key,cover_photo_url,menu_photo_url,cover_photo_thumbnail_url,menu_photo_thumbnail_url" +
        ",businesses!venues_business_id_fkey(owner_email,admin_status)"
}

private let discoverVenueActiveLegacySafeOrFilter = "admin_status.is.null,admin_status.eq.active"

private enum DiscoverVenueFastPinFallback {
    static let radiusMiles = 35.0
    static let defaultCenter = CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508)
}

private enum DiscoverViewportVenueCacheConfig {
    static let ttl: TimeInterval = 90
    static let maxEntries = 6
    static let expansionFactor = 1.35
}

private enum DiscoverCalendarDotCacheConfig {
    static let ttl: TimeInterval = 120
    static let maxEntries = 18
}

private struct GameonCalendarDotRPCParams: Encodable {
    let p_date_min: String
    let p_date_max: String
    let p_sport: String
    let p_venue_ids: [UUID]?
    let p_owner_emails: [String]?
    let p_venue_names: [String]?
    let p_region_only: Bool
}

private struct GameonCalendarDotRPCRow: Decodable {
    let event_date: String
}

/// Broader map bounds when the visible viewport text search returns no rows (Utah / project default area).
private enum DiscoverVenueSearchFallbackBounds {
    static let minLat = 36.95
    static let maxLat = 42.05
    static let minLon = -114.35
    static let maxLon = -109.0
}

// MARK: - Discover disk snapshot (venues + venue_events + merged events for instant map/calendar)

nonisolated private struct DiscoverPersistedBarVenue: Codable {
    let id: UUID
    let name: String
    let address: String
    let phone: String
    let primarySport: String
    let distance: String
    let rating: Double
    let tags: [String]
    let games: [String]
    let latitude: Double
    let longitude: Double
    let goingCounts: [String: Int]
    let screenCount: Int?
    let servesFood: Bool?
    let hasWifi: Bool?
    let hasGarden: Bool?
    let hasProjector: Bool?
    let petFriendly: Bool?
    let rawVenueFeatures: String?
    let coverPhotoURL: String?
    let menuPhotoURL: String?
    let coverPhotoThumbnailURL: String?
    let menuPhotoThumbnailURL: String?
    let ownerEmail: String?
    let businessId: UUID?
    let adminStatus: String?
    let venueOwnerEmailRaw: String?
    let businessOwnerEmailRaw: String?
    let contactEmailRaw: String?
    let supporterCountry: String?
    let originType: String?

    init(bar: BarVenue) {
        id = bar.id
        name = bar.name
        address = bar.address
        phone = bar.phone
        primarySport = bar.primarySport
        distance = bar.distance
        rating = bar.rating
        tags = bar.tags
        games = bar.games
        latitude = bar.coordinate.latitude
        longitude = bar.coordinate.longitude
        goingCounts = bar.goingCounts
        screenCount = bar.screenCount
        servesFood = bar.servesFood
        hasWifi = bar.hasWifi
        hasGarden = bar.hasGarden
        hasProjector = bar.hasProjector
        petFriendly = bar.petFriendly
        rawVenueFeatures = bar.rawVenueFeatures
        coverPhotoURL = bar.coverPhotoURL
        menuPhotoURL = bar.menuPhotoURL
        coverPhotoThumbnailURL = bar.coverPhotoThumbnailURL
        menuPhotoThumbnailURL = bar.menuPhotoThumbnailURL
        ownerEmail = bar.ownerEmail
        businessId = bar.businessId
        adminStatus = bar.adminStatus
        venueOwnerEmailRaw = bar.venueOwnerEmailRaw
        businessOwnerEmailRaw = bar.businessOwnerEmailRaw
        contactEmailRaw = bar.contactEmailRaw
        supporterCountry = bar.supporterCountry
        originType = bar.originType
    }

    func toBarVenue() -> BarVenue {
        BarVenue(
            id: id,
            name: name,
            address: address,
            phone: phone,
            primarySport: primarySport,
            distance: distance,
            rating: rating,
            tags: tags,
            games: games,
            coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
            goingCounts: goingCounts,
            screenCount: screenCount,
            servesFood: servesFood,
            hasWifi: hasWifi,
            hasGarden: hasGarden,
            hasProjector: hasProjector,
            petFriendly: petFriendly,
            rawVenueFeatures: rawVenueFeatures,
            coverPhotoURL: coverPhotoURL,
            menuPhotoURL: menuPhotoURL,
            coverPhotoThumbnailURL: coverPhotoThumbnailURL,
            menuPhotoThumbnailURL: menuPhotoThumbnailURL,
            ownerEmail: ownerEmail,
            businessId: businessId,
            adminStatus: adminStatus,
            venueOwnerEmailRaw: venueOwnerEmailRaw,
            businessOwnerEmailRaw: businessOwnerEmailRaw,
            contactEmailRaw: contactEmailRaw,
            supporterCountry: supporterCountry,
            originType: originType
        )
    }
}

nonisolated private struct DiscoverCoreDiskSnapshot: Codable {
    var savedAt: Date
    var bars: [DiscoverPersistedBarVenue]
    var venueEventRows: [VenueEventRow]
    var events: [SportsEvent]
}

private struct DiscoverVisibleVenueContext {
    let venueRows: [VenueRow]
    let venueIds: [UUID]
    let ownerEmails: [String]
    let venueNames: [String]
    let querySource: String
}

private extension MapViewModel {

    /// When a venue owner is signed in, include their managed venue id / email / name in Discover fetches even if that venue is outside the current map viewport or still loading in phase 1.
    func augmentDiscoverVisibleVenueContextForOwnerSession(_ base: DiscoverVisibleVenueContext) -> DiscoverVisibleVenueContext {
        guard hasAuthenticatedVenueOwnerSession else {
#if DEBUG
            print("[DiscoverVisibilityDebug] owner context augment skipped (no owner session)")
#endif
            return base
        }
        let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(email) else {
#if DEBUG
            print("[DiscoverVisibilityDebug] owner context augment skipped (invalid owner email)")
#endif
            return base
        }

        var venueIds = base.venueIds
        var ownerEmails = base.ownerEmails
        var venueNames = base.venueNames

        if !ownerEmails.contains(where: { OwnerBusinessEmail.normalized($0) == email }) {
            ownerEmails.append(email)
#if DEBUG
            print("[DiscoverVisibilityDebug] owner context augment added owner_email=\(email)")
#endif
        }

        if let vid = ownerVenueDatabaseId, !venueIds.contains(vid) {
            venueIds.append(vid)
#if DEBUG
            print("[DiscoverVisibilityDebug] owner context augment added venue_id=\(vid.uuidString)")
#endif
        }

        let nm = ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !nm.isEmpty, !venueNames.contains(where: { $0.caseInsensitiveCompare(nm) == .orderedSame }) {
            venueNames.append(nm)
#if DEBUG
            print("[DiscoverVisibilityDebug] owner context augment added venue_name=\(nm)")
#endif
        }

        return DiscoverVisibleVenueContext(
            venueRows: base.venueRows,
            venueIds: venueIds,
            ownerEmails: ownerEmails,
            venueNames: venueNames,
            querySource: base.querySource
        )
    }

    func updateSelectedVenuePhotoStateFromLoadedBars(_ loadedBars: [BarVenue]) {
        guard let selected = selectedBar,
              let refreshed = loadedBars.first(where: { $0.id == selected.id }) else { return }
        selectVenueForPreview(refreshed, source: "loadedBarsSelectedVenueRefresh")
    }

    func invalidateDiscoverImageCacheForChangedVenuePhotos(newBars: [BarVenue]) async {
        var previousById: [UUID: BarVenue] = [:]
        for bar in bars {
            previousById[bar.id] = bar
        }
        var urlsToInvalidate: [URL] = []
        for newBar in newBars {
            guard let oldBar = previousById[newBar.id] else { continue }
            let oldURLs = [
                oldBar.coverPhotoURL,
                oldBar.coverPhotoThumbnailURL,
                oldBar.menuPhotoURL,
                oldBar.menuPhotoThumbnailURL
            ]
            let newURLs = [
                newBar.coverPhotoURL,
                newBar.coverPhotoThumbnailURL,
                newBar.menuPhotoURL,
                newBar.menuPhotoThumbnailURL
            ]
            guard oldURLs != newURLs else { continue }
            urlsToInvalidate.append(contentsOf: (oldURLs + newURLs).compactMap { raw in
                guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
                return URL(string: trimmed)
            })
        }
        guard !urlsToInvalidate.isEmpty else { return }
        await DiscoverMapImageCache.shared.invalidate(urls: urlsToInvalidate)
#if DEBUG
        print("[VenuePhotoDisplayDebug] cacheInvalidatedForPhotoChange=true")
#endif
    }

    /// Fetches the signed-in owner's managed venue row when it is not already in the viewport batch (e.g. new venue or null coordinates excluded from SQL bounds).
    func mergeManagedVenueRowForOwnerDiscoverIfNeeded(into rows: [VenueRow]) async throws -> [VenueRow] {
        guard hasAuthenticatedVenueOwnerSession, let vid = ownerVenueDatabaseId else { return rows }
        if rows.contains(where: { $0.id == vid }) { return rows }

        let extra: [VenueRow] = try await supabase
            .from("venues")
            .select(DiscoverVenueFastPinSelect.columns)
            .eq("id", value: vid.uuidString.lowercased())
            .or(discoverVenueActiveLegacySafeOrFilter)
            .limit(1)
            .execute()
            .value

        guard let row = extra.first else {
#if DEBUG
            print("[DiscoverVisibilityDebug] mergeManagedVenueRow: no DB row for ownerVenueDatabaseId=\(vid.uuidString)")
#endif
            return rows
        }

#if DEBUG
        let nm = row.venue_name ?? "?"
        print("[DiscoverVisibilityDebug] mergeManagedVenueRow appended venue=\(nm) id=\(vid.uuidString) lat=\(row.latitude.map(String.init(describing:)) ?? "nil") lon=\(row.longitude.map(String.init(describing:)) ?? "nil")")
#endif
        return rows + [row]
    }

    #if DEBUG
    private func discoverDebugLogPublicVenueRowsForDiscover(_ rows: [VenueRow], window: DiscoverMapBoundsWindow) {
        for row in rows {
            let idStr = row.id?.uuidString ?? "nil"
            let nm = (row.venue_name ?? "").replacingOccurrences(of: "\n", with: " ")
            let la = row.latitude.map { String($0) } ?? "nil"
            let lo = row.longitude.map { String($0) } ?? "nil"
            let adm = row.admin_status ?? "nil"
            let included: String
            if let la = row.latitude, let lo = row.longitude,
               la >= window.minLat, la <= window.maxLat,
               lo >= window.minLon, lo <= window.maxLon {
                included = "yes"
            } else {
                included = "no"
            }
            print("[DiscoverVenuePublic] venue_name=\(nm) id=\(idStr) latitude=\(la) longitude=\(lo) admin_status=\(adm) includedInDiscover=\(included)")
        }
    }
    #endif

    /// `venue_events` on the selected day can reference `venue_id` rows that are still missing from viewport `venues` (null coordinates excluded from bounds SQL).
    private func discoverSupplementVenueIdsFromSelectedDayEvents(
        selectedDay: String,
        sport: String,
        existingVenueIds: Set<UUID>
    ) async throws -> [UUID] {
        struct VenueIdEventRow: Decodable {
            let venue_id: UUID?
        }

        var q = supabase
            .from("venue_events")
            .select("venue_id")
            .eq("event_date", value: selectedDay)
            .eq("admin_status", value: "active")
        if sport != "All" {
            q = q.eq("sport", value: sport)
        }
        let rows: [VenueIdEventRow] = try await q.limit(500).execute().value
        var out: [UUID] = []
        var seen = existingVenueIds
        for r in rows {
            guard let v = r.venue_id, !seen.contains(v) else { continue }
            seen.insert(v)
            out.append(v)
            if out.count >= 150 { break }
        }
        return out
    }

    /// Persist geocoded coordinates for the signed-in owner's managed venues missing DB lat/lon (guest Discover uses real coordinates only).
    private func backfillOwnedVenueCoordinatesInDiscoverVenueRows(_ rows: [VenueRow]) async -> Set<UUID> {
        guard hasAuthenticatedVenueOwnerSession else { return Set() }
        let owner = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(owner) else { return Set() }

        var patched: Set<UUID> = []
        for row in rows {
            guard let vid = row.id else { continue }
            guard row.latitude == nil || row.longitude == nil else { continue }
            let rowOwner = OwnerBusinessEmail.normalized(row.owner_email ?? "")
            guard rowOwner == owner || vid == ownerVenueDatabaseId else { continue }
            let addr = BusinessVenueAddressFormatter.geocodeQuery(
                line1: row.address ?? "",
                line2: row.address_line2 ?? "",
                locality: row.city ?? "",
                region: row.state ?? "",
                postalCode: row.zip_code ?? "",
                countryCode: row.country ?? BusinessLocationCountryPolicy.defaultCountryCode
            )
            guard !addr.isEmpty else { continue }
            guard let coord = await geocodeAddress(addr) else { continue }
            do {
                try await supabase
                    .from("venues")
                    .update(VenueCoordinatesPatch(latitude: coord.latitude, longitude: coord.longitude))
                    .eq("id", value: vid.uuidString.lowercased())
                    .execute()
                patched.insert(vid)
#if DEBUG
                print("[VenueCoordBackfill] discover load saved id=\(vid.uuidString.lowercased()) lat=\(coord.latitude) lon=\(coord.longitude)")
#endif
            } catch {
#if DEBUG
                print("[VenueCoordBackfill] discover load update failed id=\(vid.uuidString):", error)
#endif
            }
        }
        return patched
    }

    private func refreshDiscoverVenueRowsByIds(_ rows: [VenueRow], ids: Set<UUID>) async throws -> [VenueRow] {
        guard !ids.isEmpty else { return rows }
        let idStrings = ids.map { $0.uuidString.lowercased() }
        let fresh: [VenueRow] = try await supabase
            .from("venues")
            .select(DiscoverVenueFastPinSelect.columns)
            .in("id", values: idStrings)
            .or(discoverVenueActiveLegacySafeOrFilter)
            .limit(max(200, idStrings.count))
            .execute()
            .value
        let freshById = Dictionary(uniqueKeysWithValues: fresh.compactMap { r -> (UUID, VenueRow)? in
            guard let id = r.id else { return nil }
            return (id, r)
        })
        return rows.map { row in
            guard let id = row.id, let repl = freshById[id] else { return row }
            return repl
        }
    }

    /// Text search fallback: active venues whose name matches but `latitude` is still null (geocode not written yet).
    func fetchDiscoverVenueRowsNullLatitudeMatchingText(token: String, limit: Int) async throws -> [VenueRow] {
        let trimmed = String(token.prefix(72))
        guard trimmed.count >= 2 else { return [] }
        let pattern = "%\(trimmed)%"
        return try await supabase
            .from("venues")
            .select(discoverVenueRowSelectColumns)
            .or(discoverVenueActiveLegacySafeOrFilter)
            .is("latitude", value: nil)
            .ilike("venue_name", pattern: pattern)
            .limit(limit)
            .execute()
            .value
    }
}

extension MapViewModel {

    func refreshDiscoverPublicVisibilityAfterApprovedVenueStatusChange() async {
        await refreshDiscoverAfterApprovedVenueStatusChange()
    }

    nonisolated private static func discoverCoreSnapshotFileURL() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("gameon_discover_core_snapshot_v2_admin_active.json", isDirectory: false)
    }

    /// Disk read + JSON decode off the main actor; returns `nil` when missing, invalid, or empty bars.
    nonisolated private static func decodeDiscoverCoreDiskSnapshotIfPresent() -> DiscoverCoreDiskSnapshot? {
        let url = discoverCoreSnapshotFileURL()
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let snap = try? decoder.decode(DiscoverCoreDiskSnapshot.self, from: data),
              !snap.bars.isEmpty else {
            return nil
        }
        return snap
    }

    func renderCachedDiscoverCore() async {
        let t0 = Date()
        discoverSnapshotRestoredThisLaunch = false
        let snap = await Task.detached(priority: .userInitiated) {
            MapViewModel.decodeDiscoverCoreDiskSnapshotIfPresent()
        }.value
        guard let snap else {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[CriticalPath] cached core rendered ms=\(ms) bars=0 (no snapshot / decode failed)")
            #endif
            return
        }
        applyRestoredDiscoverCoreSnapshot(snap, deferRecomputeCalendarDotDates: true)
        discoverSnapshotRestoredThisLaunch = true
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[CriticalPath] cached core rendered ms=\(ms) bars=\(bars.count) events=\(events.count)")
        #endif
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            self.recomputeCalendarDotDates()
        }
    }

    private func applyRestoredDiscoverCoreSnapshot(
        _ snap: DiscoverCoreDiskSnapshot,
        deferRecomputeCalendarDotDates: Bool = false
    ) {
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
        discoverVenueEventsFetchCache = nil
        discoverSelectedDayVenueEventsCache = [:]
        discoverCurrentVisibleVenueRows = []
        discoverCurrentVisibleVenueIds = []
        discoverCurrentVisibleOwnerEmails = []
        discoverCurrentVisibleVenueNames = []

        let mapped = snap.bars.map { $0.toBarVenue() }
        if SampleData.includeSampleData {
            bars = mapped + SampleData.bars
        } else {
            bars = mapped
        }
        venueEventRows = snap.venueEventRows
        rebuildVenueEventIDsByKey(from: snap.venueEventRows)
        flushDiscoverMapRenderSnapshotRebuild(reason: "restoredDiscoverCoreSnapshot")

        events = snap.events
        bumpScheduleDataGeneration()
        if !deferRecomputeCalendarDotDates {
            recomputeCalendarDotDates()
        }
        pruneSelectionIfNeededAfterFilterChange()
    }

    func persistDiscoverCoreSnapshot() {
        guard !bars.isEmpty else { return }
        let snap = DiscoverCoreDiskSnapshot(
            savedAt: Date(),
            bars: bars.map { DiscoverPersistedBarVenue(bar: $0) },
            venueEventRows: venueEventRows,
            events: events
        )
        let url = Self.discoverCoreSnapshotFileURL()
        let dataToWrite: Data
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .deferredToDate
            dataToWrite = try enc.encode(snap)
        } catch {
            #if DEBUG
            print("[CriticalPath] discover snapshot encode failed:", error)
            #endif
            return
        }
        Task.detached(priority: .utility) {
            do {
                try dataToWrite.write(to: url, options: .atomic)
            } catch {
                #if DEBUG
                print("[CriticalPath] discover snapshot save failed:", error)
                #endif
            }
        }
    }

    /// Fast pins first, selected-day venue events second, then heavier enrichment in the background.
    func refreshDiscoverCoreInBackground(forceVenueRefresh: Bool = false) async {
        let t0 = Date()
        #if DEBUG
        print("[PerfPhase1D] discoverCriticalPathPreserved=true")
        print("[Perf] Discover startup begin forceVenueRefresh=\(forceVenueRefresh)")
        #endif
        await loadVenuesFromSupabase(forceRefresh: forceVenueRefresh)
        scheduleDiscoverFullEnrichmentInBackground()
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[CriticalPath] fresh core visible ms=\(ms) bars=\(bars.count) events=\(events.count)")
        if startupDiscoverPreloadCompletionLogPending {
            startupDiscoverPreloadCompletionLogPending = false
            print("[StartupDiscover] preloadCompleted venues=\(bars.count) events=\(events.count)")
        }
        #endif
    }

    private func boundsWindow(
        from bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    ) -> DiscoverMapBoundsWindow {
        DiscoverMapBoundsWindow(
            minLat: bounds.minLat,
            maxLat: bounds.maxLat,
            minLon: bounds.minLon,
            maxLon: bounds.maxLon
        )
    }

    private func expandedViewportBounds(for bounds: DiscoverMapBoundsWindow) -> DiscoverMapBoundsWindow {
        let latHalf = max(bounds.latSpan / 2, 0.01) * DiscoverViewportVenueCacheConfig.expansionFactor
        let lonHalf = max(bounds.lonSpan / 2, 0.01) * DiscoverViewportVenueCacheConfig.expansionFactor
        return DiscoverMapBoundsWindow(
            minLat: max(bounds.centerLat - latHalf, -90),
            maxLat: min(bounds.centerLat + latHalf, 90),
            minLon: max(bounds.centerLon - lonHalf, -180),
            maxLon: min(bounds.centerLon + lonHalf, 180)
        )
    }

    private func discoverViewportVenueCacheKey(
        for coverageBounds: DiscoverMapBoundsWindow,
        source: String
    ) -> String {
        String(
            format: "%@|c:%.3f,%.3f|s:%.3f,%.3f",
            source,
            coverageBounds.centerLat,
            coverageBounds.centerLon,
            coverageBounds.latSpan,
            coverageBounds.lonSpan
        )
    }

    private func filterVenueRows(
        _ rows: [VenueRow],
        within bounds: DiscoverMapBoundsWindow
    ) -> [VenueRow] {
        rows.filter { row in
            guard let latitude = row.latitude, let longitude = row.longitude else { return false }
            return latitude >= bounds.minLat
                && latitude <= bounds.maxLat
                && longitude >= bounds.minLon
                && longitude <= bounds.maxLon
        }
    }

    private func pruneDiscoverViewportVenueRowsCacheIfNeeded() {
        guard discoverViewportVenueRowsCache.count > DiscoverViewportVenueCacheConfig.maxEntries else { return }
        let sorted = discoverViewportVenueRowsCache
            .map { ($0.key, $0.value.fetchedAt) }
            .sorted { $0.1 < $1.1 }
        let dropCount = discoverViewportVenueRowsCache.count - DiscoverViewportVenueCacheConfig.maxEntries
        guard dropCount > 0 else { return }
        for index in 0..<dropCount {
            discoverViewportVenueRowsCache.removeValue(forKey: sorted[index].0)
        }
    }

    func invalidateDiscoverVisibilityCachesAfterApprovedVenueRefresh() {
        discoverViewportVenueRowsCache.removeAll()
        discoverVenueEventsFetchCache = nil
        discoverSelectedDayVenueEventsCache.removeAll()
        venueGameCalendarDotDatesCache.removeAll()
        discoverCurrentVisibleVenueRows = []
        discoverCurrentVisibleVenueIds = []
        discoverCurrentVisibleOwnerEmails = []
        discoverCurrentVisibleVenueNames = []
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
        discoverSearchDebounceTask?.cancel()
        discoverSearchDebounceTask = nil
        venueSearchResults = []
        debouncedDiscoverSearchText = ""
#if DEBUG
        print("[ApprovedVenueVisibilityDebug] discoverCacheInvalidatedAfterApproval=true")
        print("[ApprovedVenueVisibilityDebug] searchCacheInvalidatedAfterApproval=true")
#endif
    }

    func refreshDiscoverAfterApprovedVenueStatusChange() async {
        invalidateDiscoverVisibilityCachesAfterApprovedVenueRefresh()
        await loadVenuesFromSupabase(forceRefresh: true)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            scheduleDiscoverSearchDebounce()
        }
    }

    private func discoverGamesDateLowerString(daysBack: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        return DiscoverVenueGameDateFormatting.sqlDate.string(from: d)
    }

    private func discoverGamesDateUpperString(daysForward: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: daysForward, to: Date()) ?? Date()
        return DiscoverVenueGameDateFormatting.sqlDate.string(from: d)
    }

    private func discoverCalendarDotRange(
        around month: Date
    ) -> (monthStart: Date, dateMin: Date, dateMax: Date) {
        let cal = Calendar.current
        let monthStart = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let previousMonthStart = cal.date(byAdding: .month, value: -1, to: monthStart) ?? monthStart
        let nextMonthStart = cal.date(byAdding: .month, value: 2, to: monthStart) ?? monthStart
        let dateMax = cal.date(byAdding: .day, value: -1, to: nextMonthStart) ?? monthStart
        let rawDateMin = cal.startOfDay(for: previousMonthStart)
        let todayStart = cal.startOfDay(for: Date())
        let dateMin = max(rawDateMin, todayStart)
        #if DEBUG
        if rawDateMin < todayStart {
            print("[CalendarDotsPerf] past range trimmed start=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: rawDateMin))")
        }
        #endif
        return (
            monthStart: monthStart,
            dateMin: dateMin,
            dateMax: cal.startOfDay(for: dateMax)
        )
    }

    private func discoverCalendarDotCacheKey(
        monthStart: Date,
        dateMin: Date,
        dateMax: Date,
        sport: String,
        venueIds: [UUID],
        ownerEmails: [String],
        venueNames: [String]
    ) -> String {
        let fmt = DiscoverVenueGameDateFormatting.sqlDate
        let idTag = venueIds.map(\.uuidString).sorted().joined(separator: ",").prefix(320)
        let ownerTag = ownerEmails.sorted().joined(separator: ",").prefix(180)
        let nameTag = venueNames.sorted().joined(separator: ",").prefix(180)
        return "m:\(fmt.string(from: monthStart))|r:\(fmt.string(from: dateMin))...\(fmt.string(from: dateMax))|s:\(sport)|vid:\(venueIds.count):\(idTag)|o:\(ownerEmails.count):\(ownerTag)|v:\(venueNames.count):\(nameTag)"
    }

    private func pickupGameCalendarDotCacheKey(
        monthStart: Date,
        dateMin: Date,
        dateMax: Date,
        sport: String
    ) -> String {
        let fmt = DiscoverVenueGameDateFormatting.sqlDate
        return "p:\(fmt.string(from: monthStart))|r:\(fmt.string(from: dateMin))...\(fmt.string(from: dateMax))|s:\(sport)"
    }

    /// Start-of-day normalized dates inside the Discover calendar-dot fetch window (inclusive).
    private func discoverCalendarDotDatesInFetchWindow(_ dates: Set<Date>, dateMin: Date, dateMax: Date) -> Set<Date> {
        let cal = Calendar.current
        let lo = cal.startOfDay(for: dateMin)
        let hi = cal.startOfDay(for: dateMax)
        var out: Set<Date> = []
        out.reserveCapacity(min(dates.count, 64))
        for d in dates {
            let s = cal.startOfDay(for: d)
            if s >= lo, s <= hi {
                out.insert(s)
            }
        }
        return out
    }

    private func pruneVenueGameCalendarDotDatesCacheIfNeeded() {
        guard venueGameCalendarDotDatesCache.count > DiscoverCalendarDotCacheConfig.maxEntries else { return }
        let sorted = venueGameCalendarDotDatesCache
            .map { ($0.key, $0.value.fetchedAt) }
            .sorted { $0.1 < $1.1 }
        let drop = venueGameCalendarDotDatesCache.count - DiscoverCalendarDotCacheConfig.maxEntries
        guard drop > 0 else { return }
        for index in 0..<drop {
            venueGameCalendarDotDatesCache.removeValue(forKey: sorted[index].0)
        }
    }

    private func prunePickupGameCalendarDotDatesCacheIfNeeded() {
        guard pickupGameCalendarDotDatesCache.count > DiscoverCalendarDotCacheConfig.maxEntries else { return }
        let sorted = pickupGameCalendarDotDatesCache
            .map { ($0.key, $0.value.fetchedAt) }
            .sorted { $0.1 < $1.1 }
        let drop = pickupGameCalendarDotDatesCache.count - DiscoverCalendarDotCacheConfig.maxEntries
        guard drop > 0 else { return }
        for index in 0..<drop {
            pickupGameCalendarDotDatesCache.removeValue(forKey: sorted[index].0)
        }
    }

    /// Calendar-dot RPC uses ``discoverCurrentVisibleVenue*`` (viewport-scoped). After a disk snapshot restore those arrays are cleared while ``bars`` / ``mapVisibleBars`` still show pins, so Discover’s calendar would load no dots until a full venue pass — use map bars as RPC scope for guests and snapshot-first launches.
    private func effectiveVenueCalendarDotRPCInputs() -> (venueIds: [UUID], ownerEmails: [String], venueNames: [String]) {
        let visIds = discoverCurrentVisibleVenueIds
        let visEmails = discoverCurrentVisibleOwnerEmails
        let visNames = discoverCurrentVisibleVenueNames
        if !visIds.isEmpty || !visEmails.isEmpty || !visNames.isEmpty {
            return (visIds, visEmails, visNames)
        }
        let basis = mapVisibleBars.isEmpty ? bars : mapVisibleBars
        guard !basis.isEmpty else { return ([], [], []) }
        var seen = Set<UUID>()
        var ids: [UUID] = []
        ids.reserveCapacity(basis.count)
        for b in basis where seen.insert(b.id).inserted {
            ids.append(b.id)
        }
        let emails = Array(
            Set(
                basis
                    .compactMap(\.ownerEmail)
                    .map { OwnerBusinessEmail.normalized($0) }
                    .filter { OwnerBusinessEmail.isValidStrict($0) }
            )
        ).sorted()
        let names = Array(
            Set(
                basis.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            )
        ).sorted()
        return (ids, emails, names)
    }

    /// Public ``venue_events`` rows already on device (Discover load or snapshot), scoped by calendar window and optional venue allowlist.
    private func discoverVenueCalendarDotDatesFromVenueEventsInRange(
        dateMin: Date,
        dateMax: Date,
        sport: String,
        venueIds: [UUID],
        venueNames: [String]
    ) -> Set<Date> {
        let cal = Calendar.current
        let fmt = DiscoverVenueGameDateFormatting.sqlDate
        let dMin = cal.startOfDay(for: dateMin)
        let dMax = cal.startOfDay(for: dateMax)
        let idFilter = Set(venueIds)
        let loweredNames = Set(venueNames.map { $0.lowercased() })
        let filterVenues = !idFilter.isEmpty || !loweredNames.isEmpty
        let sportFilter = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        var out = Set<Date>()
        for row in venueEventRows {
            if let adm = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               adm == "cancelled" || adm == "rejected" {
                continue
            }
            if sportFilter != "All" {
                let rs = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard rs == sportFilter else { continue }
            }
            guard let raw = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines), raw.count >= 10 else { continue }
            let ymd = String(raw.prefix(10))
            guard let dayDate = fmt.date(from: ymd) else { continue }
            let day = cal.startOfDay(for: dayDate)
            guard day >= dMin && day <= dMax else { continue }
            if filterVenues {
                var ok = false
                if let vid = row.venue_id, idFilter.contains(vid) { ok = true }
                if !ok {
                    let vn = (row.venue_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                    if !vn.isEmpty, loweredNames.contains(vn) { ok = true }
                }
                guard ok else { continue }
            }
            out.insert(day)
        }
        return out
    }

    /// Selected-day pickup rows already on the map can still imply a dot on that day when the broader Supabase dot query returns nothing (e.g. RLS nuance).
    private func discoverPickupCalendarDotDatesFromLoadedPickupRows(
        dateMin: Date,
        dateMax: Date,
        sport: String
    ) -> Set<Date> {
        let cal = Calendar.current
        let dMin = cal.startOfDay(for: dateMin)
        let dMax = cal.startOfDay(for: dateMax)
        let sportFilter = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let now = Date()
        var out = Set<Date>()
        for row in pickupGamesForDiscoverMap {
            if sportFilter != "All", row.sport != sportFilter { continue }
            guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { continue }
            let day = cal.startOfDay(for: start)
            guard day >= dMin && day <= dMax else { continue }
            if let remStr = row.remove_after_at,
               let rem = PickupGameModels.parseSupabaseTimestamptz(remStr),
               rem <= now {
                continue
            }
            guard row.is_visible, row.status.lowercased() == "active" else { continue }
            out.insert(day)
        }
        return out
    }

    private func fetchCalendarDotDatesFromRPC(
        dateMin: Date,
        dateMax: Date,
        sport: String,
        venueIds: [UUID],
        ownerEmails: [String],
        venueNames: [String]
    ) async throws -> Set<Date> {
        let fmt = DiscoverVenueGameDateFormatting.sqlDate
        let params = GameonCalendarDotRPCParams(
            p_date_min: fmt.string(from: dateMin),
            p_date_max: fmt.string(from: dateMax),
            p_sport: sport,
            p_venue_ids: venueIds.isEmpty ? nil : venueIds,
            p_owner_emails: ownerEmails.isEmpty ? nil : ownerEmails,
            p_venue_names: venueNames.isEmpty ? nil : venueNames,
            p_region_only: true
        )
        let rows: [GameonCalendarDotRPCRow] = try await supabase
            .rpc("gameon_calendar_dot_dates", params: params)
            .execute()
            .value

        let cal = Calendar.current
        var dates: Set<Date> = []
        dates.reserveCapacity(rows.count)
        for row in rows {
            let raw = row.event_date.trimmingCharacters(in: .whitespacesAndNewlines)
            guard raw.count >= 10 else { continue }
            let ymd = String(raw.prefix(10))
            guard let parsed = fmt.date(from: ymd) else { continue }
            dates.insert(cal.startOfDay(for: parsed))
        }
        return dates
    }

    private func venueCalendarDotsRequestIsCurrent(requestID: UUID) -> Bool {
        venueCalendarDotLoadRequestID == requestID
    }

    private func pickupCalendarDotsRequestIsCurrent(requestID: UUID) -> Bool {
        pickupCalendarDotLoadRequestID == requestID
    }

    /// Guest Discover: avoid reusing empty calendar-dot caches after RLS/data fixes (calendar open, month paging, phase-1 preload).
    private func discoverGuestCalendarDotEmptyCacheBypassReason(_ reason: String) -> Bool {
        guard isGuestDiscoverMode else { return false }
        switch reason {
        case "calendar_open", "month_change", "phase1_preload":
            return true
        default:
            return false
        }
    }

    /// Guest Discover: always hit the network when the calendar sheet opens so dots are not stuck behind a fresh-but-empty TTL entry.
    private func discoverGuestCalendarOpenForcesCalendarDotNetwork(_ reason: String) -> Bool {
        isGuestDiscoverMode && reason == "calendar_open"
    }

    func hasFreshVenueGameCalendarDotCache(for month: Date) -> Bool {
        let (venueIds, ownerEmails, venueNames) = effectiveVenueCalendarDotRPCInputs()
        guard !venueIds.isEmpty || !ownerEmails.isEmpty || !venueNames.isEmpty else { return false }
        let range = discoverCalendarDotRange(around: month)
        let cacheKey = discoverCalendarDotCacheKey(
            monthStart: range.monthStart,
            dateMin: range.dateMin,
            dateMax: range.dateMax,
            sport: selectedSport,
            venueIds: venueIds,
            ownerEmails: ownerEmails,
            venueNames: venueNames
        )
        guard let cached = venueGameCalendarDotDatesCache[cacheKey] else { return false }
        if isGuestDiscoverMode, cached.dates.isEmpty { return false }
        return Date().timeIntervalSince(cached.fetchedAt) < DiscoverCalendarDotCacheConfig.ttl
    }

    func hasFreshPickupGameCalendarDotCache(for month: Date) -> Bool {
        let range = discoverCalendarDotRange(around: month)
        let cacheKey = pickupGameCalendarDotCacheKey(
            monthStart: range.monthStart,
            dateMin: range.dateMin,
            dateMax: range.dateMax,
            sport: selectedSport
        )
        guard let cached = pickupGameCalendarDotDatesCache[cacheKey] else { return false }
        if isGuestDiscoverMode, cached.dates.isEmpty { return false }
        return Date().timeIntervalSince(cached.fetchedAt) < DiscoverCalendarDotCacheConfig.ttl
    }

    func hasFreshDiscoverCalendarDotCache(for month: Date) -> Bool {
        switch discoverMapContentMode {
        case .venues:
            return hasFreshVenueGameCalendarDotCache(for: month)
        case .pickupGames:
            return hasFreshPickupGameCalendarDotCache(for: month)
        }
    }

    func loadDiscoverCalendarDots(
        around month: Date,
        reason: String,
        logIfOpeningBeforeReady: Bool = false
    ) {
        #if DEBUG
        let modeStr: String = {
            switch discoverMapContentMode {
            case .venues: return "venues"
            case .pickupGames: return "pickupGames"
            }
        }()
        let fmt = DiscoverVenueGameDateFormatting.sqlDate
        print("[DiscoverCalendarDotsDebug] loadDiscoverCalendarDots reason=\(reason) mode=\(modeStr) around=\(fmt.string(from: month))")
        #endif
        switch discoverMapContentMode {
        case .venues:
            loadVenueGameCalendarDotsForDiscover(around: month, reason: reason, logIfOpeningBeforeReady: logIfOpeningBeforeReady)
        case .pickupGames:
            loadPickupGameCalendarDotsForDiscover(around: month, reason: reason, logIfOpeningBeforeReady: logIfOpeningBeforeReady)
        }
    }

    /// Launch/account warm path: populate calendar dot caches without requiring Calendar tab selection.
    func warmPreloadCalendarCaches(reason: String) {
        let month = calendarTabSelectedDate
        loadVenueGameCalendarDotsForDiscover(
            around: month,
            reason: "\(reason)_venue",
            logIfOpeningBeforeReady: false
        )
        loadPickupGameCalendarDotsForDiscover(
            around: month,
            reason: "\(reason)_pickup",
            logIfOpeningBeforeReady: false
        )
    }

    /// Launch warm path: pickup calendar dots + selected-day map rows (no-op when already preloaded).
    func warmPreloadPickupDiscoverMetadataIfNeeded() {
        beginDiscoverPickupMetadataBackgroundPreloadIfNeeded()
    }

    /// Bottom-tab Calendar: warm **both** venue and pickup dot caches for `month` without mutating ``discoverMapContentMode``.
    func loadCalendarTabCalendarDotsAroundMonth(_ month: Date, reason: String) {
        guard isCalendarTabSelected else {
#if DEBUG
            print("[PerfPhase1D] deferredCalendarWork reason=loadCalendarTabCalendarDotsAroundMonth:\(reason)")
#endif
            return
        }
        loadVenueGameCalendarDotsForDiscover(around: month, reason: reason + "_calTabVenue", logIfOpeningBeforeReady: false)
        loadPickupGameCalendarDotsForDiscover(around: month, reason: reason + "_calTabPickup", logIfOpeningBeforeReady: false)
    }

    private func loadVenueGameCalendarDotsForDiscover(
        around month: Date,
        reason: String,
        logIfOpeningBeforeReady: Bool
    ) {
        let (venueIds, ownerEmails, venueNames) = effectiveVenueCalendarDotRPCInputs()
        let range = discoverCalendarDotRange(around: month)
        let monthStart = range.monthStart
        let sport = selectedSport
        let cacheKey = discoverCalendarDotCacheKey(
            monthStart: monthStart,
            dateMin: range.dateMin,
            dateMax: range.dateMax,
            sport: sport,
            venueIds: venueIds,
            ownerEmails: ownerEmails,
            venueNames: venueNames
        )

        #if DEBUG
        let fmtLog = DiscoverVenueGameDateFormatting.sqlDate
        let cacheKeyHit = venueGameCalendarDotDatesCache[cacheKey] != nil
        let namesPreview = venueNames.prefix(6).joined(separator: ", ")
        let skipRPC = venueIds.isEmpty && ownerEmails.isEmpty && venueNames.isEmpty
        print(
            "[CalendarDotsAudit] loadVenueGameCalendarDots filters dateMin=\(fmtLog.string(from: range.dateMin)) dateMax=\(fmtLog.string(from: range.dateMax)) selectedSport=\(sport) effectiveVenueIds=\(venueIds.count) ownerEmails=\(ownerEmails.count) venueNames=\(venueNames.count) namesPreview=[\(namesPreview)] venueEventRowsInMemory=\(venueEventRows.count) mapVisibleBars=\(mapVisibleBars.count) bars=\(bars.count) rpc_p_region_only=true venue_events_rest_chunkSize=80 venue_events_rest_explicitRowLimit=none skipRPC=\(skipRPC)"
        )
        print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots start reason=\(reason) monthAround=\(fmtLog.string(from: month)) effectiveVenueIds=\(venueIds.count) effectiveOwnerEmails=\(ownerEmails.count) effectiveVenueNames=\(venueNames.count) bars=\(bars.count) mapVisibleBars=\(mapVisibleBars.count) venueEventRows=\(venueEventRows.count) cacheKeyHit=\(cacheKeyHit)")
        #endif

        if logIfOpeningBeforeReady && (isLoadingVenueCalendarDots || hasFreshVenueGameCalendarDotCache(for: monthStart) == false) {
            #if DEBUG
            print("[CalendarDotsPerf] calendar opened before dots ready month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
            #endif
        }

        let venueDotsAtVeryStart = venueGameCalendarDotDates

        if isGuestDiscoverMode,
           discoverGuestCalendarDotEmptyCacheBypassReason(reason),
           let stale = venueGameCalendarDotDatesCache[cacheKey],
           stale.dates.isEmpty {
            venueGameCalendarDotDatesCache.removeValue(forKey: cacheKey)
            #if DEBUG
            print("[CalendarDotsFix] guest empty cache bypassed")
            #endif
        }

        if let cached = venueGameCalendarDotDatesCache[cacheKey] {
            venueGameCalendarDotDates = cached.dates
            #if DEBUG
            print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots syncCacheApplied=yes venueGameCalendarDotDates=\(venueGameCalendarDotDates.count)")
            print("[CalendarDotsPerf] cached venue dots applied immediately month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) count=\(cached.dates.count) ageSec=\(String(format: "%.1f", Date().timeIntervalSince(cached.fetchedAt)))")
            #endif
        } else {
            let fromRowsSync = discoverVenueCalendarDotDatesFromVenueEventsInRange(
                dateMin: range.dateMin,
                dateMax: range.dateMax,
                sport: sport,
                venueIds: venueIds,
                venueNames: venueNames
            )
            let preservedStart = discoverCalendarDotDatesInFetchWindow(venueDotsAtVeryStart, dateMin: range.dateMin, dateMax: range.dateMax)
            if !fromRowsSync.isEmpty {
                venueGameCalendarDotDates = fromRowsSync
                #if DEBUG
                print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots syncCacheApplied=no seededFromVenueEventRows=\(fromRowsSync.count)")
                #endif
            } else if !preservedStart.isEmpty {
                venueGameCalendarDotDates = preservedStart
                #if DEBUG
                print("[CalendarDotsFix] kept existing venue dots count=\(preservedStart.count) syncCacheApplied=no (no cache; in-window prior)")
                print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots syncCacheApplied=no keptInWindowPrior=\(preservedStart.count)")
                #endif
            } else {
                venueGameCalendarDotDates = []
                #if DEBUG
                print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots syncCacheApplied=no venueGameCalendarDotDates=0")
                #endif
            }
        }

        let cacheAge = venueGameCalendarDotDatesCache[cacheKey].map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
        let guestCalendarOpenForcesNetwork = discoverGuestCalendarOpenForcesCalendarDotNetwork(reason)
        if !guestCalendarOpenForcesNetwork && cacheAge < DiscoverCalendarDotCacheConfig.ttl {
            if let task = venueCalendarDotLoadTask {
                #if DEBUG
                print("[CalendarDotsPerf] venueDotTaskCancelled")
                #endif
                task.cancel()
            }
            venueCalendarDotLoadTask = nil
            venueCalendarDotLoadRequestID = nil
            isLoadingVenueCalendarDots = false
            calendarDotStatusText = nil
            #if DEBUG
            print("[CalendarDotsPerf] venue dots cache fresh skip network month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
            print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit ttlSkip finalVenueGameCalendarDotDates=\(venueGameCalendarDotDates.count)")
            #endif
            return
        }

        if reason != "phase1_preload" || !venueGameCalendarDotDates.isEmpty {
            calendarDotStatusText = "Loading game dates..."
        }

        isLoadingVenueCalendarDots = true
        if let task = venueCalendarDotLoadTask {
            #if DEBUG
            print("[CalendarDotsPerf] venueDotTaskCancelled")
            #endif
            task.cancel()
        }
        let requestID = UUID()
        venueCalendarDotLoadRequestID = requestID

        #if DEBUG
        print("[CalendarDotsPerf] venue preload started month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) reason=\(reason) venueIds=\(venueIds.count)")
        print("[CalendarDotsPerf] venueDotTaskStarted")
        #endif

        venueCalendarDotLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let venueDotsBaselineBeforeNetwork = self.venueGameCalendarDotDates
            defer {
                if self.venueCalendarDotsRequestIsCurrent(requestID: requestID) {
                    self.isLoadingVenueCalendarDots = false
                    self.venueCalendarDotLoadTask = nil
                    if !self.isLoadingPickupCalendarDots {
                        self.calendarDotStatusText = nil
                    }
                    self.applyDiscoverGuestNearestEventDateIfNeeded(reason: reason)
                    #if DEBUG
                    print("[CalendarDotsPerf] venueDotTaskCompleted")
                    #endif
                }
            }

            guard !venueIds.isEmpty || !ownerEmails.isEmpty || !venueNames.isEmpty else {
                let localOnly = self.discoverVenueCalendarDotDatesFromVenueEventsInRange(
                    dateMin: range.dateMin,
                    dateMax: range.dateMax,
                    sport: sport,
                    venueIds: [],
                    venueNames: []
                )
                guard self.venueCalendarDotsRequestIsCurrent(requestID: requestID) else { return }
                if !localOnly.isEmpty {
                    self.venueGameCalendarDotDatesCache[cacheKey] = (dates: localOnly, fetchedAt: Date())
                    self.pruneVenueGameCalendarDotDatesCacheIfNeeded()
                    self.venueGameCalendarDotDates = localOnly
                    #if DEBUG
                    print("[CalendarDotsPerf] venue dots local-only (no RPC scope) count=\(localOnly.count)")
                    print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit noRPCScopeLocalOnly finalVenueGameCalendarDotDates=\(localOnly.count)")
                    #endif
                } else {
                    let preserved = self.discoverCalendarDotDatesInFetchWindow(
                        self.venueGameCalendarDotDates,
                        dateMin: range.dateMin,
                        dateMax: range.dateMax
                    )
                    if !preserved.isEmpty {
                        self.venueGameCalendarDotDates = preserved
                        #if DEBUG
                        print("[CalendarDotsFix] kept existing venue dots count=\(preserved.count) because refresh returned empty")
                        print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit noRPCScopeEmpty keptInWindow=\(preserved.count)")
                        #endif
                    } else {
                        self.venueGameCalendarDotDates = []
                        #if DEBUG
                        print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit noRPCScopeEmpty finalVenueGameCalendarDotDates=0")
                        #endif
                    }
                }
                return
            }

            do {
                let fetchedDates = try await self.fetchCalendarDotDatesFromRPC(
                    dateMin: range.dateMin,
                    dateMax: range.dateMax,
                    sport: sport,
                    venueIds: venueIds,
                    ownerEmails: ownerEmails,
                    venueNames: venueNames
                )
                guard !Task.isCancelled else { return }
                guard self.venueCalendarDotsRequestIsCurrent(requestID: requestID) else {
                    #if DEBUG
                    print("[CalendarDotsPerf] stale venue dot result ignored month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                    #endif
                    return
                }

                let fromRows = self.discoverVenueCalendarDotDatesFromVenueEventsInRange(
                    dateMin: range.dateMin,
                    dateMax: range.dateMax,
                    sport: sport,
                    venueIds: venueIds,
                    venueNames: venueNames
                )
                let merged = fetchedDates.union(fromRows)

                if merged.isEmpty {
                    // Do not treat "RPC 0 + in-memory fallback 0" as a fresh cache entry, or TTL would block retries.
                    self.venueGameCalendarDotDatesCache.removeValue(forKey: cacheKey)
                    #if DEBUG
                    print("[CalendarDotsCache] venue dots skip emptyCache rpcCount=\(fetchedDates.count) fallbackFromRows=\(fromRows.count) month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                    #endif
                    let preserved = self.discoverCalendarDotDatesInFetchWindow(
                        venueDotsBaselineBeforeNetwork,
                        dateMin: range.dateMin,
                        dateMax: range.dateMax
                    )
                    if !preserved.isEmpty {
                        self.venueGameCalendarDotDates = preserved
                        #if DEBUG
                        print("[CalendarDotsFix] kept existing venue dots count=\(preserved.count) because refresh returned empty")
                        #endif
                    } else {
                        self.venueGameCalendarDotDates = merged
                    }
                } else {
                    self.venueGameCalendarDotDatesCache[cacheKey] = (dates: merged, fetchedAt: Date())
                    self.pruneVenueGameCalendarDotDatesCacheIfNeeded()
                    self.venueGameCalendarDotDates = merged
                }

                #if DEBUG
                print("[CalendarDotsDebug] venue RPC dot dates count=\(fetchedDates.count) merged=\(merged.count) month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                print("[CalendarDotsPerf] venue fetch completed month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) count=\(merged.count)")
                print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit rpcOk finalVenueGameCalendarDotDates=\(self.venueGameCalendarDotDates.count) fetched=\(fetchedDates.count) fallbackFromRows=\(fromRows.count)")
                #endif
            } catch is CancellationError {
                return
            } catch {
                guard self.venueCalendarDotsRequestIsCurrent(requestID: requestID) else {
                    #if DEBUG
                    print("[CalendarDotsPerf] stale venue dot result ignored month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                    #endif
                    return
                }
                let fromRows = self.discoverVenueCalendarDotDatesFromVenueEventsInRange(
                    dateMin: range.dateMin,
                    dateMax: range.dateMax,
                    sport: sport,
                    venueIds: venueIds,
                    venueNames: venueNames
                )
                let fallback = fromRows.union(
                    self.discoverVenueCalendarDotDatesFromVenueEventsInRange(
                        dateMin: range.dateMin,
                        dateMax: range.dateMax,
                        sport: sport,
                        venueIds: [],
                        venueNames: []
                    )
                )
                if !fallback.isEmpty {
                    self.venueGameCalendarDotDatesCache[cacheKey] = (dates: fallback, fetchedAt: Date())
                    self.pruneVenueGameCalendarDotDatesCacheIfNeeded()
                    self.venueGameCalendarDotDates = fallback
                    #if DEBUG
                    print("[CalendarDotsPerf] venue RPC failed; applied venue_event fallback count=\(fallback.count) error=\(error.localizedDescription)")
                    print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit rpcFail finalVenueGameCalendarDotDates=\(fallback.count)")
                    #endif
                } else {
                    let preserved = self.discoverCalendarDotDatesInFetchWindow(
                        venueDotsBaselineBeforeNetwork,
                        dateMin: range.dateMin,
                        dateMax: range.dateMax
                    )
                    if !preserved.isEmpty {
                        self.venueGameCalendarDotDates = preserved
                        #if DEBUG
                        print("[CalendarDotsFix] kept existing venue dots count=\(preserved.count) because refresh returned empty")
                        print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit rpcFail keptInWindow=\(preserved.count)")
                        #endif
                    }
                    if !self.isLoadingPickupCalendarDots {
                        self.calendarDotStatusText = nil
                    }
                    self.isLoadingVenueCalendarDots = false
                    self.venueCalendarDotLoadTask = nil
                    #if DEBUG
                    if preserved.isEmpty {
                        print("[DiscoverCalendarDotsDebug] loadVenueGameCalendarDots exit rpcFailNoFallback finalVenueGameCalendarDotDates=0")
                    }
                    #endif
                }
            }
        }
    }

    private func loadPickupGameCalendarDotsForDiscover(
        around month: Date,
        reason: String,
        logIfOpeningBeforeReady: Bool
    ) {
        let range = discoverCalendarDotRange(around: month)
        let monthStart = range.monthStart
        let sport = selectedSport
        let cacheKey = pickupGameCalendarDotCacheKey(
            monthStart: monthStart,
            dateMin: range.dateMin,
            dateMax: range.dateMax,
            sport: sport
        )

        #if DEBUG
        let fmtLog = DiscoverVenueGameDateFormatting.sqlDate
        let pickupCacheKeyHit = pickupGameCalendarDotDatesCache[cacheKey] != nil
        print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots start reason=\(reason) monthAround=\(fmtLog.string(from: month)) pickupGamesForDiscoverMap=\(pickupGamesForDiscoverMap.count) cacheKeyHit=\(pickupCacheKeyHit)")
        #endif

        if logIfOpeningBeforeReady && (isLoadingPickupCalendarDots || hasFreshPickupGameCalendarDotCache(for: monthStart) == false) {
            #if DEBUG
            print("[CalendarDotsPerf] calendar opened before pickup dots ready month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
            #endif
        }

        let pickupDotsAtVeryStart = pickupGameCalendarDotDates

        if isGuestDiscoverMode,
           discoverGuestCalendarDotEmptyCacheBypassReason(reason),
           let stale = pickupGameCalendarDotDatesCache[cacheKey],
           stale.dates.isEmpty {
            pickupGameCalendarDotDatesCache.removeValue(forKey: cacheKey)
            #if DEBUG
            print("[CalendarDotsFix] guest empty cache bypassed")
            #endif
        }

        if let cached = pickupGameCalendarDotDatesCache[cacheKey] {
            pickupGameCalendarDotDates = cached.dates
            #if DEBUG
            print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots syncCacheApplied=yes pickupGameCalendarDotDates=\(pickupGameCalendarDotDates.count)")
            print("[CalendarDotsPerf] cached pickup dots applied immediately month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) count=\(cached.dates.count) ageSec=\(String(format: "%.1f", Date().timeIntervalSince(cached.fetchedAt)))")
            #endif
        } else {
            let fromRowsSync = discoverPickupCalendarDotDatesFromLoadedPickupRows(
                dateMin: range.dateMin,
                dateMax: range.dateMax,
                sport: sport
            )
            let preservedStart = discoverCalendarDotDatesInFetchWindow(pickupDotsAtVeryStart, dateMin: range.dateMin, dateMax: range.dateMax)
            if !fromRowsSync.isEmpty {
                pickupGameCalendarDotDates = fromRowsSync
                #if DEBUG
                print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots syncCacheApplied=no seededFromPickupRows=\(fromRowsSync.count)")
                #endif
            } else if !preservedStart.isEmpty {
                pickupGameCalendarDotDates = preservedStart
                #if DEBUG
                print("[CalendarDotsFix] kept existing pickup dots count=\(preservedStart.count) syncCacheApplied=no (no cache; in-window prior)")
                print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots syncCacheApplied=no keptInWindowPrior=\(preservedStart.count)")
                #endif
            } else {
                pickupGameCalendarDotDates = []
                #if DEBUG
                print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots syncCacheApplied=no pickupGameCalendarDotDates=0")
                #endif
            }
        }

        let pickupCacheAge = pickupGameCalendarDotDatesCache[cacheKey].map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
        let guestCalendarOpenForcesNetwork = discoverGuestCalendarOpenForcesCalendarDotNetwork(reason)
        if !guestCalendarOpenForcesNetwork && pickupCacheAge < DiscoverCalendarDotCacheConfig.ttl {
            if let task = pickupCalendarDotLoadTask {
                #if DEBUG
                print("[CalendarDotsPerf] pickupDotTaskCancelled")
                #endif
                task.cancel()
            }
            pickupCalendarDotLoadTask = nil
            pickupCalendarDotLoadRequestID = nil
            isLoadingPickupCalendarDots = false
            calendarDotStatusText = nil
            #if DEBUG
            print("[CalendarDotsPerf] pickup dots cache fresh skip network month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
            print("[PickupCalendarPerf] pickup dots cache fresh skip network month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
            print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots exit ttlSkip finalPickupGameCalendarDotDates=\(pickupGameCalendarDotDates.count)")
            #endif
            return
        }

        if reason != "phase1_preload" || !pickupGameCalendarDotDates.isEmpty {
            calendarDotStatusText = "Loading game dates..."
        }

        isLoadingPickupCalendarDots = true
        if let task = pickupCalendarDotLoadTask {
            #if DEBUG
            print("[CalendarDotsPerf] pickupDotTaskCancelled")
            #endif
            task.cancel()
        }
        let requestID = UUID()
        pickupCalendarDotLoadRequestID = requestID

        #if DEBUG
        print("[CalendarDotsPerf] pickup preload started month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) reason=\(reason)")
        print("[CalendarDotsPerf] pickupDotTaskStarted")
        #endif

        pickupCalendarDotLoadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let pickupDotsBaselineBeforeNetwork = self.pickupGameCalendarDotDates
            #if DEBUG
            print("[PickupCalendarPerf] background refresh started month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) reason=\(reason)")
            #endif
            defer {
                if self.pickupCalendarDotsRequestIsCurrent(requestID: requestID) {
                    self.isLoadingPickupCalendarDots = false
                    self.pickupCalendarDotLoadTask = nil
                    if !self.isLoadingVenueCalendarDots {
                        self.calendarDotStatusText = nil
                    }
                    self.applyDiscoverGuestNearestEventDateIfNeeded(reason: reason)
                    #if DEBUG
                    print("[CalendarDotsPerf] pickupDotTaskCompleted")
                    #endif
                }
            }

            if self.discoverMapContentMode == .pickupGames, self.pickupGamesForDiscoverMap.isEmpty {
                await self.refreshPickupGamesForDiscoverMap(force: false, preservePickupCalendarDotDatesCache: true)
            }

            do {
                let fetchedDates = try await self.fetchPickupGameCalendarDotDatesForDiscoverRange(
                    dateMin: range.dateMin,
                    dateMax: range.dateMax
                )
                guard !Task.isCancelled else { return }
                guard self.pickupCalendarDotsRequestIsCurrent(requestID: requestID) else {
                    #if DEBUG
                    print("[CalendarDotsPerf] stale pickup dot result ignored month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                    #endif
                    return
                }

                let fromRows = self.discoverPickupCalendarDotDatesFromLoadedPickupRows(
                    dateMin: range.dateMin,
                    dateMax: range.dateMax,
                    sport: sport
                )
                let merged = fetchedDates.union(fromRows)

                if merged.isEmpty {
                    self.pickupGameCalendarDotDatesCache.removeValue(forKey: cacheKey)
                    #if DEBUG
                    print("[CalendarDotsCache] pickup dots skip emptyCache rpcDotCount=\(fetchedDates.count) fallbackFromRows=\(fromRows.count) month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                    #endif
                    let preserved = self.discoverCalendarDotDatesInFetchWindow(
                        pickupDotsBaselineBeforeNetwork,
                        dateMin: range.dateMin,
                        dateMax: range.dateMax
                    )
                    if !preserved.isEmpty {
                        self.pickupGameCalendarDotDates = preserved
                        #if DEBUG
                        print("[CalendarDotsFix] kept existing pickup dots count=\(preserved.count) because refresh returned empty")
                        #endif
                    } else {
                        self.pickupGameCalendarDotDates = merged
                    }
                } else {
                    self.pickupGameCalendarDotDatesCache[cacheKey] = (dates: merged, fetchedAt: Date())
                    self.prunePickupGameCalendarDotDatesCacheIfNeeded()
                    self.pickupGameCalendarDotDates = merged
                }

                #if DEBUG
                print("[CalendarDotsDebug] pickup dot dates count=\(fetchedDates.count) merged=\(merged.count) month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                print("[CalendarDotsPerf] pickup fetch completed month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) count=\(merged.count)")
                print("[PickupCalendarPerf] background refresh completed month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart)) count=\(merged.count)")
                print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots exit rpcOk finalPickupGameCalendarDotDates=\(self.pickupGameCalendarDotDates.count) fetchedDotCount=\(fetchedDates.count) fallbackDotCount=\(fromRows.count)")
                #endif
            } catch is CancellationError {
                return
            } catch {
                guard self.pickupCalendarDotsRequestIsCurrent(requestID: requestID) else {
                    #if DEBUG
                    print("[CalendarDotsPerf] stale pickup dot result ignored month=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: monthStart))")
                    #endif
                    return
                }
                let fb = self.discoverPickupCalendarDotDatesFromLoadedPickupRows(
                    dateMin: range.dateMin,
                    dateMax: range.dateMax,
                    sport: sport
                )
                if !fb.isEmpty {
                    self.pickupGameCalendarDotDatesCache[cacheKey] = (dates: fb, fetchedAt: Date())
                    self.prunePickupGameCalendarDotDatesCacheIfNeeded()
                    self.pickupGameCalendarDotDates = fb
                    #if DEBUG
                    print("[CalendarDotsPerf] pickup RPC failed; applied map-row fallback count=\(fb.count) error=\(error.localizedDescription)")
                    print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots exit rpcFail finalPickupGameCalendarDotDates=\(fb.count) fetchedDotCount=0 fallbackDotCount=\(fb.count)")
                    #endif
                } else {
                    let preserved = self.discoverCalendarDotDatesInFetchWindow(
                        pickupDotsBaselineBeforeNetwork,
                        dateMin: range.dateMin,
                        dateMax: range.dateMax
                    )
                    if !preserved.isEmpty {
                        self.pickupGameCalendarDotDates = preserved
                        #if DEBUG
                        print("[CalendarDotsFix] kept existing pickup dots count=\(preserved.count) because refresh returned empty")
                        print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots exit rpcFail keptInWindow=\(preserved.count)")
                        #endif
                    }
                    if !self.isLoadingVenueCalendarDots {
                        self.calendarDotStatusText = nil
                    }
                    self.isLoadingPickupCalendarDots = false
                    self.pickupCalendarDotLoadTask = nil
                    #if DEBUG
                    if preserved.isEmpty {
                        print("[DiscoverCalendarDotsDebug] loadPickupGameCalendarDots exit rpcFailNoFallback finalPickupGameCalendarDotDates=0 fetchedDotCount=0 fallbackDotCount=0")
                    }
                    #endif
                }
            }
        }
    }

    func preloadDiscoverCalendarDotsForVisibleVenues() {
        loadDiscoverCalendarDots(around: selectedDate, reason: "phase1_preload")
    }

    /// Inclusive date envelope for Phase 3a.2 calendar-dot RPC shadow (same windows as ``performLoadGamesFromSupabase``: official 10d/365, venue 30d/180).
    func calendarDotRPCShadowScheduleBounds() -> (min: Date, max: Date) {
        let cal = Calendar.current
        let now = Date()
        let officialStart = cal.date(byAdding: .day, value: -10, to: now) ?? now
        let officialEnd = cal.date(byAdding: .day, value: 365, to: now) ?? now
        let venueStart = cal.date(byAdding: .day, value: -30, to: now) ?? now
        let venueEnd = cal.date(byAdding: .day, value: 180, to: now) ?? now
        let minD = min(officialStart, venueStart)
        let maxD = max(officialEnd, venueEnd)
        return (cal.startOfDay(for: minD), cal.startOfDay(for: maxD))
    }

    private func discoverBoundsBucketString() -> String {
        guard let b = currentMapRegionBounds() else { return "nb" }
        return String(
            format: "%.3f|%.3f|%.3f|%.3f",
            b.minLat, b.maxLat, b.minLon, b.maxLon
        )
    }

    private func chunked<T>(_ array: [T], size: Int) -> [[T]] {
        guard size > 0, !array.isEmpty else { return array.isEmpty ? [] : [array] }
        return stride(from: 0, to: array.count, by: size).map {
            Array(array[$0..<min($0 + size, array.count)])
        }
    }

    private func discoverVenueEventsCacheKey(
        boundsBucket: String,
        sport: String,
        dateLower: String,
        dateUpper: String,
        venueIds: [UUID],
        ownerEmails: [String],
        venueNames: [String]
    ) -> String {
        let idTag = "vid:\(venueIds.count):\(venueIds.map(\.uuidString).sorted().joined(separator: ",").prefix(400))"
        return "\(boundsBucket)|\(sport)|\(dateLower)|\(dateUpper)|\(idTag)|o:\(ownerEmails.count):\(ownerEmails.sorted().joined(separator: ",").prefix(400))|v:\(venueNames.count):\(venueNames.sorted().joined(separator: ",").prefix(400))"
    }

    /// Batched `venue_events` for Discover: ``venue_id IN (...)`` first, then legacy ``owner_email`` / ``venue_name`` batches only for rows with null ``venue_id``.
    private func fetchVenueEventRowsForDiscover(
        venueIds: [UUID],
        ownerEmails: [String],
        venueNames: [String],
        dateLower: String,
        dateUpper: String,
        sport: String
    ) async throws -> [VenueEventRow] {
        let boundsBucket = discoverBoundsBucketString()
        let cacheKey = discoverVenueEventsCacheKey(
            boundsBucket: boundsBucket,
            sport: sport,
            dateLower: dateLower,
            dateUpper: dateUpper,
            venueIds: venueIds,
            ownerEmails: ownerEmails,
            venueNames: venueNames
        )

        if let cached = discoverVenueEventsFetchCache,
           cached.key == cacheKey,
           Date().timeIntervalSince(cached.fetchedAt) < 45 {
            if isGuestDiscoverMode, cached.rows.isEmpty {
                discoverVenueEventsFetchCache = nil
                #if DEBUG
                print("[VenueEventsFix] guest empty venue_events cache bypassed")
                #endif
            } else {
                #if DEBUG
                print("[Phase1Perf] fetchVenueEventRowsForDiscover CACHE_HIT rows=\(cached.rows.count) ms=0")
                print("[DiscoverPerf] calendar/venue_events cache HIT rows=\(cached.rows.count) keyPrefix=\(String(cacheKey.prefix(96)))…")
                print("[DiscoverVenueEventsDebug] fetched venue_events count=\(cached.rows.count) (cache hit)")
                #endif
                return cached.rows
            }
        }

        #if DEBUG
        print("[DiscoverPerf] calendar/venue_events cache MISS keyPrefix=\(String(cacheKey.prefix(96)))…")
        print(
            "[CalendarDotsAudit] fetchVenueEventRowsForDiscover queryFilters dateLower=\(dateLower) dateUpper=\(dateUpper) sport=\(sport) venueIds=\(venueIds.count) ownerEmails=\(ownerEmails.count) venueNames=\(venueNames.count) admin_status=active (merge also drops non-active) venue_id_null_path_for_email_name=true chunkSize=80 explicitRowLimit=none"
        )
        let idSample = venueIds.prefix(5).map(\.uuidString).joined(separator: ",")
        print(
            "[VenueEventsReadAudit] table=venue_events dateLower=\(dateLower) dateUpper=\(dateUpper) selectedSport=\(sport) venueIdsCount=\(venueIds.count) venueIdsFirst5=[\(idSample)] filters: admin_status==active event_date gte/lte (no client status column) (no client is_visible column on this query)"
        )
        #endif

        let t0 = Date()
        var byID: [UUID: VenueEventRow] = [:]
        let selectCols = "id,venue_id,owner_email,venue_name,event_title,sport,home_team,away_team,event_date,event_time,admin_status,scheduled_start_at,cleanup_delay_hours,purge_after_at,external_league,external_game_id,external_source,imported_from_api,created_at"
        let chunkSize = 80

        func mergeRows(_ rows: [VenueEventRow]) {
            for row in rows {
                let st = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if let st, !st.isEmpty, st != "active" { continue }
                if let id = row.id { byID[id] = row }
            }
        }

        for chunk in chunked(venueIds, size: chunkSize) where !chunk.isEmpty {
            var q = supabase
                .from("venue_events")
                .select(selectCols)
                .in("venue_id", values: chunk)
                .eq("admin_status", value: "active")
                .gte("event_date", value: dateLower)
                .lte("event_date", value: dateUpper)
            if sport != "All" {
                q = q.eq("sport", value: sport)
            }
            let rows: [VenueEventRow] = try await q.execute().value
            mergeRows(rows)
        }

        for chunk in chunked(ownerEmails, size: chunkSize) where !chunk.isEmpty {
            var q = supabase
                .from("venue_events")
                .select(selectCols)
                .in("owner_email", values: chunk)
                .is("venue_id", value: nil)
                .eq("admin_status", value: "active")
                .gte("event_date", value: dateLower)
                .lte("event_date", value: dateUpper)
            if sport != "All" {
                q = q.eq("sport", value: sport)
            }
            let rows: [VenueEventRow] = try await q.execute().value
            mergeRows(rows)
        }

        for chunk in chunked(venueNames, size: chunkSize) where !chunk.isEmpty {
            var q = supabase
                .from("venue_events")
                .select(selectCols)
                .in("venue_name", values: chunk)
                .is("venue_id", value: nil)
                .eq("admin_status", value: "active")
                .gte("event_date", value: dateLower)
                .lte("event_date", value: dateUpper)
            if sport != "All" {
                q = q.eq("sport", value: sport)
            }
            let rows: [VenueEventRow] = try await q.execute().value
            mergeRows(rows)
        }

        let merged = Array(byID.values)
        if isGuestDiscoverMode, merged.isEmpty {
            discoverVenueEventsFetchCache = nil
        } else {
            discoverVenueEventsFetchCache = (key: cacheKey, rows: merged, fetchedAt: Date())
        }

        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[Phase1Perf] fetchVenueEventRowsForDiscover rows=\(merged.count) ms=\(ms)")
        print("[DiscoverPerf] venue_events fetch rows=\(merged.count) ms=\(ms)")
        print("[DiscoverVenueEventsDebug] fetched venue_events count=\(merged.count) (fresh fetch)")
        for row in merged.prefix(8) {
            let eid = row.id?.uuidString ?? "nil"
            let vid = row.venue_id?.uuidString ?? "nil"
            let title = row.event_title ?? ""
            let d = row.event_date ?? ""
            print("[CalendarDotsDebug] included venue_event id=\(eid) venue_id=\(vid) date=\(d) title=\(title)")
        }
        #endif

        return merged
    }

    private func pruneDiscoverSelectedDayVenueEventsCacheIfNeeded() {
        let maxKeys = 16
        guard discoverSelectedDayVenueEventsCache.count > maxKeys else { return }
        let sorted = discoverSelectedDayVenueEventsCache
            .map { ($0.key, $0.value.fetchedAt) }
            .sorted { $0.1 < $1.1 }
        let drop = discoverSelectedDayVenueEventsCache.count - maxKeys
        for index in 0..<drop {
            discoverSelectedDayVenueEventsCache.removeValue(forKey: sorted[index].0)
        }
    }

    private func applyDiscoverSelectedDayVenueRows(
        _ fetchedVenueEventRows: [VenueEventRow],
        venueRows: [VenueRow],
        applyIfStillCurrent: (() -> Bool)? = nil
    ) async {
        let rowsCopy = venueRows
        let eventsCopy = fetchedVenueEventRows
        let (phaseBars, idsByKey): ([BarVenue], [String: UUID]) = await Task.detached(priority: .userInitiated) { () -> ([BarVenue], [String: UUID]) in
            DiscoverVenueLoadAssembler.buildMappedBars(venueRows: rowsCopy, fetchedVenueEventRows: eventsCopy)
        }.value

        guard applyIfStillCurrent?() ?? true else { return }

        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil

        var mergedBars = phaseBars
        if let sel = selectedBar, !mergedBars.contains(where: { $0.id == sel.id }) {
            mergedBars.append(sel)
        }

        if SampleData.includeSampleData {
            bars = mergedBars + SampleData.bars
        } else {
            bars = mergedBars
        }

        venueEventRows = fetchedVenueEventRows
        venueEventIDsByKey = idsByKey
        await mergeVenueSliceIntoEvents(venueRows: fetchedVenueEventRows)
        await reconcileGameRemindersForLoadedVenueEvents()
        pruneSelectionIfNeededAfterFilterChange()
        persistDiscoverCoreSnapshot()
    }

    private func discoverSelectedDayRefreshIsCurrent(
        requestID: UUID,
        selectedDay: String,
        sport: String
    ) -> Bool {
        discoverSelectedDayRefreshRequestID == requestID
            && DiscoverVenueGameDateFormatting.sqlDate.string(from: selectedDate) == selectedDay
            && selectedSport == sport
    }

    func refreshDiscoverSelectedDayVenueEventsForCurrentContext(requestID: UUID) async {
        let cal = Calendar.current
        let minDay = cal.startOfDay(for: Date())
        let selStart = cal.startOfDay(for: selectedDate)
        if selStart < minDay {
            #if DEBUG
            print("[DiscoverPerf] skipped past selected-day load date=\(DiscoverVenueGameDateFormatting.sqlDate.string(from: selectedDate))")
            #endif
            selectedDate = minDay
        }

        if discoverMapContentMode == .pickupGames {
            isRefreshingDiscoverEvents = true
            defer {
                if discoverSelectedDayRefreshRequestID == requestID {
                    isRefreshingDiscoverEvents = false
                    discoverSelectedDayRefreshTask = nil
                }
            }
            guard discoverSelectedDayRefreshRequestID == requestID else { return }
            await refreshPickupGamesForDiscoverMap()
            guard discoverSelectedDayRefreshRequestID == requestID else { return }
            setDiscoverMapStatus("Updated just now", isLoading: false, autoClearAfter: 2.2)
            return
        }

        let venueRows = discoverCurrentVisibleVenueRows
        let venueIds = discoverCurrentVisibleVenueIds
        let ownerEmails = discoverCurrentVisibleOwnerEmails
        let venueNames = discoverCurrentVisibleVenueNames
        let selectedDay = DiscoverVenueGameDateFormatting.sqlDate.string(from: selectedDate)
        let selectedSportSnapshot = selectedSport
        let boundsBucket = discoverBoundsBucketString()
        let cacheKey = discoverVenueEventsCacheKey(
            boundsBucket: boundsBucket,
            sport: selectedSportSnapshot,
            dateLower: selectedDay,
            dateUpper: selectedDay,
            venueIds: venueIds,
            ownerEmails: ownerEmails,
            venueNames: venueNames
        )

        #if DEBUG
        print("[CalendarPerf] Background date refresh started date=\(selectedDay) sport=\(selectedSportSnapshot)")
        #endif

        isRefreshingDiscoverEvents = true
        defer {
            if discoverSelectedDayRefreshRequestID == requestID {
                isRefreshingDiscoverEvents = false
                discoverSelectedDayRefreshTask = nil
            }
        }

        guard !venueRows.isEmpty else {
            await loadVenuesFromSupabase()
            guard discoverSelectedDayRefreshIsCurrent(
                requestID: requestID,
                selectedDay: selectedDay,
                sport: selectedSportSnapshot
            ) else {
                #if DEBUG
                print("[CalendarPerf] Ignored stale date refresh result date=\(selectedDay) sport=\(selectedSportSnapshot)")
                #endif
                return
            }
            setDiscoverMapStatus("Updated just now", isLoading: false, autoClearAfter: 2.2)
            #if DEBUG
            print("[CalendarPerf] Background date refresh completed date=\(selectedDay) sport=\(selectedSportSnapshot)")
            #endif
            return
        }

        var appliedCachedRows = false
        if let cached = discoverSelectedDayVenueEventsCache[cacheKey],
           Date().timeIntervalSince(cached.fetchedAt) < 90 {
            await applyDiscoverSelectedDayVenueRows(
                cached.rows,
                venueRows: venueRows,
                applyIfStillCurrent: { [weak self] in
                    self?.discoverSelectedDayRefreshIsCurrent(
                        requestID: requestID,
                        selectedDay: selectedDay,
                        sport: selectedSportSnapshot
                    ) ?? false
                }
            )
            guard discoverSelectedDayRefreshIsCurrent(
                requestID: requestID,
                selectedDay: selectedDay,
                sport: selectedSportSnapshot
            ) else {
                #if DEBUG
                print("[CalendarPerf] Ignored stale date refresh result date=\(selectedDay) sport=\(selectedSportSnapshot)")
                #endif
                return
            }
            appliedCachedRows = true
            setDiscoverMapStatus("Showing cached results", isLoading: true)
            #if DEBUG
            print("[CalendarPerf] Cached selected-day events applied date=\(selectedDay) rows=\(cached.rows.count)")
            #endif
        }

        do {
            let fetchedVenueEventRows = try await fetchVenueEventRowsForDiscover(
                venueIds: venueIds,
                ownerEmails: ownerEmails,
                venueNames: venueNames,
                dateLower: selectedDay,
                dateUpper: selectedDay,
                sport: selectedSportSnapshot
            )
            guard !Task.isCancelled else { return }
            guard discoverSelectedDayRefreshIsCurrent(
                requestID: requestID,
                selectedDay: selectedDay,
                sport: selectedSportSnapshot
            ) else {
                #if DEBUG
                print("[CalendarPerf] Ignored stale date refresh result date=\(selectedDay) sport=\(selectedSportSnapshot)")
                #endif
                return
            }

            discoverSelectedDayVenueEventsCache[cacheKey] = (rows: fetchedVenueEventRows, fetchedAt: Date())
            pruneDiscoverSelectedDayVenueEventsCacheIfNeeded()

            await applyDiscoverSelectedDayVenueRows(
                fetchedVenueEventRows,
                venueRows: venueRows,
                applyIfStillCurrent: { [weak self] in
                    self?.discoverSelectedDayRefreshIsCurrent(
                        requestID: requestID,
                        selectedDay: selectedDay,
                        sport: selectedSportSnapshot
                    ) ?? false
                }
            )
            guard discoverSelectedDayRefreshIsCurrent(
                requestID: requestID,
                selectedDay: selectedDay,
                sport: selectedSportSnapshot
            ) else {
                #if DEBUG
                print("[CalendarPerf] Ignored stale date refresh result date=\(selectedDay) sport=\(selectedSportSnapshot)")
                #endif
                return
            }

            setDiscoverMapStatus("Updated just now", isLoading: false, autoClearAfter: 2.2)
            #if DEBUG
            print("[CalendarPerf] Background date refresh completed date=\(selectedDay) rows=\(fetchedVenueEventRows.count)")
            #endif
        } catch is CancellationError {
            return
        } catch {
            guard discoverSelectedDayRefreshIsCurrent(
                requestID: requestID,
                selectedDay: selectedDay,
                sport: selectedSportSnapshot
            ) else {
                #if DEBUG
                print("[CalendarPerf] Ignored stale date refresh result date=\(selectedDay) sport=\(selectedSportSnapshot)")
                #endif
                return
            }
            #if DEBUG
            print("[DiscoverDatePerf] selected-day refresh error date=\(selectedDay) error=\(error)")
            #endif
            eventLoadError = "Couldn't refresh games for this date. Showing your last results."
            if appliedCachedRows {
                setDiscoverMapStatus("Showing cached results", isLoading: false, autoClearAfter: 2.2)
            } else if discoverSelectedDayRefreshRequestID == requestID {
                setDiscoverMapStatus(nil, isLoading: false)
            }
        }
    }

    func refreshDiscoverSelectedDayVenueEventsForCurrentContext() {
        let requestID = discoverSelectedDayRefreshRequestID ?? UUID()
        discoverSelectedDayRefreshRequestID = requestID
        scheduleDiscoverSelectedDayRefresh(requestID: requestID)
    }

    private func rebuildVenueEventIDsByKey(from rows: [VenueEventRow]) {
        var idsByKey: [String: UUID] = [:]
        for row in rows {
            DiscoverVenueLoadAssembler.registerVenueEventIDKeys(into: &idsByKey, row: row)
        }
        venueEventIDsByKey = idsByKey
    }

    private func mergeVenueSliceIntoEvents(venueRows: [VenueEventRow]) async {
        let eventsSnapshot = events
        let rowsSnapshot = venueRows
        let appendSampleVenueEvents = SampleData.includeSampleData
        let sampleVenueEventsSlice: [SportsEvent] = appendSampleVenueEvents
            ? SampleData.events.filter { $0.league == "Venue Event" }
            : []

        let merged = await Task.detached(priority: .userInitiated) { () -> [SportsEvent] in
            let nonVenue = eventsSnapshot.filter { $0.league != "Venue Event" }
            let fmt = DateFormatter()
            fmt.dateFormat = "yyyy-MM-dd"
            fmt.timeZone = TimeZone.current
            var next = nonVenue + DiscoverVenueLoadAssembler.sportsEventsFromVenueEventRows(rowsSnapshot, formatter: fmt)
            if appendSampleVenueEvents {
                next.append(contentsOf: sampleVenueEventsSlice)
            }
            return next
        }.value

        events = merged
        bumpScheduleDataGeneration()
        scheduleDiscoverMapRenderSnapshotRebuild(reason: "mergeVenueSliceIntoEvents")
    }

    private func scheduleDiscoverFullEnrichmentInBackground() {
        discoverFullEnrichmentTask?.cancel()
        discoverFullEnrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let t0 = Date()
            defer { self.discoverFullEnrichmentTask = nil }

            #if DEBUG
            print("[Perf] Phase 3 enrichment started")
            #endif
            await self.refreshSocialEnrichmentInBackground()
            guard !Task.isCancelled else { return }

            if self.isCalendarTabSelected {
                await self.awaitLoadGamesCoalescedUntilIdle()
            } else {
#if DEBUG
                print("[PerfPhase1D] deferredCalendarWork reason=performLoadGamesFromSupabase")
#endif
            }
            guard !Task.isCancelled else { return }

            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Phase3Perf] full enrichment load ms=\(ms) bars=\(self.bars.count) events=\(self.events.count)")
            print("[Perf] Phase 3 enrichment completed ms=\(ms)")
            #endif

            guard !Task.isCancelled else { return }
            if self.isCalendarTabSelected || self.discoverMapContentMode == .pickupGames {
                self.beginDiscoverPickupMetadataBackgroundPreloadIfNeeded()
            } else {
#if DEBUG
                print("[PerfPhase1D] deferredCalendarWork reason=beginDiscoverPickupMetadataBackgroundPreload")
#endif
            }
        }
    }

    /// One-shot: after Discover core enrichment, warm pickup calendar-dot cache (month of ``selectedDate``) and selected-day map rows without clearing dot cache. Runs for guests too when public reads succeed; not tied to map pan.
    private func beginDiscoverPickupMetadataBackgroundPreloadIfNeeded() {
        guard !discoverPickupMetadataPreloadCompleted else { return }
        guard discoverPickupMetadataPreloadTask == nil else { return }

        discoverPickupMetadataPreloadTask = Task { @MainActor [weak self] in
            defer {
                self?.discoverPickupMetadataPreloadTask = nil
                self?.discoverPickupMetadataPreloadCompleted = true
            }
            guard let self else { return }
            guard !Task.isCancelled else { return }

            let anchor = self.selectedDate
            let range = self.discoverCalendarDotRange(around: anchor)
            let monthStart = range.monthStart
            let sport = self.selectedSport
            let cacheKey = self.pickupGameCalendarDotCacheKey(
                monthStart: monthStart,
                dateMin: range.dateMin,
                dateMax: range.dateMax,
                sport: sport
            )
            let cacheAge = self.pickupGameCalendarDotDatesCache[cacheKey].map { Date().timeIntervalSince($0.fetchedAt) } ?? .infinity
            if cacheAge >= DiscoverCalendarDotCacheConfig.ttl {
                do {
                    let dates = try await self.fetchPickupGameCalendarDotDatesForDiscoverRange(
                        dateMin: range.dateMin,
                        dateMax: range.dateMax
                    )
                    guard !Task.isCancelled else { return }
                    if !(self.isGuestDiscoverMode && dates.isEmpty) {
                        self.pickupGameCalendarDotDatesCache[cacheKey] = (dates: dates, fetchedAt: Date())
                        self.prunePickupGameCalendarDotDatesCacheIfNeeded()
                    }
                    if self.discoverMapContentMode == .pickupGames,
                       (!dates.isEmpty || !self.isGuestDiscoverMode) {
                        self.pickupGameCalendarDotDates = dates
                    }
                } catch {
                    #if DEBUG
                    print("[DiscoverPickupPreload] pickup calendar dots prefetch failed:", error)
                    #endif
                }
            }

            guard !Task.isCancelled else { return }
            await self.refreshPickupGamesForDiscoverMap(force: true, preservePickupCalendarDotDatesCache: true)
        }
    }

    /// After a venue owner inserts a game, patch in-memory Discover/calendar/map state so the new listing appears without waiting for the next full fetch.
    func applyCreatedVenueEventLocally(_ row: VenueEventRow) async {
        if let id = row.id {
            venueEventRows.removeAll { $0.id == id }
        }
        venueEventRows.append(row)

        rebuildVenueEventIDsByKey(from: venueEventRows)
        await mergeVenueSliceIntoEvents(venueRows: venueEventRows)

        if let gameTitleForBar = row.event_title,
           !gameTitleForBar.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let vid = row.venue_id
            bars = bars.map { bar in
                let matchesById = vid != nil && bar.id == vid
                let matchesByName = !venueName.isEmpty
                    && bar.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(venueName) == .orderedSame
                guard matchesById || matchesByName else { return bar }
                if bar.games.contains(gameTitleForBar) { return bar }
                var nextGames = bar.games
                nextGames.append(gameTitleForBar)
                nextGames.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                return BarVenue(
                    id: bar.id,
                    name: bar.name,
                    address: bar.address,
                    phone: bar.phone,
                    primarySport: bar.primarySport,
                    distance: bar.distance,
                    rating: bar.rating,
                    tags: bar.tags,
                    games: nextGames,
                    coordinate: bar.coordinate,
                    goingCounts: bar.goingCounts,
                    screenCount: bar.screenCount,
                    servesFood: bar.servesFood,
                    hasWifi: bar.hasWifi,
                    hasGarden: bar.hasGarden,
                    hasProjector: bar.hasProjector,
                    petFriendly: bar.petFriendly,
                    rawVenueFeatures: bar.rawVenueFeatures,
                    coverPhotoURL: bar.coverPhotoURL,
                    menuPhotoURL: bar.menuPhotoURL,
                    coverPhotoThumbnailURL: bar.coverPhotoThumbnailURL,
                    menuPhotoThumbnailURL: bar.menuPhotoThumbnailURL,
                    ownerEmail: bar.ownerEmail,
                    businessId: bar.businessId,
                    adminStatus: bar.adminStatus,
                    venueOwnerEmailRaw: bar.venueOwnerEmailRaw,
                    businessOwnerEmailRaw: bar.businessOwnerEmailRaw,
                    contactEmailRaw: bar.contactEmailRaw,
                    supporterCountry: bar.supporterCountry,
                    originType: bar.originType
                )
            }
        }

        discoverVenueEventsFetchCache = nil
        discoverSelectedDayVenueEventsCache = [:]
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil

        recomputeCalendarDotDates()
        pruneSelectionIfNeededAfterFilterChange()

        #if DEBUG
        let dateStr = row.event_date ?? "?"
        let titleStr = row.event_title ?? "?"
        let idStr = row.id?.uuidString ?? "nil"
        print("[VenueGameSave] inserted local row id=\(idStr) date=\(dateStr) title=\(titleStr)")
        print("[VenueGameSave] recomputed calendar dots count=\(calendarDotDates.count)")
        print("[VenueGameSave] cleared discover venue-event cache")
        #endif
    }

    /// After a business owner archives/cancels a game: drop it from in-memory Discover/calendar/map state immediately (server already `admin_status != active`).
    func applyCancelledVenueEventLocally(
        removedEventId: UUID,
        venueId: UUID?,
        venueName: String?,
        eventTitle: String?,
        eventDate: String?
    ) async {
        venueEventRows.removeAll { $0.id == removedEventId }
        rebuildVenueEventIDsByKey(from: venueEventRows)
        await mergeVenueSliceIntoEvents(venueRows: venueEventRows)

        let title = eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !title.isEmpty {
            let vName = venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let vid = venueId
            bars = bars.map { bar in
                let matchesById = vid != nil && bar.id == vid
                let matchesByName = !vName.isEmpty
                    && bar.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(vName) == .orderedSame
                guard matchesById || matchesByName else { return bar }
                let nextGames = bar.games.filter { $0 != title }
                guard nextGames.count != bar.games.count else { return bar }
                return BarVenue(
                    id: bar.id,
                    name: bar.name,
                    address: bar.address,
                    phone: bar.phone,
                    primarySport: bar.primarySport,
                    distance: bar.distance,
                    rating: bar.rating,
                    tags: bar.tags,
                    games: nextGames,
                    coordinate: bar.coordinate,
                    goingCounts: bar.goingCounts,
                    screenCount: bar.screenCount,
                    servesFood: bar.servesFood,
                    hasWifi: bar.hasWifi,
                    hasGarden: bar.hasGarden,
                    hasProjector: bar.hasProjector,
                    petFriendly: bar.petFriendly,
                    rawVenueFeatures: bar.rawVenueFeatures,
                    coverPhotoURL: bar.coverPhotoURL,
                    menuPhotoURL: bar.menuPhotoURL,
                    coverPhotoThumbnailURL: bar.coverPhotoThumbnailURL,
                    menuPhotoThumbnailURL: bar.menuPhotoThumbnailURL,
                    ownerEmail: bar.ownerEmail,
                    businessId: bar.businessId,
                    adminStatus: bar.adminStatus,
                    venueOwnerEmailRaw: bar.venueOwnerEmailRaw,
                    businessOwnerEmailRaw: bar.businessOwnerEmailRaw,
                    contactEmailRaw: bar.contactEmailRaw,
                    supporterCountry: bar.supporterCountry,
                    originType: bar.originType
                )
            }
        }

        discoverVenueEventsFetchCache = nil
        discoverSelectedDayVenueEventsCache = [:]
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
        venueGameCalendarDotDatesCache.removeAll()

        venueEventInterestCounts[removedEventId] = nil
        venueEventComments[removedEventId] = nil
        venueEventVibeCounts[removedEventId] = nil

        recomputeCalendarDotDates()
        pruneSelectionIfNeededAfterFilterChange()

        refreshDiscoverSelectedDayVenueEventsForCurrentContext()
        loadDiscoverCalendarDots(around: selectedDate, reason: "owner_cancel_game")

        #if DEBUG
        print("[DiscoverGameCancelRefresh] removed local event_id=\(removedEventId.uuidString.lowercased())")
        if let eventDate {
            print("[CalendarDotsDebug] removed cancelled event date=\(eventDate) event_id=\(removedEventId.uuidString.lowercased())")
        }
        print("[DiscoverGameCancelRefresh] refreshed selected day + calendar dot reload scheduled")
        #endif
    }

    /// Venue rows in the current map bounds (shared by map reload and schedule hydration).
    /// Single venue by id (for Following → Discover when the venue is outside the current map bounds query).
    func fetchBarVenueByIdFromSupabase(id: UUID) async -> BarVenue? {
        do {
            let rows: [VenueRow] = try await supabase
                .from("venues")
                .select(discoverVenueRowSelectColumns)
                .eq("id", value: id)
                .or(discoverVenueActiveLegacySafeOrFilter)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else { return nil }
            let (mapped, _) = DiscoverVenueLoadAssembler.buildMappedBars(venueRows: [row], fetchedVenueEventRows: [])
            return mapped.first
        } catch {
#if DEBUG
            print("[FollowingNav] fetchBarVenueByIdFromSupabase failed id=\(id):", error)
#endif
            return nil
        }
    }

    private func discoverFastPinQueryBounds() -> (
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        source: String
    ) {
        if let bounds = currentMapRegionBounds() {
            return (bounds, "map_bounds")
        }

        let manager = CLLocationManager()
        if let coordinate = manager.location?.coordinate {
            return (
                boundsAround(
                    coordinate: coordinate,
                    radiusMiles: DiscoverVenueFastPinFallback.radiusMiles
                ),
                "user_location_fallback"
            )
        }

        return (
            boundsAround(
                coordinate: DiscoverVenueFastPinFallback.defaultCenter,
                radiusMiles: DiscoverVenueFastPinFallback.radiusMiles
            ),
            "default_center_fallback"
        )
    }

    private func boundsAround(
        coordinate: CLLocationCoordinate2D,
        radiusMiles: Double
    ) -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double) {
        let latDelta = radiusMiles / 69.0
        let lonMilesPerDegree = max(cos(coordinate.latitude * .pi / 180) * 69.172, 0.01)
        let lonDelta = radiusMiles / lonMilesPerDegree
        return (
            minLat: coordinate.latitude - latDelta,
            maxLat: coordinate.latitude + latDelta,
            minLon: coordinate.longitude - lonDelta,
            maxLon: coordinate.longitude + lonDelta
        )
    }

    private func fetchVenueRows(
        in bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        selectColumns: String,
        limit: Int = 200
    ) async throws -> [VenueRow] {
        return try await supabase
            .from("venues")
            .select(selectColumns)
            .or(discoverVenueActiveLegacySafeOrFilter)
            .gte("latitude", value: bounds.minLat)
            .lte("latitude", value: bounds.maxLat)
            .gte("longitude", value: bounds.minLon)
            .lte("longitude", value: bounds.maxLon)
            .limit(limit)
            .execute()
            .value
    }

    private func fetchVenueRowsUsingViewportCache(
        requestedBounds: DiscoverMapBoundsWindow,
        source: String,
        selectColumns: String,
        limit: Int = 200,
        forceRefresh: Bool = false
    ) async throws -> [VenueRow] {
        if !forceRefresh {
            let now = Date()
            let cachedEntries = discoverViewportVenueRowsCache.values.sorted { $0.fetchedAt > $1.fetchedAt }
            if let entry = cachedEntries.first(where: { entry in
                now.timeIntervalSince(entry.fetchedAt) < DiscoverViewportVenueCacheConfig.ttl
                    && entry.coverageBounds.contains(requestedBounds)
            }) {
                let filtered = filterVenueRows(entry.rows, within: requestedBounds)
                #if DEBUG
                print("[Perf] Venue viewport cache hit key=\(entry.key) requestedRows=\(filtered.count) cachedRows=\(entry.rows.count)")
                #endif
                return filtered
            }
        }

        let coverageBounds = expandedViewportBounds(for: requestedBounds)
        let cacheKey = discoverViewportVenueCacheKey(for: coverageBounds, source: source)
        #if DEBUG
        print("[Perf] Venue viewport cache miss key=\(cacheKey)")
        #endif

        let fetchedRows = try await fetchVenueRows(
            in: (
                minLat: coverageBounds.minLat,
                maxLat: coverageBounds.maxLat,
                minLon: coverageBounds.minLon,
                maxLon: coverageBounds.maxLon
            ),
            selectColumns: selectColumns,
            limit: limit
        )

        discoverViewportVenueRowsCache[cacheKey] = DiscoverViewportVenueRowsCacheEntry(
            key: cacheKey,
            source: source,
            requestedBounds: requestedBounds,
            coverageBounds: coverageBounds,
            rows: fetchedRows,
            fetchedAt: Date()
        )
        pruneDiscoverViewportVenueRowsCacheIfNeeded()
        return filterVenueRows(fetchedRows, within: requestedBounds)
    }

    func fetchVenueRowsInCurrentBounds(
        limit: Int = 200,
        selectColumns: String = DiscoverVenueFastPinSelect.columns
    ) async throws -> [VenueRow] {
        let queryWindow = discoverFastPinQueryBounds()
        return try await fetchVenueRows(
            in: queryWindow.bounds,
            selectColumns: selectColumns,
            limit: limit
        )
    }

    private func discoverVisibleVenueContext(
        from venueRows: [VenueRow],
        querySource: String,
        venueIdSupplement: [UUID] = []
    ) -> DiscoverVisibleVenueContext {
        let rowIds = venueRows.compactMap(\.id)
        let mergedIds = Array(Set(rowIds + venueIdSupplement))
        return DiscoverVisibleVenueContext(
            venueRows: venueRows,
            venueIds: mergedIds,
            ownerEmails: Array(
                Set(
                    venueRows.compactMap { $0.owner_email }
                        .map { OwnerBusinessEmail.normalized($0) }
                        .filter { OwnerBusinessEmail.isValidStrict($0) }
                )
            ),
            venueNames: Array(
                Set(
                    venueRows.compactMap { $0.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                )
            ),
            querySource: querySource
        )
    }

    /// PostgREST `ilike` value for the HTTP filter API (`*` wildcards; reserved chars escaped).
    private static func postgrestIlikeTokenForOrFilter(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let escaped = trimmed
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: ".", with: "\\.")
        return "*\(escaped)*"
    }

    private static func discoverVenueTextOrFilter(forSearchToken token: String) -> String {
        let like = postgrestIlikeTokenForOrFilter(token)
        return "venue_name.ilike.\(like),address.ilike.\(like),formatted_address.ilike.\(like),city.ilike.\(like),zip_code.ilike.\(like),postal_code.ilike.\(like),country.ilike.\(like)"
    }

    private func fetchVenueRowsForDiscoverTextSearch(
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        orFilter: String,
        limit: Int = 40
    ) async throws -> [VenueRow] {
        try await supabase
            .from("venues")
            .select(discoverVenueRowSelectColumns)
            .or(discoverVenueActiveLegacySafeOrFilter)
            .gte("latitude", value: bounds.minLat)
            .lte("latitude", value: bounds.maxLat)
            .gte("longitude", value: bounds.minLon)
            .lte("longitude", value: bounds.maxLon)
            .or(orFilter)
            .order("venue_name", ascending: true)
            .limit(limit)
            .execute()
            .value
    }

    private func fetchVenueRowsForDiscoverTextSearchGlobal(
        orFilter: String,
        limit: Int = 60
    ) async throws -> [VenueRow] {
        try await supabase
            .from("venues")
            .select(discoverVenueRowSelectColumns)
            .or(discoverVenueActiveLegacySafeOrFilter)
            .or(orFilter)
            .order("venue_name", ascending: true)
            .limit(limit)
            .execute()
            .value
    }

    /// Supabase `venues` text search (active only), scoped to map bounds first, then Utah-wide fallback. Omits `venue_events`; games are filled later by the normal Discover pipeline when present.
    /// - Parameter useViewportTextSearchBounds: When `true`, tries the current map viewport first, then Utah fallback when empty. When `false`, uses Utah-wide bounds only (place-style search not tied to the visible map).
    func fetchDiscoverVenueSearchBars(query: String, useViewportTextSearchBounds: Bool = true) async -> [BarVenue] {
        let token = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 2 else { return [] }

        let capped = String(token.prefix(72))
#if DEBUG
        print("[DiscoverSearchDebug] search query token=\(capped) useViewportTextSearchBounds=\(useViewportTextSearchBounds)")
#endif
        let orFilter = Self.discoverVenueTextOrFilter(forSearchToken: capped)

        do {
            var rows: [VenueRow] = []
            if useViewportTextSearchBounds, let viewport = currentMapRegionBounds() {
                rows = try await fetchVenueRowsForDiscoverTextSearch(bounds: viewport, orFilter: orFilter)
            }
            #if DEBUG
            print("[VenueSearch] remote bounds results count=\(rows.count)")
            #endif
            if useViewportTextSearchBounds {
                if rows.isEmpty {
                    rows = try await fetchVenueRowsForDiscoverTextSearchGlobal(orFilter: orFilter)
                    #if DEBUG
                    print("[VenueSearch] remote active fallback results count=\(rows.count)")
                    #endif
                } else {
                    #if DEBUG
                    print("[VenueSearch] remote active fallback results count=0")
                    #endif
                }
            } else {
                rows = try await fetchVenueRowsForDiscoverTextSearchGlobal(orFilter: orFilter)
                #if DEBUG
                print("[VenueSearch] remote global-active results count=\(rows.count)")
                #endif
            }

            let withIds = rows.filter { $0.id != nil }
            var seen = Set<UUID>()
            let uniqueRows = withIds.filter { row in
                guard let id = row.id else { return false }
                return seen.insert(id).inserted
            }

            var mergedUnique = uniqueRows
            do {
                let noCoordRows = try await fetchDiscoverVenueRowsNullLatitudeMatchingText(token: capped, limit: 12)
                var seenIds = Set(uniqueRows.compactMap(\.id))
                for r in noCoordRows {
                    guard let id = r.id, !seenIds.contains(id) else { continue }
                    seenIds.insert(id)
                    mergedUnique.append(r)
                }
#if DEBUG
                if !noCoordRows.isEmpty {
                    print("[DiscoverSearchDebug] merged \(noCoordRows.count) name-matched rows with null latitude (geocode pending)")
                }
#endif
            } catch {
#if DEBUG
                print("[DiscoverSearchDebug] null-latitude name search failed:", error)
#endif
            }

#if DEBUG
            let approvedManagedIds = Set(managedVenuesForOwner().compactMap(\.id))
            for row in mergedUnique {
                guard let id = row.id else { continue }
                if row.latitude == nil || row.longitude == nil {
                    print("[ApprovedVenueVisibilityDebug] missingCoordinates id=\(id.uuidString)")
                }
                if approvedManagedIds.contains(id) {
                    print("[ApprovedVenueVisibilityDebug] searchQueryIncludedApprovedVenue id=\(id.uuidString)")
                }
            }
#endif

            let (mapped, _) = await Task.detached(priority: .userInitiated) { () -> ([BarVenue], [String: UUID]) in
                DiscoverVenueLoadAssembler.buildMappedBars(venueRows: mergedUnique, fetchedVenueEventRows: [])
            }.value
            return mapped
        } catch {
            #if DEBUG
            print("[DiscoverSearch] fetchDiscoverVenueSearchBars failed:", error)
            #endif
            return []
        }
    }

    func loadVenuesFromSupabase(forceRefresh: Bool = false, logManualMapReload: Bool = false) async {
        let t0 = Date()
        let requestID = UUID()
        loadVenuesRequestID = requestID
        let citySearchDebugContext = pendingCitySearchVenueDebugContext
        #if DEBUG
        print("[DiscoverPerf] map venue reload START forceRefresh=\(forceRefresh)")
        if let citySearchDebugContext {
            print("[CitySearchVenueDebug] query=\(citySearchDebugContext.query)")
            print("[CitySearchVenueDebug] reloadTriggered=true")
            print("[CitySearchVenueDebug] requestID=\(requestID.uuidString.lowercased())")
            print("[CitySearchVenueDebug] displayMode=\(mapDisplayMode.rawValue)")
            print("[CitySearchVenueDebug] selectedSport=\(selectedSport)")
            print("[CitySearchVenueDebug] noGameCommunityIncluded=\(mapDisplayMode == .allSpots && selectedSport == "All")")
        }
        if logManualMapReload {
            print("[ManualMapReloadDebug] requestID=\(requestID.uuidString.lowercased())")
        }
        #endif

        clampDiscoverMapSelectedDateToMinimumCalendarDayIfNeeded()

        discoverSelectedDayRefreshTask?.cancel()
        discoverSelectedDayRefreshTask = nil

        if forceRefresh {
            discoverViewportVenueRowsCache.removeAll()
            discoverVenueEventsFetchCache = nil
            discoverSelectedDayVenueEventsCache.removeAll()
            venueGameCalendarDotDatesCache.removeAll()
#if DEBUG
            print("[DiscoverVisibilityDebug] cleared viewport + venue_event + calendar dot caches (forceRefresh)")
#endif
        }

        func loadVenuesRequestIsCurrent(phase: String) -> Bool {
            guard loadVenuesRequestID == requestID else {
                #if DEBUG
                print("[DiscoverReloadSmoothDebug] staleRequestIgnored phase=\(phase)")
                #endif
                return false
            }
            return true
        }

        let preserveExistingRows = !bars.isEmpty || !venueEventRows.isEmpty
        let coldStartPhase1Allowed = bars.isEmpty && venueEventRows.isEmpty
        #if DEBUG
        if preserveExistingRows {
            print("[DiscoverReloadSmoothDebug] preserveExistingRows=true")
        }
        if coldStartPhase1Allowed {
            print("[DiscoverReloadSmoothDebug] coldStartPhase1Allowed=true")
        }
        #endif

        let showBlockingMapSpinner = coldStartPhase1Allowed
        isLoadingMapVenues = showBlockingMapSpinner
        isRefreshingMapVenues = !showBlockingMapSpinner
        defer {
            if loadVenuesRequestIsCurrent(phase: "finalLoadingState") {
                isLoadingMapVenues = false
                isRefreshingMapVenues = false
                if citySearchDebugContext != nil {
                    pendingCitySearchVenueDebugContext = nil
                }
            }
        }

        do {
            suppressDiscoverSnapshotRebuilds = true
            defer {
                suppressDiscoverSnapshotRebuilds = false
                flushDiscoverMapRenderSnapshotRebuild(reason: "loadVenuesFromSupabase")
            }

            let phase1Query = discoverFastPinQueryBounds()
            let venueRowsRaw = try await fetchVenueRowsUsingViewportCache(
                requestedBounds: boundsWindow(from: phase1Query.bounds),
                source: phase1Query.source,
                selectColumns: DiscoverVenueFastPinSelect.columns,
                limit: 200,
                forceRefresh: forceRefresh
            )
            let venueRows = try await mergeManagedVenueRowForOwnerDiscoverIfNeeded(into: venueRowsRaw)
            let windowForDiscoverLog = boundsWindow(from: phase1Query.bounds)
#if DEBUG
            discoverDebugLogPublicVenueRowsForDiscover(venueRows, window: windowForDiscoverLog)
#endif
            let patchedCoordinateIds = await backfillOwnedVenueCoordinatesInDiscoverVenueRows(venueRows)
            let venueRowsForContext: [VenueRow]
            if patchedCoordinateIds.isEmpty {
                venueRowsForContext = venueRows
            } else {
                venueRowsForContext = try await refreshDiscoverVenueRowsByIds(venueRows, ids: patchedCoordinateIds)
#if DEBUG
                discoverDebugLogPublicVenueRowsForDiscover(venueRowsForContext, window: windowForDiscoverLog)
#endif
            }
#if DEBUG
            if citySearchDebugContext != nil {
                print("[CitySearchVenueDebug] rowsReturned=\(venueRowsForContext.count)")
            }
            let approvedManagedIdsForDiscover = Set(managedVenuesForOwner().compactMap(\.id))
            for row in venueRowsForContext {
                guard let id = row.id else { continue }
                if row.latitude == nil || row.longitude == nil {
                    print("[ApprovedVenueVisibilityDebug] missingCoordinates id=\(id.uuidString)")
                }
                if approvedManagedIdsForDiscover.contains(id) {
                    print("[ApprovedVenueVisibilityDebug] discoverQueryIncludedApprovedVenue id=\(id.uuidString)")
                }
            }
#endif

            let selectedDay = DiscoverVenueGameDateFormatting.sqlDate.string(from: selectedDate)
            let supplementVenueIds = try await discoverSupplementVenueIdsFromSelectedDayEvents(
                selectedDay: selectedDay,
                sport: selectedSport,
                existingVenueIds: Set(venueRowsForContext.compactMap(\.id))
            )
#if DEBUG
            if !supplementVenueIds.isEmpty {
                print("[DiscoverVenuePublic] supplementVenueIdsForDayEvents count=\(supplementVenueIds.count) selectedDay=\(selectedDay)")
            }
#endif

            let baseVisibleVenueContext = discoverVisibleVenueContext(
                from: venueRowsForContext,
                querySource: phase1Query.source,
                venueIdSupplement: supplementVenueIds
            )
            let visibleVenueContext = augmentDiscoverVisibleVenueContextForOwnerSession(baseVisibleVenueContext)

            guard loadVenuesRequestIsCurrent(phase: "phase1") else { return }
            discoverCurrentVisibleVenueRows = visibleVenueContext.venueRows
            discoverCurrentVisibleVenueIds = visibleVenueContext.venueIds
            discoverCurrentVisibleOwnerEmails = visibleVenueContext.ownerEmails
            discoverCurrentVisibleVenueNames = visibleVenueContext.venueNames

            let (phase1Bars, _): ([BarVenue], [String: UUID]) = await Task.detached(priority: .userInitiated) { () -> ([BarVenue], [String: UUID]) in
                DiscoverVenueLoadAssembler.buildMappedBars(
                    venueRows: visibleVenueContext.venueRows,
                    fetchedVenueEventRows: []
                )
            }.value

            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil

            if coldStartPhase1Allowed {
                var mergedPhase1Bars = phase1Bars
                if let sel = selectedBar, !mergedPhase1Bars.contains(where: { $0.id == sel.id }) {
                    mergedPhase1Bars.append(sel)
                }

                if SampleData.includeSampleData {
                    await invalidateDiscoverImageCacheForChangedVenuePhotos(newBars: mergedPhase1Bars)
                    bars = mergedPhase1Bars + SampleData.bars
                } else {
                    await invalidateDiscoverImageCacheForChangedVenuePhotos(newBars: mergedPhase1Bars)
                    bars = mergedPhase1Bars
                }
                updateSelectedVenuePhotoStateFromLoadedBars(mergedPhase1Bars)

                venueEventRows = []
                rebuildVenueEventIDsByKey(from: [])
                pruneSelectionIfNeededAfterFilterChange()

                if showBlockingMapSpinner {
                    guard loadVenuesRequestIsCurrent(phase: "phase1LoadingState") else { return }
                    isLoadingMapVenues = false
                    isRefreshingMapVenues = true
                }
            }

            let phase1CompletedAt = Date()

            #if DEBUG
            if logManualMapReload {
                print("[ManualMapReloadDebug] rowsReturned=\(venueRowsForContext.count)")
            }
            let phase1Ms = Int(phase1CompletedAt.timeIntervalSince(t0) * 1000)
            print("[Phase1Perf] fast venue load ms=\(phase1Ms) bars=\(phase1Bars.count) source=\(visibleVenueContext.querySource)")
            print("[Perf] Phase 1 pins loaded ms=\(phase1Ms) bars=\(phase1Bars.count)")
            #endif

            let fetchedVenueEventRows = try await fetchVenueEventRowsForDiscover(
                venueIds: visibleVenueContext.venueIds,
                ownerEmails: visibleVenueContext.ownerEmails,
                venueNames: visibleVenueContext.venueNames,
                dateLower: selectedDay,
                dateUpper: selectedDay,
                sport: selectedSport
            )

            let rowsCopy = visibleVenueContext.venueRows
            let eventsCopy = fetchedVenueEventRows
            let (phase2Bars, idsByKey): ([BarVenue], [String: UUID]) = await Task.detached(priority: .userInitiated) { () -> ([BarVenue], [String: UUID]) in
                DiscoverVenueLoadAssembler.buildMappedBars(venueRows: rowsCopy, fetchedVenueEventRows: eventsCopy)
            }.value

            guard loadVenuesRequestIsCurrent(phase: "phase2") else { return }
            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil

            var mergedPhase2Bars = phase2Bars
            if let sel = selectedBar, !mergedPhase2Bars.contains(where: { $0.id == sel.id }) {
                mergedPhase2Bars.append(sel)
            }

            if SampleData.includeSampleData {
                await invalidateDiscoverImageCacheForChangedVenuePhotos(newBars: mergedPhase2Bars)
                bars = mergedPhase2Bars + SampleData.bars
            } else {
                await invalidateDiscoverImageCacheForChangedVenuePhotos(newBars: mergedPhase2Bars)
                bars = mergedPhase2Bars
            }
            updateSelectedVenuePhotoStateFromLoadedBars(mergedPhase2Bars)

            venueEventRows = fetchedVenueEventRows
            venueEventIDsByKey = idsByKey
            await mergeVenueSliceIntoEvents(venueRows: fetchedVenueEventRows)
            await reconcileGameRemindersForLoadedVenueEvents()
            pruneSelectionIfNeededAfterFilterChange()
            persistDiscoverCoreSnapshot()
#if DEBUG
            print("[PerfPhase1D] deferredCalendarWork reason=phase1_preload")
#endif

            #if DEBUG
            print("[DiscoverReloadSmoothDebug] finalApply venueRows=\(fetchedVenueEventRows.count)")
            let phase2Ms = Int(Date().timeIntervalSince(phase1CompletedAt) * 1000)
            let totalMs = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Phase2Perf] selected-day venue event load ms=\(phase2Ms) rows=\(fetchedVenueEventRows.count) visibleVenueIds=\(visibleVenueContext.venueIds.count)")
            print("[DiscoverPerf] map venue reload DONE bars=\(phase2Bars.count) selected_day_venue_events=\(fetchedVenueEventRows.count) totalMs=\(totalMs)")
            print("[Perf] Phase 2 selected-day events loaded ms=\(phase2Ms) rows=\(fetchedVenueEventRows.count)")
            let dbgDateFmt = DateFormatter()
            dbgDateFmt.dateFormat = "yyyy-MM-dd"
            dbgDateFmt.timeZone = TimeZone.current
            print("[DiscoverVenueEventsDebug] visibleVenueIds count=\(visibleVenueContext.venueIds.count)")
            print("[DiscoverVenueEventsDebug] fetched venue_events count=\(fetchedVenueEventRows.count)")
            let maxEvLog = 60
            for row in fetchedVenueEventRows.prefix(maxEvLog) {
                let idStr = row.id?.uuidString ?? "nil"
                let vid = row.venue_id?.uuidString ?? "nil"
                let nm = row.venue_name ?? ""
                let dt = row.event_date ?? ""
                let sp = row.sport ?? ""
                let adm = row.admin_status ?? "nil"
                print("[DiscoverVenueEventsDebug] event id=\(idStr) venue_id=\(vid) venue_name=\(nm) event_date=\(dt) sport=\(sp) admin_status=\(adm)")
            }
            if fetchedVenueEventRows.count > maxEvLog {
                print("[DiscoverVenueEventsDebug] … omitted \(fetchedVenueEventRows.count - maxEvLog) additional venue_events from per-row log")
            }
            let maxBarLog = 50
            for bar in phase2Bars.prefix(maxBarLog) {
                print("[DiscoverVenueEventsDebug] mapped bar=\(bar.name) games count=\(bar.games.count)")
            }
            if phase2Bars.count > maxBarLog {
                print("[DiscoverVenueEventsDebug] … omitted \(phase2Bars.count - maxBarLog) additional bars from mapped log")
            }
            let filteredDiscoverCount = bars.filter { !matchingEventsForDiscoverFilter(bar: $0).isEmpty }.count
            print("[DiscoverVenueEventsDebug] filteredBars count=\(filteredDiscoverCount)")
            print("[DiscoverVenueEventsDebug] selectedDate=\(dbgDateFmt.string(from: selectedDate)) selectedSport=\(selectedSport)")
            if citySearchDebugContext != nil {
                print("[CitySearchVenueDebug] visiblePins=\(mapVisibleBars.count)")
            }
            #endif

        } catch {
            #if DEBUG
            if logManualMapReload {
                print("[ManualMapReloadDebug] rowsReturned=0")
            }
            print("[DiscoverPerf] map venue reload ERROR:", error)
            #endif
        }
    }

    /// Coalesces overlapping schedule loads (Discover + Calendar + ``refreshDiscoverCoreInBackground``).
    func loadGamesFromSupabase() {
        loadGamesCoalesceNeedsAnotherPass = true
        guard loadGamesCoalesceTask == nil else { return }
        loadGamesCoalesceTask = Task { @MainActor in
            defer { self.loadGamesCoalesceTask = nil }
            while self.loadGamesCoalesceNeedsAnotherPass {
                self.loadGamesCoalesceNeedsAnotherPass = false
                await self.performLoadGamesFromSupabase()
            }
        }
    }

    /// Awaits until the coalesced games loader queue is idle (used after map venue reload in ``refreshDiscoverCoreInBackground``).
    func awaitLoadGamesCoalescedUntilIdle() async {
        loadGamesFromSupabase()
        while let t = loadGamesCoalesceTask {
            await t.value
        }
    }

    /// Official `games` rows + `venue_events` → ``events`` / calendar dots / IDs. Interest counts load separately via ``refreshSocialEnrichmentInBackground()`` so Discover stays responsive.
    func performLoadGamesFromSupabase() async {
        let perfWallStart = Date()

        await MainActor.run {
            eventLoadError = nil
            let blockSpinner = !discoverSnapshotRestoredThisLaunch && !didCompleteSuccessfulGamesFetch
            isLoadingEvents = blockSpinner
            let hasSurfaceData = !events.isEmpty || !bars.isEmpty || discoverSnapshotRestoredThisLaunch
            isRefreshingDiscoverEvents = !blockSpinner && hasSurfaceData
        }

        do {
            let sport = selectedSport
            let dateLowerOfficial = tenDaysAgoString()
            let dateUpperOfficial = discoverGamesDateUpperString(daysForward: 365)
            let dateLowerVenue = discoverGamesDateLowerString(daysBack: 30)
            let dateUpperVenue = discoverGamesDateUpperString(daysForward: 180)

            let officialRows: [GameRow] = try await supabase
                .from("games")
                .select("title,sport,league,game_date,game_time")
                .gte("game_date", value: dateLowerOfficial)
                .lte("game_date", value: dateUpperOfficial)
                .order("game_date", ascending: true)
                .execute()
                .value

            let officialEvents: [SportsEvent] = await Task.detached(priority: .userInitiated) { () -> [SportsEvent] in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone.current
                return DiscoverVenueLoadAssembler.sportsEventsFromOfficialRows(officialRows, formatter: formatter)
            }.value

            let ownerEmailsFromBars = Array(
                Set(
                    bars.compactMap { $0.ownerEmail }.map { OwnerBusinessEmail.normalized($0) }
                        .filter { OwnerBusinessEmail.isValidStrict($0) }
                )
            )
            let venueNamesFromBars = Array(Set(bars.map(\.name).filter { !$0.isEmpty }))

            let venueRowsForKeys: [VenueRow]
            if ownerEmailsFromBars.isEmpty && venueNamesFromBars.isEmpty {
                venueRowsForKeys = try await fetchVenueRowsInCurrentBounds(limit: 200)
            } else {
                venueRowsForKeys = []
            }

            let ownerEmails: [String]
            let venueNames: [String]
            if venueRowsForKeys.isEmpty {
                ownerEmails = ownerEmailsFromBars
                venueNames = venueNamesFromBars
            } else {
                ownerEmails = Array(
                    Set(
                        venueRowsForKeys.compactMap { $0.owner_email }.map { OwnerBusinessEmail.normalized($0) }
                            .filter { OwnerBusinessEmail.isValidStrict($0) }
                    )
                )
                venueNames = Array(
                    Set(venueRowsForKeys.compactMap { $0.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                )
            }

            let venueIdsForEvents = Array(
                Set(bars.map(\.id) + venueRowsForKeys.compactMap(\.id) + discoverCurrentVisibleVenueIds)
            )

            let venueEventRowsFetched = try await fetchVenueEventRowsForDiscover(
                venueIds: venueIdsForEvents,
                ownerEmails: ownerEmails,
                venueNames: venueNames,
                dateLower: dateLowerVenue,
                dateUpper: dateUpperVenue,
                sport: sport
            )

            let venueEventsAsSportsEvents: [SportsEvent] = await Task.detached(priority: .userInitiated) { () -> [SportsEvent] in
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"
                formatter.timeZone = TimeZone.current
                return DiscoverVenueLoadAssembler.sportsEventsFromVenueEventRows(venueEventRowsFetched, formatter: formatter)
            }.value

            var finalEvents = officialEvents + venueEventsAsSportsEvents
            if SampleData.includeSampleData {
                finalEvents.append(contentsOf: SampleData.events)
            }

            await MainActor.run {
                discoverClusteredBarsCacheKey = nil
                discoverClusteredBarsCache = nil
                events = finalEvents
                venueEventRows = venueEventRowsFetched
                rebuildVenueEventIDsByKey(from: venueEventRowsFetched)
                bumpScheduleDataGeneration()
                recomputeCalendarDotDates()
                eventLoadError = nil
                isLoadingEvents = false
                isRefreshingDiscoverEvents = false
                didCompleteSuccessfulGamesFetch = true
                pruneSelectionIfNeededAfterFilterChange()
                persistDiscoverCoreSnapshot()
            }

            #if DEBUG
            let wallMs = Int(Date().timeIntervalSince(perfWallStart) * 1000)
            print("[Phase3Perf] performLoadGamesFromSupabase totalMs=\(wallMs) official=\(officialEvents.count) venueEvents=\(venueEventsAsSportsEvents.count)")
            print("[DiscoverPerf] loadGames DONE official=\(officialEvents.count) venueEvents=\(venueEventsAsSportsEvents.count)")
            #endif

        } catch {
            #if DEBUG
            print("ERROR LOADING GAMES FROM SUPABASE:", error)
            #endif

            await MainActor.run {
                eventLoadError = "Couldn't refresh venues for this date. Showing your last results."
                isLoadingEvents = false
                isRefreshingDiscoverEvents = false
            }
        }
    }

    func tenDaysAgoString() -> String {
        discoverGamesDateLowerString(daysBack: 10)
    }
}
