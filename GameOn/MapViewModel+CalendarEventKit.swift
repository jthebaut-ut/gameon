import Foundation
import EventKit

extension MapViewModel {

    func requestCalendarAccess() async -> Bool {
        do {
            return try await eventStore.requestFullAccessToEvents()
        } catch {
            print("Calendar permission error:", error)
            return false
        }
    }

    func addGameToCalendar(
        title: String,
        date: Date,
        location: String,
        fanGeoIdentifier: String? = nil
    ) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else { return }

        let granted = await requestCalendarAccess()
        guard granted else {
            calendarSyncMessage = "Apple Calendar access is off. Turn it on in Settings ▸ Privacy & Security ▸ Calendars for FanGeo whenever you want events added there."
            return
        }

        if let existingEvent = calendarSyncExistingEvent(
            title: title,
            date: date,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        ) {
            existingEvent.title = title
            existingEvent.startDate = date
            existingEvent.endDate = date.addingTimeInterval(2 * 60 * 60)
            existingEvent.location = location
            existingEvent.notes = calendarSyncNotes(fanGeoIdentifier: fanGeoIdentifier)
            do {
                try eventStore.save(existingEvent, span: .thisEvent)
                calendarSyncMessage = "Updated in Apple Calendar"
                print("Event updated in Apple Calendar:", title)
            } catch {
                calendarSyncMessage = "Could not update Apple Calendar"
                print("Error updating event:", error)
            }
            return
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = title
        event.startDate = date
        event.endDate = date.addingTimeInterval(2 * 60 * 60)
        event.location = location
        event.notes = calendarSyncNotes(fanGeoIdentifier: fanGeoIdentifier)
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
            calendarSyncMessage = "Added to Apple Calendar"
            print("Event added to Apple Calendar:", title)
        } catch {
            calendarSyncMessage = "Could not add to Apple Calendar"
            print("Error saving event:", error)
        }
    }

    func removeGameFromAppleCalendar(fanGeoIdentifier: String) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else { return }
        guard !fanGeoIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let granted = await requestCalendarAccess()
        guard granted else { return }
        let predicate = eventStore.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast,
            end: Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? .distantFuture,
            calendars: nil
        )
        guard let event = eventStore.events(matching: predicate).first(where: {
            calendarSyncEvent($0, hasFanGeoIdentifier: fanGeoIdentifier)
        }) else {
            return
        }

        do {
            try eventStore.remove(event, span: .thisEvent)
            calendarSyncMessage = "Removed from Apple Calendar"
            print("Event removed from Apple Calendar:", fanGeoIdentifier)
        } catch {
            calendarSyncMessage = "Could not remove Apple Calendar event"
            print("Error removing event:", error)
        }
    }

    func syncVenueGameToAppleCalendarIfNeeded(venueEventID: UUID) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else { return }
        let identifier = "venue|\(venueEventID.uuidString.lowercased())"

        if let item = followingTabGoingItems.first(where: { $0.id == venueEventID }),
           let start = calendarSyncVenueStartDate(for: item.venueEvent) {
            let title = item.venueEvent.event_title?.trimmingCharacters(in: .whitespacesAndNewlines)
            await addGameToCalendar(
                title: title?.isEmpty == false ? title! : "Venue Game",
                date: start,
                location: item.bar.name,
                fanGeoIdentifier: identifier
            )
            return
        }

        guard let row = venueEventRows.first(where: { $0.id == venueEventID }),
              let start = calendarSyncVenueStartDate(for: row) else {
            return
        }

        let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let location = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines)
        await addGameToCalendar(
            title: title?.isEmpty == false ? title! : "Venue Game",
            date: start,
            location: location?.isEmpty == false ? location! : "Venue",
            fanGeoIdentifier: identifier
        )
    }

    func syncPickupGamesToAppleCalendarIfNeeded(reason: String) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else { return }
#if DEBUG
        print("[CalendarSyncDebug] pickupSyncStarted reason=\(reason)")
#endif
        var seen = Set<String>()
        for game in myPickupGamesForSettings {
            await syncPickupGameToAppleCalendarIfNeeded(game, seen: &seen, source: "hosted")
        }
        for card in myPickupGameJoinRequestCards where card.pill == .approved {
            if let row = resolvedPickupGameRow(for: card.pickupGameId) {
                await syncPickupGameToAppleCalendarIfNeeded(row, seen: &seen, source: "joined")
            } else if let start = PickupGameModels.parseSupabaseTimestamptz(card.game_start_at) {
                let key = "pickup|\(card.pickupGameId.uuidString.lowercased())"
                guard seen.insert(key).inserted else { continue }
                await addGameToCalendar(
                    title: card.title,
                    date: start,
                    location: card.locationLine,
                    fanGeoIdentifier: key
                )
            }
        }
#if DEBUG
        print("[CalendarSyncDebug] pickupSyncFinished reason=\(reason) count=\(seen.count)")
#endif
    }

    func syncFanGeoAttendingEventsToAppleCalendar(reason: String) async {
        guard notificationSettingsStore.syncGoingGamesToAppleCalendar else { return }
#if DEBUG
        print("[CalendarSyncDebug] globalSyncStarted reason=\(reason)")
#endif
        var seen = Set<String>()

        for item in followingTabGoingItems where item.isServerGoing {
            guard let start = calendarSyncVenueStartDate(for: item.venueEvent) else { continue }
            let title = item.venueEvent.event_title?.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = "venue|\(item.id.uuidString.lowercased())"
            guard seen.insert(key).inserted else { continue }
            await addGameToCalendar(
                title: title?.isEmpty == false ? title! : "Venue Game",
                date: start,
                location: item.bar.name,
                fanGeoIdentifier: key
            )
        }

        await syncPickupGamesToAppleCalendarIfNeeded(reason: reason)

        for game in savedProGames {
            let key = "pro|\(game.stableKey)"
            guard seen.insert(key).inserted else { continue }
            await addGameToCalendar(
                title: "\(game.awayTeam) vs \(game.homeTeam)",
                date: game.startTime,
                location: game.league,
                fanGeoIdentifier: key
            )
        }
#if DEBUG
        print("[CalendarSyncDebug] globalSyncFinished reason=\(reason) count=\(seen.count)")
#endif
    }

    private func syncPickupGameToAppleCalendarIfNeeded(
        _ game: PickupGameRow,
        seen: inout Set<String>,
        source: String
    ) async {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game.game_start_at) else { return }
        let key = "pickup|\(game.id.uuidString.lowercased())"
        guard seen.insert(key).inserted else { return }
        await addGameToCalendar(
            title: game.title,
            date: start,
            location: pickupGameCalendarAddressLine(game),
            fanGeoIdentifier: key
        )
#if DEBUG
        print("[CalendarSyncDebug] pickupSynced source=\(source) id=\(game.id.uuidString.lowercased())")
#endif
    }

    private func calendarSyncExistingEvent(
        title: String,
        date: Date,
        location: String,
        fanGeoIdentifier: String?
    ) -> EKEvent? {
        if let fanGeoIdentifier,
           !fanGeoIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let predicate = eventStore.predicateForEvents(
                withStart: Calendar.current.date(byAdding: .year, value: -1, to: date) ?? date,
                end: Calendar.current.date(byAdding: .year, value: 2, to: date) ?? date,
                calendars: nil
            )
            if let event = eventStore.events(matching: predicate).first(where: {
                calendarSyncEvent($0, hasFanGeoIdentifier: fanGeoIdentifier)
            }) {
                return event
            }
        }

        let startWindow = Calendar.current.startOfDay(for: date)
        let endWindow = Calendar.current.date(byAdding: .day, value: 1, to: startWindow) ?? date
        let predicate = eventStore.predicateForEvents(
            withStart: startWindow,
            end: endWindow,
            calendars: nil
        )

        return eventStore.events(matching: predicate).first { event in
            event.title == title &&
                event.location == location
        }
    }

    private func calendarSyncEvent(_ event: EKEvent, hasFanGeoIdentifier identifier: String) -> Bool {
        event.notes?.contains(calendarSyncIdentifierLine(fanGeoIdentifier: identifier)) == true
    }

    private func calendarSyncNotes(fanGeoIdentifier: String?) -> String {
        guard let fanGeoIdentifier,
              !fanGeoIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Added by FanGeo"
        }
        return "Added by FanGeo\n\(calendarSyncIdentifierLine(fanGeoIdentifier: fanGeoIdentifier))"
    }

    private func calendarSyncIdentifierLine(fanGeoIdentifier: String) -> String {
        "FanGeo ID: \(fanGeoIdentifier)"
    }

    private func calendarSyncVenueStartDate(for row: VenueEventRow) -> Date? {
        if let scheduledStart = calendarSyncParseISODate(row.scheduled_start_at) {
            return scheduledStart
        }

        guard let dateString = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dateString.isEmpty else {
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        guard let day = dateFormatter.date(from: dateString) else { return nil }

        guard let timeString = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines),
              !timeString.isEmpty,
              !timeString.localizedCaseInsensitiveContains("TBD") else {
            return day
        }

        for format in ["h:mm a", "hh:mm a", "H:mm", "HH:mm"] {
            let timeFormatter = DateFormatter()
            timeFormatter.locale = Locale(identifier: "en_US_POSIX")
            timeFormatter.dateFormat = format
            timeFormatter.timeZone = TimeZone.current
            if let time = timeFormatter.date(from: timeString.uppercased()) {
                var dayComponents = Calendar.current.dateComponents([.year, .month, .day], from: day)
                let timeComponents = Calendar.current.dateComponents([.hour, .minute, .second], from: time)
                dayComponents.hour = timeComponents.hour
                dayComponents.minute = timeComponents.minute
                dayComponents.second = timeComponents.second ?? 0
                return Calendar.current.date(from: dayComponents)
            }
        }

        return day
    }

    private func calendarSyncParseISODate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
