import Foundation
import UserNotifications

struct GameReminderNotificationEvent {
    let eventId: UUID
    let title: String?
    let venueName: String?
    let startDate: Date
}

final class GameReminderNotificationService {
    static let shared = GameReminderNotificationService()

    private let center: UNUserNotificationCenter
    private let identifierPrefix = "fangeo.gameReminder."

    private init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        let status = await center.notificationSettings().authorizationStatus
        print("[NotificationDebug] authorizationStatus=\(Self.authorizationStatusDescription(status))")
        return status
    }

    func requestAuthorizationIfNeeded() async -> Bool {
        let status = await authorizationStatus()
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied:
            print("[NotificationDebug] permissionDenied=true")
            return false
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                let updatedStatus = await authorizationStatus()
                let allowed = granted && Self.isAllowedStatus(updatedStatus)
                if !allowed {
                    print("[NotificationDebug] permissionDenied=true")
                }
                return allowed
            } catch {
                print("[NotificationDebug] permissionDenied=\(error.localizedDescription)")
                return false
            }
        @unknown default:
            print("[NotificationDebug] permissionDenied=unknownStatus")
            return false
        }
    }

    func canScheduleNotifications() async -> Bool {
        Self.isAllowedStatus(await authorizationStatus())
    }

    func scheduleReminder(
        for event: GameReminderNotificationEvent,
        reminderMinutesBefore: Int,
        repeatUntilStart: Bool = false,
        repeatEveryMinutes: Int = 30
    ) async {
        print("[NotificationDebug] reminderPreference=\(reminderMinutesBefore)")
        print("[NotificationDebug] schedulingReminder eventId=\(event.eventId.uuidString)")

        guard await requestAuthorizationIfNeeded() else {
            print("[NotificationDebug] permissionDenied=true")
            return
        }

        let fireDate = event.startDate.addingTimeInterval(TimeInterval(-reminderMinutesBefore * 60))

        await cancelReminder(eventId: event.eventId)

        let fireDates = reminderFireDates(
            firstFireDate: fireDate,
            eventStartDate: event.startDate,
            repeatUntilStart: repeatUntilStart,
            repeatEveryMinutes: repeatEveryMinutes
        )

        guard !fireDates.isEmpty else { return }

        for (index, scheduledDate) in fireDates.enumerated() {
            let minutesUntilStart = max(1, Int(event.startDate.timeIntervalSince(scheduledDate) / 60))
            let content = UNMutableNotificationContent()
            content.title = "Game starting soon"
            content.body = Self.body(for: event, reminderMinutesBefore: minutesUntilStart)
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: scheduledDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let request = UNNotificationRequest(
                identifier: reminderIdentifier(for: event.eventId, repeatIndex: index),
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
            } catch {
                print("[NotificationDebug] schedulingFailed eventId=\(event.eventId.uuidString) error=\(error.localizedDescription)")
            }
        }
    }

    func cancelReminder(eventId: UUID) async {
        print("[NotificationDebug] cancelReminder eventId=\(eventId.uuidString)")
        let baseIdentifier = reminderIdentifier(for: eventId)
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0 == baseIdentifier || $0.hasPrefix("\(baseIdentifier).") }
        center.removePendingNotificationRequests(withIdentifiers: identifiers.isEmpty ? [baseIdentifier] : identifiers)
    }

    func cancelAllGameReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    private func reminderIdentifier(for eventId: UUID) -> String {
        "\(identifierPrefix)\(eventId.uuidString.lowercased())"
    }

    private func reminderIdentifier(for eventId: UUID, repeatIndex: Int) -> String {
        let base = reminderIdentifier(for: eventId)
        return repeatIndex == 0 ? base : "\(base).repeat\(repeatIndex)"
    }

    private func reminderFireDates(
        firstFireDate: Date,
        eventStartDate: Date,
        repeatUntilStart: Bool,
        repeatEveryMinutes: Int
    ) -> [Date] {
        let now = Date()
        guard firstFireDate < eventStartDate else { return [] }
        guard repeatUntilStart else {
            guard firstFireDate > now else { return [] }
            print("[NotificationDebug] scheduledFireDate=\(Self.debugDateString(firstFireDate))")
            return [firstFireDate]
        }

        let step = max(1, repeatEveryMinutes)
        var dates: [Date] = []
        var next = firstFireDate
        while next < eventStartDate {
            if next > now {
                print("[NotificationDebug] scheduledFireDate=\(Self.debugDateString(next))")
                dates.append(next)
            }
            guard let advanced = Calendar.current.date(byAdding: .minute, value: step, to: next) else {
                break
            }
            next = advanced
        }
        return dates
    }

    private static func isAllowedStatus(_ status: UNAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    private static func authorizationStatusDescription(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .denied: return "denied"
        case .authorized: return "authorized"
        case .provisional: return "provisional"
        case .ephemeral: return "ephemeral"
        @unknown default: return "unknown"
        }
    }

    private static func body(
        for event: GameReminderNotificationEvent,
        reminderMinutesBefore: Int
    ) -> String {
        let lead = leadDescription(minutes: reminderMinutesBefore)
        if let title = cleaned(event.title) {
            return "\(title) starts in \(lead)."
        }
        if let venueName = cleaned(event.venueName) {
            return "Your game at \(venueName) starts in \(lead)."
        }
        return "Your game starts in \(lead)."
    }

    private static func leadDescription(minutes: Int) -> String {
        if minutes == 1440 { return "1 day" }
        if minutes % 1440 == 0 { return "\(minutes / 1440) days" }
        if minutes == 60 { return "1 hour" }
        if minutes % 60 == 0 { return "\(minutes / 60) hours" }
        if minutes == 1 { return "1 minute" }
        return "\(minutes) minutes"
    }

    private static func cleaned(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func debugDateString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        formatter.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return formatter.string(from: date)
    }
}
