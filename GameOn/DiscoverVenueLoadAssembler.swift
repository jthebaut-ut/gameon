import CoreLocation
import Foundation

/// CPU-only assembly for Discover venue pins (keeps heavy grouping off the ``MapViewModel`` actor when used from a detached task).
enum DiscoverVenueLoadAssembler {

    static func buildMappedBars(
        venueRows: [VenueRow],
        fetchedVenueEventRows: [VenueEventRow]
    ) -> ([BarVenue], [String: UUID]) {
        var eventsByVenueId: [UUID: [VenueEventRow]] = [:]
        var eventsByOwner: [String: [VenueEventRow]] = [:]
        var eventsByVenueName: [String: [VenueEventRow]] = [:]
        for ev in fetchedVenueEventRows {
            if let vid = ev.venue_id {
                eventsByVenueId[vid, default: []].append(ev)
            }
            if let e = ev.owner_email {
                let k = OwnerBusinessEmail.normalized(e)
                if OwnerBusinessEmail.isValidStrict(k) {
                    eventsByOwner[k, default: []].append(ev)
                }
            }
            if let v = ev.venue_name {
                eventsByVenueName[v, default: []].append(ev)
            }
        }

        var idsByKey: [String: UUID] = [:]
        for row in fetchedVenueEventRows {
            guard let id = row.id, let title = row.event_title else { continue }
            if let venueId = row.venue_id {
                idsByKey["\(venueId.uuidString)-\(title)"] = id
            }
            if let venueName = row.venue_name {
                idsByKey["\(venueName)-\(title)"] = id
            }
        }

        let mappedBars: [BarVenue] = venueRows.compactMap { row -> BarVenue? in
            guard
                let name = row.venue_name,
                let latitude = row.latitude,
                let longitude = row.longitude
            else {
                return nil
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
                primarySport: "Soccer",
                distance: "",
                rating: 4.5,
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
                businessId: row.business_id
            )
        }

        return (mappedBars, idsByKey)
    }

    static func sportsEventsFromOfficialRows(_ officialRows: [GameRow], formatter: DateFormatter) -> [SportsEvent] {
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

    static func sportsEventsFromVenueEventRows(_ rows: [VenueEventRow], formatter: DateFormatter) -> [SportsEvent] {
        rows.compactMap { row in
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
