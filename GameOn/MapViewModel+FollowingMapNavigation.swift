import CoreLocation
import Foundation
import MapKit

// MARK: - Following → Discover (saved venue on map)

@MainActor
extension MapViewModel {

    /// Saved venue row in Following: switch to Discover and focus this venue when consumed.
    func requestDiscoverFocusForSavedVenue(_ bar: BarVenue) {
        pendingFollowingMapVenueID = bar.id
        pendingFollowingMapVenueSnapshot = bar
    }

    /// Resolve ``pendingFollowingMapVenueID`` using snapshot, ``bars``, Supabase by id, coordinates, or geocoded address — never requires the venue to already be in the current map region.
    func consumeFollowingVenueNavigationIfPending() async {
        guard let id = pendingFollowingMapVenueID else { return }
        defer {
            pendingFollowingMapVenueID = nil
            pendingFollowingMapVenueSnapshot = nil
        }

        followingMapNavigationMessage = nil

        var resolved: BarVenue?
        if let match = bars.first(where: { $0.id == id }) {
            resolved = match
        } else if let snap = pendingFollowingMapVenueSnapshot, snap.id == id {
            resolved = snap
        } else {
            resolved = await fetchBarVenueByIdFromSupabase(id: id)
        }

        guard var bar = resolved else {
#if DEBUG
            print("[FollowingNav] tapped saved venue id=\(id) — no row from bars, snapshot, or Supabase")
#endif
            followingMapNavigationMessage = "Couldn’t find this venue on the map."
            scheduleFollowingMapNavigationMessageClear()
            return
        }

#if DEBUG
        print("[FollowingNav] tapped saved venue name=\(bar.name) address=\(bar.address) id=\(bar.id)")
#endif

        if Self.followingMapCoordinateLooksUsable(bar.coordinate) {
#if DEBUG
            print("[FollowingNav] using saved coordinates lat=\(bar.coordinate.latitude) lon=\(bar.coordinate.longitude)")
#endif
            centerMap(on: bar, selectForPreview: true)
        } else {
            let addr = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
            if let coord = await geocodeAddress(addr), Self.followingMapCoordinateLooksUsable(coord) {
#if DEBUG
                print("[FollowingNav] geocoded coordinates lat=\(coord.latitude) lon=\(coord.longitude)")
#endif
                bar = Self.copyBarVenue(bar, coordinate: coord)
                centerMap(on: coord, selectedBar: bar)
            } else if let fetched = await fetchBarVenueByIdFromSupabase(id: id),
                      Self.followingMapCoordinateLooksUsable(fetched.coordinate) {
#if DEBUG
                print("[FollowingNav] fetched coordinates from Supabase lat=\(fetched.coordinate.latitude) lon=\(fetched.coordinate.longitude)")
#endif
                bar = fetched
                centerMap(on: fetched, selectForPreview: true)
            } else {
#if DEBUG
                print("[FollowingNav] no usable coordinates after saved coords, geocode, and fetch")
#endif
                followingMapNavigationMessage = "Couldn’t find this venue on the map."
                scheduleFollowingMapNavigationMessageClear()
                return
            }
        }

#if DEBUG
        print("[FollowingNav] centered map on saved venue")
#endif

        await loadVenuesFromSupabase()

#if DEBUG
        print("[FollowingNav] reloaded venues for new map region")
#endif

        let keepId = bar.id
        if !bars.contains(where: { $0.id == keepId }) {
            bars.append(bar)
        }
        if let refreshed = bars.first(where: { $0.id == keepId }) {
            selectedBar = refreshed
        } else {
            selectedBar = bar
        }

#if DEBUG
        print("[FollowingNav] selection preserved id=\(keepId) barsCount=\(bars.count)")
#endif
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

    private static func copyBarVenue(_ bar: BarVenue, coordinate: CLLocationCoordinate2D) -> BarVenue {
        BarVenue(
            id: bar.id,
            name: bar.name,
            address: bar.address,
            phone: bar.phone,
            primarySport: bar.primarySport,
            distance: bar.distance,
            rating: bar.rating,
            tags: bar.tags,
            games: bar.games,
            coordinate: coordinate,
            goingCounts: bar.goingCounts,
            screenCount: bar.screenCount,
            servesFood: bar.servesFood,
            hasWifi: bar.hasWifi,
            hasGarden: bar.hasGarden,
            hasProjector: bar.hasProjector,
            petFriendly: bar.petFriendly,
            coverPhotoURL: bar.coverPhotoURL,
            menuPhotoURL: bar.menuPhotoURL,
            coverPhotoThumbnailURL: bar.coverPhotoThumbnailURL,
            menuPhotoThumbnailURL: bar.menuPhotoThumbnailURL,
            ownerEmail: bar.ownerEmail,
            businessId: bar.businessId
        )
    }
}
