import Foundation
import Supabase

extension MapViewModel {

    var canMarkInterest: Bool {
        !currentUserEmail.isEmpty || !venueOwnerEmail.isEmpty
    }

    func markInterestedInVenueEvent(venueEventID: UUID, refreshFollowing: Bool = true) async {
        let session = try? await supabase.auth.session
        let interestEmail = session?.user.email ?? ""

        guard !interestEmail.isEmpty else {
            print("USER MUST BE LOGGED IN TO MARK INTEREST")
            return
        }

        do {
            let interest = VenueEventInterestInsert(
                venue_event_id: venueEventID,
                user_email: interestEmail
            )

            try await supabase
                .from("venue_event_interests")
                .upsert(
                    interest,
                    onConflict: "user_email,venue_event_id"
                )
                .execute()

            await MainActor.run {
                venueEventInterestIDs.insert(venueEventID)
                venueEventInterestCounts[venueEventID, default: 0] += 1
            }

            if refreshFollowing {
                await refreshFollowingTabDataGlobally()
            }

            print("INTEREST SAVED")

        } catch {
            print("ERROR SAVING INTEREST:", error)
        }
    }

    func removeInterestInVenueEvent(venueEventID: UUID, refreshFollowing: Bool = true) async {
        let interestEmail = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail
        guard !interestEmail.isEmpty else { return }

        do {
            try await supabase
                .from("venue_event_interests")
                .delete()
                .eq("venue_event_id", value: venueEventID)
                .eq("user_email", value: interestEmail)
                .execute()

            await MainActor.run {
                venueEventInterestIDs.remove(venueEventID)
                venueEventInterestCounts[venueEventID] = max((venueEventInterestCounts[venueEventID] ?? 1) - 1, 0)
            }

            if refreshFollowing {
                await refreshFollowingTabDataGlobally()
            }

            print("INTEREST REMOVED")

        } catch {
            print("ERROR REMOVING INTEREST:", error)
        }
    }

    func goingProfiles(for venueEventID: UUID) -> [UserProfileRow] {
        goingProfilesByVenueEventID[venueEventID] ?? []
    }

    func venueEventLookupKey(for bar: BarVenue, gameTitle: String) -> String {
        "\(bar.name)-\(gameTitle)"
    }

    func cachedVenueEventID(for bar: BarVenue, gameTitle: String) -> UUID? {
        venueEventIDsByKey[venueEventLookupKey(for: bar, gameTitle: gameTitle)]
    }

    func interestedPlans() -> [(bar: BarVenue, gameTitle: String, date: String, time: String, count: Int)] {
        var plans: [(bar: BarVenue, gameTitle: String, date: String, time: String, count: Int)] = []

        for row in venueEventRows {
            guard
                let id = row.id,
                venueEventInterestIDs.contains(id),
                let title = row.event_title
            else {
                continue
            }

            guard let bar = bars.first(where: { bar in
                if let venueName = row.venue_name,
                   bar.name == venueName {
                    return true
                }

                if let title = row.event_title,
                   bar.games.contains(title) {
                    return true
                }

                return false
            }) else {
                continue
            }

            plans.append((
                bar: bar,
                gameTitle: title,
                date: row.event_date ?? "Date TBD",
                time: row.event_time ?? "Time TBD",
                count: venueEventInterestCounts[id] ?? 0
            ))
        }

        return plans
    }

    func loadGoingUserProfiles(for venueEventID: UUID) async {
        do {
            let interestRows: [VenueEventInterestRow] = try await supabase
                .from("venue_event_interests")
                .select()
                .eq("venue_event_id", value: venueEventID)
                .execute()
                .value

            let emails = interestRows.compactMap { $0.user_email }

            guard !emails.isEmpty else {
                await MainActor.run {
                    goingUserProfiles = []
                    goingProfilesByVenueEventID[venueEventID] = []
                }
                return
            }

            let profileRows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select()
                .in("email", values: emails)
                .execute()
                .value

            await MainActor.run {
                goingUserProfiles = profileRows
                goingProfilesByVenueEventID[venueEventID] = profileRows
            }

        } catch {
            if error is CancellationError {
#if DEBUG
                print("[LoadCancelled] going profiles")
#endif
            } else {
                print("ERROR LOADING GOING USER PROFILES:", error)
            }
        }
    }

    func removeInterested(in bar: BarVenue, gameTitle: String) {
        let key = venueEventInterestKey(for: bar, gameTitle: gameTitle)
        interestedVenueEventKeys.remove(key)
    }

    func interestKey(for bar: BarVenue) -> String? {
        guard let selectedEvent else { return nil }
        return "\(bar.id.uuidString)-\(selectedEvent.title)"
    }

    func isInterested(in bar: BarVenue) -> Bool {
        guard let key = interestKey(for: bar) else { return false }
        return interestedVenueEventKeys.contains(key)
    }

    func toggleInterest(in bar: BarVenue) {
        guard let key = interestKey(for: bar) else { return }

        if interestedVenueEventKeys.contains(key) {
            interestedVenueEventKeys.remove(key)
        } else {
            interestedVenueEventKeys.insert(key)
        }
    }

    func venueEventInterestKey(for bar: BarVenue, gameTitle: String) -> String {
        "\(bar.id.uuidString)-\(gameTitle)"
    }

    func isInterested(in bar: BarVenue, gameTitle: String) -> Bool {
        let key = venueEventInterestKey(for: bar, gameTitle: gameTitle)
        return interestedVenueEventKeys.contains(key)
    }

    func markInterested(in bar: BarVenue, gameTitle: String) {
        let key = venueEventInterestKey(for: bar, gameTitle: gameTitle)
        interestedVenueEventKeys.insert(key)
    }

    func displayedGoingCount(for bar: BarVenue, gameTitle: String) -> Int {
        let baseCount = bar.goingCounts[gameTitle] ?? 0
        return isInterested(in: bar, gameTitle: gameTitle) ? baseCount + 1 : baseCount
    }

    func venueEventInterestKey(for bar: BarVenue) -> String? {
        guard let selectedEvent else { return nil }
        return "\(bar.id.uuidString)-\(selectedEvent.title)"
    }

    func isInterestedInSelectedEvent(at bar: BarVenue) -> Bool {
        guard let key = venueEventInterestKey(for: bar) else { return false }
        return interestedVenueEventKeys.contains(key)
    }

    func toggleInterestForSelectedEvent(at bar: BarVenue) {
        guard let key = venueEventInterestKey(for: bar) else { return }

        if interestedVenueEventKeys.contains(key) {
            interestedVenueEventKeys.remove(key)
        } else {
            interestedVenueEventKeys.insert(key)
        }
    }

    func displayedGoingCount(for bar: BarVenue) -> Int {
        let baseCount = goingCount(for: bar)
        return isInterestedInSelectedEvent(at: bar) ? baseCount + 1 : baseCount
    }

    func isInterestedInVenueEvent(_ venueEventID: UUID) -> Bool {
        venueEventInterestIDs.contains(venueEventID)
    }

    func interestCountForVenueEvent(_ venueEventID: UUID) -> Int {
        venueEventInterestCounts[venueEventID] ?? 0
    }

    func venueEventID(for bar: BarVenue, gameTitle: String) async -> UUID? {
        let key = venueEventLookupKey(for: bar, gameTitle: gameTitle)
        if let cached = venueEventIDsByKey[key] {
            return cached
        }

        if let row = venueEventRows.first(where: { row in
            guard row.event_title == gameTitle else { return false }
            if row.venue_name == bar.name { return true }
            if let o = row.owner_email, let bo = bar.ownerEmail, o == bo { return true }
            return false
        }), let id = row.id {
            venueEventIDsByKey[key] = id
            return id
        }

        do {
            var q = supabase
                .from("venue_events")
                .select("id,owner_email,venue_name,event_title")
                .eq("event_title", value: gameTitle)

            if let owner = bar.ownerEmail?.trimmingCharacters(in: .whitespacesAndNewlines), !owner.isEmpty {
                q = q.eq("owner_email", value: owner)
            } else {
                q = q.eq("venue_name", value: bar.name)
            }

            let rows: [VenueEventRow] = try await q
                .limit(1)
                .execute()
                .value

            #if DEBUG
            print("[DiscoverPerf] venueEventID network lookup title=\(gameTitle) rows=\(rows.count)")
            #endif

            if let id = rows.first?.id {
                venueEventIDsByKey[key] = id
                return id
            }

            return nil

        } catch {
            #if DEBUG
            print("ERROR FINDING VENUE EVENT ID:", error)
            #endif
            return nil
        }
    }

    func loadVisibleVenueEventInterests() async {
        let visibleEventIDs = venueEventRows.compactMap { $0.id }

        guard !visibleEventIDs.isEmpty else {
            return
        }

        let t0 = Date()
        let interestEmail = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail
        let selectCols = "venue_event_id,user_email"
        let chunkSize = 90

        do {
            var counts: [UUID: Int] = [:]
            var myInterests: Set<UUID> = []
            var totalRows = 0

            var index = 0
            while index < visibleEventIDs.count {
                let end = min(index + chunkSize, visibleEventIDs.count)
                let chunk = Array(visibleEventIDs[index..<end])
                index = end

                let rows: [VenueEventInterestRow] = try await supabase
                    .from("venue_event_interests")
                    .select(selectCols)
                    .in("venue_event_id", values: chunk)
                    .execute()
                    .value

                totalRows += rows.count
                for row in rows {
                    guard let eventID = row.venue_event_id else { continue }
                    counts[eventID, default: 0] += 1
                    if row.user_email == interestEmail {
                        myInterests.insert(eventID)
                    }
                }
            }

            await MainActor.run {
                venueEventInterestCounts = counts
                venueEventInterestIDs = myInterests
            }

            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[DiscoverPerf] visible interests loaded events=\(visibleEventIDs.count) rows=\(totalRows) ms=\(ms)")
            #endif

        } catch {
            #if DEBUG
            print("ERROR LOADING VISIBLE VENUE EVENT INTERESTS:", error)
            #endif
        }
    }
}
