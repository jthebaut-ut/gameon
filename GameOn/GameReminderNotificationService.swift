import Foundation
import UserNotifications

struct GameReminderNotificationEvent {
    let eventId: UUID
    let title: String?
    let venueName: String?
    let startDate: Date
}

struct ProGameReminderNotificationEvent {
    let identifier: String
    let awayTeam: String
    let homeTeam: String
    let sport: String
    let startDate: Date
}

struct ProGameFinalNotificationEvent {
    let identifier: String
    let body: String
    let awayTeam: String
    let homeTeam: String
}

struct ProGameHalftimeNotificationEvent {
    let identifier: String
    let body: String
    let awayTeam: String
    let homeTeam: String
}

struct ProGamePredictionResultNotificationEvent {
    let identifier: String
    let body: String
    let awayTeam: String
    let homeTeam: String
}

struct ProGameScoreUpdateNotificationEvent {
    let identifier: String
    let scoreToken: String
    let title: String
    let body: String
    let awayTeam: String
    let homeTeam: String
}

struct ProGameCardNotificationEvent {
    let identifier: String
    let eventKey: String
    let title: String
    let body: String
    let awayTeam: String
    let homeTeam: String
    let cardType: LiveCardEventType
}

final class GameReminderNotificationService {
    static let shared = GameReminderNotificationService()

    private let center: UNUserNotificationCenter
    private let identifierPrefix = "fangeo.gameReminder."
    private let proGameIdentifierPrefix = "fangeo.proGameReminder."
    private let proGameFinalIdentifierPrefix = "fangeo.proGameFinal."
    private let proGameHalftimeIdentifierPrefix = "fangeo.proGameHalftime."
    private let proGamePredictionResultIdentifierPrefix = "fangeo.proGamePredictionResult."
    private let proGameScoreUpdateIdentifierPrefix = "fangeo.proGameScoreUpdate."
    private let proGameCardNotificationIdentifierPrefix = "fangeo.proGameCard."

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
            await PushNotificationRegistrationService.shared.registerForRemoteNotificationsIfAuthorized(reason: "alreadyAuthorized")
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
                } else {
                    await PushNotificationRegistrationService.shared.registerForRemoteNotificationsIfAuthorized(reason: "permissionGranted")
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

    func scheduleProGameReminder(
        for event: ProGameReminderNotificationEvent,
        userPreference: String,
        reminderMinutesBefore: Int,
        repeatUntilStart: Bool = false,
        repeatEveryMinutes: Int = 30
    ) async {
        let matchupTitle = ProGameNotificationFormatting.matchupTitle(
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "kickoff",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        print("[ProGameReminderDebug] userPreference=\(userPreference)")
        print("[ProGameReminderDebug] gameId=\(event.identifier)")
        print("[ProGameReminderDebug] gameStart=\(Self.debugDateString(event.startDate))")
        print("[ProGameReminderDebug] title=\"\(matchupTitle)\"")

        let permissionBefore = await authorizationStatus()
        print("[ProGameReminderDebug] permissionStatus=\(Self.authorizationStatusDescription(permissionBefore))")
        guard await requestAuthorizationIfNeeded() else {
            let permissionAfter = await authorizationStatus()
            print("[ProGameReminderDebug] notificationCreated=false")
            print("[ProGameReminderDebug] schedulingSuccess=false")
            print("[ProGameReminderDebug] schedulingFailure=permissionDenied")
            print("[ProGameReminderDebug] permissionStatus=\(Self.authorizationStatusDescription(permissionAfter))")
            return
        }

        let fireDate = event.startDate.addingTimeInterval(TimeInterval(-reminderMinutesBefore * 60))

        await cancelProGameReminder(identifier: event.identifier)

        let fireDates = proGameReminderFireDates(
            preferredFireDate: fireDate,
            eventStartDate: event.startDate,
            repeatUntilStart: repeatUntilStart,
            repeatEveryMinutes: repeatEveryMinutes
        )

        guard !fireDates.isEmpty else {
            print("[ProGameReminderDebug] scheduledTime=none")
            print("[ProGameReminderDebug] notificationCreated=false")
            print("[ProGameReminderDebug] schedulingSuccess=false")
            print("[ProGameReminderDebug] schedulingFailure=noFutureFireDate")
            return
        }

        for (index, scheduledDate) in fireDates.enumerated() {
            let minutesUntilStart = max(1, Int(event.startDate.timeIntervalSince(scheduledDate) / 60))
            let content = UNMutableNotificationContent()
            content.title = ProGameNotificationFormatting.kickoffHeaderTitle(sport: event.sport)
            content.subtitle = matchupTitle
            content.body = scheduledDate >= event.startDate
                ? ProGameNotificationFormatting.kickoffStartingBody
                : "\(ProGameNotificationFormatting.kickoffLeadBodyPrefix) \(Self.leadDescription(minutes: minutesUntilStart))."
            content.sound = .default

            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: scheduledDate
            )
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            let scheduledIdentifier = proGameReminderIdentifier(for: event.identifier, repeatIndex: index)
            let request = UNNotificationRequest(
                identifier: scheduledIdentifier,
                content: content,
                trigger: trigger
            )

            do {
                try await center.add(request)
                let pending = await center.pendingNotificationRequests()
                let isPending = pending.contains { $0.identifier == scheduledIdentifier }
                print("[ProGameReminderDebug] scheduledTime=\(Self.debugDateString(scheduledDate))")
                print("[ProGameReminderDebug] scheduledIdentifier=\(scheduledIdentifier)")
                print("[ProGameReminderDebug] notificationCreated=\(isPending)")
                print("[ProGameReminderDebug] schedulingSuccess=\(isPending)")
            } catch {
                print("[ProGameReminderDebug] scheduledTime=\(Self.debugDateString(scheduledDate))")
                print("[ProGameReminderDebug] scheduledIdentifier=\(scheduledIdentifier)")
                print("[ProGameReminderDebug] notificationCreated=false")
                print("[ProGameReminderDebug] schedulingSuccess=false")
                print("[ProGameReminderDebug] schedulingFailure=\(error.localizedDescription)")
            }
        }
    }

    func cancelProGameReminder(identifier: String) async {
        print("[ProGameReminderDebug] cancelReminder gameId=\(identifier)")
        let baseIdentifier = proGameReminderIdentifier(for: identifier)
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0 == baseIdentifier || $0.hasPrefix("\(baseIdentifier).") }
        center.removePendingNotificationRequests(withIdentifiers: identifiers.isEmpty ? [baseIdentifier] : identifiers)
        print("[ProGameReminderDebug] canceledIdentifiers=\((identifiers.isEmpty ? [baseIdentifier] : identifiers).joined(separator: ","))")
    }

    func cancelAllProGameReminders() async {
        let requests = await center.pendingNotificationRequests()
        let identifiers = requests
            .map(\.identifier)
            .filter { $0.hasPrefix(proGameIdentifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func cancelProGameFinalNotification(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [proGameFinalIdentifier(for: identifier)])
    }

    func cancelProGameScoreUpdateNotifications(identifier: String) async {
        let baseIdentifier = proGameScoreUpdateIdentifierPrefix + identifier
        let identifiers = await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(baseIdentifier) }
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func scheduleProGameFinalNotification(for event: ProGameFinalNotificationEvent) async {
        print("[ProGameNotificationDebug] schedulingFinal id=\(event.identifier)")
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "final",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )

        guard await requestAuthorizationIfNeeded() else {
            print("[ProGameNotificationDebug] finalPermissionDenied=true")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = ProGameNotificationFormatting.finalScoreTitle
        content.body = event.body
        content.sound = .default

        let identifier = proGameFinalIdentifier(for: event.identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] finalSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func scheduleProGameHalftimeNotification(for event: ProGameHalftimeNotificationEvent) async {
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "halftime",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = ProGameNotificationFormatting.halftimeTitle
        content.body = event.body
        content.sound = .default

        let identifier = proGameHalftimeIdentifier(for: event.identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] halftimeSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func scheduleProGamePredictionResultNotification(for event: ProGamePredictionResultNotificationEvent) async {
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "predictionResult",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )
        guard await requestAuthorizationIfNeeded() else { return }

        let content = UNMutableNotificationContent()
        content.title = ProGameNotificationFormatting.predictionResultTitle
        content.body = event.body
        content.sound = .default

        let identifier = proGamePredictionResultIdentifier(for: event.identifier)
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
        let request = UNNotificationRequest(
            identifier: identifier,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] predictionResultSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func cancelProGameHalftimeNotification(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [proGameHalftimeIdentifier(for: identifier)])
    }

    func cancelProGamePredictionResultNotification(identifier: String) async {
        center.removePendingNotificationRequests(withIdentifiers: [proGamePredictionResultIdentifier(for: identifier)])
    }

    func scheduleProGameScoreUpdateNotification(for event: ProGameScoreUpdateNotificationEvent) async {
        print("[ProGameNotificationDebug] schedulingScoreUpdate id=\(event.identifier) score=\(event.scoreToken)")
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "score",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam
        )

        guard await requestAuthorizationIfNeeded() else {
            print("[ProGameNotificationDebug] scoreUpdatePermissionDenied=true")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: proGameScoreUpdateIdentifier(for: event.identifier, scoreToken: event.scoreToken),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
        } catch {
            print("[ProGameNotificationDebug] scoreUpdateSchedulingFailed id=\(event.identifier) error=\(error.localizedDescription)")
        }
    }

    func scheduleProGameCardNotification(for event: ProGameCardNotificationEvent) async {
        print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=pending dedupeHit=false")
        ProGameNotificationFormatting.logPushFlagDebug(
            notificationType: "card",
            awayTeam: event.awayTeam,
            homeTeam: event.homeTeam,
            scoringTeam: nil
        )

        guard await requestAuthorizationIfNeeded() else {
            print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=false dedupeHit=false reason=permissionDenied")
            return
        }

        let content = UNMutableNotificationContent()
        content.title = event.title
        content.body = event.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: proGameCardNotificationIdentifier(for: event.identifier, eventKey: event.eventKey),
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )

        do {
            try await center.add(request)
            print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=true dedupeHit=false")
        } catch {
            print("[ProGameCardNotificationDebug] gameId=\(event.identifier) cardType=\(event.cardType.stableToken) eventKey=\(event.eventKey) notificationSent=false dedupeHit=false error=\(error.localizedDescription)")
        }
    }

    private func reminderIdentifier(for eventId: UUID) -> String {
        "\(identifierPrefix)\(eventId.uuidString.lowercased())"
    }

    private func reminderIdentifier(for eventId: UUID, repeatIndex: Int) -> String {
        let base = reminderIdentifier(for: eventId)
        return repeatIndex == 0 ? base : "\(base).repeat\(repeatIndex)"
    }

    private func proGameReminderIdentifier(for identifier: String) -> String {
        "\(proGameIdentifierPrefix)\(identifier)"
    }

    private func proGameReminderIdentifier(for identifier: String, repeatIndex: Int) -> String {
        let base = proGameReminderIdentifier(for: identifier)
        return repeatIndex == 0 ? base : "\(base).repeat\(repeatIndex)"
    }

    private func proGameFinalIdentifier(for identifier: String) -> String {
        "\(proGameFinalIdentifierPrefix)\(identifier)"
    }

    private func proGameHalftimeIdentifier(for identifier: String) -> String {
        "\(proGameHalftimeIdentifierPrefix)\(identifier)"
    }

    private func proGamePredictionResultIdentifier(for identifier: String) -> String {
        "\(proGamePredictionResultIdentifierPrefix)\(identifier)"
    }

    private func proGameScoreUpdateIdentifier(for identifier: String, scoreToken: String) -> String {
        "\(proGameScoreUpdateIdentifierPrefix)\(identifier).\(scoreToken)"
    }

    private func proGameCardNotificationIdentifier(for identifier: String, eventKey: String) -> String {
        let sanitizedKey = eventKey
            .replacingOccurrences(of: "|", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "\(proGameCardNotificationIdentifierPrefix)\(identifier).\(sanitizedKey)"
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

    private func proGameReminderFireDates(
        preferredFireDate: Date,
        eventStartDate: Date,
        repeatUntilStart: Bool,
        repeatEveryMinutes: Int
    ) -> [Date] {
        let now = Date()
        guard eventStartDate > now else { return [] }

        guard repeatUntilStart else {
            let fireDate = preferredFireDate > now ? preferredFireDate : eventStartDate
            print("[ProGameReminderDebug] reminderDate=\(Self.debugDateString(fireDate))")
            return [fireDate]
        }

        let step = max(1, repeatEveryMinutes)
        var dates: [Date] = []
        var next = preferredFireDate
        while next < eventStartDate {
            if next > now {
                print("[ProGameReminderDebug] reminderDate=\(Self.debugDateString(next))")
                dates.append(next)
            }
            guard let advanced = Calendar.current.date(byAdding: .minute, value: step, to: next) else {
                break
            }
            next = advanced
        }
        if dates.isEmpty || (dates.last ?? .distantPast) < eventStartDate {
            print("[ProGameReminderDebug] reminderDate=\(Self.debugDateString(eventStartDate))")
            dates.append(eventStartDate)
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
            let formattedTitle = ProGameNotificationFormatting.formatTextContainingTeamNames(title)
            return "\(formattedTitle) starts in \(lead)."
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
