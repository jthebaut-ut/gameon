import Combine
import SwiftUI

nonisolated enum ProGameNotificationPreferenceKeys {
    static let finalScoreAlerts = "proGameFinalScoreNotifications"
}

nonisolated enum FanGeoCalendarAlertTiming: String, CaseIterable, Identifiable {
    case none
    case atEventTime
    case fifteenMinutesBefore
    case oneHourBefore
    case oneDayBefore

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none:
            return "None"
        case .atEventTime:
            return "At time of event"
        case .fifteenMinutesBefore:
            return "15 minutes before"
        case .oneHourBefore:
            return "1 hour before"
        case .oneDayBefore:
            return "1 day before"
        }
    }

    var relativeOffset: TimeInterval? {
        switch self {
        case .none:
            return nil
        case .atEventTime:
            return 0
        case .fifteenMinutesBefore:
            return -15 * 60
        case .oneHourBefore:
            return -60 * 60
        case .oneDayBefore:
            return -24 * 60 * 60
        }
    }

    static func resolved(rawValue: String) -> FanGeoCalendarAlertTiming {
        FanGeoCalendarAlertTiming(rawValue: rawValue) ?? .oneHourBefore
    }
}

@MainActor
final class NotificationSettingsStore: ObservableObject {
    @AppStorage("notifyBeforeGame")
    var notifyBeforeGame: Bool = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("reminderMinutesBefore")
    var reminderMinutesBefore: Int = 60 {
        willSet { objectWillChange.send() }
    }

    @AppStorage("repeatGameReminder")
    var repeatGameReminder: Bool = false {
        willSet { objectWillChange.send() }
    }

    @AppStorage("repeatEveryMinutes")
    var repeatEveryMinutes: Int = 30 {
        willSet { objectWillChange.send() }
    }

    @AppStorage("syncGoingGamesToAppleCalendar")
    var syncGoingGamesToAppleCalendar: Bool = false {
        willSet { objectWillChange.send() }
    }

    @AppStorage("venue_calendar_alert_timing")
    private var venueCalendarAlertTimingRaw: String = FanGeoCalendarAlertTiming.oneHourBefore.rawValue {
        willSet { objectWillChange.send() }
    }

    @AppStorage("pickup_calendar_alert_timing")
    private var pickupCalendarAlertTimingRaw: String = FanGeoCalendarAlertTiming.oneHourBefore.rawValue {
        willSet { objectWillChange.send() }
    }

    @AppStorage("pro_calendar_alert_timing")
    private var proCalendarAlertTimingRaw: String = FanGeoCalendarAlertTiming.oneHourBefore.rawValue {
        willSet { objectWillChange.send() }
    }

    @AppStorage("proGameReminderNotifications")
    var proGameReminderNotifications: Bool = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage(ProGameNotificationPreferenceKeys.finalScoreAlerts)
    var proGameFinalScoreNotifications: Bool = true {
        willSet { objectWillChange.send() }
    }

    @Published var notificationPermissionMessage: String = "" {
        didSet {
            print("[NotificationSettingsStoreDebug] permissionMessageUpdated=\(notificationPermissionMessage)")
        }
    }

    private var gameReminderService: GameReminderNotificationService {
        GameReminderNotificationService.shared
    }
    private var authorizationRefreshTask: Task<Void, Never>?

    init() {
        print("[NotificationSettingsStoreDebug] initialized")
    }

    var venueCalendarAlertTiming: FanGeoCalendarAlertTiming {
        get { FanGeoCalendarAlertTiming.resolved(rawValue: venueCalendarAlertTimingRaw) }
        set { venueCalendarAlertTimingRaw = newValue.rawValue }
    }

    var pickupCalendarAlertTiming: FanGeoCalendarAlertTiming {
        get { FanGeoCalendarAlertTiming.resolved(rawValue: pickupCalendarAlertTimingRaw) }
        set { pickupCalendarAlertTimingRaw = newValue.rawValue }
    }

    var proCalendarAlertTiming: FanGeoCalendarAlertTiming {
        get { FanGeoCalendarAlertTiming.resolved(rawValue: proCalendarAlertTimingRaw) }
        set { proCalendarAlertTimingRaw = newValue.rawValue }
    }

    func refreshGameNotificationAuthorizationState() async {
        if let authorizationRefreshTask {
            print("[NotificationPerf] authorizationRefreshCoalesced=true")
            await authorizationRefreshTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performGameNotificationAuthorizationRefresh()
        }
        authorizationRefreshTask = task
        await task.value
        authorizationRefreshTask = nil
    }

    private func performGameNotificationAuthorizationRefresh() async {
        let startedAt = Date()
        print("[NotificationSettingsDebug] load authorizationState notifyBeforeGame=\(notifyBeforeGame) proGameReminderNotifications=\(proGameReminderNotifications) reminderMinutesBefore=\(reminderMinutesBefore) repeatGameReminder=\(repeatGameReminder) repeatEveryMinutes=\(repeatEveryMinutes)")
        let status = await gameReminderService.authorizationStatus()
        switch status {
        case .denied:
            notifyBeforeGame = false
            proGameReminderNotifications = false
            await gameReminderService.cancelAllGameReminders()
            await gameReminderService.cancelAllProGameReminders()
            notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
        case .authorized, .provisional, .ephemeral:
            notificationPermissionMessage = ""
        case .notDetermined:
            notificationPermissionMessage = (notifyBeforeGame || proGameReminderNotifications || proGameFinalScoreNotifications)
                ? "FanGeo will ask for notification permission before scheduling game reminders."
                : ""
        @unknown default:
            notificationPermissionMessage = "Could not read notification permission status."
        }
        print("[NotificationPerf] authorizationRefreshFinished durationMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
    }

    func setGameNotificationsEnabled(_ enabled: Bool) async -> Bool {
        print("[NotificationSettingsDebug] save notifyBeforeGame requested=\(enabled)")
        if enabled {
            let granted = await gameReminderService.requestAuthorizationIfNeeded()
            guard granted else {
                notifyBeforeGame = false
                notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
                print("[NotificationSettingsDebug] save notifyBeforeGame deniedBySystem")
                return false
            }

            notifyBeforeGame = true
            notificationPermissionMessage = ""
            return true
        } else {
            notifyBeforeGame = false
            notificationPermissionMessage = ""
            await gameReminderService.cancelAllGameReminders()
            return false
        }
    }

    func setProGameRemindersEnabled(_ enabled: Bool) async -> Bool {
        print("[NotificationSettingsDebug] save proGameReminderNotifications requested=\(enabled)")
        if enabled {
            let granted = await gameReminderService.requestAuthorizationIfNeeded()
            guard granted else {
                proGameReminderNotifications = false
                notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
                print("[NotificationSettingsDebug] save proGameReminderNotifications deniedBySystem")
                return false
            }

            proGameReminderNotifications = true
            notificationPermissionMessage = ""
            return true
        } else {
            proGameReminderNotifications = false
            notificationPermissionMessage = ""
            await gameReminderService.cancelAllProGameReminders()
            return false
        }
    }
}
