import CoreLocation
import Foundation

/// CPU-only assembly for Discover venue pins (keeps heavy grouping off the ``MapViewModel`` actor when used from a detached task).
enum DiscoverVenueLoadAssembler {

    /// Trimmed title used for venue-event id keys and Going lookups (must match ``MapViewModel`` normalization).
    nonisolated static func normalizedVenueGameTitle(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    /// Registers primary + legacy lookup keys for a venue event row (trimmed and raw titles).
    nonisolated static func registerVenueEventIDKeys(
        into idsByKey: inout [String: UUID],
        row: VenueEventRow
    ) {
        guard let id = row.id, let title = row.event_title else { return }
        let trimmed = normalizedVenueGameTitle(title)
        guard !trimmed.isEmpty else { return }
        if let venueId = row.venue_id {
            idsByKey["\(venueId.uuidString)-\(trimmed)"] = id
            if trimmed != title {
                idsByKey["\(venueId.uuidString)-\(title)"] = id
            }
        }
        if let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines), !venueName.isEmpty {
            idsByKey["\(venueName)-\(trimmed)"] = id
            if trimmed != title {
                idsByKey["\(venueName)-\(title)"] = id
            }
        }
    }

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
        return VenueGameExpiration.isActiveOnDiscoverSurfaces(row: ev)
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

    /// Strict, normalized public listing email (same rules as ``VenueGameBusinessEmail``).
    nonisolated private static func strictPublicOwnerEmail(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let norm = OwnerBusinessEmail.normalized(trimmed)
        guard OwnerBusinessEmail.isValidStrict(norm) else { return nil }
        return norm
    }

    /// `businesses.admin_status`: only `active` (or legacy empty) is treated as safe for public contact email.
    nonisolated private static func isPublicContactBusinessEmbedActive(_ embed: VenueRowBusinessEmbed?) -> Bool {
        guard let embed else { return false }
        let st = embed.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return st.isEmpty || st == "active"
    }

    /// Prefer strict `venues.owner_email`; when missing/invalid, fall back to embedded `businesses.owner_email` for linked active businesses.
    nonisolated private static func mergedPublicOwnerEmail(for row: VenueRow) -> String? {
        if let v = strictPublicOwnerEmail(row.owner_email) { return v }
        guard row.business_id != nil else { return nil }
        guard isPublicContactBusinessEmbedActive(row.businesses) else { return nil }
        return strictPublicOwnerEmail(row.businesses?.owner_email)
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
            registerVenueEventIDKeys(into: &idsByKey, row: row)
        }

        let mappedBars: [BarVenue] = venueRows.compactMap { row -> BarVenue? in
            guard let name = row.venue_name else { return nil }

            // Public Discover pins must use real `venues.latitude` / `venues.longitude` (bounds queries + guest map).
            // Calendar / event lists still hydrate from `venue_events` using supplemented venue ids when coords are missing.
            guard let latitude = row.latitude, let longitude = row.longitude else {
#if DEBUG
                print("[DiscoverVisibilityDebug] venue=\(name) skipped map pin (missing latitude/longitude in DB)")
                if let id = row.id {
                    print("[ApprovedVenueVisibilityDebug] missingCoordinates id=\(id.uuidString)")
                }
#endif
                return nil
            }

            var titleSet = Set<String>()
            if let venueUuid = row.id {
                for ev in eventsByVenueId[venueUuid] ?? [] {
                    if let t = ev.event_title { titleSet.insert(t) }
                }
            }
            if let k = mergedPublicOwnerEmail(for: row) {
                for ev in eventsByOwner[k] ?? [] where ev.venue_id == nil {
                    if let t = ev.event_title { titleSet.insert(t) }
                }
            }
            for ev in eventsByVenueName[name] ?? [] where ev.venue_id == nil {
                if let t = ev.event_title { titleSet.insert(t) }
            }
            let gamesForThisVenue = Array(titleSet).sorted()

            let ownerForBar: String? = mergedPublicOwnerEmail(for: row)
            var supportedSports = Set<String>()
            if let venueUuid = row.id {
                supportedSports.formUnion(sportsByVenueId[venueUuid] ?? [])
            }
            if let ownerForBar {
                supportedSports.formUnion(sportsByOwner[ownerForBar] ?? [])
            }
            supportedSports.formUnion(sportsByVenueName[name] ?? [])
            supportedSports.formUnion(row.sport_tags?.compactMap { normalizedSport($0) } ?? [])

            return BarVenue(
                id: row.id ?? UUID(),
                name: name,
                address: Self.displayAddress(for: row),
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
                screenCount: row.screen_count,
                servesFood: row.serves_food,
                hasWifi: row.has_wifi,
                hasGarden: row.has_garden,
                hasProjector: row.has_projector,
                petFriendly: row.pet_friendly,
                rawVenueFeatures: row.features,
                coverPhotoURL: row.cover_photo_url,
                menuPhotoURL: row.menu_photo_url,
                coverPhotoThumbnailURL: row.cover_photo_thumbnail_url,
                menuPhotoThumbnailURL: row.menu_photo_thumbnail_url,
                ownerEmail: ownerForBar,
                businessId: row.business_id,
                adminStatus: row.admin_status,
                communityType: row.community_type,
                placeType: row.place_type,
                sportTags: row.sport_tags ?? [],
                venueOwnerEmailRaw: row.owner_email,
                businessOwnerEmailRaw: row.businesses?.owner_email,
                contactEmailRaw: nil,
                supporterCountry: row.supporter_country,
                originType: row.origin_type
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

    nonisolated private static func displayAddress(for row: VenueRow) -> String {
        let formatted = row.formatted_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !formatted.isEmpty { return formatted }

        return BusinessVenueAddressFormatter.formattedAddress(
            line1: row.address_line1 ?? row.address ?? "",
            line2: row.address_line2 ?? "",
            locality: row.city ?? "",
            region: row.region ?? row.state ?? "",
            postalCode: row.postal_code ?? row.zip_code ?? "",
            countryCode: row.country ?? ""
        )
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
                id: row.id ?? UUID(),
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
