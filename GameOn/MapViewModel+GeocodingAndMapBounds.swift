import CoreLocation
import Foundation
import MapKit
import SwiftUI

extension MapViewModel {

    func experience(for bar: BarVenue) -> VenueExperience? {
        venueExperiences.first { $0.venueName == bar.name }
    }

    func clusteredBars() -> [VenueCluster] {
        let source = mapVisibleBars
        guard !source.isEmpty else {
            discoverClusteredBarsCache = nil
            discoverClusteredBarsCacheKey = nil
            return []
        }

        let dayBucket = Int(selectedDate.timeIntervalSince1970 / 86400)
        let coordFingerprint = source.prefix(64).reduce(into: 0.0) { partial, bar in
            partial += bar.coordinate.latitude + bar.coordinate.longitude + Double(bar.games.count)
        }
        let cacheKey = "\(source.count)|\(dayBucket)|\(selectedSport)|\(mapDisplayMode.rawValue)|\(debouncedDiscoverSearchText.hashValue)|\(String(format: "%.5f", visibleLatitudeDelta))|\(String(format: "%.4f", coordFingerprint))"
        if cacheKey == discoverClusteredBarsCacheKey, let cached = discoverClusteredBarsCache {
            return cached
        }

        var gridSize = 0.035
        if visibleLatitudeDelta > 0.35 {
            gridSize = 0.08
        }

        let grouped = Dictionary(grouping: source) { bar in
            let latKey = Int(bar.coordinate.latitude / gridSize)
            let lonKey = Int(bar.coordinate.longitude / gridSize)
            return "\(latKey)-\(lonKey)"
        }

        let clusters = grouped.map { key, bars in
            let avgLat = bars.map { $0.coordinate.latitude }.reduce(0, +) / Double(bars.count)
            let avgLon = bars.map { $0.coordinate.longitude }.reduce(0, +) / Double(bars.count)
            return VenueCluster(
                id: "c-\(key)",
                bars: bars,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }

        discoverClusteredBarsCacheKey = cacheKey
        discoverClusteredBarsCache = clusters
        return clusters
    }

    /// Grid-bucketed pickup pins for Discover (same spacing idea as ``clusteredBars()``). Lightweight memo for map body churn.
    func clusteredPickupGamesForDiscoverMap(rows: [PickupGameRow]) -> [PickupGameCluster] {
        let withCoords = rows.filter { $0.latitude != nil && $0.longitude != nil }
        guard !withCoords.isEmpty else {
            discoverPickupClustersCache = nil
            discoverPickupClustersCacheKey = nil
            return []
        }

        let dayBucket = Int(selectedDate.timeIntervalSince1970 / 86400)
        let coordFingerprint = withCoords.prefix(48).reduce(into: 0.0) { partial, row in
            partial += (row.latitude ?? 0) + (row.longitude ?? 0)
        }
        let cacheKey = "\(withCoords.count)|\(dayBucket)|\(selectedSport)|\(debouncedDiscoverSearchText.hashValue)|\(String(format: "%.5f", visibleLatitudeDelta))|\(String(format: "%.4f", coordFingerprint))"
        if cacheKey == discoverPickupClustersCacheKey, let cached = discoverPickupClustersCache {
            return cached
        }

        var gridSize = 0.035
        if visibleLatitudeDelta > 0.35 {
            gridSize = 0.08
        }

        let grouped = Dictionary(grouping: withCoords) { row in
            let lat = row.latitude!
            let lon = row.longitude!
            let latKey = Int(lat / gridSize)
            let lonKey = Int(lon / gridSize)
            return "\(latKey)-\(lonKey)"
        }

        let clusters: [PickupGameCluster] = grouped.map { key, list in
            let avgLat = list.map { $0.latitude! }.reduce(0, +) / Double(list.count)
            let avgLon = list.map { $0.longitude! }.reduce(0, +) / Double(list.count)
            return PickupGameCluster(
                id: "p-\(key)",
                rows: list,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }
        .sorted { $0.id < $1.id }

        discoverPickupClustersCacheKey = cacheKey
        discoverPickupClustersCache = clusters
        return clusters
    }

    func invalidatePickupGameClusterAnnotationCache() {
        discoverPickupClustersCache = nil
        discoverPickupClustersCacheKey = nil
    }

    /// Zoom in on a multi-venue cluster (Discover); uses current span so repeated taps keep tightening.
    func zoomTowardCluster(center: CLLocationCoordinate2D) {
        let current = max(visibleLatitudeDelta, 0.02)
        let nextLat = max(min(current / 3.4, 1.4), 0.018)
        let nextLon = max(min(current / 3.4 * 1.08, 1.5), 0.018)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: center,
                span: MKCoordinateSpan(latitudeDelta: nextLat, longitudeDelta: nextLon)
            )
        )
    }

    /// Per-venue map energy: sum of (going + comments + vibes) across games shown for that day slice.
    func mapPinEnergyScore(bar: BarVenue, gamesOnMapDay: [SportsEvent]) -> Int {
        gamesOnMapDay.reduce(0) { total, game in
            guard let id = cachedVenueEventID(for: bar, gameTitle: game.title) else {
                return total
            }
            let going = interestCountForVenueEvent(id)
            let comments = venueEventComments[id]?.count ?? 0
            let vibes = venueEventVibeCounts[id]?.values.reduce(0, +) ?? 0
            return total + going + comments + vibes
        }
    }

    /// Strongest single-game energy in the cluster and that game’s sport (for marker glyph).
    func clusterVenueAnnotationEnergy(cluster: VenueCluster) -> (maxScore: Int, dominantSport: String?) {
        var maxScore = 0
        var dominantSport: String?
        for bar in cluster.bars {
            let gamesToday = selectedDayEventsForMap(bar)
            for game in gamesToday {
                guard let id = cachedVenueEventID(for: bar, gameTitle: game.title) else { continue }
                let going = interestCountForVenueEvent(id)
                let comments = venueEventComments[id]?.count ?? 0
                let vibes = venueEventVibeCounts[id]?.values.reduce(0, +) ?? 0
                let score = going + comments + vibes
                if score > maxScore {
                    maxScore = score
                    dominantSport = game.sport
                }
            }
        }
        return (maxScore, dominantSport)
    }

    /// Short label for cluster badge (same bands as game rows).
    func mapClusterEnergyCaption(maxScore: Int) -> String? {
        if maxScore >= 40 { return "👑 Trending" }
        if maxScore >= 16 { return "🚀 Hot" }
        if maxScore >= 6 { return "🔥 Active" }
        if maxScore >= 1 { return "✨ Starting" }
        return nil
    }

    func centerMap(on bar: BarVenue, selectForPreview: Bool = true) {
        #if DEBUG
        let t0 = Date()
        #endif
        if selectForPreview {
            if let hold = discoverRemotePreviewHoldVenueId, hold != bar.id {
                discoverRemotePreviewHoldVenueId = nil
            }
            selectedPickupGameForMap = nil
            selectedBar = bar
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: bar.coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
        #if DEBUG
        if selectForPreview {
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverPerf] venue preview open (centerMap) ms=\(ms) venue=\(bar.name)")
        }
        #endif
    }

    /// Centers the map on a coordinate (e.g. geocoded address) while optionally keeping a venue selected for the preview card.
    func centerMap(on coordinate: CLLocationCoordinate2D, selectedBar: BarVenue?) {
        if let selectedBar {
            if let hold = discoverRemotePreviewHoldVenueId, hold != selectedBar.id {
                discoverRemotePreviewHoldVenueId = nil
            }
            selectedPickupGameForMap = nil
            self.selectedBar = selectedBar
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
    }

    func searchMapLocation() {
        discoverSearchDebounceTask?.cancel()
        discoverSearchDebounceTask = nil

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            venueSearchResults = []
            debouncedDiscoverSearchText = ""
            return
        }

        debouncedDiscoverSearchText = q
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil

        let region = cameraPosition.region
        let localOrdered = discoverVenueSearchLocalMatchesOrdered(query: q, region: region)
        #if DEBUG
        print("[VenueSearch] local results count=\(localOrdered.count)")
        #endif

        if q.count < 2 {
            venueSearchResults = localOrdered
            return
        }

        Task { @MainActor in
            isDiscoverVenueSearchLoading = true
            defer { isDiscoverVenueSearchLoading = false }

            #if DEBUG
            let tSearch0 = Date()
            #endif
            let remoteMatches = await fetchDiscoverVenueSearchBars(query: q)
            #if DEBUG
            let remoteMs = Int(Date().timeIntervalSince(tSearch0) * 1000)
            print("[Phase1Perf] discoverSearch keyboardGo remoteVenuesMs=\(remoteMs) rows=\(remoteMatches.count) query=\(q)")
            #endif

            var seen = Set(localOrdered.map(\.id))
            var merged: [BarVenue] = localOrdered
            for b in remoteMatches where seen.insert(b.id).inserted {
                merged.append(b)
            }
            venueSearchResults = merged

            if merged.isEmpty, let coord = await geocodeAddress(q) {
                venueSearchResults = []
                cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                    )
                )
            }
        }
    }

    func geocodeAddress(_ address: String) async -> CLLocationCoordinate2D? {
        await withCheckedContinuation { continuation in
            CLGeocoder().geocodeAddressString(address) { placemarks, error in
                if error != nil {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: placemarks?.first?.location?.coordinate)
            }
        }
    }

    /// Reverse geocode for pickup map pin (street line, city, state); all nil if lookup fails.
    func reverseGeocodeAddressFields(for coordinate: CLLocationCoordinate2D) async -> (
        street: String?,
        city: String?,
        state: String?
    ) {
        await withCheckedContinuation { continuation in
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            CLGeocoder().reverseGeocodeLocation(location) { placemarks, error in
                if error != nil {
                    continuation.resume(returning: (nil, nil, nil))
                    return
                }
                guard let pm = placemarks?.first else {
                    continuation.resume(returning: (nil, nil, nil))
                    return
                }
                let num = pm.subThoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let name = pm.thoroughfare?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let streetCombined = [num, name].filter { !$0.isEmpty }.joined(separator: " ")
                let street: String? = streetCombined.isEmpty ? nil : streetCombined
                let city: String? = {
                    guard let t = pm.locality?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                    return t
                }()
                let state: String? = {
                    guard let t = pm.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                    return t
                }()
                continuation.resume(returning: (street, city, state))
            }
        }
    }

    /// Axis-aligned bounds of the current map camera region (Supabase venue windowing).
    func currentMapRegionBounds() -> (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? {
        guard let region = cameraPosition.region else { return nil }
        let center = region.center
        let span = region.span
        let minLat = center.latitude - span.latitudeDelta / 2
        let maxLat = center.latitude + span.latitudeDelta / 2
        let minLon = center.longitude - span.longitudeDelta / 2
        let maxLon = center.longitude + span.longitudeDelta / 2
        return (minLat, maxLat, minLon, maxLon)
    }
}
