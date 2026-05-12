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

private let discoverVenueRowSelectColumns =
    "id,owner_email,business_id,venue_identity_key,admin_status,venue_name,address,city,state,zip_code,phone,website,description,features," +
    "screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,latitude,longitude," +
    "cover_photo_url,menu_photo_url,cover_photo_thumbnail_url,menu_photo_thumbnail_url"

private let discoverVenueFastPinSelectColumns =
    "id,venue_name,address,city,state,zip_code,latitude,longitude,owner_email,business_id,admin_status,screen_count,venue_identity_key"

private let discoverVenueActiveLegacySafeOrFilter = "admin_status.is.null,admin_status.eq.active"

private enum DiscoverVenueFastPinFallback {
    static let radiusMiles = 70.0
    static let defaultCenter = CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508)
}

private enum DiscoverViewportVenueCacheConfig {
    static let ttl: TimeInterval = 90
    static let maxEntries = 6
    static let expansionFactor = 1.35
}

/// Broader map bounds when the visible viewport text search returns no rows (Utah / project default area).
private enum DiscoverVenueSearchFallbackBounds {
    static let minLat = 36.95
    static let maxLat = 42.05
    static let minLon = -114.35
    static let maxLon = -109.0
}

// MARK: - Discover disk snapshot (venues + venue_events + merged events for instant map/calendar)

private struct DiscoverPersistedBarVenue: Codable {
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
    let screenCount: Int
    let servesFood: Bool
    let hasWifi: Bool
    let hasGarden: Bool
    let hasProjector: Bool
    let petFriendly: Bool
    let coverPhotoURL: String?
    let menuPhotoURL: String?
    let coverPhotoThumbnailURL: String?
    let menuPhotoThumbnailURL: String?
    let ownerEmail: String?
    let businessId: UUID?
    let adminStatus: String?

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
        coverPhotoURL = bar.coverPhotoURL
        menuPhotoURL = bar.menuPhotoURL
        coverPhotoThumbnailURL = bar.coverPhotoThumbnailURL
        menuPhotoThumbnailURL = bar.menuPhotoThumbnailURL
        ownerEmail = bar.ownerEmail
        businessId = bar.businessId
        adminStatus = bar.adminStatus
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
            coverPhotoURL: coverPhotoURL,
            menuPhotoURL: menuPhotoURL,
            coverPhotoThumbnailURL: coverPhotoThumbnailURL,
            menuPhotoThumbnailURL: menuPhotoThumbnailURL,
            ownerEmail: ownerEmail,
            businessId: businessId,
            adminStatus: adminStatus
        )
    }
}

private struct DiscoverCoreDiskSnapshot: Codable {
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

extension MapViewModel {

    private static var discoverCoreSnapshotURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("gameon_discover_core_snapshot_v2_admin_active.json", isDirectory: false)
    }

    func renderCachedDiscoverCore() {
        let t0 = Date()
        discoverSnapshotRestoredThisLaunch = false
        guard let data = try? Data(contentsOf: Self.discoverCoreSnapshotURL) else {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[CriticalPath] cached core rendered ms=\(ms) bars=0 (no snapshot file)")
            #endif
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        guard let snap = try? decoder.decode(DiscoverCoreDiskSnapshot.self, from: data),
              !snap.bars.isEmpty else {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[CriticalPath] cached core rendered ms=\(ms) bars=0 (decode failed)")
            #endif
            return
        }
        applyRestoredDiscoverCoreSnapshot(snap)
        discoverSnapshotRestoredThisLaunch = true
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[CriticalPath] cached core rendered ms=\(ms) bars=\(bars.count) events=\(events.count)")
        #endif
    }

    private func applyRestoredDiscoverCoreSnapshot(_ snap: DiscoverCoreDiskSnapshot) {
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

        events = snap.events
        bumpScheduleDataGeneration()
        recomputeCalendarDotDates()
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
        do {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .deferredToDate
            let data = try enc.encode(snap)
            try data.write(to: Self.discoverCoreSnapshotURL, options: .atomic)
        } catch {
            #if DEBUG
            print("[CriticalPath] discover snapshot save failed:", error)
            #endif
        }
    }

    /// Fast pins first, selected-day venue events second, then heavier enrichment in the background.
    func refreshDiscoverCoreInBackground() async {
        let t0 = Date()
        #if DEBUG
        print("[Perf] Discover startup begin")
        #endif
        await loadVenuesFromSupabase()
        scheduleDiscoverFullEnrichmentInBackground()
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[CriticalPath] fresh core visible ms=\(ms) bars=\(bars.count) events=\(events.count)")
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

    private func discoverGamesDateLowerString(daysBack: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        return DiscoverVenueGameDateFormatting.sqlDate.string(from: d)
    }

    private func discoverGamesDateUpperString(daysForward: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: daysForward, to: Date()) ?? Date()
        return DiscoverVenueGameDateFormatting.sqlDate.string(from: d)
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
            #if DEBUG
            print("[Phase1Perf] fetchVenueEventRowsForDiscover CACHE_HIT rows=\(cached.rows.count) ms=0")
            print("[DiscoverPerf] calendar/venue_events cache HIT rows=\(cached.rows.count) keyPrefix=\(String(cacheKey.prefix(96)))…")
            print("[DiscoverVenueEventsDebug] fetched venue_events count=\(cached.rows.count) (cache hit)")
            #endif
            return cached.rows
        }

        #if DEBUG
        print("[DiscoverPerf] calendar/venue_events cache MISS keyPrefix=\(String(cacheKey.prefix(96)))…")
        #endif

        let t0 = Date()
        var byID: [UUID: VenueEventRow] = [:]
        let selectCols = "id,venue_id,owner_email,venue_name,event_title,sport,event_date,event_time,admin_status"
        let chunkSize = 80

        func mergeRows(_ rows: [VenueEventRow]) {
            for row in rows {
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
        discoverVenueEventsFetchCache = (key: cacheKey, rows: merged, fetchedAt: Date())

        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[Phase1Perf] fetchVenueEventRowsForDiscover rows=\(merged.count) ms=\(ms)")
        print("[DiscoverPerf] venue_events fetch rows=\(merged.count) ms=\(ms)")
        print("[DiscoverVenueEventsDebug] fetched venue_events count=\(merged.count) (fresh fetch)")
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
        venueRows: [VenueRow]
    ) async {
        let rowsCopy = venueRows
        let eventsCopy = fetchedVenueEventRows
        let (phaseBars, idsByKey): ([BarVenue], [String: UUID]) = await Task.detached(priority: .userInitiated) { () -> ([BarVenue], [String: UUID]) in
            DiscoverVenueLoadAssembler.buildMappedBars(venueRows: rowsCopy, fetchedVenueEventRows: eventsCopy)
        }.value

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
        mergeVenueSliceIntoEvents(venueRows: fetchedVenueEventRows)
        pruneSelectionIfNeededAfterFilterChange()
        persistDiscoverCoreSnapshot()
    }

    func refreshDiscoverSelectedDayVenueEventsForCurrentContext() {
        discoverSelectedDayRefreshTask?.cancel()
        discoverSelectedDayRefreshTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.discoverSelectedDayRefreshTask = nil }

            let venueRows = self.discoverCurrentVisibleVenueRows
            let venueIds = self.discoverCurrentVisibleVenueIds
            let ownerEmails = self.discoverCurrentVisibleOwnerEmails
            let venueNames = self.discoverCurrentVisibleVenueNames

            guard !venueRows.isEmpty else {
                await self.loadVenuesFromSupabase()
                return
            }

            let selectedDay = DiscoverVenueGameDateFormatting.sqlDate.string(from: self.selectedDate)
            let selectedSportSnapshot = self.selectedSport
            let boundsBucket = self.discoverBoundsBucketString()
            let cacheKey = self.discoverVenueEventsCacheKey(
                boundsBucket: boundsBucket,
                sport: selectedSportSnapshot,
                dateLower: selectedDay,
                dateUpper: selectedDay,
                venueIds: venueIds,
                ownerEmails: ownerEmails,
                venueNames: venueNames
            )

            #if DEBUG
            print("[DiscoverDatePerf] selected-day refresh start date=\(selectedDay) sport=\(selectedSportSnapshot) visibleVenueIds=\(venueIds.count)")
            #endif

            self.isRefreshingDiscoverEvents = true
            self.isUpdatingMapGames = true
            self.mapStatusText = "Updating games..."
            defer {
                self.isRefreshingDiscoverEvents = false
                self.isUpdatingMapGames = false
                self.mapStatusText = nil
            }

            if let cached = self.discoverSelectedDayVenueEventsCache[cacheKey],
               Date().timeIntervalSince(cached.fetchedAt) < 90 {
                #if DEBUG
                print("[DiscoverDatePerf] selected-day cache hit date=\(selectedDay) rows=\(cached.rows.count)")
                #endif
                await self.applyDiscoverSelectedDayVenueRows(cached.rows, venueRows: venueRows)
                #if DEBUG
                print("[DiscoverDatePerf] pins updated from cache date=\(selectedDay) rows=\(cached.rows.count)")
                #endif
            }

            do {
                #if DEBUG
                print("[DiscoverDatePerf] selected-day fetch start date=\(selectedDay)")
                #endif
                let fetchedVenueEventRows = try await self.fetchVenueEventRowsForDiscover(
                    venueIds: venueIds,
                    ownerEmails: ownerEmails,
                    venueNames: venueNames,
                    dateLower: selectedDay,
                    dateUpper: selectedDay,
                    sport: selectedSportSnapshot
                )
                guard !Task.isCancelled else { return }

                self.discoverSelectedDayVenueEventsCache[cacheKey] = (rows: fetchedVenueEventRows, fetchedAt: Date())
                self.pruneDiscoverSelectedDayVenueEventsCacheIfNeeded()

                #if DEBUG
                print("[DiscoverDatePerf] selected-day fetch complete date=\(selectedDay) rows=\(fetchedVenueEventRows.count)")
                #endif

                await self.applyDiscoverSelectedDayVenueRows(fetchedVenueEventRows, venueRows: venueRows)
                #if DEBUG
                print("[DiscoverDatePerf] pins updated date=\(selectedDay) rows=\(fetchedVenueEventRows.count)")
                #endif
            } catch is CancellationError {
                return
            } catch {
                #if DEBUG
                print("[DiscoverDatePerf] selected-day refresh error date=\(selectedDay) error=\(error)")
                #endif
                self.eventLoadError = "Couldn't refresh games for this date. Showing your last results."
            }
        }
    }

    private func rebuildVenueEventIDsByKey(from rows: [VenueEventRow]) {
        var idsByKey: [String: UUID] = [:]
        for row in rows {
            guard let id = row.id, let title = row.event_title else { continue }
            if let venueId = row.venue_id {
                idsByKey["\(venueId.uuidString)-\(title)"] = id
            }
            if let venueName = row.venue_name {
                idsByKey["\(venueName)-\(title)"] = id
            }
        }
        venueEventIDsByKey = idsByKey
    }

    private func mergeVenueSliceIntoEvents(venueRows: [VenueEventRow]) {
        let nonVenue = events.filter { $0.league != "Venue Event" }
        let fmt = DiscoverVenueGameDateFormatting.sqlDate
        var next = nonVenue + DiscoverVenueLoadAssembler.sportsEventsFromVenueEventRows(venueRows, formatter: fmt)
        if SampleData.includeSampleData {
            next.append(contentsOf: SampleData.events.filter { $0.league == "Venue Event" })
        }
        events = next
        bumpScheduleDataGeneration()
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
            await self.awaitLoadGamesCoalescedUntilIdle()
            guard !Task.isCancelled else { return }
            await self.refreshSocialEnrichmentInBackground()

            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Phase3Perf] full enrichment load ms=\(ms) bars=\(self.bars.count) events=\(self.events.count)")
            print("[Perf] Phase 3 enrichment completed ms=\(ms)")
            #endif
        }
    }

    /// After a venue owner inserts a game, patch in-memory Discover/calendar/map state so the new listing appears without waiting for the next full fetch.
    func applyCreatedVenueEventLocally(_ row: VenueEventRow) {
        if let id = row.id {
            venueEventRows.removeAll { $0.id == id }
        }
        venueEventRows.append(row)

        rebuildVenueEventIDsByKey(from: venueEventRows)
        mergeVenueSliceIntoEvents(venueRows: venueEventRows)

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
                    coverPhotoURL: bar.coverPhotoURL,
                    menuPhotoURL: bar.menuPhotoURL,
                    coverPhotoThumbnailURL: bar.coverPhotoThumbnailURL,
                    menuPhotoThumbnailURL: bar.menuPhotoThumbnailURL,
                    ownerEmail: bar.ownerEmail,
                    businessId: bar.businessId
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
        selectColumns: String = discoverVenueFastPinSelectColumns
    ) async throws -> [VenueRow] {
        let queryWindow = discoverFastPinQueryBounds()
        return try await fetchVenueRows(
            in: queryWindow.bounds,
            selectColumns: selectColumns,
            limit: limit
        )
    }

    private func discoverVisibleVenueContext(from venueRows: [VenueRow], querySource: String) -> DiscoverVisibleVenueContext {
        DiscoverVisibleVenueContext(
            venueRows: venueRows,
            venueIds: venueRows.compactMap(\.id),
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
        return "venue_name.ilike.\(like),address.ilike.\(like),city.ilike.\(like),zip_code.ilike.\(like)"
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

    /// Supabase `venues` text search (active only), scoped to map bounds first, then Utah-wide fallback. Omits `venue_events`; games are filled later by the normal Discover pipeline when present.
    func fetchDiscoverVenueSearchBars(query: String) async -> [BarVenue] {
        let token = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard token.count >= 2 else { return [] }

        let capped = String(token.prefix(72))
        let orFilter = Self.discoverVenueTextOrFilter(forSearchToken: capped)

        do {
            var rows: [VenueRow] = []
            if let viewport = currentMapRegionBounds() {
                rows = try await fetchVenueRowsForDiscoverTextSearch(bounds: viewport, orFilter: orFilter)
            }
            #if DEBUG
            print("[VenueSearch] remote bounds results count=\(rows.count)")
            #endif
            if rows.isEmpty {
                let fb = DiscoverVenueSearchFallbackBounds.self
                rows = try await fetchVenueRowsForDiscoverTextSearch(
                    bounds: (fb.minLat, fb.maxLat, fb.minLon, fb.maxLon),
                    orFilter: orFilter
                )
                #if DEBUG
                print("[VenueSearch] remote Utah fallback results count=\(rows.count)")
                #endif
            } else {
                #if DEBUG
                print("[VenueSearch] remote Utah fallback results count=0")
                #endif
            }

            let withIds = rows.filter { $0.id != nil }
            var seen = Set<UUID>()
            let uniqueRows = withIds.filter { row in
                guard let id = row.id else { return false }
                return seen.insert(id).inserted
            }

            let (mapped, _) = await Task.detached(priority: .userInitiated) { () -> ([BarVenue], [String: UUID]) in
                DiscoverVenueLoadAssembler.buildMappedBars(venueRows: uniqueRows, fetchedVenueEventRows: [])
            }.value
            return mapped
        } catch {
            #if DEBUG
            print("[DiscoverSearch] fetchDiscoverVenueSearchBars failed:", error)
            #endif
            return []
        }
    }

    func loadVenuesFromSupabase(forceRefresh: Bool = false) async {
        let t0 = Date()
        #if DEBUG
        print("[DiscoverPerf] map venue reload START")
        #endif

        discoverSelectedDayRefreshTask?.cancel()
        discoverSelectedDayRefreshTask = nil

        let showBlockingMapSpinner = bars.isEmpty
        isLoadingMapVenues = showBlockingMapSpinner
        isRefreshingMapVenues = !showBlockingMapSpinner
        defer {
            isLoadingMapVenues = false
            isRefreshingMapVenues = false
        }

        do {
            let phase1Query = discoverFastPinQueryBounds()
            let venueRows = try await fetchVenueRowsUsingViewportCache(
                requestedBounds: boundsWindow(from: phase1Query.bounds),
                source: phase1Query.source,
                selectColumns: discoverVenueFastPinSelectColumns,
                limit: 200,
                forceRefresh: forceRefresh
            )
            let visibleVenueContext = discoverVisibleVenueContext(from: venueRows, querySource: phase1Query.source)
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

            var mergedPhase1Bars = phase1Bars
            if let sel = selectedBar, !mergedPhase1Bars.contains(where: { $0.id == sel.id }) {
                mergedPhase1Bars.append(sel)
            }

            if SampleData.includeSampleData {
                bars = mergedPhase1Bars + SampleData.bars
            } else {
                bars = mergedPhase1Bars
            }

            venueEventRows = []
            rebuildVenueEventIDsByKey(from: [])
            pruneSelectionIfNeededAfterFilterChange()

            if showBlockingMapSpinner {
                isLoadingMapVenues = false
                isRefreshingMapVenues = true
            }

            let phase1CompletedAt = Date()

            #if DEBUG
            let phase1Ms = Int(phase1CompletedAt.timeIntervalSince(t0) * 1000)
            print("[Phase1Perf] fast venue load ms=\(phase1Ms) bars=\(phase1Bars.count) source=\(visibleVenueContext.querySource)")
            print("[Perf] Phase 1 pins loaded ms=\(phase1Ms) bars=\(phase1Bars.count)")
            #endif

            let selectedDay = DiscoverVenueGameDateFormatting.sqlDate.string(from: selectedDate)
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

            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil

            var mergedPhase2Bars = phase2Bars
            if let sel = selectedBar, !mergedPhase2Bars.contains(where: { $0.id == sel.id }) {
                mergedPhase2Bars.append(sel)
            }

            if SampleData.includeSampleData {
                bars = mergedPhase2Bars + SampleData.bars
            } else {
                bars = mergedPhase2Bars
            }

            venueEventRows = fetchedVenueEventRows
            venueEventIDsByKey = idsByKey
            mergeVenueSliceIntoEvents(venueRows: fetchedVenueEventRows)
            pruneSelectionIfNeededAfterFilterChange()
            persistDiscoverCoreSnapshot()

            #if DEBUG
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
            #endif

        } catch {
            #if DEBUG
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
                Set(bars.map(\.id) + venueRowsForKeys.compactMap(\.id))
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
