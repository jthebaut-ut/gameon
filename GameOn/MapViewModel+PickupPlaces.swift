import CoreLocation
import Foundation
import MapKit
import Supabase
import SwiftUI

private let pickupPlacesSelectColumnsWithSportTags =
    "id,name,place_type,sport_tags,city,state,latitude,longitude"

private let pickupPlacesSelectColumnsWithSport =
    "id,name,place_type,sport,city,state,latitude,longitude"

private struct PickupPlaceTaggedDBRow: Decodable {
    let id: UUID
    let name: String?
    let place_type: String?
    let sport_tags: [String]?
    let city: String?
    let state: String?
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
        return [
            String(format: "%.4f", bounds.minLat),
            String(format: "%.4f", bounds.maxLat),
            String(format: "%.4f", bounds.minLon),
            String(format: "%.4f", bounds.maxLon)
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
                latitude: latitude,
                longitude: longitude
            )
        }
    }

    func refreshPickupPlacesForDiscoverMap(force: Bool = false) async {
        guard force || (discoverMapContentMode == .pickupGames && discoverPickupSubMode == .places) else { return }
        guard let bounds = currentMapRegionBounds() else {
            pickupPlacesForDiscoverMap = []
            isLoadingPickupPlacesForMap = false
            return
        }

        let fetchKey = pickupPlacesCurrentFetchKey
        if !force, fetchKey == lastPickupPlacesFetchKey, !pickupPlacesForDiscoverMap.isEmpty {
            return
        }

        isLoadingPickupPlacesForMap = true
#if DEBUG
        print("[PickupPlacesDebug] fetchStarted=true bounds=\(fetchKey)")
#endif
        do {
            let taggedRows: [PickupPlaceTaggedDBRow] = try await supabase
                .from("pickup_places")
                .select(pickupPlacesSelectColumnsWithSportTags)
                .gte("latitude", value: bounds.minLat)
                .lte("latitude", value: bounds.maxLat)
                .gte("longitude", value: bounds.minLon)
                .lte("longitude", value: bounds.maxLon)
                .limit(500)
                .execute()
                .value
            await publishPickupPlaces(mappedPickupPlaceRows(taggedRows), fetchKey: fetchKey)
        } catch {
#if DEBUG
            print("[PickupPlacesDebug] sportTagsFetchFailed=\(error)")
#endif
            do {
                let sportRows: [PickupPlaceSportDBRow] = try await supabase
                    .from("pickup_places")
                    .select(pickupPlacesSelectColumnsWithSport)
                    .gte("latitude", value: bounds.minLat)
                    .lte("latitude", value: bounds.maxLat)
                    .gte("longitude", value: bounds.minLon)
                    .lte("longitude", value: bounds.maxLon)
                    .limit(500)
                    .execute()
                    .value
                await publishPickupPlaces(mappedPickupPlaceRows(sportRows), fetchKey: fetchKey)
            } catch {
                pickupPlacesForDiscoverMap = []
                lastPickupPlacesFetchKey = nil
                isLoadingPickupPlacesForMap = false
#if DEBUG
                print("[PickupPlacesDebug] rowsLoaded=0 error=\(error)")
#endif
            }
        }
    }

    private func publishPickupPlaces(_ rows: [PickupPlaceRow], fetchKey: String) async {
        pickupPlacesForDiscoverMap = rows
        lastPickupPlacesFetchKey = fetchKey
        isLoadingPickupPlacesForMap = false
#if DEBUG
        print("[PickupPlacesDebug] rowsLoaded=\(rows.count)")
#endif
        pruneSelectedPickupPlaceIfNeeded()
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
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let mapItem = MKMapItem(location: location, address: nil)
        mapItem.name = place.name
        mapItem.openInMaps()
    }

    func pruneSelectedPickupPlaceIfNeeded() {
        guard let selectedPickupPlaceForMap else { return }
        let visible = pickupPlacesVisibleAsMapPins(for: currentMapRegionBounds())
        if !visible.contains(where: { $0.id == selectedPickupPlaceForMap.id }) {
            self.selectedPickupPlaceForMap = nil
        }
    }
}
