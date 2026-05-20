import CoreLocation
import Foundation

nonisolated struct DiscoverMapRenderSnapshotKey: Equatable, @unchecked Sendable {
    let selectedDay: String
    let selectedSport: String
    let mapDisplayMode: DiscoverMapDisplayMode
    let searchText: String
    let visibleLatitudeDeltaBucket: String
    let venueCount: Int
    let eventRowCount: Int
}

nonisolated struct DiscoverVenuePinRenderItem: Identifiable, @unchecked Sendable {
    let id: UUID
    let bar: BarVenue
    let selectedDayGames: [SportsEvent]
    let venueEventIDsByGameTitle: [String: UUID]
    let goingTotalsByGameTitle: [String: Int]
    let liveNowByGameTitle: [String: Bool]
    let goingTotal: Int
    let pinEnergyScore: Int
    let hasLiveNow: Bool
}

nonisolated struct DiscoverVenueClusterRenderItem: Identifiable, @unchecked Sendable {
    let id: String
    let bars: [BarVenue]
    let coordinate: CLLocationCoordinate2D
    let venueIDs: [UUID]
    let count: Int
    let maxEnergyScore: Int
    let dominantSport: String?
    let hasLiveNow: Bool
}

nonisolated struct DiscoverMapRenderSnapshot: @unchecked Sendable {
    let key: DiscoverMapRenderSnapshotKey
    let builtAt: Date
    let venuePinsByID: [UUID: DiscoverVenuePinRenderItem]
    let venueClustersByID: [String: DiscoverVenueClusterRenderItem]

    static let empty = DiscoverMapRenderSnapshot(
        key: DiscoverMapRenderSnapshotKey(
            selectedDay: "",
            selectedSport: "All",
            mapDisplayMode: .allSpots,
            searchText: "",
            visibleLatitudeDeltaBucket: "",
            venueCount: 0,
            eventRowCount: 0
        ),
        builtAt: .distantPast,
        venuePinsByID: [:],
        venueClustersByID: [:]
    )
}

private nonisolated struct DiscoverMapSnapshotDetachedInput: @unchecked Sendable {
    let bars: [BarVenue]
    let events: [SportsEvent]
    let selectedDate: Date
    let selectedSport: String
    let mapDisplayModeRawValue: String
    let searchQuery: String
    let visibleLatitudeDelta: Double
    let venueEventIDsByKey: [String: UUID]
    let venueEventInterestCounts: [UUID: Int]
    let venueEventRows: [VenueEventRow]
    let liveWindowHours: Int
}

nonisolated struct DiscoverMapSnapshotDetachedOutput: @unchecked Sendable {
    let venueCount: Int
    let venuePinsByID: [UUID: DiscoverVenuePinRenderItem]
    let venueClustersByID: [String: DiscoverVenueClusterRenderItem]
    let builtAt: Date
}

private nonisolated struct DiscoverDetachedVenueCluster: @unchecked Sendable {
    let id: String
    let bars: [BarVenue]
    let coordinate: CLLocationCoordinate2D

    var count: Int {
        bars.count
    }
}

private nonisolated enum DiscoverMapRenderSnapshotBuilder {
    static func build(input: DiscoverMapSnapshotDetachedInput) -> DiscoverMapSnapshotDetachedOutput? {
        do {
            try checkCancellation(checkpoint: "venueLoop")

            var visibleBars: [BarVenue] = []
            visibleBars.reserveCapacity(input.bars.count)
            for bar in input.bars {
                try checkCancellation(checkpoint: "venueLoop")
                if try shouldShowVenueOnMap(bar, input: input) {
                    visibleBars.append(bar)
                }
            }

            var pinItems: [UUID: DiscoverVenuePinRenderItem] = [:]
            pinItems.reserveCapacity(visibleBars.count)

            for bar in visibleBars {
                try checkCancellation(checkpoint: "venueLoop")
                let gamesToday = try selectedDayEvents(for: bar, sportFilter: input.selectedSport, input: input)
                var eventIDsByTitle: [String: UUID] = [:]
                var goingByTitle: [String: Int] = [:]
                var liveNowByTitle: [String: Bool] = [:]
                var goingTotal = 0
                var hasLiveNow = false

                for game in gamesToday {
                    try checkCancellation(checkpoint: "venueLoop")
                    if let eventID = cachedVenueEventID(for: bar, gameTitle: game.title, input: input) {
                        eventIDsByTitle[game.title] = eventID
                        let going = input.venueEventInterestCounts[eventID] ?? 0
                        goingByTitle[game.title] = going
                        goingTotal += going
                    } else {
                        goingByTitle[game.title] = 0
                    }

                    let gameIsLive = try hasLiveVenueEventNow(for: bar, game: game, input: input)
                    liveNowByTitle[game.title] = gameIsLive
                    hasLiveNow = hasLiveNow || gameIsLive
                }

                pinItems[bar.id] = DiscoverVenuePinRenderItem(
                    id: bar.id,
                    bar: bar,
                    selectedDayGames: gamesToday,
                    venueEventIDsByGameTitle: eventIDsByTitle,
                    goingTotalsByGameTitle: goingByTitle,
                    liveNowByGameTitle: liveNowByTitle,
                    goingTotal: goingTotal,
                    pinEnergyScore: goingTotal,
                    hasLiveNow: hasLiveNow
                )
            }

            try checkCancellation(checkpoint: "clusterAssembly")
            let clusters = try clusteredBars(from: visibleBars, visibleLatitudeDelta: input.visibleLatitudeDelta)
            var clusterItems: [String: DiscoverVenueClusterRenderItem] = [:]
            clusterItems.reserveCapacity(clusters.count)

            for cluster in clusters {
                try checkCancellation(checkpoint: "clusterAssembly")
                var maxEnergyScore = 0
                var dominantSport: String?
                var clusterHasLiveNow = false

                for bar in cluster.bars {
                    try checkCancellation(checkpoint: "clusterAssembly")
                    guard let pin = pinItems[bar.id] else { continue }
                    clusterHasLiveNow = clusterHasLiveNow || pin.hasLiveNow
                    for game in pin.selectedDayGames {
                        let gameScore = pin.goingTotalsByGameTitle[game.title] ?? 0
                        if gameScore > maxEnergyScore {
                            maxEnergyScore = gameScore
                            dominantSport = game.sport
                        }
                    }
                }

                clusterItems[cluster.id] = DiscoverVenueClusterRenderItem(
                    id: cluster.id,
                    bars: cluster.bars,
                    coordinate: cluster.coordinate,
                    venueIDs: cluster.bars.map(\.id),
                    count: cluster.count,
                    maxEnergyScore: maxEnergyScore,
                    dominantSport: dominantSport,
                    hasLiveNow: clusterHasLiveNow
                )
            }

            return DiscoverMapSnapshotDetachedOutput(
                venueCount: visibleBars.count,
                venuePinsByID: pinItems,
                venueClustersByID: clusterItems,
                builtAt: Date()
            )
        } catch is CancellationError {
            return nil
        } catch {
            return nil
        }
    }

    private static func checkCancellation(checkpoint: String) throws {
        guard Task.isCancelled else { return }
        #if DEBUG
        switch checkpoint {
        case "venueLoop":
            print("[DiscoverSnapshotPerf] cancellationCheckpoint=venueLoop")
        case "clusterAssembly":
            print("[DiscoverSnapshotPerf] cancellationCheckpoint=clusterAssembly")
        default:
            print("[DiscoverSnapshotPerf] cancellationCheckpoint=\(checkpoint)")
        }
        print("[DiscoverSnapshotPerf] buildCancelledEarly=true")
        #endif
        throw CancellationError()
    }

    private static func shouldShowVenueOnMap(_ venue: BarVenue, input: DiscoverMapSnapshotDetachedInput) throws -> Bool {
        guard venueIsActiveForMap(venue) else { return false }

        try checkCancellation(checkpoint: "venueLoop")
        let sportScopedEvents = try selectedDayEvents(for: venue, sportFilter: input.selectedSport, input: input)
        let allSportEvents = try selectedDayEvents(for: venue, sportFilter: "All", input: input)
        let searchScopedEvents = input.selectedSport == "All" ? allSportEvents : sportScopedEvents

        guard venueMatchesMapSearch(venue, candidateEvents: searchScopedEvents, input: input) else { return false }

        if input.mapDisplayModeRawValue == "gamesOnly" {
            return input.selectedSport == "All" ? !allSportEvents.isEmpty : !sportScopedEvents.isEmpty
        }

        if input.selectedSport == "All" {
            return true
        }
        return !sportScopedEvents.isEmpty
    }

    private static func selectedDayEvents(
        for venue: BarVenue,
        sportFilter: String,
        input: DiscoverMapSnapshotDetachedInput
    ) throws -> [SportsEvent] {
        let calendar = Calendar.current
        var matchingEvents: [SportsEvent] = []
        matchingEvents.reserveCapacity(input.events.count)
        for event in input.events {
            try checkCancellation(checkpoint: "venueLoop")
            if calendar.isDate(event.date, inSameDayAs: input.selectedDate) &&
                venue.games.contains(event.title) &&
                (sportFilter == "All" || event.sport == sportFilter) {
                matchingEvents.append(event)
            }
        }
        return matchingEvents
    }

    private static func venueMatchesMapSearch(
        _ venue: BarVenue,
        candidateEvents: [SportsEvent],
        input: DiscoverMapSnapshotDetachedInput
    ) -> Bool {
        let query = input.searchQuery
        guard !query.isEmpty else { return true }
        if venue.name.localizedCaseInsensitiveContains(query) || venue.address.localizedCaseInsensitiveContains(query) {
            return true
        }
        return candidateEvents.contains { matchesSearch($0, query: query) }
    }

    private static func matchesSearch(_ event: SportsEvent, query: String) -> Bool {
        query.isEmpty ||
            event.title.localizedCaseInsensitiveContains(query) ||
            event.sport.localizedCaseInsensitiveContains(query) ||
            SportFilterCatalog.storedSport(event.sport, matchesSearchQuery: query) ||
            event.league.localizedCaseInsensitiveContains(query)
    }

    private static func venueIsActiveForMap(_ venue: BarVenue) -> Bool {
        let normalized = venue.adminStatus?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized.isEmpty || normalized == "active"
    }

    private static func clusteredBars(
        from source: [BarVenue],
        visibleLatitudeDelta: Double
    ) throws -> [DiscoverDetachedVenueCluster] {
        guard !source.isEmpty else {
            return []
        }

        var gridSize = 0.035
        if visibleLatitudeDelta > 0.35 {
            gridSize = 0.08
        }

        try checkCancellation(checkpoint: "clusterAssembly")
        var grouped: [String: [BarVenue]] = [:]
        for bar in source {
            try checkCancellation(checkpoint: "clusterAssembly")
            let latKey = Int(bar.coordinate.latitude / gridSize)
            let lonKey = Int(bar.coordinate.longitude / gridSize)
            grouped["\(latKey)-\(lonKey)", default: []].append(bar)
        }

        var clusters: [DiscoverDetachedVenueCluster] = []
        clusters.reserveCapacity(grouped.count)
        for (key, bars) in grouped {
            try checkCancellation(checkpoint: "clusterAssembly")
            let avgLat = bars.map { $0.coordinate.latitude }.reduce(0, +) / Double(bars.count)
            let avgLon = bars.map { $0.coordinate.longitude }.reduce(0, +) / Double(bars.count)
            clusters.append(DiscoverDetachedVenueCluster(
                id: "c-\(key)",
                bars: bars,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            ))
        }
        return clusters
    }

    private static func normalizedGameTitle(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func venueEventTitlesMatch(_ storedTitle: String?, _ gameTitle: String) -> Bool {
        let lhs = normalizedGameTitle(storedTitle ?? "")
        let rhs = normalizedGameTitle(gameTitle)
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }

    private static func cachedVenueEventID(
        for bar: BarVenue,
        gameTitle: String,
        input: DiscoverMapSnapshotDetachedInput
    ) -> UUID? {
        let trimmed = normalizedGameTitle(gameTitle)
        guard !trimmed.isEmpty else { return nil }
        let primary = "\(bar.id.uuidString)-\(trimmed)"
        if let id = input.venueEventIDsByKey[primary] {
            return id
        }
        if let id = input.venueEventIDsByKey["\(bar.id.uuidString)-\(gameTitle)"] {
            return id
        }
        if let id = input.venueEventIDsByKey["\(bar.name)-\(trimmed)"] {
            return id
        }
        return input.venueEventIDsByKey["\(bar.name)-\(gameTitle)"]
    }

    private static func cachedVenueEventRow(
        for bar: BarVenue,
        gameTitle: String,
        input: DiscoverMapSnapshotDetachedInput
    ) throws -> VenueEventRow? {
        for row in input.venueEventRows {
            try checkCancellation(checkpoint: "venueLoop")
            if venueEventRowMatchesBar(row, bar: bar, gameTitle: gameTitle) {
                return row
            }
        }
        return nil
    }

    private static func venueEventRowMatchesBar(
        _ row: VenueEventRow,
        bar: BarVenue,
        gameTitle: String
    ) -> Bool {
        guard venueEventTitlesMatch(row.event_title, gameTitle) else { return false }
        if let venueID = row.venue_id, venueID == bar.id { return true }
        let barName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !venueName.isEmpty, venueName.caseInsensitiveCompare(barName) == .orderedSame { return true }
        if let owner = row.owner_email,
           let barOwner = bar.ownerEmail,
           OwnerBusinessEmail.normalized(owner) == OwnerBusinessEmail.normalized(barOwner) {
            return true
        }
        return false
    }

    private static func hasLiveVenueEventNow(
        for bar: BarVenue,
        game: SportsEvent,
        input: DiscoverMapSnapshotDetachedInput
    ) throws -> Bool {
        guard let row = try cachedVenueEventRow(for: bar, gameTitle: game.title, input: input),
              let start = parseScheduledStart(row.scheduled_start_at) else {
            return false
        }
        let now = Date()
        let liveEnd = start.addingTimeInterval(TimeInterval(input.liveWindowHours * 3600))
        return now >= start && now <= liveEnd
    }

    private static func parseScheduledStart(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

extension MapViewModel {
    /// Coalesces rapid snapshot invalidations (e.g. bars + venueEventRows during venue load) into one detached build.
    func scheduleDiscoverMapRenderSnapshotRebuild(reason: String) {
        if suppressDiscoverSnapshotRebuilds {
#if DEBUG
            print("[PerfPhase1B] snapshotRebuildSuppressed reason=\(reason)")
#endif
            return
        }

        if discoverSnapshotRebuildCoalesceTask != nil {
#if DEBUG
            print("[PerfPhase1B] snapshotRebuildCoalesced reason=\(reason)")
#endif
        }

        discoverSnapshotPendingRebuildReason = reason
        discoverSnapshotRebuildCoalesceTask?.cancel()
        discoverSnapshotRebuildCoalesceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: self.discoverSnapshotRebuildCoalesceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            let flushReason = self.discoverSnapshotPendingRebuildReason ?? reason
            self.discoverSnapshotPendingRebuildReason = nil
            self.discoverSnapshotRebuildCoalesceTask = nil
#if DEBUG
            print("[PerfPhase1B] snapshotRebuildFlushed reason=\(flushReason)")
#endif
            self.performDiscoverMapRenderSnapshotRebuild(reason: flushReason)
        }
    }

    /// Runs a snapshot build immediately (cancels any pending coalesced rebuild).
    func flushDiscoverMapRenderSnapshotRebuild(reason: String) {
        discoverSnapshotRebuildCoalesceTask?.cancel()
        discoverSnapshotRebuildCoalesceTask = nil
        discoverSnapshotPendingRebuildReason = nil
#if DEBUG
        print("[PerfPhase1B] snapshotRebuildFlushed reason=\(reason)")
#endif
        performDiscoverMapRenderSnapshotRebuild(reason: reason)
    }

    func rebuildDiscoverMapRenderSnapshot(reason: String) {
        scheduleDiscoverMapRenderSnapshotRebuild(reason: reason)
    }

    /// `VenueCluster` list derived from the latest published map snapshot (empty when snapshot not ready).
    func discoverMapRenderSnapshotVenueClustersForMap() -> [VenueCluster] {
        let items = Array(discoverMapRenderSnapshot.venueClustersByID.values)
        guard !items.isEmpty else { return [] }
        return items
            .map { item in
                VenueCluster(id: item.id, bars: item.bars, coordinate: item.coordinate)
            }
            .sorted { $0.id < $1.id }
    }

    private func performDiscoverMapRenderSnapshotRebuild(reason: String) {
        let buildStart = Date()
        if let previousTask = activeDiscoverSnapshotTask, !previousTask.isCancelled {
            previousTask.cancel()
            #if DEBUG
            print("[DiscoverSnapshotPerf] previousTaskCancelled=true")
            #endif
        }
        discoverMapRenderSnapshotGeneration &+= 1
        let generation = discoverMapRenderSnapshotGeneration
        let selectedDayString = discoverMapSelectedDayString()
        let capturedSelectedSport = selectedSport
        let capturedMapDisplayMode = mapDisplayMode
        let capturedSearchText = debouncedDiscoverSearchText
        let capturedVisibleLatitudeDelta = visibleLatitudeDelta
        let capturedEventRowCount = venueEventRows.count
        let input = DiscoverMapSnapshotDetachedInput(
            bars: bars,
            events: events,
            selectedDate: selectedDate,
            selectedSport: selectedSport,
            mapDisplayModeRawValue: mapDisplayMode.rawValue,
            searchQuery: effectiveDiscoverSearchQuery,
            visibleLatitudeDelta: visibleLatitudeDelta,
            venueEventIDsByKey: venueEventIDsByKey,
            venueEventInterestCounts: venueEventInterestCounts,
            venueEventRows: venueEventRows,
            liveWindowHours: FanGeoLiveEnergyTiming.liveWindowHours
        )

        #if DEBUG
        print("[DiscoverMapSnapshotDebug] detachedBuildStarted=true")
        #endif

        let detachedTask = Task.detached(priority: .userInitiated) {
            #if DEBUG
            let detachedBuildStart = Date()
            #endif
            let output = DiscoverMapRenderSnapshotBuilder.build(input: input)
            #if DEBUG
            let detachedBuildMs = Int(Date().timeIntervalSince(detachedBuildStart) * 1000)
            print("[DiscoverMapSnapshotDebug] detachedBuildFinishedMs=\(detachedBuildMs)")
            #endif
            return output
        }
        activeDiscoverSnapshotTask = detachedTask
        #if DEBUG
        print("[DiscoverSnapshotPerf] activeTaskReplaced=true")
        #endif

        Task { @MainActor [weak self] in
            guard let output = await detachedTask.value else {
                guard let self else { return }
                if self.discoverMapRenderSnapshotGeneration == generation {
                    self.activeDiscoverSnapshotTask = nil
                }
                return
            }
            guard let self else { return }

            guard self.discoverMapRenderSnapshotGeneration == generation else {
                #if DEBUG
                print("[DiscoverMapSnapshotDebug] detachedBuildDiscardedStale=true")
                #endif
                return
            }
            self.activeDiscoverSnapshotTask = nil

            let key = DiscoverMapRenderSnapshotKey(
                selectedDay: selectedDayString,
                selectedSport: capturedSelectedSport,
                mapDisplayMode: capturedMapDisplayMode,
                searchText: capturedSearchText,
                visibleLatitudeDeltaBucket: String(format: "%.5f", capturedVisibleLatitudeDelta),
                venueCount: output.venueCount,
                eventRowCount: capturedEventRowCount
            )

            #if DEBUG
            let publishStart = Date()
            #endif
            self.applyDiscoverMapRenderSnapshot(
                DiscoverMapRenderSnapshot(
                    key: key,
                    builtAt: output.builtAt,
                    venuePinsByID: output.venuePinsByID,
                    venueClustersByID: output.venueClustersByID
                )
            )

            #if DEBUG
            let publishMs = Int(Date().timeIntervalSince(publishStart) * 1000)
            let buildMs = Int(Date().timeIntervalSince(buildStart) * 1000)
            print("[DiscoverMapSnapshotDebug] publishSnapshotMainActorMs=\(publishMs)")
            print("[DiscoverMapSnapshotDebug] rebuild reason=\(reason)")
            print("[DiscoverMapSnapshotDebug] venueCount=\(output.venuePinsByID.count)")
            print("[DiscoverMapSnapshotDebug] clusterCount=\(output.venueClustersByID.count)")
            print("[DiscoverMapSnapshotDebug] buildMs=\(buildMs)")
            #endif
        }
    }

    private func discoverMapRenderSnapshotKey(venueCount: Int) -> DiscoverMapRenderSnapshotKey {
        DiscoverMapRenderSnapshotKey(
            selectedDay: discoverMapSelectedDayString(),
            selectedSport: selectedSport,
            mapDisplayMode: mapDisplayMode,
            searchText: debouncedDiscoverSearchText,
            visibleLatitudeDeltaBucket: String(format: "%.5f", visibleLatitudeDelta),
            venueCount: venueCount,
            eventRowCount: venueEventRows.count
        )
    }

    private func discoverMapSelectedDayString() -> String {
        let dayFormatter = DateFormatter()
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current
        return dayFormatter.string(from: selectedDate)
    }
}
