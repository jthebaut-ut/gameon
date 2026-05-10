import Foundation
import MapKit
import SwiftUI

extension MapViewModel {

    /// Debounces ``searchText`` (~260ms) before updating ``debouncedDiscoverSearchText``, recomputing visible-only ``venueSearchResults``, and invalidating map cluster memo.
    func scheduleDiscoverSearchDebounce() {
        discoverSearchDebounceTask?.cancel()

        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            debouncedDiscoverSearchText = ""
            venueSearchResults = []
            discoverClusteredBarsCacheKey = nil
            discoverClusteredBarsCache = nil
            discoverSearchDebounceTask = nil
            return
        }

        discoverSearchDebounceTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(260))
            guard !Task.isCancelled else { return }

            let q = self.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else {
                self.debouncedDiscoverSearchText = ""
                self.venueSearchResults = []
                return
            }

            #if DEBUG
            let t0 = Date()
            #endif
            let region = self.cameraPosition.region
            let inRegion = self.bars.filter { self.isBarCoordinate($0, in: region) }
            let matches = self.visibleBarsMatchingSearch(query: q, region: region)
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[SearchPerf] query=\(q) visibleBars=\(inRegion.count) matches=\(matches.count) ms=\(ms)")
            #endif

            self.discoverClusteredBarsCacheKey = nil
            self.discoverClusteredBarsCache = nil
            self.debouncedDiscoverSearchText = q
            self.venueSearchResults = matches
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
        if bar.primarySport.lowercased().contains(lower) { return true }
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

    /// Dynamic search result: clear query, select canonical venue, center map (``centerMap(on:)`` sets ``selectedBar``).
    func selectVenueFromDiscoverSearchResult(_ bar: BarVenue) {
        let canonical = canonicalBarForDiscover(bar)
        clearDiscoverVenueSearchForSelection()
        #if DEBUG
        let n = gamesForVenuePreview(bar: canonical, date: selectedDate, sportFilter: selectedSport).count
        let dateLabel = selectedDate.formatted(date: .abbreviated, time: .omitted)
        print("[VenueSearchSelect] venue=\(canonical.name) date=\(dateLabel) gamesForPreview=\(n)")
        #endif
        centerMap(on: canonical)
    }
}
