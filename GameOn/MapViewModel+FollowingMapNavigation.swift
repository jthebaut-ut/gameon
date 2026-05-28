import CoreLocation
import Foundation
import MapKit
import SwiftUI

// MARK: - Following → Discover (saved venue on map)

@MainActor
extension MapViewModel {

    /// Saved venue row in Following: switch to Discover and focus this venue when consumed.
    func requestDiscoverFocusForSavedVenue(_ bar: BarVenue) {
        pendingFollowingMapVenueID = bar.id
        pendingFollowingMapVenueSnapshot = bar
    }

    /// Pickup row in Following: switch to Discover and focus this pickup game when consumed.
    func requestDiscoverFocusForPickupGame(id: UUID, snapshot: PickupGameRow?) {
        pendingFollowingMapPickupGameID = id
        pendingFollowingMapPickupGameSnapshot = snapshot
    }

    /// Hosted pickup row in Following: switch to Discover and focus this pickup game when consumed.
    func requestDiscoverFocusForHostedPickupGame(_ row: PickupGameRow) {
        requestDiscoverFocusForPickupGame(id: row.id, snapshot: row)
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
            selectVenueForPreview(refreshed, source: "followingMapNavigation")
        } else {
            selectVenueForPreview(bar, source: "followingMapNavigation")
        }

#if DEBUG
        print("[FollowingNav] selection preserved id=\(keepId) barsCount=\(bars.count)")
#endif
    }

    /// Resolve a hosted pickup game from Following and focus it in Discover pickup-games mode.
    func consumeFollowingPickupGameNavigationIfPending() async {
        guard let id = pendingFollowingMapPickupGameID else { return }
        defer {
            pendingFollowingMapPickupGameID = nil
            pendingFollowingMapPickupGameSnapshot = nil
        }

        followingMapNavigationMessage = nil

        guard let row = resolvedPickupGameRow(for: id) ?? pendingFollowingMapPickupGameSnapshot else {
            followingMapNavigationMessage = "This game does not have a map location yet."
            scheduleFollowingMapNavigationMessageClear()
            return
        }

        guard let coordinate = await followingPickupCoordinate(for: row) else {
#if DEBUG
            print("[FollowingPickupMapNav] no usable coordinates gameId=\(id.uuidString.lowercased())")
#endif
            followingMapNavigationMessage = "This game does not have a map location yet."
            scheduleFollowingMapNavigationMessageClear()
            return
        }
        let focusedRow = Self.pickupRow(row, withCoordinate: coordinate)

        if discoverMapContentMode != .pickupGames {
            clearDiscoverMapContentSelectionsWhenSwitching(to: .pickupGames)
            discoverMapContentMode = .pickupGames
        }
        if discoverPickupSubMode != .games {
            discoverPickupSubMode = .games
        }

        selectedSport = focusedRow.sport
        if let start = PickupGameModels.parseSupabaseTimestamptz(focusedRow.game_start_at) {
            let requestID = beginDiscoverDateChange(to: start)
            scheduleDiscoverSelectedDayRefresh(requestID: requestID)
        }

        selectedBar = nil
        selectedEvent = nil
        selectedPickupPlaceForMap = nil
        centerDiscoverMapOnPickupCoordinate(coordinate)
        mergePickupInsertedLocally(focusedRow)
        selectPickupGameOnMap(focusedRow)

#if DEBUG
        print("[FollowingPickupMapNav] centered gameId=\(id.uuidString.lowercased()) latitude=\(coordinate.latitude) longitude=\(coordinate.longitude)")
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

    private func followingPickupCoordinate(for row: PickupGameRow) async -> CLLocationCoordinate2D? {
        if let latitude = row.latitude, let longitude = row.longitude {
            let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
            if Self.followingMapCoordinateLooksUsable(coordinate) {
                return coordinate
            }
        }

        if let coordinate = pickupPlaceCoordinateMatching(row: row) {
            return coordinate
        }
        if let coordinate = venueCoordinateMatching(row: row) {
            return coordinate
        }

        let addressLine = [row.address, row.city, row.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
        guard !addressLine.isEmpty,
              let geocoded = await geocodeAddress(addressLine),
              Self.followingMapCoordinateLooksUsable(geocoded) else {
            return nil
        }
        return geocoded
    }

    private func pickupPlaceCoordinateMatching(row: PickupGameRow) -> CLLocationCoordinate2D? {
        let rowCity = Self.normalizedFollowingLocationComponent(row.city)
        let rowState = Self.normalizedFollowingLocationComponent(row.state)
        guard !rowCity.isEmpty, !rowState.isEmpty else { return nil }
        let sport = Self.normalizedFollowingLocationComponent(row.sport)
        let matches = pickupPlacesForDiscoverMap.filter { place in
            Self.normalizedFollowingLocationComponent(place.city) == rowCity
                && Self.normalizedFollowingLocationComponent(place.state) == rowState
                && (sport.isEmpty || place.sportTags.contains { Self.normalizedFollowingLocationComponent($0) == sport })
        }
        return matches.count == 1 ? matches[0].coordinate : nil
    }

    private func venueCoordinateMatching(row: PickupGameRow) -> CLLocationCoordinate2D? {
        let rowAddress = Self.normalizedFollowingLocationComponent(row.address)
        guard !rowAddress.isEmpty else { return nil }
        return bars.first { venue in
            Self.normalizedFollowingLocationComponent(venue.address) == rowAddress
        }?.coordinate
    }

    private static func normalizedFollowingLocationComponent(_ raw: String?) -> String {
        raw?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .lowercased() ?? ""
    }

    private func centerDiscoverMapOnPickupCoordinate(_ coordinate: CLLocationCoordinate2D) {
        let spanVal = min(max(visibleLatitudeDelta * 0.35, 0.04), 0.35)
        cameraPosition = .region(
            MKCoordinateRegion(
                center: coordinate,
                span: MKCoordinateSpan(latitudeDelta: spanVal, longitudeDelta: spanVal)
            )
        )
        visibleLatitudeDelta = spanVal
        invalidatePickupGameClusterAnnotationCache()
    }

    private static func pickupRow(_ row: PickupGameRow, withCoordinate coordinate: CLLocationCoordinate2D) -> PickupGameRow {
        PickupGameRow(
            id: row.id,
            creator_user_id: row.creator_user_id,
            creator_email: row.creator_email,
            title: row.title,
            sport: row.sport,
            description: row.description,
            game_format: row.game_format,
            skill_level: row.skill_level,
            game_start_at: row.game_start_at,
            end_time: row.end_time,
            address: row.address,
            city: row.city,
            state: row.state,
            latitude: coordinate.latitude,
            longitude: coordinate.longitude,
            is_visible: row.is_visible,
            players_needed: row.players_needed,
            play_environment: row.play_environment,
            participant_preference: row.participant_preference,
            age_min: row.age_min,
            age_max: row.age_max,
            is_free: row.is_free,
            entry_fee_amount: row.entry_fee_amount,
            max_players: row.max_players,
            status: row.status,
            approved_join_count: row.approved_join_count,
            cleanup_delay_hours: row.cleanup_delay_hours,
            remove_after_at: row.remove_after_at,
            created_at: row.created_at,
            updated_at: row.updated_at
        )
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
            rawVenueFeatures: bar.rawVenueFeatures,
            coverPhotoURL: bar.coverPhotoURL,
            menuPhotoURL: bar.menuPhotoURL,
            coverPhotoThumbnailURL: bar.coverPhotoThumbnailURL,
            menuPhotoThumbnailURL: bar.menuPhotoThumbnailURL,
            ownerEmail: bar.ownerEmail,
            businessId: bar.businessId,
            adminStatus: bar.adminStatus,
            communityType: bar.communityType,
            placeType: bar.placeType,
            sportTags: bar.sportTags,
            venueOwnerEmailRaw: bar.venueOwnerEmailRaw,
            businessOwnerEmailRaw: bar.businessOwnerEmailRaw,
            contactEmailRaw: bar.contactEmailRaw,
            supporterCountry: bar.supporterCountry,
            originType: bar.originType
        )
    }
}
