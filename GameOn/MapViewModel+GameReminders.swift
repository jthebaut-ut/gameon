import Foundation
import UserNotifications

extension MapViewModel {
    private var gameReminderService: GameReminderNotificationService {
        GameReminderNotificationService.shared
    }

    func refreshGameNotificationAuthorizationState() async {
        await notificationSettingsStore.refreshGameNotificationAuthorizationState()
    }

    func setGameNotificationsEnabled(_ enabled: Bool) async {
        if await notificationSettingsStore.setGameNotificationsEnabled(enabled) {
            await rescheduleAvailableGameReminders(reason: "settingsEnabled")
        }
    }

    func gameReminderPreferenceDidChange() async {
        print("[NotificationSettingsDebug] save reminderPreference notifyBeforeGame=\(notifyBeforeGame) reminderMinutesBefore=\(reminderMinutesBefore) repeatGameReminder=\(repeatGameReminder) repeatEveryMinutes=\(repeatEveryMinutes)")
        print("[NotificationDebug] reminderPreference=\(reminderMinutesBefore)")
        guard notifyBeforeGame else { return }
        await rescheduleAvailableGameReminders(reason: "preferenceChanged")
    }

    func scheduleGameReminderIfPossible(venueEventID: UUID) async {
        guard notifyBeforeGame else { return }
        guard let event = gameReminderNotificationEvent(for: venueEventID) else { return }
        await gameReminderService.scheduleReminder(
            for: event,
            reminderMinutesBefore: reminderMinutesBefore,
            repeatUntilStart: repeatGameReminder,
            repeatEveryMinutes: repeatEveryMinutes
        )
    }

    func cancelGameReminder(venueEventID: UUID) async {
        await gameReminderService.cancelReminder(eventId: venueEventID)
    }

    func rescheduleGameReminderIfPossible(venueEventID: UUID) async {
        print("[NotificationDebug] rescheduleReminder eventId=\(venueEventID.uuidString)")
        guard notifyBeforeGame else {
            await cancelGameReminder(venueEventID: venueEventID)
            return
        }
        await scheduleGameReminderIfPossible(venueEventID: venueEventID)
    }

    func reconcileGameRemindersAfterFollowingRefresh() async {
        guard notifyBeforeGame else { return }
        await rescheduleAvailableGameReminders(reason: "followingRefresh")
    }

    func reconcileGameRemindersForLoadedVenueEvents() async {
        guard notifyBeforeGame else { return }
        let visibleGoingIDs = venueEventRows.compactMap(\.id).filter { venueEventInterestIDs.contains($0) }
        for eventID in visibleGoingIDs {
            await rescheduleGameReminderIfPossible(venueEventID: eventID)
        }
    }

    private func rescheduleAvailableGameReminders(reason: String) async {
        let eventIDs = availableGoingVenueEventIDs()
        for eventID in eventIDs {
            print("[NotificationDebug] rescheduleReminder eventId=\(eventID.uuidString) reason=\(reason)")
            await scheduleGameReminderIfPossible(venueEventID: eventID)
        }
    }

    private func availableGoingVenueEventIDs() -> [UUID] {
        var ids: [UUID] = []
        var seen: Set<UUID> = []

        for item in followingTabGoingItems where item.isServerGoing {
            if seen.insert(item.id).inserted {
                ids.append(item.id)
            }
        }

        for id in venueEventInterestIDs {
            if seen.insert(id).inserted {
                ids.append(id)
            }
        }

        return ids
    }

    private func gameReminderNotificationEvent(for venueEventID: UUID) -> GameReminderNotificationEvent? {
        if let item = followingTabGoingItems.first(where: { $0.id == venueEventID }),
           let startDate = gameReminderStartDate(for: item.venueEvent) {
            return GameReminderNotificationEvent(
                eventId: venueEventID,
                title: item.venueEvent.event_title,
                venueName: item.bar.name,
                startDate: startDate
            )
        }

        guard let row = venueEventRows.first(where: { $0.id == venueEventID }),
              let startDate = gameReminderStartDate(for: row)
        else {
            return nil
        }

        let venueName = row.venue_name ?? bars.first(where: { bar in
            if let venueID = row.venue_id, venueID == bar.id { return true }
            return false
        })?.name

        return GameReminderNotificationEvent(
            eventId: venueEventID,
            title: row.event_title,
            venueName: venueName,
            startDate: startDate
        )
    }

    private func gameReminderStartDate(for row: VenueEventRow) -> Date? {
        if let scheduledStart = parseGameReminderISODate(row.scheduled_start_at) {
            return scheduledStart
        }

        guard let dateString = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dateString.isEmpty
        else {
            return nil
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        guard let day = dateFormatter.date(from: dateString) else { return nil }

        guard let timeString = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines),
              !timeString.isEmpty,
              !timeString.localizedCaseInsensitiveContains("TBD")
        else {
            return day
        }

        let timeFormats = ["h:mm a", "hh:mm a", "H:mm", "HH:mm"]
        for format in timeFormats {
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

    private func parseGameReminderISODate(_ raw: String?) -> Date? {
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
