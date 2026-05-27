import CoreLocation
import Foundation
import MapKit
import Supabase
import SwiftUI
import UIKit

private let pickupPlacesSelectColumnsWithSportTags =
    "id,name,place_type,sport_tags,city,state,zip,latitude,longitude"

private let pickupPlacesSelectColumnsWithSport =
    "id,name,place_type,sport,city,state,zip,latitude,longitude"

private let pickupPlacesMapFetchLimit = 500
private let pickupPlacesRegionalCacheTTL: TimeInterval = 180
private let pickupPlacesRegionalCacheMaxEntries = 12

private struct PickupPlaceTaggedDBRow: Decodable {
    let id: UUID
    let name: String?
    let place_type: String?
    let sport_tags: [String]?
    let city: String?
    let state: String?
    let zip: String?
    let latitude: Double?
    let longitude: Double?
}

private struct PickupPlaceSportDBRow: Decodable {
    let id: UUID
    let name: String?
    let place_type: String?
    let sport: String?
    let city: String?
    let state: String?
    let zip: String?
    let latitude: Double?
    let longitude: Double?
}

nonisolated struct PickupPlaceCluster: Identifiable {
    let id: String
    let rows: [PickupPlaceRow]
    let coordinate: CLLocationCoordinate2D

    var count: Int { rows.count }
}

extension MapViewModel {
    private var pickupPlacesCurrentFetchKey: String {
        guard let bounds = currentMapRegionBounds() else { return "no-bounds" }
        let sportKey = pickupPlacesServerSportTerms(for: selectedSport).joined(separator: ",")
        return [
            String(format: "%.4f", bounds.minLat),
            String(format: "%.4f", bounds.maxLat),
            String(format: "%.4f", bounds.minLon),
            String(format: "%.4f", bounds.maxLon),
            sportKey.isEmpty ? "all-sports" : sportKey
        ].joined(separator: "|")
    }

    private func mappedPickupPlaceRows(_ rows: [PickupPlaceTaggedDBRow]) -> [PickupPlaceRow] {
        rows.compactMap { row in
            guard let latitude = row.latitude,
                  let longitude = row.longitude else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return PickupPlaceRow(
                id: row.id,
                name: (row.name ?? "Pickup place").trimmingCharacters(in: .whitespacesAndNewlines),
                placeType: row.place_type,
                sportTags: row.sport_tags ?? [],
                city: row.city,
                state: row.state,
                zip: row.zip,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    private func mappedPickupPlaceRows(_ rows: [PickupPlaceSportDBRow]) -> [PickupPlaceRow] {
        rows.compactMap { row in
            guard let latitude = row.latitude,
                  let longitude = row.longitude else { return nil }
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return PickupPlaceRow(
                id: row.id,
                name: (row.name ?? "Pickup place").trimmingCharacters(in: .whitespacesAndNewlines),
                placeType: row.place_type,
                sportTags: sport.isEmpty ? [] : [sport],
                city: row.city,
                state: row.state,
                zip: row.zip,
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    func refreshPickupPlacesForDiscoverMap(force: Bool = false) async {
        guard force || (discoverMapContentMode == .pickupGames && discoverPickupSubMode == .places) else { return }
        guard let bounds = currentMapRegionBounds() else {
            isLoadingPickupPlacesForMap = false
            print("[PickupPlacesWarmCache] skipped reason=noBounds preservedRows=\(pickupPlacesForDiscoverMap.count)")
            return
        }

        let fetchKey = pickupPlacesCurrentFetchKey
        if !force, fetchKey == lastPickupPlacesFetchKey, !pickupPlacesForDiscoverMap.isEmpty {
            print("[PickupPlacesWarmCache] cacheHit=true reason=alreadyVisible key=\(fetchKey) rows=\(pickupPlacesForDiscoverMap.count)")
            return
        }

        let requestID = UUID()
        pickupPlacesDiscoverRequestID = requestID
        let cached = pickupPlacesRegionalCache[fetchKey]
        let cachedIsFresh = cached.map { Date().timeIntervalSince($0.fetchedAt) < pickupPlacesRegionalCacheTTL } ?? false
        if !force, let cached {
            pickupPlacesForDiscoverMap = cached.rows
            lastPickupPlacesFetchKey = fetchKey
            isLoadingPickupPlacesForMap = false
            print("[PickupPlacesWarmCache] immediateCachePublish=true key=\(fetchKey) rows=\(cached.rows.count) fresh=\(cachedIsFresh)")
            if cachedIsFresh {
                pruneSelectedPickupPlaceIfNeeded()
                return
            }
        } else {
            isLoadingPickupPlacesForMap = true
            print("[PickupPlacesWarmCache] cacheHit=false key=\(fetchKey)")
        }

        let startedAt = Date()
        let sportTerms = pickupPlacesServerSportTerms(for: selectedSport)
        let sportLog = sportTerms.isEmpty ? "All" : sportTerms.joined(separator: ",")
#if DEBUG
        print("[PickupPlacesDebug] fetchStarted=true bounds=\(fetchKey)")
        print("[PickupPlacesPerf] bounds=\(fetchKey)")
        print("[PickupPlacesPerf] sport=\(sportLog)")
#endif
        do {
            let taggedRows = try await fetchPickupPlaceTaggedRowsForMap(bounds: bounds, sportTerms: sportTerms)
            await publishPickupPlaces(
                mappedPickupPlaceRows(taggedRows),
                fetchKey: fetchKey,
                requestID: requestID,
                startedAt: startedAt
            )
        } catch {
#if DEBUG
            print("[PickupPlacesDebug] sportTagsFetchFailed=\(error)")
#endif
            do {
                let sportRows = try await fetchPickupPlaceSportRowsForMap(bounds: bounds, sportTerms: sportTerms)
                await publishPickupPlaces(
                    mappedPickupPlaceRows(sportRows),
                    fetchKey: fetchKey,
                    requestID: requestID,
                    startedAt: startedAt
                )
            } catch {
                if pickupPlacesDiscoverRequestID == requestID {
                    isLoadingPickupPlacesForMap = false
                }
                print("[PickupPlacesWarmCache] networkFailedPreservedRows=\(pickupPlacesForDiscoverMap.count) key=\(fetchKey)")
#if DEBUG
                print("[PickupPlacesDebug] rowsLoaded=0 error=\(error)")
                print("[PickupPlacesPerf] rowsLoaded=0")
                print("[PickupPlacesPerf] durationMs=\(pickupPlacesPerfDurationMs(since: startedAt))")
#endif
            }
        }
    }

    func warmPreloadPickupPlacesForCurrentRegion() async {
        guard let bounds = currentMapRegionBounds() else {
            print("[PickupPlacesWarmCache] warmSkipped reason=noBounds")
            return
        }
        let fetchKey = pickupPlacesCurrentFetchKey
        if let cached = pickupPlacesRegionalCache[fetchKey],
           Date().timeIntervalSince(cached.fetchedAt) < pickupPlacesRegionalCacheTTL {
            print("[PickupPlacesWarmCache] warmCacheHit=true key=\(fetchKey) rows=\(cached.rows.count)")
            return
        }

        let sportTerms = pickupPlacesServerSportTerms(for: selectedSport)
        let startedAt = Date()
        print("[PickupPlacesWarmCache] warmFetchStarted key=\(fetchKey)")
        do {
            let taggedRows = try await fetchPickupPlaceTaggedRowsForMap(bounds: bounds, sportTerms: sportTerms)
            let rows = mappedPickupPlaceRows(taggedRows)
            storePickupPlacesRegionalCache(rows, fetchKey: fetchKey)
            print("[PickupPlacesWarmCache] warmFetchCompleted rows=\(rows.count) durationMs=\(pickupPlacesPerfDurationMs(since: startedAt))")
        } catch {
            do {
                let sportRows = try await fetchPickupPlaceSportRowsForMap(bounds: bounds, sportTerms: sportTerms)
                let rows = mappedPickupPlaceRows(sportRows)
                storePickupPlacesRegionalCache(rows, fetchKey: fetchKey)
                print("[PickupPlacesWarmCache] warmFetchCompleted rows=\(rows.count) durationMs=\(pickupPlacesPerfDurationMs(since: startedAt)) fallback=true")
            } catch {
                print("[PickupPlacesWarmCache] warmFetchFailed key=\(fetchKey) error=\(error.localizedDescription)")
            }
        }
    }

    private func fetchPickupPlaceTaggedRowsForMap(
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        sportTerms: [String]
    ) async throws -> [PickupPlaceTaggedDBRow] {
        if let sportFilter = pickupPlacesSportTagsOrFilter(terms: sportTerms) {
            return try await supabase
                .from("pickup_places")
                .select(pickupPlacesSelectColumnsWithSportTags)
                .gte("latitude", value: bounds.minLat)
                .lte("latitude", value: bounds.maxLat)
                .gte("longitude", value: bounds.minLon)
                .lte("longitude", value: bounds.maxLon)
                .or(sportFilter)
                .limit(pickupPlacesMapFetchLimit)
                .execute()
                .value
        }

        return try await supabase
            .from("pickup_places")
            .select(pickupPlacesSelectColumnsWithSportTags)
            .gte("latitude", value: bounds.minLat)
            .lte("latitude", value: bounds.maxLat)
            .gte("longitude", value: bounds.minLon)
            .lte("longitude", value: bounds.maxLon)
            .limit(pickupPlacesMapFetchLimit)
            .execute()
            .value
    }

    private func fetchPickupPlaceSportRowsForMap(
        bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double),
        sportTerms: [String]
    ) async throws -> [PickupPlaceSportDBRow] {
        if let sportFilter = pickupPlacesSportOrFilter(terms: sportTerms) {
            return try await supabase
                .from("pickup_places")
                .select(pickupPlacesSelectColumnsWithSport)
                .gte("latitude", value: bounds.minLat)
                .lte("latitude", value: bounds.maxLat)
                .gte("longitude", value: bounds.minLon)
                .lte("longitude", value: bounds.maxLon)
                .or(sportFilter)
                .limit(pickupPlacesMapFetchLimit)
                .execute()
                .value
        }

        return try await supabase
            .from("pickup_places")
            .select(pickupPlacesSelectColumnsWithSport)
            .gte("latitude", value: bounds.minLat)
            .lte("latitude", value: bounds.maxLat)
            .gte("longitude", value: bounds.minLon)
            .lte("longitude", value: bounds.maxLon)
            .limit(pickupPlacesMapFetchLimit)
            .execute()
            .value
    }

    private func publishPickupPlaces(_ rows: [PickupPlaceRow], fetchKey: String, requestID: UUID, startedAt: Date) async {
        guard pickupPlacesDiscoverRequestID == requestID else {
            print("[PickupPlacesWarmCache] staleDiscard=true key=\(fetchKey)")
            return
        }
        storePickupPlacesRegionalCache(rows, fetchKey: fetchKey)
        pickupPlacesForDiscoverMap = rows
        lastPickupPlacesFetchKey = fetchKey
        isLoadingPickupPlacesForMap = false
        print("[PickupPlacesWarmCache] networkPublish=true key=\(fetchKey) rows=\(rows.count)")
#if DEBUG
        print("[PickupPlacesDebug] rowsLoaded=\(rows.count)")
        print("[PickupPlacesPerf] rowsLoaded=\(rows.count)")
        print("[PickupPlacesPerf] durationMs=\(pickupPlacesPerfDurationMs(since: startedAt))")
#endif
        pruneSelectedPickupPlaceIfNeeded()
    }

    private func storePickupPlacesRegionalCache(_ rows: [PickupPlaceRow], fetchKey: String) {
        pickupPlacesRegionalCache[fetchKey] = (rows: rows, fetchedAt: Date())
        prunePickupPlacesRegionalCacheIfNeeded()
    }

    private func prunePickupPlacesRegionalCacheIfNeeded() {
        guard pickupPlacesRegionalCache.count > pickupPlacesRegionalCacheMaxEntries else { return }
        let sorted = pickupPlacesRegionalCache
            .map { ($0.key, $0.value.fetchedAt) }
            .sorted { $0.1 < $1.1 }
        let dropCount = pickupPlacesRegionalCache.count - pickupPlacesRegionalCacheMaxEntries
        for index in 0..<max(0, dropCount) {
            pickupPlacesRegionalCache.removeValue(forKey: sorted[index].0)
        }
    }

    private func pickupPlacesServerSportTerms(for rawSport: String) -> [String] {
        let trimmed = rawSport.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "All" else { return [] }

        var terms: [String] = []
        func add(_ raw: String) {
            let normalized = pickupPlacesNormalizedSportTerm(raw)
            guard !normalized.isEmpty, !terms.contains(normalized) else { return }
            terms.append(normalized)
        }

        add(trimmed)
        add(AppSportCatalog.displayLabel(forSportToken: trimmed))

        switch pickupPlacesNormalizedSportTerm(trimmed) {
        case "nba", "basketball":
            add("basketball")
            add("nba")
        case "nfl", "football", "american_football":
            add("football")
            add("american_football")
            add("nfl")
        case "nhl", "hockey":
            add("hockey")
            add("nhl")
        case "soccer", "mls":
            add("soccer")
            add("mls")
        case "formula_1", "formula_one", "f1":
            add("formula_1")
            add("formula 1")
            add("f1")
        case "ping_pong", "table_tennis", "pingpong":
            add("ping_pong")
            add("table_tennis")
            add("pingpong")
        default:
            break
        }

        return terms
    }

    private func pickupPlacesNormalizedSportTerm(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "&", with: "and")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    private func pickupPlacesSportTagsOrFilter(terms: [String]) -> String? {
        let filters = pickupPlacesSportTagFilterTerms(from: terms)
            .map { "sport_tags.cs.\(pickupPlacesPostgrestArrayLiteral(for: $0))" }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    private func pickupPlacesSportTagFilterTerms(from terms: [String]) -> [String] {
        var expanded: [String] = []
        func add(_ raw: String) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !expanded.contains(trimmed) else { return }
            expanded.append(trimmed)
        }

        for term in terms {
            add(term)
            let spaced = term.replacingOccurrences(of: "_", with: " ")
            add(spaced)
            add(spaced.capitalized)
            if term.count <= 5 {
                add(term.uppercased())
            }
        }

        return expanded
    }

    private func pickupPlacesSportOrFilter(terms: [String]) -> String? {
        let filters = terms.map { "sport.ilike.\(pickupPlacesPostgrestIlikeToken($0))" }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    private func pickupPlacesPostgrestArrayLiteral(for raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "{\"\(escaped)\"}"
    }

    private func pickupPlacesPostgrestIlikeToken(_ raw: String) -> String {
        let escaped = raw
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: ",", with: "\\,")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: ".", with: "\\.")
        return "*\(escaped)*"
    }

    private func pickupPlacesPerfDurationMs(since startedAt: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startedAt) * 1000))
    }

    func pickupPlacesVisibleAsMapPins(for bounds: (minLat: Double, maxLat: Double, minLon: Double, maxLon: Double)? = nil) -> [PickupPlaceRow] {
        var rows = pickupPlacesForDiscoverMap.filter { place in
            let coordinate = place.coordinate
            guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
            if let bounds {
                guard place.latitude >= bounds.minLat,
                      place.latitude <= bounds.maxLat,
                      place.longitude >= bounds.minLon,
                      place.longitude <= bounds.maxLon else { return false }
            }
            return true
        }

        let selected = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        if selected != "All" {
            rows = rows.filter { pickupPlace($0, matchesSport: selected) }
        }

        let q = effectiveDiscoverSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return rows }
        return rows.filter { pickupPlace($0, matchesSearch: q) }
    }

    private func pickupPlace(_ place: PickupPlaceRow, matchesSport selected: String) -> Bool {
        place.sportTags.contains { tag in
            tag.localizedCaseInsensitiveContains(selected)
                || selected.localizedCaseInsensitiveContains(tag)
                || SportFilterCatalog.storedSport(tag, matchesSearchQuery: selected)
        }
    }

    private func pickupPlace(_ place: PickupPlaceRow, matchesSearch query: String) -> Bool {
        if place.name.localizedCaseInsensitiveContains(query) { return true }
        if place.typeDisplay.localizedCaseInsensitiveContains(query) { return true }
        if place.cityStateDisplay.localizedCaseInsensitiveContains(query) { return true }
        return place.sportTags.contains { tag in
            tag.localizedCaseInsensitiveContains(query)
                || SportFilterCatalog.storedSport(tag, matchesSearchQuery: query)
        }
    }

    func clusteredPickupPlacesForDiscoverMap(rows: [PickupPlaceRow]) -> [PickupPlaceCluster] {
        let source = rows.filter { CLLocationCoordinate2DIsValid($0.coordinate) }
        guard !source.isEmpty else { return [] }
        let grouped = Dictionary(grouping: source) { place in
            DiscoverVenueClusterTuning.clusterKey(
                for: place.coordinate,
                visibleLatitudeDelta: visibleLatitudeDelta
            )
        }
        return grouped.map { key, places in
            let avgLat = places.map(\.latitude).reduce(0, +) / Double(places.count)
            let avgLon = places.map(\.longitude).reduce(0, +) / Double(places.count)
            return PickupPlaceCluster(
                id: "pickup-place-\(key)",
                rows: places,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }
        .sorted { $0.id < $1.id }
    }

    func selectPickupPlaceOnMap(_ place: PickupPlaceRow) {
        selectedBar = nil
        selectedEvent = nil
        selectedPickupGameForMap = nil
        discoverRemotePreviewHoldVenueId = nil
        selectedPickupPlaceForMap = place
#if DEBUG
        print("[PickupPlacesDebug] selectedPlace=\(place.id.uuidString.lowercased()) name=\(place.name)")
#endif
    }

    func centerMap(on place: PickupPlaceRow, selectForPreview: Bool = true) {
        if selectForPreview {
            selectPickupPlaceOnMap(place)
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: place.coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
    }

    func openDirections(to place: PickupPlaceRow) {
        let coordinate = place.coordinate
        if CLLocationCoordinate2DIsValid(coordinate),
           let url = URL(string: "maps://?daddr=\(coordinate.latitude),\(coordinate.longitude)") {
#if DEBUG
            print("[PickupLocationDebug] directionsUsingCoordinates=true latitude=\(coordinate.latitude) longitude=\(coordinate.longitude)")
#endif
            UIApplication.shared.open(url)
            return
        }

        let addressFallback = [place.name, place.city, place.state, place.zip]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !addressFallback.isEmpty else { return }
        var components = URLComponents()
        components.scheme = "maps"
        components.queryItems = [URLQueryItem(name: "daddr", value: addressFallback)]
#if DEBUG
        print("[PickupLocationDebug] directionsUsingCoordinates=false addressFallback=\(addressFallback)")
#endif
        if let url = components.url {
            UIApplication.shared.open(url)
        }
    }

    func pruneSelectedPickupPlaceIfNeeded() {
        guard let selectedPickupPlaceForMap else { return }
        let visible = pickupPlacesVisibleAsMapPins(for: currentMapRegionBounds())
        if !visible.contains(where: { $0.id == selectedPickupPlaceForMap.id }) {
            self.selectedPickupPlaceForMap = nil
        }
    }
}
