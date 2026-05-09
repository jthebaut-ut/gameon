import CoreLocation
import Foundation
import MapKit
import SwiftUI

extension MapViewModel {

    func experience(for bar: BarVenue) -> VenueExperience? {
        venueExperiences.first { $0.venueName == bar.name }
    }

    func clusteredBars() -> [VenueCluster] {
        let source = filteredBars
        guard !source.isEmpty else { return [] }

        var gridSize = 0.035
        if visibleLatitudeDelta > 0.35 {
            gridSize = 0.08
        }

        let grouped = Dictionary(grouping: source) { bar in
            let latKey = Int(bar.coordinate.latitude / gridSize)
            let lonKey = Int(bar.coordinate.longitude / gridSize)
            return "\(latKey)-\(lonKey)"
        }

        return grouped.map { key, bars in
            let avgLat = bars.map { $0.coordinate.latitude }.reduce(0, +) / Double(bars.count)
            let avgLon = bars.map { $0.coordinate.longitude }.reduce(0, +) / Double(bars.count)
            return VenueCluster(
                id: "c-\(key)",
                bars: bars,
                coordinate: CLLocationCoordinate2D(latitude: avgLat, longitude: avgLon)
            )
        }
    }

    func centerMap(on bar: BarVenue, selectForPreview: Bool = true) {
        if selectForPreview {
            selectedBar = bar
        }
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: bar.coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
    }

    func searchMapLocation() {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else {
            venueSearchResults = []
            return
        }
        let lower = q.lowercased()
        let matches = bars.filter {
            $0.name.lowercased().contains(lower)
                || $0.address.lowercased().contains(lower)
                || $0.primarySport.lowercased().contains(lower)
        }
        if !matches.isEmpty {
            venueSearchResults = matches
            return
        }
        Task {
            if let coord = await geocodeAddress(q) {
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
