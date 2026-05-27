import CoreLocation
import Foundation
import MapKit
import SwiftUI

private enum DiscoverCitySearchVenueReloadConfig {
    static let radiusMiles = 25.0
}

fileprivate enum DiscoverLocationFetchResult {
    case coordinate(CLLocationCoordinate2D)
    case unavailable(reason: String)
}

struct BusinessVenueGeocodeResult: Sendable {
    let coordinate: CLLocationCoordinate2D
    let formattedAddress: String
}

struct BusinessVenueReverseGeocodeResult: Sendable {
    let addressLine1: String?
    let addressLine2: String?
    let locality: String?
    let region: String?
    let postalCode: String?
    let countryCode: String?
    let formattedAddress: String?
}

enum DiscoverVenueClusterTuning {
    private struct DenseDistrictBounds: Sendable {
        let latitude: ClosedRange<Double>
        let longitude: ClosedRange<Double>

        nonisolated func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
            latitude.contains(coordinate.latitude) && longitude.contains(coordinate.longitude)
        }
    }

    nonisolated private static let denseEntertainmentDistricts: [DenseDistrictBounds] = [
        // Las Vegas Strip / Paradise corridor.
        DenseDistrictBounds(latitude: 36.075...36.155, longitude: (-115.195)...(-115.140)),
        // Downtown Las Vegas / Fremont.
        DenseDistrictBounds(latitude: 36.160...36.185, longitude: (-115.160)...(-115.130)),
        // Miami Beach / South Beach.
        DenseDistrictBounds(latitude: 25.760...25.890, longitude: (-80.155)...(-80.110)),
        // Downtown Los Angeles / LA Live.
        DenseDistrictBounds(latitude: 34.030...34.070, longitude: (-118.285)...(-118.220)),
        // Manhattan.
        DenseDistrictBounds(latitude: 40.680...40.885, longitude: (-74.030)...(-73.905)),
        // Disney Springs / Lake Buena Vista.
        DenseDistrictBounds(latitude: 28.360...28.395, longitude: (-81.535)...(-81.490)),
        // Scottsdale entertainment district.
        DenseDistrictBounds(latitude: 33.485...33.515, longitude: (-111.945)...(-111.910)),
    ]

    nonisolated static func clusterKey(for coordinate: CLLocationCoordinate2D, visibleLatitudeDelta: Double) -> String {
        let gridSize = clusterGridSize(for: coordinate, visibleLatitudeDelta: visibleLatitudeDelta)
        let latKey = Int(coordinate.latitude / gridSize)
        let lonKey = Int(coordinate.longitude / gridSize)
        let gridKey = Int((gridSize * 1_000_000).rounded())
        return "g\(gridKey)-\(latKey)-\(lonKey)"
    }

    nonisolated static func clusterGridSize(for coordinate: CLLocationCoordinate2D, visibleLatitudeDelta: Double) -> Double {
        guard isDenseEntertainmentDistrict(coordinate) else {
            return visibleLatitudeDelta > 0.35 ? 0.08 : 0.035
        }

        if visibleLatitudeDelta > 0.35 {
            return 0.08
        } else if visibleLatitudeDelta > 0.18 {
            return 0.024
        } else if visibleLatitudeDelta > 0.08 {
            return 0.006
        } else if visibleLatitudeDelta > 0.035 {
            return 0.0025
        } else {
            return 0.0012
        }
    }

    nonisolated private static func isDenseEntertainmentDistrict(_ coordinate: CLLocationCoordinate2D) -> Bool {
        denseEntertainmentDistricts.contains { $0.contains(coordinate) }
    }
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
        let idFingerprint = source.prefix(96).map { $0.id.uuidString.lowercased() }.joined(separator: ",")
        let cacheKey = "\(source.count)|\(idFingerprint)|\(dayBucket)|\(selectedSport)|\(mapDisplayMode.rawValue)|\(debouncedDiscoverSearchText.hashValue)|\(String(format: "%.5f", visibleLatitudeDelta))|\(String(format: "%.4f", coordFingerprint))"
        if cacheKey == discoverClusteredBarsCacheKey, let cached = discoverClusteredBarsCache {
            return cached
        }

        let grouped = Dictionary(grouping: source) { bar in
            DiscoverVenueClusterTuning.clusterKey(
                for: bar.coordinate,
                visibleLatitudeDelta: visibleLatitudeDelta
            )
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

    func clusteredPickupPlaceBarsForDiscoverMap(rows: [BarVenue]) -> [VenueCluster] {
        let source = rows.filter { CLLocationCoordinate2DIsValid($0.coordinate) }
        guard !source.isEmpty else { return [] }

        let grouped = Dictionary(grouping: source) { bar in
            DiscoverVenueClusterTuning.clusterKey(
                for: bar.coordinate,
                visibleLatitudeDelta: visibleLatitudeDelta
            )
        }

        return grouped.map { key, bars in
            let avgLat = bars.map { $0.coordinate.latitude }.reduce(0, +) / Double(bars.count)
            let avgLon = bars.map { $0.coordinate.longitude }.reduce(0, +) / Double(bars.count)
            return VenueCluster(
                id: "pp-\(key)",
                bars: bars,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }
        .sorted { $0.id < $1.id }
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
            let comments = fanUpdatesDisplayCommentCount(for: id)
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
                let comments = fanUpdatesDisplayCommentCount(for: id)
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
            selectVenueForPreview(bar, source: "centerMap")
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
            selectVenueForPreview(selectedBar, source: "centerMapCoordinate")
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
            let remoteMatches = await self.fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: false)
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

    func submitDiscoverAddressSearchFromReturn() async -> Bool {
        discoverSearchDebounceTask?.cancel()
        discoverSearchDebounceTask = nil

        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            venueSearchResults = []
            debouncedDiscoverSearchText = ""
            return false
        }

        let kind = discoverMapSearchKind(for: q)
#if DEBUG
        print("[DiscoverSearchDebug] addressSearchSubmitted query=\(q)")
#endif

        isDiscoverVenueSearchLoading = true
        defer { isDiscoverVenueSearchLoading = false }

        if kind == .globalPlace, let resolution = await geocodeDiscoverAddressSearch(q) {
            applySuccessfulDiscoverAddressSearch(resolution: resolution, query: q)
            return true
        }

        let localOrdered = kind == .appContentRegionBound
            ? await discoverRegionBoundAppContentSearchOrderedDetached(query: q)
            : []
        let remoteMatches = await fetchDiscoverVenueSearchBars(query: q, useViewportTextSearchBounds: false)
        var seen = Set(localOrdered.map(\.id))
        var merged: [BarVenue] = localOrdered
        for bar in remoteMatches where seen.insert(bar.id).inserted {
            merged.append(bar)
        }

        if kind == .appContentRegionBound, merged.isEmpty, let resolution = await geocodeDiscoverAddressSearch(q) {
            applySuccessfulDiscoverAddressSearch(resolution: resolution, query: q)
            return true
        }

        debouncedDiscoverSearchText = q
        venueSearchResults = merged
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
        discoverPickupClustersCacheKey = nil
        discoverPickupClustersCache = nil
        return false
    }

    private func applySuccessfulDiscoverAddressSearch(resolution: CitySearchVenueDebugContext, query: String) {
        selectedBar = nil
        selectedEvent = nil
        selectedPickupGameForMap = nil
        discoverRemotePreviewHoldVenueId = nil
        venueSearchResults = []
        searchText = ""
        debouncedDiscoverSearchText = ""
        discoverClusteredBarsCacheKey = nil
        discoverClusteredBarsCache = nil
        discoverPickupClustersCacheKey = nil
        discoverPickupClustersCache = nil
        pendingCitySearchVenueDebugContext = resolution
        cameraPosition = .region(
            MKCoordinateRegion(
                center: resolution.resolvedCoordinate,
                span: MKCoordinateSpan(
                    latitudeDelta: resolution.bounds.latSpan,
                    longitudeDelta: resolution.bounds.lonSpan
                )
            )
        )
#if DEBUG
        print("[CitySearchVenueDebug] query=\(query)")
        print("[CitySearchVenueDebug] resolvedCoordinate=\(resolution.resolvedCoordinate.latitude),\(resolution.resolvedCoordinate.longitude)")
        print("[CitySearchVenueDebug] resolvedCity=\(resolution.resolvedCity)")
        print("[CitySearchVenueDebug] resolvedState=\(resolution.resolvedState)")
        print("[CitySearchVenueDebug] radiusMiles=\(resolution.radiusMiles)")
        print("[CitySearchVenueDebug] bounds=\(Self.citySearchBoundsDescription(resolution.bounds))")
        print("[DiscoverSearchDebug] addressSearchClearedAfterSubmit=true")
#endif
    }

    private func geocodeDiscoverAddressSearch(_ address: String) async -> CitySearchVenueDebugContext? {
        guard let request = MKGeocodingRequest(addressString: address) else { return nil }
        do {
            guard let item = try await request.mapItems.first else {
                return nil
            }
            let coordinate = item.location.coordinate
            let radiusMiles = DiscoverCitySearchVenueReloadConfig.radiusMiles
            let bounds = Self.citySearchBounds(around: coordinate, radiusMiles: radiusMiles)
            let cityState = Self.discoverCitySearchLocationText(from: item)
            return CitySearchVenueDebugContext(
                query: address,
                resolvedCoordinate: coordinate,
                resolvedCity: cityState.city,
                resolvedState: cityState.state,
                radiusMiles: radiusMiles,
                bounds: bounds
            )
        } catch {
            return nil
        }
    }

    nonisolated private static func discoverCitySearchLocationText(from item: MKMapItem) -> (city: String, state: String) {
        if #available(iOS 26.0, *) {
            let representations = item.addressRepresentations
            let city = trimmedNonEmpty(representations?.cityName) ?? ""
            let lines = addressLines(from: representations, address: item.address)
            let regionPostal = stateAndPostalCode(from: lines, city: city)
            let state = stateAbbreviation(from: trimmedNonEmpty(representations?.cityWithContext), city: city)
                ?? regionPostal.state
                ?? ""
            return (city, state)
        } else {
            return (
                item.placemark.locality ?? "",
                item.placemark.administrativeArea ?? item.placemark.countryCode ?? ""
            )
        }
    }

    nonisolated private static func citySearchBounds(
        around coordinate: CLLocationCoordinate2D,
        radiusMiles: Double
    ) -> DiscoverMapBoundsWindow {
        let latDelta = radiusMiles / 69.0
        let lonMilesPerDegree = max(cos(coordinate.latitude * .pi / 180) * 69.172, 0.01)
        let lonDelta = radiusMiles / lonMilesPerDegree
        return DiscoverMapBoundsWindow(
            minLat: coordinate.latitude - latDelta,
            maxLat: coordinate.latitude + latDelta,
            minLon: coordinate.longitude - lonDelta,
            maxLon: coordinate.longitude + lonDelta
        )
    }

    nonisolated private static func citySearchBoundsDescription(_ bounds: DiscoverMapBoundsWindow) -> String {
        String(
            format: "%.5f...%.5f,%.5f...%.5f",
            bounds.minLat,
            bounds.maxLat,
            bounds.minLon,
            bounds.maxLon
        )
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

    func geocodeBusinessVenueAddress(_ query: String, fallbackFormattedAddress: String) async -> BusinessVenueGeocodeResult? {
#if DEBUG
        print("[InternationalAddressDebug] geocodeQuery=\(query)")
#endif
        guard let request = MKGeocodingRequest(addressString: query) else {
#if DEBUG
            print("[InternationalAddressDebug] addressValidation=geocodeRequestInvalid")
#endif
            return nil
        }
        do {
            let item = try await request.mapItems.first
            guard let coordinate = item?.location.coordinate else {
#if DEBUG
                print("[InternationalAddressDebug] addressValidation=geocodeNoResult")
#endif
                return nil
            }
            let formatted = Self.formattedBusinessVenueAddress(from: item) ?? fallbackFormattedAddress
#if DEBUG
            print("[InternationalAddressDebug] addressValidation=geocodeResolved")
            print("[InternationalAddressDebug] formattedAddress=\(formatted)")
            print("[InternationalAddressDebug] latitude=\(coordinate.latitude)")
            print("[InternationalAddressDebug] longitude=\(coordinate.longitude)")
#endif
            return BusinessVenueGeocodeResult(coordinate: coordinate, formattedAddress: formatted)
        } catch {
#if DEBUG
            print("[InternationalAddressDebug] addressValidation=geocodeFailed \(error.localizedDescription)")
#endif
            return nil
        }
    }

    func reverseGeocodeBusinessVenueLocation(for coordinate: CLLocationCoordinate2D) async -> BusinessVenueReverseGeocodeResult {
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let result: BusinessVenueReverseGeocodeResult
        if #available(iOS 26.0, *) {
            result = await Self.businessVenueReverseGeocodeResultUsingMapKit(for: location)
        } else {
            result = BusinessVenueReverseGeocodeResult(
                addressLine1: nil,
                addressLine2: nil,
                locality: nil,
                region: nil,
                postalCode: nil,
                countryCode: nil,
                formattedAddress: nil
            )
        }
#if DEBUG
        if result.formattedAddress != nil || result.addressLine1 != nil {
            print("[InternationalAddressDebug] reverseGeocodeSuccess=true")
        } else {
            print("[InternationalAddressDebug] reverseGeocodeSuccess=false")
        }
#endif
        return result
    }

    @available(iOS 26.0, *)
    nonisolated private static func businessVenueReverseGeocodeResultUsingMapKit(for location: CLLocation) async -> BusinessVenueReverseGeocodeResult {
        guard let request = MKReverseGeocodingRequest(location: location),
              let item = try? await request.mapItems.first else {
            return BusinessVenueReverseGeocodeResult(
                addressLine1: nil,
                addressLine2: nil,
                locality: nil,
                region: nil,
                postalCode: nil,
                countryCode: nil,
                formattedAddress: nil
            )
        }

        let representations = item.addressRepresentations
        let lines = addressLines(from: representations, address: item.address)
        let locality = trimmedNonEmpty(representations?.cityName)
        let cityContext = trimmedNonEmpty(representations?.cityWithContext)
        let regionPostal = stateAndPostalCode(from: lines, city: locality)
        let region = stateAbbreviation(from: cityContext, city: locality) ?? regionPostal.state
        let formatted = formattedBusinessVenueAddress(from: item)

        return BusinessVenueReverseGeocodeResult(
            addressLine1: streetLine(from: lines, city: locality),
            addressLine2: nil,
            locality: locality,
            region: region,
            postalCode: regionPostal.postalCode,
            countryCode: nil,
            formattedAddress: formatted
        )
    }

    func fetchCurrentCoordinateForBusinessPin(timeoutSeconds: TimeInterval = 12) async -> CLLocationCoordinate2D? {
        let session = DiscoverCurrentLocationFetchSession()
        let result = await session.fetchBestCoordinateOnce(timeoutSeconds: timeoutSeconds)
        guard case .coordinate(let coordinate) = result else { return nil }
        recordCurrentUserLocation(coordinate)
        return coordinate
    }

    nonisolated static func distanceMeters(
        from lhs: CLLocationCoordinate2D,
        to rhs: CLLocationCoordinate2D
    ) -> CLLocationDistance {
        let a = CLLocation(latitude: lhs.latitude, longitude: lhs.longitude)
        let b = CLLocation(latitude: rhs.latitude, longitude: rhs.longitude)
        return a.distance(from: b)
    }

    nonisolated private static func formattedBusinessVenueAddress(from item: MKMapItem?) -> String? {
        guard let item else { return nil }
        if #available(iOS 26.0, *) {
            let formatted = item.addressRepresentations?.fullAddress(includingRegion: true, singleLine: true)
                ?? item.address?.fullAddress
                ?? item.address?.shortAddress
            return trimmedNonEmpty(formatted)
        }
        return nil
    }

    nonisolated private static func businessVenueReverseGeocodeResult(
        from placemark: CLPlacemark?,
        fallbackFormattedAddress: String?
    ) -> BusinessVenueReverseGeocodeResult {
        guard let placemark else {
            return BusinessVenueReverseGeocodeResult(
                addressLine1: nil,
                addressLine2: nil,
                locality: nil,
                region: nil,
                postalCode: nil,
                countryCode: nil,
                formattedAddress: fallbackFormattedAddress
            )
        }

        let streetParts = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { trimmedNonEmpty($0) }
        let line1 = streetParts.isEmpty
            ? trimmedNonEmpty(placemark.name)
            : streetParts.joined(separator: " ")
        let locality = trimmedNonEmpty(placemark.locality)
            ?? trimmedNonEmpty(placemark.subLocality)
        let region = trimmedNonEmpty(placemark.administrativeArea)
        let postal = trimmedNonEmpty(placemark.postalCode)
        let country = trimmedNonEmpty(placemark.isoCountryCode).map(BusinessLocationCountryPolicy.normalizedStoredCountryCode)
        let formatted = fallbackFormattedAddress
            ?? BusinessVenueAddressFormatter.formattedAddress(
                line1: line1 ?? "",
                locality: locality ?? "",
                region: region ?? "",
                postalCode: postal ?? "",
                countryCode: country ?? ""
            )

        return BusinessVenueReverseGeocodeResult(
            addressLine1: line1,
            addressLine2: nil,
            locality: locality,
            region: region,
            postalCode: postal,
            countryCode: country,
            formattedAddress: trimmedNonEmpty(formatted)
        )
    }

    /// Reverse geocode for pickup map pin (street line, city, state, postal code); all nil if lookup fails.
    func reverseGeocodeAddressFields(for coordinate: CLLocationCoordinate2D) async -> (
        street: String?,
        city: String?,
        state: String?,
        postalCode: String?
    ) {
#if DEBUG
        print("[PickupLocationDebug] reverseGeocodeStarted coordinate=\(coordinate.latitude),\(coordinate.longitude)")
#endif
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        do {
            let fields: (street: String?, city: String?, state: String?, postalCode: String?)
            if #available(iOS 26.0, *) {
                fields = try await Self.reverseGeocodedAddressFieldsUsingMapKit(for: location)
            } else {
                let placemark = try await CLGeocoder().reverseGeocodeLocation(location).first
                fields = Self.reverseGeocodedAddressFields(from: placemark)
            }
#if DEBUG
            print("[PickupLocationDebug] reverseGeocodeResult street=\(fields.street ?? "")")
            print("[PickupLocationDebug] reverseGeocodeResult city=\(fields.city ?? "")")
            print("[PickupLocationDebug] reverseGeocodeResult state=\(fields.state ?? "")")
            print("[PickupLocationDebug] reverseGeocodeResult postalCode=\(fields.postalCode ?? "")")
#endif
            return fields
        } catch {
#if DEBUG
            print("[PickupLocationDebug] reverseGeocodeResult street=")
            print("[PickupLocationDebug] reverseGeocodeResult city=")
            print("[PickupLocationDebug] reverseGeocodeResult state=")
            print("[PickupLocationDebug] reverseGeocodeResult postalCode=")
#endif
            return (nil, nil, nil, nil)
        }
    }

    /// iOS 26+ reverse geocoding. MapKit exposes formatted address strings here, so this keeps field extraction
    /// narrowly focused on the US-style addresses FanGeo's pickup flow stores today.
    @available(iOS 26.0, *)
    nonisolated private static func reverseGeocodedAddressFieldsUsingMapKit(for location: CLLocation) async throws -> (
        street: String?,
        city: String?,
        state: String?,
        postalCode: String?
    ) {
        guard let request = MKReverseGeocodingRequest(location: location) else {
            return (nil, nil, nil, nil)
        }

        let item = try await request.mapItems.first
        let representations = item?.addressRepresentations
        let lines = Self.addressLines(from: representations, address: item?.address)
        let city = Self.trimmedNonEmpty(representations?.cityName)
        let cityContext = Self.trimmedNonEmpty(representations?.cityWithContext)
        let street = Self.streetLine(from: lines, city: city)
        let statePostal = Self.stateAndPostalCode(from: lines, city: city)
        let state = Self.stateAbbreviation(from: cityContext, city: city) ?? statePostal.state
        let postalCode = statePostal.postalCode

        return (street, city, state, postalCode)
    }

    @available(iOS 26.0, *)
    nonisolated private static func addressLines(from representations: MKAddressRepresentations?, address: MKAddress?) -> [String] {
        let addressText = representations?.fullAddress(includingRegion: false, singleLine: false)
            ?? address?.fullAddress
            ?? address?.shortAddress
        return addressText?
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
    }

    nonisolated private static func streetLine(from lines: [String], city: String?) -> String? {
        lines.first { line in
            guard let city, !city.isEmpty else { return true }
            return !line.localizedCaseInsensitiveContains(city)
        }
    }

    nonisolated private static func stateAbbreviation(from cityContext: String?, city: String?) -> String? {
        guard
            let cityContext,
            let city,
            cityContext.localizedCaseInsensitiveContains(city),
            let commaIndex = cityContext.firstIndex(of: ",")
        else {
            return nil
        }

        let remainder = cityContext[cityContext.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.split(separator: ",").first.map(String.init).flatMap(Self.trimmedNonEmpty)
    }

    nonisolated private static func stateAndPostalCode(from lines: [String], city: String?) -> (state: String?, postalCode: String?) {
        guard
            let city,
            let cityLine = lines.first(where: { $0.localizedCaseInsensitiveContains(city) }),
            let commaIndex = cityLine.firstIndex(of: ",")
        else {
            return (nil, nil)
        }

        let statePostal = cityLine[cityLine.index(after: commaIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = statePostal.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true).map(String.init)
        return (
            pieces.first.flatMap(Self.trimmedNonEmpty),
            pieces.dropFirst().first.flatMap(Self.trimmedNonEmpty)
        )
    }

    /// Best-effort street / city / state / postal code from iOS reverse-geocoded placemark fields.
    nonisolated private static func reverseGeocodedAddressFields(from placemark: CLPlacemark?) -> (
        street: String?,
        city: String?,
        state: String?,
        postalCode: String?
    ) {
        guard let placemark else { return (nil, nil, nil, nil) }
        let streetParts = [placemark.subThoroughfare, placemark.thoroughfare]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let street = streetParts.isEmpty ? nil : streetParts.joined(separator: " ")
        let city = placemark.locality?.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = placemark.administrativeArea?.trimmingCharacters(in: .whitespacesAndNewlines)
        let postalCode = placemark.postalCode?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (
            street,
            city?.isEmpty == false ? city : nil,
            state?.isEmpty == false ? state : nil,
            postalCode?.isEmpty == false ? postalCode : nil
        )
    }

    nonisolated private static func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
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

    private static let startupDiscoverInitialRadiusMiles: Double = 9

    /// Startup: optional GPS center + local region, then arms the next ``refreshDiscoverCoreInBackground()`` for DEBUG completion logging. Runs once per launch (see ``didFinishStartupDiscoverPrepare``).
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
            let region = Self.discoverStartupMKRegion(center: c, radiusMiles: Self.startupDiscoverInitialRadiusMiles)
            cameraPosition = .region(region)
#if DEBUG
            print("[StartupMapRegionDebug] initialSpan=\(region.span.latitudeDelta),\(region.span.longitudeDelta)")
            print("[StartupMapRegionDebug] basis=userLocation")
#endif
        case .unavailable(let reason):
#if DEBUG
            print("[StartupDiscover] fallbackToDefaultRegion reason=\(reason)")
            if let region = cameraPosition.region {
                print("[StartupMapRegionDebug] initialSpan=\(region.span.latitudeDelta),\(region.span.longitudeDelta)")
            }
            print("[StartupMapRegionDebug] basis=fallback")
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
