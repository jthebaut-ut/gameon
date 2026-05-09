import CoreLocation
import Foundation
import Supabase

extension MapViewModel {

    func loadVenuesFromSupabase() async {
        do {
            guard let bounds = currentMapRegionBounds() else {
                print("NO MAP REGION BOUNDS")
                return
            }

            let venueRowsAll: [VenueRow] = try await supabase
                .from("venues")
                .select()
                .gte("latitude", value: bounds.minLat)
                .lte("latitude", value: bounds.maxLat)
                .gte("longitude", value: bounds.minLon)
                .lte("longitude", value: bounds.maxLon)
                .limit(200)
                .execute()
                .value

            // Client-side visibility gate (defense-in-depth) until RLS is confirmed in the backend:
            // hide venues whose latest claim for `owner_email` is not approved.
            // TODO: enforce this server-side with RLS / a `venues_public` view once migrations are restored.
            let ownerEmails = Array(Set(venueRowsAll.compactMap { $0.owner_email }.filter { !$0.isEmpty }))
            var approvedOwners: Set<String> = []
            if !ownerEmails.isEmpty {
                do {
                    // Fetch recent claims for owners in view; compute latest per owner by created_at.
                    let claimRows: [VenueClaimRow] = try await supabase
                        .from("venue_claims")
                        .select()
                        .in("owner_email", values: ownerEmails)
                        .order("created_at", ascending: false)
                        .limit(500)
                        .execute()
                        .value

                    let iso = ISO8601DateFormatter()
                    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    let iso2 = ISO8601DateFormatter()
                    iso2.formatOptions = [.withInternetDateTime]
                    func parseClaimDate(_ raw: String?) -> Date? {
                        guard let raw, !raw.isEmpty else { return nil }
                        if let d = iso.date(from: raw) { return d }
                        return iso2.date(from: raw)
                    }

                    var latestByOwner: [String: (date: Date, status: String?)] = [:]
                    for row in claimRows {
                        guard let owner = row.owner_email, !owner.isEmpty else { continue }
                        guard let date = parseClaimDate(row.created_at) else { continue }
                        if let existing = latestByOwner[owner], existing.date >= date {
                            continue
                        }
                        latestByOwner[owner] = (date: date, status: row.approval_status)
                    }

                    approvedOwners = Set(
                        latestByOwner.compactMap { owner, payload in
                            let status = (payload.status ?? "").lowercased()
                            return status == "approved" ? owner : nil
                        }
                    )
                } catch {
                    // If claims lookup fails, fall back to showing all venues (do not break map).
                    approvedOwners = Set(ownerEmails)
                }
            }

            let venueRows: [VenueRow]
            if approvedOwners.isEmpty {
                venueRows = venueRowsAll
            } else {
                venueRows = venueRowsAll.filter { row in
                    guard let owner = row.owner_email, !owner.isEmpty else { return true }
                    return approvedOwners.contains(owner)
                }
            }

            let venueEventRows: [VenueEventRow] = try await supabase
                .from("venue_events")
                .select()
                .execute()
                .value

            let mappedBars: [BarVenue] = venueRows.compactMap { row -> BarVenue? in
                guard
                    let name = row.venue_name,
                    let latitude = row.latitude,
                    let longitude = row.longitude
                else {
                    return nil
                }

                let gamesForThisVenue = venueEventRows
                    .filter { eventRow in
                        if let eventOwnerEmail = eventRow.owner_email,
                           let venueOwnerEmail = row.owner_email {
                            return eventOwnerEmail == venueOwnerEmail
                        }

                        if let eventVenueName = eventRow.venue_name {
                            return eventVenueName == name
                        }

                        return false
                    }
                    .compactMap { $0.event_title }

                print("PHOTO URLS FOR:", name)
                print("COVER:", row.cover_photo_url ?? "nil")
                print("MENU:", row.menu_photo_url ?? "nil")

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
                    menuPhotoURL: row.menu_photo_url
                )
            }

            if SampleData.includeSampleData {
                bars = mappedBars + SampleData.bars
            } else {
                bars = mappedBars
            }

            print("Loaded venues from Supabase:", mappedBars.count)

        } catch {
            print("ERROR LOADING VENUES FROM SUPABASE:", error)
        }
    }

    func loadGamesFromSupabase() {
     
        
        Task {
            await MainActor.run {
                isLoadingEvents = true
            }

            do {
                let officialRows: [GameRow] = try await supabase
                    .from("games")
                    .select()
                    .gte("game_date", value: tenDaysAgoString())
                    .order("game_date", ascending: true)
                    .execute()
                    .value

                let venueRows: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .select()
                    .gte("event_date", value: tenDaysAgoString())
                    .order("event_date", ascending: true)
                    .execute()
                    .value

                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd"

                let officialEvents: [SportsEvent] = officialRows.compactMap { row in
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

                let venueEventsAsSportsEvents: [SportsEvent] = venueRows.compactMap { row in
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

                var finalEvents = officialEvents + venueEventsAsSportsEvents

                if SampleData.includeSampleData {
                    finalEvents.append(contentsOf: SampleData.events)
                }

                await MainActor.run {
                    events = finalEvents
                    venueEventRows = venueRows

                    var idsByKey: [String: UUID] = [:]

                    for row in venueRows {
                        if let id = row.id,
                           let venueName = row.venue_name,
                           let title = row.event_title {
                            idsByKey["\(venueName)-\(title)"] = id
                        }
                    }

                    venueEventIDsByKey = idsByKey
                    isLoadingEvents = false
                }
                await loadVisibleVenueEventInterests()
                print("Loaded official games:", officialEvents.count)
                print("Loaded venue games:", venueEventsAsSportsEvents.count)

            } catch {
                print("ERROR LOADING GAMES FROM SUPABASE:", error)

                await MainActor.run {
                    isLoadingEvents = false
                }
            }
        }
    }

    func tenDaysAgoString() -> String {
        let tenDaysAgo = Calendar.current.date(byAdding: .day, value: -10, to: Date()) ?? Date()

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"

        return formatter.string(from: tenDaysAgo)
    }
}
