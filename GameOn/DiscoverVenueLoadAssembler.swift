import CoreLocation
import Foundation

/// CPU-only assembly for Discover venue pins (keeps heavy grouping off the ``MapViewModel`` actor when used from a detached task).
enum DiscoverVenueLoadAssembler {

    nonisolated private static func normalizedSport(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Client-side guard: Discover only shows active venue listings (matches Supabase `admin_status = active` queries).
    nonisolated private static func isDiscoverVisibleVenueEvent(_ ev: VenueEventRow) -> Bool {
        let st = ev.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let st, !st.isEmpty, st != "active" { return false }
        return true
    }

    nonisolated private static func resolvedPrimarySport(from sports: Set<String>) -> String {
        let sorted = sports.sorted()
        switch sorted.count {
        case 0:
            return ""
        case 1:
            return sorted[0]
        default:
            return "Multi-sport"
        }
    }

    nonisolated static func buildMappedBars(
        venueRows: [VenueRow],
        fetchedVenueEventRows: [VenueEventRow]
    ) -> ([BarVenue], [String: UUID]) {
        var eventsByVenueId: [UUID: [VenueEventRow]] = [:]
        var eventsByOwner: [String: [VenueEventRow]] = [:]
        var eventsByVenueName: [String: [VenueEventRow]] = [:]
        var sportsByVenueId: [UUID: Set<String>] = [:]
        var sportsByOwner: [String: Set<String>] = [:]
        var sportsByVenueName: [String: Set<String>] = [:]
        for ev in fetchedVenueEventRows where isDiscoverVisibleVenueEvent(ev) {
            if let vid = ev.venue_id {
                eventsByVenueId[vid, default: []].append(ev)
                if let sport = normalizedSport(ev.sport) {
                    sportsByVenueId[vid, default: []].insert(sport)
                }
            }
            if let e = ev.owner_email {
                let k = OwnerBusinessEmail.normalized(e)
                if OwnerBusinessEmail.isValidStrict(k) {
                    eventsByOwner[k, default: []].append(ev)
                    if let sport = normalizedSport(ev.sport) {
                        sportsByOwner[k, default: []].insert(sport)
                    }
                }
            }
            if let v = ev.venue_name {
                eventsByVenueName[v, default: []].append(ev)
                if let sport = normalizedSport(ev.sport) {
                    sportsByVenueName[v, default: []].insert(sport)
                }
            }
        }

        var idsByKey: [String: UUID] = [:]
        for row in fetchedVenueEventRows where isDiscoverVisibleVenueEvent(row) {
            guard let id = row.id, let title = row.event_title else { continue }
            if let venueId = row.venue_id {
                idsByKey["\(venueId.uuidString)-\(title)"] = id
            }
            if let venueName = row.venue_name {
                idsByKey["\(venueName)-\(title)"] = id
            }
        }

        let mappedBars: [BarVenue] = venueRows.compactMap { row -> BarVenue? in
            guard let name = row.venue_name else { return nil }

            // Discover map queries require lat/lon in SQL, but business venues can exist before geocode completes.
            // Use a provisional Utah-area center so games/calendar/search assembly still work; replace once DB coords exist.
            let latitude: Double
            let longitude: Double
            if let la = row.latitude, let lo = row.longitude {
                latitude = la
                longitude = lo
            } else {
                latitude = 40.3916
                longitude = -111.8508
#if DEBUG
                print("[DiscoverVisibilityDebug] venue=\(name) using provisional coordinate (missing latitude/longitude in DB)")
#endif
            }

            var titleSet = Set<String>()
            if let venueUuid = row.id {
                for ev in eventsByVenueId[venueUuid] ?? [] {
                    if let t = ev.event_title { titleSet.insert(t) }
                }
            }
            if let email = row.owner_email {
                let k = OwnerBusinessEmail.normalized(email)
                if OwnerBusinessEmail.isValidStrict(k) {
                    for ev in eventsByOwner[k] ?? [] where ev.venue_id == nil {
                        if let t = ev.event_title { titleSet.insert(t) }
                    }
                }
            }
            for ev in eventsByVenueName[name] ?? [] where ev.venue_id == nil {
                if let t = ev.event_title { titleSet.insert(t) }
            }
            let gamesForThisVenue = Array(titleSet).sorted()

            let rawOwner = row.owner_email ?? ""
            let normOwner = OwnerBusinessEmail.normalized(rawOwner)
            let ownerForBar: String? = OwnerBusinessEmail.isValidStrict(normOwner) ? normOwner : nil
            var supportedSports = Set<String>()
            if let venueUuid = row.id {
                supportedSports.formUnion(sportsByVenueId[venueUuid] ?? [])
            }
            if let ownerForBar {
                supportedSports.formUnion(sportsByOwner[ownerForBar] ?? [])
            }
            supportedSports.formUnion(sportsByVenueName[name] ?? [])

            return BarVenue(
                id: row.id ?? UUID(),
                name: name,
                address: [
                    row.address,
                    row.city,
                    row.state,
                    row.zip_code
                ]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: ", "),
                phone: row.phone ?? "",
                primarySport: resolvedPrimarySport(from: supportedSports),
                distance: "",
                rating: 0,
                tags: [],
                games: gamesForThisVenue,
                coordinate: CLLocationCoordinate2D(
                    latitude: latitude,
                    longitude: longitude
                ),
                goingCounts: [:],
                screenCount: row.screen_count ?? 1,
                servesFood: row.serves_food ?? false,
                hasWifi: row.has_wifi ?? false,
                hasGarden: row.has_garden ?? false,
                hasProjector: row.has_projector ?? false,
                petFriendly: row.pet_friendly ?? false,
                coverPhotoURL: row.cover_photo_url,
                menuPhotoURL: row.menu_photo_url,
                coverPhotoThumbnailURL: row.cover_photo_thumbnail_url,
                menuPhotoThumbnailURL: row.menu_photo_thumbnail_url,
                ownerEmail: ownerForBar,
                businessId: row.business_id,
                adminStatus: row.admin_status
            )
        }

        return (mappedBars, idsByKey)
    }

    nonisolated static func sportsEventsFromOfficialRows(_ officialRows: [GameRow], formatter: DateFormatter) -> [SportsEvent] {
        officialRows.compactMap { row in
            guard
                let title = row.title,
                let sport = row.sport,
                let league = row.league,
                let gameDate = row.game_date,
                let date = formatter.date(from: gameDate)
            else {
                return nil
            }
            return SportsEvent(
                id: UUID(),
                title: title,
                sport: sport,
                league: league,
                date: date,
                time: row.game_time ?? "Time TBD",
                country: "USA"
            )
        }
    }

    nonisolated static func sportsEventsFromVenueEventRows(_ rows: [VenueEventRow], formatter: DateFormatter) -> [SportsEvent] {
        rows.filter { isDiscoverVisibleVenueEvent($0) }.compactMap { row in
            guard
                let title = row.event_title,
                let sport = row.sport,
                let gameDate = row.event_date,
                let date = formatter.date(from: gameDate)
            else {
                return nil
            }
            return SportsEvent(
                id: UUID(),
                title: title,
                sport: sport,
                league: "Venue Event",
                date: date,
                time: row.event_time ?? "Time TBD",
                country: "USA"
            )
        }
    }
}
