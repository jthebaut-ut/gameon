import CoreLocation
import Foundation
import MapKit
import SwiftUI

fileprivate enum DiscoverLocationFetchResult {
    case coordinate(CLLocationCoordinate2D)
    case unavailable(reason: String)
}

/// One-shot Core Location fetch for the Discover map “current location” control (no Utah/Lehi fallback).
private final class DiscoverCurrentLocationFetchSession: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var continuation: CheckedContinuation<DiscoverLocationFetchResult, Never>?
    private let lock = NSLock()
    private var hasFinished = false
    private var timeoutTask: Task<Void, Never>?

    func fetchBestCoordinateOnce(timeoutSeconds: TimeInterval = 12) async -> DiscoverLocationFetchResult {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            manager.delegate = self
            manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
            manager.distanceFilter = kCLDistanceFilterNone

            let status = manager.authorizationStatus
#if DEBUG
            print("[CurrentLocationButton] permission=\(Self.authDebugLabel(status))")
#endif
            switch status {
            case .notDetermined:
                manager.requestWhenInUseAuthorization()
            case .authorizedAlways, .authorizedWhenInUse:
                manager.requestLocation()
            case .denied, .restricted:
                finishUnavailable(reason: "authorizationDeniedOrRestricted")
            @unknown default:
                finishUnavailable(reason: "unknownAuthorization")
            }

            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeoutSeconds))
                self?.finishUnavailable(reason: "timeout")
            }
        }
    }

    private static func authDebugLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private func tearDownLocationUpdates() {
        manager.stopUpdatingLocation()
        manager.delegate = nil
    }

    private func finishSuccess(_ coordinate: CLLocationCoordinate2D) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        lock.unlock()

        tearDownLocationUpdates()

        cont?.resume(returning: .coordinate(coordinate))
    }

    private func finishUnavailable(reason: String) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        timeoutTask?.cancel()
        timeoutTask = nil
        let cont = continuation
        continuation = nil
        lock.unlock()

        tearDownLocationUpdates()

        cont?.resume(returning: .unavailable(reason: reason))
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
#if DEBUG
        print("[CurrentLocationButton] permission=\(Self.authDebugLabel(status))")
#endif
        switch status {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        case .denied, .restricted:
            finishUnavailable(reason: "authorizationDeniedOrRestricted")
        case .notDetermined:
            break
        @unknown default:
            finishUnavailable(reason: "unknownAuthorization")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else {
            finishUnavailable(reason: "noLocationFix")
            return
        }
        let c = loc.coordinate
        guard CLLocationCoordinate2DIsValid(c) else {
            finishUnavailable(reason: "invalidCoordinate")
            return
        }
#if DEBUG
        print("[CurrentLocationButton] realLocation=\(c.latitude),\(c.longitude)")
#endif
        finishSuccess(c)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
#if DEBUG
        print("[CurrentLocationButton] locationManagerFailed error=\(error.localizedDescription)")
#endif
        finishUnavailable(reason: "locationError")
    }
}

extension MapViewModel {

    func recordCurrentUserLocation(_ coordinate: CLLocationCoordinate2D) {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return }
        currentUserLocation = coordinate
    }

    /// Updates ``currentUserLocation`` when location permission is already granted (no new permission prompt).
    @discardableResult
    func refreshCurrentUserLocationIfAuthorized(timeoutSeconds: TimeInterval = 6) async -> Bool {
        let status = CLLocationManager().authorizationStatus
        guard status == .authorizedWhenInUse || status == .authorizedAlways else {
            return false
        }
        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: timeoutSeconds)
        guard case .coordinate(let coordinate) = result else {
            return false
        }
        recordCurrentUserLocation(coordinate)
        return true
    }

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

        let kind = discoverMapSearchKind(for: q)

        if q.count < 2 {
            Task { @MainActor [weak self] in
                guard let self else { return }
#if DEBUG
                let t0 = Date()
#endif
                if kind == .globalPlace {
                    self.venueSearchResults = []
                    if let coord = await self.geocodeAddress(q) {
                        self.cameraPosition = .region(
                            MKCoordinateRegion(
                                center: coord,
                                span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                            )
                        )
                    }
#if DEBUG
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(self.venueSearchResults.count) elapsedMs=\(ms) cancelled=no")
#endif
                } else {
                    let localOnly = await self.discoverRegionBoundAppContentSearchOrderedDetached(query: q)
                    self.venueSearchResults = localOnly
#if DEBUG
                    let ms = Int(Date().timeIntervalSince(t0) * 1000)
                    print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(localOnly.count) elapsedMs=\(ms) cancelled=no")
#endif
                }
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isDiscoverVenueSearchLoading = true
            defer { self.isDiscoverVenueSearchLoading = false }
#if DEBUG
            let t0 = Date()
#endif
            if kind == .globalPlace {
                let remote = await self.fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: false)
                self.venueSearchResults = remote
#if DEBUG
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(remote.count) elapsedMs=\(ms) cancelled=no")
#endif
                if remote.isEmpty, let coord = await self.geocodeAddress(q) {
                    self.venueSearchResults = []
                    self.cameraPosition = .region(
                        MKCoordinateRegion(
                            center: coord,
                            span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                        )
                    )
                }
                return
            }

            let localOrdered = await self.discoverRegionBoundAppContentSearchOrderedDetached(query: q)
            let remoteMatches = await self.fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: true)
            var seen = Set(localOrdered.map(\.id))
            var merged: [BarVenue] = localOrdered
            for b in remoteMatches where seen.insert(b.id).inserted {
                merged.append(b)
            }
            self.venueSearchResults = merged
#if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverMapSearchPerf] query=\"\(q)\" kind=\(kind.rawValue) candidates=\(merged.count) elapsedMs=\(ms) cancelled=no")
#endif
            if merged.isEmpty, let coord = await self.geocodeAddress(q) {
                self.venueSearchResults = []
                self.cameraPosition = .region(
                    MKCoordinateRegion(
                        center: coord,
                        span: MKCoordinateSpan(latitudeDelta: 0.25, longitudeDelta: 0.25)
                    )
                )
            }
        }
    }

    func geocodeAddress(_ address: String) async -> CLLocationCoordinate2D? {
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        do {
            let items = try await request.mapItems
            return items.first?.location.coordinate
        } catch {
            return nil
        }
    }

    /// Reverse geocode for pickup map pin (street line, city, state); all nil if lookup fails.
    func reverseGeocodeAddressFields(for coordinate: CLLocationCoordinate2D) async -> (
        street: String?,
        city: String?,
        state: String?
    ) {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        guard let request = MKReverseGeocodingRequest(location: location) else { return (nil, nil, nil) }
        do {
            let items = try await request.mapItems
            guard let item = items.first else { return (nil, nil, nil) }
            return Self.reverseGeocodedStreetCityState(from: item)
        } catch {
            return (nil, nil, nil)
        }
    }

    /// Best-effort street / city / state from MapKit’s iOS 26+ ``MKMapItem`` address representations.
    nonisolated private static func reverseGeocodedStreetCityState(from mapItem: MKMapItem) -> (
        street: String?,
        city: String?,
        state: String?
    ) {
        if let reps = mapItem.addressRepresentations {
            let street: String? = {
                if let short = mapItem.address?.shortAddress?.trimmingCharacters(in: .whitespacesAndNewlines), !short.isEmpty {
                    return short
                }
                let multi =
                    reps.fullAddress(includingRegion: false, singleLine: false)
                    ?? reps.fullAddress(includingRegion: true, singleLine: false)
                    ?? ""
                let firstLine = multi
                    .components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first(where: { !$0.isEmpty })
                return firstLine
            }()

            let city = reps.cityName

            var state: String?
            if let cwc = reps.cityWithContext {
                let parts = cwc.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                if parts.count >= 2 {
                    state = parts.last
                }
            }

            return (street, city, state)
        }

        let fallback = mapItem.address?.shortAddress ?? mapItem.address?.fullAddress
        return (fallback, nil, nil)
    }

    /// Discover “my location” control: centers on a real GPS fix using the same span rule as ``centerMap(on:selectedBar:)`` (not Utah/Lehi fallback).
    @discardableResult
    func centerDiscoverMapOnUserPhysicalLocationIfPossible() async -> Bool {
        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: 12)
        guard case .coordinate(let coordinate) = result else {
#if DEBUG
            print("[CurrentLocationButton] noRealLocationAvailable requestingPermissionOrUpdate")
#endif
            return false
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        recordCurrentUserLocation(coordinate)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
#if DEBUG
        print("[CurrentLocationButton] centeredMapOnUserLocation")
#endif
        return true
    }

    private static let startupDiscoverInitialRadiusMiles: Double = 15

    /// Startup: optional GPS center + 15 mi region, then arms the next ``refreshDiscoverCoreInBackground()`` for DEBUG completion logging. Runs once per launch (see ``didFinishStartupDiscoverPrepare``).
    func prepareInitialDiscoverRegionAndPreload() async {
        guard !didFinishStartupDiscoverPrepare else { return }
        defer {
            didFinishStartupDiscoverPrepare = true
            startupDiscoverPreloadCompletionLogPending = true
        }

        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: 3)
        switch result {
        case .coordinate(let c):
#if DEBUG
            print("[StartupDiscover] userLocationFound lat=\(c.latitude) lon=\(c.longitude)")
            print("[StartupDiscover] usingInitialRadiusMiles=\(Self.startupDiscoverInitialRadiusMiles)")
#endif
            recordCurrentUserLocation(c)
            cameraPosition = .region(
                Self.discoverStartupMKRegion(center: c, radiusMiles: Self.startupDiscoverInitialRadiusMiles)
            )
        case .unavailable(let reason):
#if DEBUG
            print("[StartupDiscover] fallbackToDefaultRegion reason=\(reason)")
#endif
            break
        }

#if DEBUG
        print("[StartupDiscover] preloadStarted")
#endif
    }

    private static func discoverStartupMKRegion(center: CLLocationCoordinate2D, radiusMiles: Double) -> MKCoordinateRegion {
        let latHalf = radiusMiles / 69.0
        let cosLat = max(cos(center.latitude * .pi / 180.0), 0.01)
        let lonMilesPerDegree = cosLat * 69.172
        let lonHalf = radiusMiles / lonMilesPerDegree
        return MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(
                latitudeDelta: max(latHalf * 2, 0.02),
                longitudeDelta: max(lonHalf * 2, 0.02)
            )
        )
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
