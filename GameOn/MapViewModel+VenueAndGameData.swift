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
    "id,owner_email,venue_name,address,city,state,zip_code,phone,website,description,features," +
    "screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,latitude,longitude," +
    "cover_photo_url,menu_photo_url,cover_photo_thumbnail_url,menu_photo_thumbnail_url"

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
            ownerEmail: ownerEmail
        )
    }
}

private struct DiscoverCoreDiskSnapshot: Codable {
    var savedAt: Date
    var bars: [DiscoverPersistedBarVenue]
    var venueEventRows: [VenueEventRow]
    var events: [SportsEvent]
}

extension MapViewModel {

    private static var discoverCoreSnapshotURL: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("gameon_discover_core_snapshot.json", isDirectory: false)
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

        let mapped = snap.bars.map { $0.toBarVenue() }
        if SampleData.includeSampleData {
            bars = mapped + SampleData.bars
        } else {
            bars = mapped
        }
        venueEventRows = snap.venueEventRows
        rebuildVenueEventIDsByKey(from: snap.venueEventRows)

        events = snap.events
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

    /// Venues → schedule/venue_events (sequential so games query keys off fresh ``bars``), then logs fresh-core timing. Social interests run from ``refreshSocialEnrichmentInBackground()`` after this returns.
    func refreshDiscoverCoreInBackground() async {
        let t0 = Date()
        await loadVenuesFromSupabase()
        await performLoadGamesFromSupabase()
        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[CriticalPath] fresh core loaded ms=\(ms) bars=\(bars.count) events=\(events.count)")
        #endif
    }

    private func discoverGamesDateLowerString(daysBack: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: -daysBack, to: Date()) ?? Date()
        return DiscoverVenueGameDateFormatting.sqlDate.string(from: d)
    }

    private func discoverGamesDateUpperString(daysForward: Int) -> String {
        let d = Calendar.current.date(byAdding: .day, value: daysForward, to: Date()) ?? Date()
        return DiscoverVenueGameDateFormatting.sqlDate.string(from: d)
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
        ownerEmails: [String],
        venueNames: [String]
    ) -> String {
        "\(boundsBucket)|\(sport)|\(dateLower)|\(dateUpper)|o:\(ownerEmails.count):\(ownerEmails.sorted().joined(separator: ",").prefix(400))|v:\(venueNames.count):\(venueNames.sorted().joined(separator: ",").prefix(400))"
    }

    /// Batched `venue_events` for Discover: owner_email OR venue_name, date window, optional sport, minimal columns.
    private func fetchVenueEventRowsForDiscover(
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
            ownerEmails: ownerEmails,
            venueNames: venueNames
        )

        if let cached = discoverVenueEventsFetchCache,
           cached.key == cacheKey,
           Date().timeIntervalSince(cached.fetchedAt) < 45 {
            #if DEBUG
            print("[DiscoverPerf] calendar/venue_events cache HIT rows=\(cached.rows.count) keyPrefix=\(String(cacheKey.prefix(96)))…")
            #endif
            return cached.rows
        }

        #if DEBUG
        print("[DiscoverPerf] calendar/venue_events cache MISS keyPrefix=\(String(cacheKey.prefix(96)))…")
        #endif

        let t0 = Date()
        var byID: [UUID: VenueEventRow] = [:]
        let selectCols = "id,owner_email,venue_name,event_title,sport,event_date,event_time"
        let chunkSize = 80

        func mergeRows(_ rows: [VenueEventRow]) {
            for row in rows {
                if let id = row.id { byID[id] = row }
            }
        }

        for chunk in chunked(ownerEmails, size: chunkSize) where !chunk.isEmpty {
            var q = supabase
                .from("venue_events")
                .select(selectCols)
                .in("owner_email", values: chunk)
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
        print("[DiscoverPerf] venue_events fetch rows=\(merged.count) ms=\(ms)")
        #endif

        return merged
    }

    private func rebuildVenueEventIDsByKey(from rows: [VenueEventRow]) {
        var idsByKey: [String: UUID] = [:]
        for row in rows {
            guard let id = row.id, let title = row.event_title else { continue }
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
    }

    /// After a venue owner inserts a game, patch in-memory Discover/calendar/map state so the new listing appears without waiting for the next full fetch.
    func applyCreatedVenueEventLocally(_ row: VenueEventRow) {
        if let id = row.id {
            venueEventRows.removeAll { $0.id == id }
        }
        venueEventRows.append(row)

        rebuildVenueEventIDsByKey(from: venueEventRows)
        mergeVenueSliceIntoEvents(venueRows: venueEventRows)

        if let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines),
           let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines),
           !venueName.isEmpty,
           !title.isEmpty {
            bars = bars.map { bar in
                guard bar.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(venueName) == .orderedSame else {
                    return bar
                }
                if bar.games.contains(title) { return bar }
                var nextGames = bar.games
                nextGames.append(title)
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
                    ownerEmail: bar.ownerEmail
                )
            }
        }

        discoverVenueEventsFetchCache = nil
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

    func fetchVenueRowsInCurrentBounds(limit: Int = 200) async throws -> [VenueRow] {
        guard let bounds = currentMapRegionBounds() else { return [] }
        return try await supabase
            .from("venues")
            .select(discoverVenueRowSelectColumns)
            .gte("latitude", value: bounds.minLat)
            .lte("latitude", value: bounds.maxLat)
            .gte("longitude", value: bounds.minLon)
            .lte("longitude", value: bounds.maxLon)
            .limit(limit)
            .execute()
            .value
    }

    func loadVenuesFromSupabase() async {
        let t0 = Date()
        #if DEBUG
        print("[DiscoverPerf] map venue reload START")
        #endif

        isLoadingMapVenues = true
        defer { isLoadingMapVenues = false }

        do {
            guard let bounds = currentMapRegionBounds() else {
                #if DEBUG
                print("[DiscoverPerf] map venue reload aborted (no bounds)")
                #endif
                return
            }

            let venueRows: [VenueRow] = try await supabase
                .from("venues")
                .select(discoverVenueRowSelectColumns)
                .gte("latitude", value: bounds.minLat)
                .lte("latitude", value: bounds.maxLat)
                .gte("longitude", value: bounds.minLon)
                .lte("longitude", value: bounds.maxLon)
                .limit(200)
                .execute()
                .value

            let ownerEmails = Array(
                Set(venueRows.compactMap { $0.owner_email?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            )
            let venueNames = Array(
                Set(venueRows.compactMap { $0.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
            )

            let dateLower = discoverGamesDateLowerString(daysBack: 30)
            let dateUpper = discoverGamesDateUpperString(daysForward: 180)

            let fetchedVenueEventRows = try await fetchVenueEventRowsForDiscover(
                ownerEmails: ownerEmails,
                venueNames: venueNames,
                dateLower: dateLower,
                dateUpper: dateUpper,
                sport: selectedSport
            )

            let rowsCopy = venueRows
            let eventsCopy = fetchedVenueEventRows
            let (mappedBars, idsByKey): ([BarVenue], [String: UUID]) = await Task.detached(priority: .userInitiated) { () -> ([BarVenue], [String: UUID]) in
                DiscoverVenueLoadAssembler.buildMappedBars(venueRows: rowsCopy, fetchedVenueEventRows: eventsCopy)
            }.value

            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil

            if SampleData.includeSampleData {
                bars = mappedBars + SampleData.bars
            } else {
                bars = mappedBars
            }

            venueEventRows = fetchedVenueEventRows
            venueEventIDsByKey = idsByKey
            mergeVenueSliceIntoEvents(venueRows: fetchedVenueEventRows)
            recomputeCalendarDotDates()
            pruneSelectionIfNeededAfterFilterChange()

            persistDiscoverCoreSnapshot()

            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverPerf] map venue reload DONE bars=\(mappedBars.count) venue_events=\(fetchedVenueEventRows.count) ms=\(ms)")
            #endif

        } catch {
            #if DEBUG
            print("[DiscoverPerf] map venue reload ERROR:", error)
            #endif
        }
    }

    func loadGamesFromSupabase() {
        Task { await performLoadGamesFromSupabase() }
    }

    /// Official `games` rows + `venue_events` → ``events`` / calendar dots / IDs. Interest counts load separately via ``refreshSocialEnrichmentInBackground()`` so Discover stays responsive.
    func performLoadGamesFromSupabase() async {
        await MainActor.run {
            if !discoverSnapshotRestoredThisLaunch {
                isLoadingEvents = true
            }
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
                Set(bars.compactMap { $0.ownerEmail?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
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
                    Set(venueRowsForKeys.compactMap { $0.owner_email?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                )
                venueNames = Array(
                    Set(venueRowsForKeys.compactMap { $0.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
                )
            }

            let venueEventRowsFetched = try await fetchVenueEventRowsForDiscover(
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
                recomputeCalendarDotDates()
                isLoadingEvents = false
                pruneSelectionIfNeededAfterFilterChange()
                persistDiscoverCoreSnapshot()
            }

            #if DEBUG
            print("[DiscoverPerf] loadGames DONE official=\(officialEvents.count) venueEvents=\(venueEventsAsSportsEvents.count)")
            #endif

        } catch {
            #if DEBUG
            print("ERROR LOADING GAMES FROM SUPABASE:", error)
            #endif

            await MainActor.run {
                isLoadingEvents = false
            }
        }
    }

    func tenDaysAgoString() -> String {
        discoverGamesDateLowerString(daysBack: 10)
    }
}
