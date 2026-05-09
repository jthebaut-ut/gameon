import CoreLocation
import Foundation

/// CPU-only assembly for Discover venue pins (keeps heavy grouping off the ``MapViewModel`` actor when used from a detached task).
enum DiscoverVenueLoadAssembler {

    static func buildMappedBars(
        venueRows: [VenueRow],
        fetchedVenueEventRows: [VenueEventRow]
    ) -> ([BarVenue], [String: UUID]) {
        var eventsByOwner: [String: [VenueEventRow]] = [:]
        var eventsByVenueName: [String: [VenueEventRow]] = [:]
        for ev in fetchedVenueEventRows {
            if let e = ev.owner_email {
                eventsByOwner[e, default: []].append(ev)
            }
            if let v = ev.venue_name {
                eventsByVenueName[v, default: []].append(ev)
            }
        }

        var idsByKey: [String: UUID] = [:]
        for row in fetchedVenueEventRows {
            guard let id = row.id, let title = row.event_title, let venueName = row.venue_name else { continue }
            idsByKey["\(venueName)-\(title)"] = id
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
            if let email = row.owner_email {
                for ev in eventsByOwner[email] ?? [] {
                    if let t = ev.event_title { titleSet.insert(t) }
                }
            }
            for ev in eventsByVenueName[name] ?? [] {
                if let t = ev.event_title { titleSet.insert(t) }
            }
            let gamesForThisVenue = Array(titleSet).sorted()

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
                ownerEmail: row.owner_email
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
