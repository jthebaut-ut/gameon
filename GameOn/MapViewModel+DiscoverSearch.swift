import Foundation
import MapKit
import SwiftUI

// MARK: - Discover map search (region-scoped venue/game vs global place)

fileprivate struct DiscoverBarSearchSnapshot: Sendable {
    let id: UUID
    let latitude: Double
    let longitude: Double
    let name: String
    let address: String
    let primarySport: String
    let tags: [String]
    let games: [String]
}

enum DiscoverMapSearchKind: String, Sendable {
    case appContentRegionBound
    case globalPlace
}

fileprivate enum DiscoverMapSearchFilter {
    static func isInBounds(
        lat: Double,
        lon: Double,
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)
    ) -> Bool {
        lat >= bounds.minLat && lat <= bounds.maxLat && lon >= bounds.minLon && lon <= bounds.maxLon
    }

    static func matchesLiveSearch(bar: DiscoverBarSearchSnapshot, queryLower: String) -> Bool {
        if bar.name.lowercased().contains(queryLower) { return true }
        if bar.address.lowercased().contains(queryLower) { return true }
        let primary = bar.primarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        if primary.lowercased().contains(queryLower) { return true }
        if SportFilterCatalog.storedSport(primary, matchesSearchQuery: queryLower) { return true }
        if bar.tags.contains(where: { $0.lowercased().contains(queryLower) }) { return true }
        if bar.games.contains(where: { $0.lowercased().contains(queryLower) }) { return true }
        return false
    }

    static func orderedMatchingBarIds(
        snapshots: [DiscoverBarSearchSnapshot],
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        queryLower: String
    ) -> [UUID] {
        var out: [UUID] = []
        out.reserveCapacity(min(32, snapshots.count))
        for s in snapshots {
            guard isInBounds(lat: s.latitude, lon: s.longitude, bounds: bounds) else { continue }
            guard matchesLiveSearch(bar: s, queryLower: queryLower) else { continue }
            out.append(s.id)
        }
        return out
    }
}

extension MapViewModel {

    /// Discover read path (map preview, games list, venue detail sheet): any authenticated social-capable session.
    var discoverAuthGateActive: Bool {
        isAuthenticatedForSocialFeatures
    }

    func canViewDiscoverDetails() -> Bool {
        discoverAuthGateActive
    }

    func logDiscoverAuthGateDebug() {
#if DEBUG
        print("[DiscoverAuthGate] isLoggedIn=\(isLoggedIn)")
        print("[DiscoverAuthGate] isVenueOwnerLoggedIn=\(isVenueOwnerLoggedIn)")
        print("[DiscoverAuthGate] canViewDiscoverDetails=\(canViewDiscoverDetails())")
#endif
    }

    /// Guest Discover: switch to Account and present the same ``SettingsUserAuthSheet`` used for fan sign-in / registration.
    func discoverPresentFanUserAuthSheet(openRegisterMode: Bool) {
        fanUserAuthSheetOpenInRegisterMode = openRegisterMode
        presentFanUserAuthSheetFromDiscover = true
        discoverNavigateToAccountForUserAuth = true
    }

    /// Clears the Discover remote-preview pin hold (e.g. when the user dismisses the preview from the UI).
    func clearDiscoverRemotePreviewHold() {
        discoverRemotePreviewHoldVenueId = nil
    }

    /// Classifies Discover search: venue/game text stays viewport-scoped; city/state/country-style queries use global place search.
    func discoverMapSearchKind(for rawQuery: String) -> DiscoverMapSearchKind {
        let q = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return .appContentRegionBound }

        if q.rangeOfCharacter(from: .decimalDigits) != nil {
            return .appContentRegionBound
        }
        if q.contains(",") {
            return .globalPlace
        }

        let collapsed = q.lowercased()
            .replacingOccurrences(of: ",", with: " ")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = collapsed.split(separator: " ").map(String.init)

        let venueish = Set([
            "bar", "grill", "pub", "sports", "pizza", "tap", "brewery", "restaurant", "tavern", "cafe", "coffee",
            "venue", "arena", "stadium", "club", "lounge", "kitchen", "wings", "bbq", "tacos", "burger"
        ])
        if tokens.contains(where: { venueish.contains($0) }) {
            return .appContentRegionBound
        }

        let placeKeywords: Set<String> = [
            "usa", "us", "utah", "colorado", "arizona", "nevada", "california", "wyoming", "idaho", "newmexico",
            "oregon", "washington", "montana", "texas", "florida", "newyork", "illinois", "pennsylvania", "ohio",
            "georgia", "northcarolina", "michigan", "tennessee", "wisconsin", "minnesota", "canada", "mexico",
            "england", "france", "germany", "spain", "japan", "china", "uk", "ireland", "australia", "slc", "nyc", "la"
        ]
        let compact = tokens.joined()
        if tokens.count == 1, placeKeywords.contains(compact) {
            return .globalPlace
        }

        if tokens.count >= 2 {
            let last = tokens[tokens.count - 1]
            if last.count == 2, last.uppercased() == last, last.allSatisfy({ $0.isLetter }) {
                return .globalPlace
            }
        }

        if tokens.count >= 2, tokens.count <= 4, tokens.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isLetter) }) {
            return .globalPlace
        }

        return .appContentRegionBound
    }

    /// Loaded venues in the current map bounds matching name/address/sport/tags/games (no Supabase). Order follows ``bars``.
    func discoverRegionBoundAppContentSearchOrderedDetached(query: String) async -> [BarVenue] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let lower = trimmed.lowercased()
        guard let bounds = currentMapRegionBounds() else { return [] }

        let snapshots: [DiscoverBarSearchSnapshot] = bars.map {
            DiscoverBarSearchSnapshot(
                id: $0.id,
                latitude: $0.coordinate.latitude,
                longitude: $0.coordinate.longitude,
                name: $0.name,
                address: $0.address,
                primarySport: $0.primarySport,
                tags: $0.tags,
                games: $0.games
            )
        }
        let barsSnapshot = bars

        let orderedIds = await Task.detached(priority: .userInitiated) {
            DiscoverMapSearchFilter.orderedMatchingBarIds(
                snapshots: snapshots,
                bounds: bounds,
                queryLower: lower
            )
        }.value

        return orderedIds.compactMap { id in barsSnapshot.first { $0.id == id } }
    }

    /// In-map matches only (current camera region, loaded ``bars``). Same field rules as ``matchesDiscoverLiveSearch``.
    func discoverVenueSearchLocalMatchesOrdered(query: String, region: MKCoordinateRegion?) -> [BarVenue] {
        visibleBarsMatchingSearch(query: query, region: region)
    }

    /// Debounces ``searchText`` (~300ms) before updating ``debouncedDiscoverSearchText`` and ``venueSearchResults``.
    func scheduleDiscoverSearchDebounce() {
        discoverSearchDebounceTask?.cancel()

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            debouncedDiscoverSearchText = ""
            venueSearchResults = []
            isDiscoverVenueSearchLoading = false
            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil
            discoverSearchDebounceTask = nil
            return
        }

        discoverSearchDebounceTask = Task { @MainActor [weak self] in
            guard let self else { return }
#if DEBUG
            let wall0 = Date()
#endif
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled {
#if DEBUG
                let ms = Int(Date().timeIntervalSince(wall0) * 1000)
                print("[DiscoverMapSearchPerf] query=\"\(trimmed)\" kind=n/a candidates=0 elapsedMs=\(ms) cancelled=yes")
#endif
                return
            }

            let q = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                self.debouncedDiscoverSearchText = ""
                self.venueSearchResults = []
                self.isDiscoverVenueSearchLoading = false
                return
            }

            self.isDiscoverVenueSearchLoading = true
            defer { self.isDiscoverVenueSearchLoading = false }

            let kind = self.discoverMapSearchKind(for: q)
#if DEBUG
            let tCompute = Date()
#endif

            var merged: [BarVenue] = []
            var candidateCount = 0

            switch kind {
            case .appContentRegionBound:
                merged = await self.discoverRegionBoundAppContentSearchOrderedDetached(query: q)
            case .globalPlace:
                if q.count >= 2 {
                    merged = await self.fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: false)
                }
            }
            candidateCount = merged.count

            guard !Task.isCancelled else {
#if DEBUG
                let elapsedMs = Int(Date().timeIntervalSince(tCompute) * 1000)
                let wallMs = Int(Date().timeIntervalSince(wall0) * 1000)
                print(
                    "[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(candidateCount) elapsedMs=\(elapsedMs) wallMs=\(wallMs) cancelled=yes"
                )
#endif
                return
            }

            self.discoverClusteredBarsCacheKey = nil
            self.discoverClusteredBarsCache = nil
            self.debouncedDiscoverSearchText = q
            self.venueSearchResults = merged

#if DEBUG
            let elapsedMs = Int(Date().timeIntervalSince(tCompute) * 1000)
            let wallMs = Int(Date().timeIntervalSince(wall0) * 1000)
            print(
                "[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(candidateCount) elapsedMs=\(elapsedMs) wallMs=\(wallMs) cancelled=no"
            )
#endif
        }
    }

    /// Venues whose coordinates fall inside `region` and whose loaded fields match `query` (no Supabase).
    func visibleBarsMatchingSearch(query: String, region: MKCoordinateRegion?) -> [BarVenue] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, let region else { return [] }
        let lower = q.lowercased()
        return bars.filter { isBarCoordinate($0, in: region) && matchesDiscoverLiveSearch($0, lowercasedQuery: lower) }
    }

    func isBarCoordinate(_ bar: BarVenue, in region: MKCoordinateRegion?) -> Bool {
        guard let region else { return false }
        let lat = bar.coordinate.latitude
        let lon = bar.coordinate.longitude
        let c = region.center
        let s = region.span
        return lat >= c.latitude - s.latitudeDelta / 2
            && lat <= c.latitude + s.latitudeDelta / 2
            && lon >= c.longitude - s.longitudeDelta / 2
            && lon <= c.longitude + s.longitudeDelta / 2
    }

    /// Name, address (includes city/state from venue row), primary sport, tags, and loaded game titles.
    func matchesDiscoverLiveSearch(_ bar: BarVenue, lowercasedQuery lower: String) -> Bool {
        if bar.name.lowercased().contains(lower) { return true }
        if bar.address.lowercased().contains(lower) { return true }
        let primary = bar.primarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        if primary.lowercased().contains(lower) { return true }
        if SportFilterCatalog.storedSport(primary, matchesSearchQuery: lower) { return true }
        if bar.tags.contains(where: { $0.lowercased().contains(lower) }) { return true }
        if bar.games.contains(where: { $0.lowercased().contains(lower) }) { return true }
        return false
    }

    /// All in-memory bars matching the Discover live search fields (used on keyboard **Go** after visible-only pass).
    func allBarsMatchingDiscoverLiveSearch(query: String) -> [BarVenue] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let lower = q.lowercased()
        return bars.filter { matchesDiscoverLiveSearch($0, lowercasedQuery: lower) }
    }

    /// Count of loaded venues inside the current map camera region (for empty-state copy).
    func visibleBarCountInCurrentMapRegion() -> Int {
        guard let region = cameraPosition.region else { return 0 }
        return bars.filter { isBarCoordinate($0, in: region) }.count
    }

    /// Clears Discover search text, debounced query, and result chips so the venue preview uses the same event slice as map taps after a search selection.
    func clearDiscoverVenueSearchForSelection() {
        discoverSearchDebounceTask?.cancel()
        discoverSearchDebounceTask = nil
        searchText = ""
        debouncedDiscoverSearchText = ""
        venueSearchResults = []
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
    }

    /// Same `BarVenue` instance as map data when this id is present in ``bars``.
    func canonicalBarForDiscover(_ bar: BarVenue) -> BarVenue {
        bars.first { $0.id == bar.id } ?? bar
    }

    /// Ensures a venue opened from Supabase text search stays in ``bars`` so map reloads and ``pruneSelectionIfNeededAfterFilterChange()`` do not drop the preview.
    /// No-game venues from search use ``discoverRemotePreviewHoldVenueId`` instead and are **not** merged (they must not join the default pin dataset).
    func mergeDiscoverSearchVenueIntoBarsIfMissing(_ bar: BarVenue) {
        if bars.contains(where: { $0.id == bar.id }) { return }
        bars.append(bar)
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
    }

    /// Dynamic search result: clear query, select canonical venue, center map (``centerMap(on:)`` sets ``selectedBar``).
    func selectVenueFromDiscoverSearchResult(_ bar: BarVenue) {
        let inBars = bars.contains(where: { $0.id == bar.id })
        if !bar.games.isEmpty {
            mergeDiscoverSearchVenueIntoBarsIfMissing(bar)
        }
        let canonical = canonicalBarForDiscover(bar)

        if bar.games.isEmpty && !inBars {
            discoverRemotePreviewHoldVenueId = canonical.id
#if DEBUG
            print("[VenueSearch] selected remote venue id=\(canonical.id.uuidString) name=\(canonical.name)")
#endif
        } else {
            discoverRemotePreviewHoldVenueId = nil
        }

        clearDiscoverVenueSearchForSelection()
#if DEBUG
        let n = gamesForVenuePreview(bar: canonical, date: selectedDate, sportFilter: selectedSport).count
        let dateLabel = selectedDate.formatted(date: .abbreviated, time: .omitted)
        print("[VenueSearchSelect] venue=\(canonical.name) date=\(dateLabel) gamesForPreview=\(n)")
#endif
        centerMap(on: canonical)
    }
}
