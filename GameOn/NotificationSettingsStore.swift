import Combine
import SwiftUI

nonisolated enum ProGameNotificationPreferenceKeys {
    static let finalScoreAlerts = "proGameFinalScoreNotifications"
    static let favoriteTeamAlerts = "favoriteTeamProGameAlertsEnabled"
    static let reminderTiming = "proGameReminderTiming"
    static let kickoffAlert = "proGameKickoffAlertEnabled"
}

nonisolated enum ProGameReminderTiming: String, CaseIterable, Identifiable {
    case never
    case oneDay
    case oneHour
    case thirtyMinutes
    case tenMinutes

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .never:
            return "Never"
        case .oneDay:
            return "1 Day Before"
        case .oneHour:
            return "1 Hour Before"
        case .thirtyMinutes:
            return "30 Minutes Before"
        case .tenMinutes:
            return "10 Minutes Before"
        }
    }

    var schedulesKickoffReminder: Bool {
        self != .never
    }

    var reminderMinutesBefore: Int? {
        switch self {
        case .never:
            return nil
        case .oneDay:
            return 24 * 60
        case .oneHour:
            return 60
        case .thirtyMinutes:
            return 30
        case .tenMinutes:
            return 10
        }
    }

    static func resolved(rawValue: String) -> ProGameReminderTiming {
        ProGameReminderTiming(rawValue: rawValue) ?? .oneHour
    }

    static func from(reminderMinutesBefore minutes: Int) -> ProGameReminderTiming {
        switch minutes {
        case 24 * 60:
            return .oneDay
        case 60:
            return .oneHour
        case 30:
            return .thirtyMinutes
        case 10:
            return .tenMinutes
        default:
            return .oneHour
        }
    }

    /// Timing choices for optional pre-kickoff game reminders.
    static var pickerOptions: [ProGameReminderTiming] {
        allCases
    }
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

    @AppStorage("syncSavedProGamesToAppleCalendar")
    var syncSavedProGamesToAppleCalendar: Bool = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("syncVenueGamesToAppleCalendar")
    var syncVenueGamesToAppleCalendar: Bool = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage("syncPickupGamesToAppleCalendar")
    var syncPickupGamesToAppleCalendar: Bool = true {
        willSet { objectWillChange.send() }
    }

    func isAppleCalendarSyncEnabled(forFanGeoIdentifier identifier: String?) -> Bool {
        guard syncGoingGamesToAppleCalendar else { return false }
        let normalized = identifier?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        if normalized.hasPrefix("pro|") {
            return syncSavedProGamesToAppleCalendar
        }
        if normalized.hasPrefix("venue|") {
            return syncVenueGamesToAppleCalendar
        }
        if normalized.hasPrefix("pickup|") {
            return syncPickupGamesToAppleCalendar
        }
        return true
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

    @AppStorage(ProGameNotificationPreferenceKeys.reminderTiming)
    private var proGameReminderTimingRaw: String = ProGameReminderTiming.oneHour.rawValue {
        willSet { objectWillChange.send() }
    }

    @AppStorage(ProGameNotificationPreferenceKeys.kickoffAlert)
    var proGameKickoffAlertEnabled: Bool = true {
        willSet { objectWillChange.send() }
    }

    var proGameReminderTiming: ProGameReminderTiming {
        get { ProGameReminderTiming.resolved(rawValue: proGameReminderTimingRaw) }
        set { proGameReminderTimingRaw = newValue.rawValue }
    }

    var proGameGameReminderEnabled: Bool {
        proGameReminderTiming.schedulesKickoffReminder
    }

    @AppStorage(ProGameNotificationPreferenceKeys.finalScoreAlerts)
    var proGameFinalScoreNotifications: Bool = true {
        willSet { objectWillChange.send() }
    }

    @AppStorage(ProGameNotificationPreferenceKeys.favoriteTeamAlerts)
    var favoriteTeamProGameAlertsEnabled: Bool = false {
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
        migrateProGameReminderTimingIfNeeded()
        migrateProGameKickoffAlertSplitIfNeeded()
        print("[NotificationSettingsStoreDebug] initialized")
    }

    private func migrateProGameKickoffAlertSplitIfNeeded() {
        let migrationKey = "proGameKickoffAlertSplitMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        let defaults = UserDefaults.standard
        if defaults.object(forKey: ProGameNotificationPreferenceKeys.kickoffAlert) == nil {
            proGameKickoffAlertEnabled = true
            let legacyPreKickoffDisabled = defaults.object(forKey: "proGameReminderNotifications") as? Bool == false
                || defaults.object(forKey: "proGameKickoffRemindersEnabled") as? Bool == false
            if legacyPreKickoffDisabled {
                proGameReminderTimingRaw = ProGameReminderTiming.never.rawValue
            }
        }

        defaults.set(true, forKey: migrationKey)
    }

    private func migrateProGameReminderTimingIfNeeded() {
        let migrationKey = "proGameReminderTimingMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: migrationKey) else { return }

        if UserDefaults.standard.string(forKey: ProGameNotificationPreferenceKeys.reminderTiming) == nil {
            let defaults = UserDefaults.standard
            let legacyEnabled = defaults.object(forKey: "proGameReminderNotifications") as? Bool ?? true
            if legacyEnabled {
                let legacyMinutes = defaults.object(forKey: "reminderMinutesBefore") as? Int ?? 60
                proGameReminderTimingRaw = ProGameReminderTiming.from(reminderMinutesBefore: legacyMinutes).rawValue
                proGameKickoffAlertEnabled = true
            } else {
                proGameReminderTimingRaw = ProGameReminderTiming.never.rawValue
                proGameKickoffAlertEnabled = true
            }
        }

        UserDefaults.standard.set(true, forKey: migrationKey)
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
        print("[NotificationSettingsDebug] load authorizationState notifyBeforeGame=\(notifyBeforeGame) proGameKickoffAlertEnabled=\(proGameKickoffAlertEnabled) proGameReminderTiming=\(proGameReminderTiming.rawValue) reminderMinutesBefore=\(reminderMinutesBefore) repeatGameReminder=\(repeatGameReminder) repeatEveryMinutes=\(repeatEveryMinutes)")
        let status = await gameReminderService.authorizationStatus()
        switch status {
        case .denied:
            notifyBeforeGame = false
            proGameKickoffAlertEnabled = false
            favoriteTeamProGameAlertsEnabled = false
            proGameFinalScoreNotifications = false
            await gameReminderService.cancelAllGameReminders()
            await gameReminderService.cancelAllProGameKickoffAlerts()
            await gameReminderService.cancelAllProGamePreKickoffReminders()
            notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
        case .authorized, .provisional, .ephemeral:
            notificationPermissionMessage = ""
        case .notDetermined:
            notificationPermissionMessage = (notifyBeforeGame || proGameKickoffAlertEnabled || proGameGameReminderEnabled || proGameFinalScoreNotifications)
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

    func setProGameKickoffAlertEnabled(_ enabled: Bool) async -> Bool {
        print("[NotificationSettingsDebug] save proGameKickoffAlertEnabled requested=\(enabled)")
        if enabled {
            let granted = await gameReminderService.requestAuthorizationIfNeeded()
            guard granted else {
                proGameKickoffAlertEnabled = false
                notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
                print("[NotificationSettingsDebug] save proGameKickoffAlertEnabled deniedBySystem")
                return false
            }

            proGameKickoffAlertEnabled = true
            notificationPermissionMessage = ""
            return true
        }

        proGameKickoffAlertEnabled = false
        notificationPermissionMessage = ""
        await gameReminderService.cancelAllProGameKickoffAlerts()
        return true
    }

    func setProGameFinalScoreNotificationsEnabled(_ enabled: Bool) async -> Bool {
        print("[NotificationSettingsDebug] save proGameFinalScoreNotifications requested=\(enabled)")
        if enabled {
            let granted = await gameReminderService.requestAuthorizationIfNeeded()
            guard granted else {
                proGameFinalScoreNotifications = false
                notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
                print("[NotificationSettingsDebug] save proGameFinalScoreNotifications deniedBySystem")
                return false
            }

            proGameFinalScoreNotifications = true
            notificationPermissionMessage = ""
            return true
        }

        proGameFinalScoreNotifications = false
        notificationPermissionMessage = ""
        return true
    }

    func setProGameGameReminderTiming(_ timing: ProGameReminderTiming) async -> Bool {
        print("[NotificationSettingsDebug] save proGameReminderTiming requested=\(timing.rawValue)")
        if timing.schedulesKickoffReminder {
            let granted = await gameReminderService.requestAuthorizationIfNeeded()
            guard granted else {
                notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
                print("[NotificationSettingsDebug] save proGameReminderTiming deniedBySystem")
                return false
            }
            notificationPermissionMessage = ""
        }

        proGameReminderTiming = timing
        if timing == .never {
            await gameReminderService.cancelAllProGamePreKickoffReminders()
        }
        return true
    }
}
