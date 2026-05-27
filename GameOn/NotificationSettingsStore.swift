import Combine
import SwiftUI

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
        print("[NotificationSettingsDebug] load authorizationState notifyBeforeGame=\(notifyBeforeGame) reminderMinutesBefore=\(reminderMinutesBefore) repeatGameReminder=\(repeatGameReminder) repeatEveryMinutes=\(repeatEveryMinutes)")
        let status = await gameReminderService.authorizationStatus()
        switch status {
        case .denied:
            notifyBeforeGame = false
            await gameReminderService.cancelAllGameReminders()
            notificationPermissionMessage = "Notifications are off for FanGeo. Turn them on in iOS Settings to receive game reminders."
        case .authorized, .provisional, .ephemeral:
            notificationPermissionMessage = ""
        case .notDetermined:
            notificationPermissionMessage = notifyBeforeGame ? "FanGeo will ask for notification permission before scheduling game reminders." : ""
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
}
