import CoreLocation
import Foundation
import MapKit

// MARK: - Following → Discover (saved venue on map)

@MainActor
extension MapViewModel {

    /// Saved venue row in Following: switch to Discover and focus this venue when consumed.
    func requestDiscoverFocusForSavedVenue(_ bar: BarVenue) {
        pendingFollowingMapVenueID = bar.id
    }

    /// Resolve ``pendingFollowingMapVenueID`` using venue coordinates or a one-shot geocode of ``BarVenue/address``.
    func consumeFollowingVenueNavigationIfPending() async {
        guard let id = pendingFollowingMapVenueID else { return }
        defer { pendingFollowingMapVenueID = nil }

        followingMapNavigationMessage = nil

        guard let bar = bars.first(where: { $0.id == id }) else {
            followingMapNavigationMessage = "Couldn’t find this venue on the map."
            scheduleFollowingMapNavigationMessageClear()
            return
        }

        if Self.followingMapCoordinateLooksUsable(bar.coordinate) {
            centerMap(on: bar, selectForPreview: true)
            return
        }

        let addr = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !addr.isEmpty else {
            followingMapNavigationMessage = "Couldn’t find this venue on the map."
            scheduleFollowingMapNavigationMessageClear()
            return
        }

        if let coord = await geocodeAddress(addr), Self.followingMapCoordinateLooksUsable(coord) {
            centerMap(on: coord, selectedBar: bar)
        } else {
            followingMapNavigationMessage = "Couldn’t find this venue on the map."
            scheduleFollowingMapNavigationMessageClear()
        }
    }

    private func scheduleFollowingMapNavigationMessageClear() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            followingMapNavigationMessage = nil
        }
    }

    /// True when ``coordinate`` is present enough to skip address geocoding.
    private static func followingMapCoordinateLooksUsable(_ c: CLLocationCoordinate2D) -> Bool {
        guard CLLocationCoordinate2DIsValid(c) else { return false }
        if abs(c.latitude) < 1e-5 && abs(c.longitude) < 1e-5 { return false }
        return abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }
}
