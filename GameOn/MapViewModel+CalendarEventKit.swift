import Foundation
import EventKit

nonisolated enum FanGeoCalendarEventStore {
    static let eventIdentifierMapKey = "gameon.appleCalendar.eventIdentifiers.v1"
}

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
        let displayTitle = calendarSyncDisplayTitle(
            title: title,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        )

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
            existingEvent.title = displayTitle
            existingEvent.startDate = date
            existingEvent.endDate = date.addingTimeInterval(2 * 60 * 60)
            existingEvent.location = calendarSyncCleanLocation(location)
            existingEvent.notes = calendarSyncNotes(
                title: title,
                date: date,
                location: location,
                fanGeoIdentifier: fanGeoIdentifier
            )
            calendarSyncCleanRestrictedFields(existingEvent)
            calendarSyncApplyAlarmPreference(to: existingEvent, fanGeoIdentifier: fanGeoIdentifier)
            do {
                try eventStore.save(existingEvent, span: .thisEvent)
                calendarSyncStoreEventIdentifier(existingEvent.eventIdentifier, fanGeoIdentifier: fanGeoIdentifier)
                calendarSyncMessage = "Updated in Apple Calendar"
                print("Event updated in Apple Calendar:", displayTitle)
            } catch {
                calendarSyncMessage = "Could not update Apple Calendar"
                print("Error updating event:", error)
            }
            return
        }

        let event = EKEvent(eventStore: eventStore)
        event.title = displayTitle
        event.startDate = date
        event.endDate = date.addingTimeInterval(2 * 60 * 60)
        event.location = calendarSyncCleanLocation(location)
        event.notes = calendarSyncNotes(
            title: title,
            date: date,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        )
        calendarSyncCleanRestrictedFields(event)
        calendarSyncApplyAlarmPreference(to: event, fanGeoIdentifier: fanGeoIdentifier)
        event.calendar = eventStore.defaultCalendarForNewEvents

        do {
            try eventStore.save(event, span: .thisEvent)
            calendarSyncStoreEventIdentifier(event.eventIdentifier, fanGeoIdentifier: fanGeoIdentifier)
            calendarSyncMessage = "Added to Apple Calendar"
            print("Event added to Apple Calendar:", displayTitle)
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
        guard let event = calendarSyncEventForRemoval(fanGeoIdentifier: fanGeoIdentifier) else {
            return
        }

        do {
            try eventStore.remove(event, span: .thisEvent)
            calendarSyncRemoveStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier)
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
        let displayTitle = calendarSyncDisplayTitle(
            title: title,
            location: location,
            fanGeoIdentifier: fanGeoIdentifier
        )
        if let fanGeoIdentifier,
           !fanGeoIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let eventIdentifier = calendarSyncStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier),
               let event = eventStore.event(withIdentifier: eventIdentifier) {
                return event
            }

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

        return eventStore.events(matching: predicate).first {
            calendarSyncEvent($0, matchesTitle: title, displayTitle: displayTitle, location: location)
        }
    }

    private func calendarSyncEvent(_ event: EKEvent, hasFanGeoIdentifier identifier: String) -> Bool {
        event.notes?.contains(calendarSyncIdentifierLine(fanGeoIdentifier: identifier)) == true
    }

    private func calendarSyncEvent(
        _ event: EKEvent,
        matchesTitle title: String,
        displayTitle: String,
        location: String
    ) -> Bool {
        guard event.title == title || event.title == displayTitle else { return false }
        guard let expectedLocation = calendarSyncCleanLocation(location) else { return true }
        let eventLocation = event.location?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return eventLocation.isEmpty || eventLocation == expectedLocation
    }

    private func calendarSyncEventForRemoval(fanGeoIdentifier: String) -> EKEvent? {
        if let eventIdentifier = calendarSyncStoredEventIdentifier(fanGeoIdentifier: fanGeoIdentifier),
           let event = eventStore.event(withIdentifier: eventIdentifier) {
            return event
        }

        let predicate = eventStore.predicateForEvents(
            withStart: Calendar.current.date(byAdding: .year, value: -1, to: Date()) ?? .distantPast,
            end: Calendar.current.date(byAdding: .year, value: 2, to: Date()) ?? .distantFuture,
            calendars: nil
        )
        return eventStore.events(matching: predicate).first(where: {
            calendarSyncEvent($0, hasFanGeoIdentifier: fanGeoIdentifier)
        })
    }

    private func calendarSyncDisplayTitle(
        title: String,
        location: String,
        fanGeoIdentifier: String?
    ) -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseTitle = cleanTitle.isEmpty ? "Game" : cleanTitle
        guard !calendarSyncTitle(baseTitle, hasCaseInsensitivePrefix: "FanGeo:"),
              !calendarSyncTitle(baseTitle, hasCaseInsensitivePrefix: "FanGeo Pickup:")
        else {
            return baseTitle
        }

        switch calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) {
        case .pickup:
            return "FanGeo Pickup: \(baseTitle)"
        case .venue:
            let venueName = calendarSyncCleanLocation(location) ?? ""
            if venueName.isEmpty || venueName.localizedCaseInsensitiveCompare("Venue") == .orderedSame {
                return "FanGeo: \(baseTitle)"
            }
            return "FanGeo: \(baseTitle) @ \(venueName)"
        case .pro, .general:
            return "FanGeo: \(baseTitle)"
        }
    }

    private func calendarSyncNotes(
        title: String,
        date: Date,
        location: String,
        fanGeoIdentifier: String?
    ) -> String {
        var lines = ["Added by FanGeo"]
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanLocation = calendarSyncCleanLocation(location) ?? ""

        switch calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) {
        case .pro:
            if !cleanTitle.isEmpty {
                lines.append("Teams: \(cleanTitle)")
            }
            if !cleanLocation.isEmpty {
                lines.append("Competition: \(cleanLocation)")
            }
        case .venue:
            if !cleanTitle.isEmpty {
                lines.append("Teams: \(cleanTitle)")
            }
            if !cleanLocation.isEmpty {
                lines.append("Venue: \(cleanLocation)")
            }
        case .pickup:
            if !cleanTitle.isEmpty {
                lines.append("Pickup Game: \(cleanTitle)")
            }
            if !cleanLocation.isEmpty {
                lines.append("Location: \(cleanLocation)")
            }
        case .general:
            if !cleanTitle.isEmpty {
                lines.append("Event: \(cleanTitle)")
            }
            if !cleanLocation.isEmpty {
                lines.append("Location: \(cleanLocation)")
            }
        }

        lines.append("Start: \(calendarSyncNotesDateFormatter.string(from: date))")
        return lines.joined(separator: "\n")
    }

    private func calendarSyncIdentifierLine(fanGeoIdentifier: String) -> String {
        "FanGeo ID: \(fanGeoIdentifier)"
    }

    private func calendarSyncCleanRestrictedFields(_ event: EKEvent) {
        event.url = nil
        event.structuredLocation = nil
    }

    private func calendarSyncCleanLocation(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard !trimmed.localizedCaseInsensitiveContains("thesportsdb") else { return nil }
        guard !trimmed.localizedCaseInsensitiveContains("fangeo id") else { return nil }
        guard !calendarSyncLooksLikePhoneOrProviderIdentifier(trimmed) else { return nil }
        return trimmed
    }

    private func calendarSyncLooksLikePhoneOrProviderIdentifier(_ raw: String) -> Bool {
        let digits = raw.filter(\.isNumber)
        guard !digits.isEmpty else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789-+() .")
        let containsOnlyPhoneCharacters = raw.unicodeScalars.allSatisfy { allowed.contains($0) }
        return containsOnlyPhoneCharacters && digits.count >= 4 && digits.count <= 15
    }

    private func calendarSyncStoredEventIdentifier(fanGeoIdentifier: String) -> String? {
        calendarSyncStoredEventIdentifiers()[fanGeoIdentifier]
    }

    private func calendarSyncStoreEventIdentifier(_ eventIdentifier: String?, fanGeoIdentifier: String?) {
        guard let eventIdentifier,
              let fanGeoIdentifier = fanGeoIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !fanGeoIdentifier.isEmpty else { return }
        var identifiers = calendarSyncStoredEventIdentifiers()
        identifiers[fanGeoIdentifier] = eventIdentifier
        UserDefaults.standard.set(identifiers, forKey: FanGeoCalendarEventStore.eventIdentifierMapKey)
    }

    private func calendarSyncRemoveStoredEventIdentifier(fanGeoIdentifier: String) {
        var identifiers = calendarSyncStoredEventIdentifiers()
        identifiers.removeValue(forKey: fanGeoIdentifier)
        UserDefaults.standard.set(identifiers, forKey: FanGeoCalendarEventStore.eventIdentifierMapKey)
    }

    private func calendarSyncStoredEventIdentifiers() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: FanGeoCalendarEventStore.eventIdentifierMapKey) as? [String: String] ?? [:]
    }

    private func calendarSyncApplyAlarmPreference(to event: EKEvent, fanGeoIdentifier: String?) {
        guard let timing = calendarSyncAlertTiming(fanGeoIdentifier: fanGeoIdentifier) else { return }
        for alarm in event.alarms ?? [] {
            event.removeAlarm(alarm)
        }
        guard let offset = timing.relativeOffset else { return }
        event.addAlarm(EKAlarm(relativeOffset: offset))
    }

    private func calendarSyncAlertTiming(fanGeoIdentifier: String?) -> FanGeoCalendarAlertTiming? {
        switch calendarSyncEventKind(fanGeoIdentifier: fanGeoIdentifier) {
        case .venue:
            return notificationSettingsStore.venueCalendarAlertTiming
        case .pickup:
            return notificationSettingsStore.pickupCalendarAlertTiming
        case .pro:
            return notificationSettingsStore.proCalendarAlertTiming
        case .general:
            return nil
        }
    }

    private enum CalendarSyncEventKind {
        case venue
        case pickup
        case pro
        case general
    }

    private func calendarSyncEventKind(fanGeoIdentifier: String?) -> CalendarSyncEventKind {
        let normalized = fanGeoIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalized.hasPrefix("venue|") { return .venue }
        if normalized.hasPrefix("pickup|") { return .pickup }
        if normalized.hasPrefix("pro|") { return .pro }
        return .general
    }

    private func calendarSyncTitle(_ title: String, hasCaseInsensitivePrefix prefix: String) -> Bool {
        title.range(
            of: prefix,
            options: [.caseInsensitive, .anchored],
            range: title.startIndex..<title.endIndex,
            locale: .current
        ) != nil
    }

    private var calendarSyncNotesDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.timeZone = .current
        return formatter
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
