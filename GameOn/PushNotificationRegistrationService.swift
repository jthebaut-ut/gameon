import Foundation
import Supabase
import UserNotifications

#if canImport(UIKit)
import UIKit
#endif

final class PushNotificationRegistrationService {
    static let shared = PushNotificationRegistrationService()

    private static let deviceTokenDefaultsKey = "gameon.apnsDeviceToken.v1"
    private static let environmentDefaultsKey = "gameon.apnsEnvironment.v1"

    private init() {}

    func registerForRemoteNotificationsIfAuthorized(reason: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard Self.canRegisterRemoteNotifications(status: settings.authorizationStatus) else {
#if DEBUG
            print("[PushTokenDebug] registerSkipped reason=\(reason) permission=\(Self.authorizationStatusDescription(settings.authorizationStatus))")
#endif
            return
        }

#if canImport(UIKit)
        await MainActor.run {
#if DEBUG
            print("[PushTokenDebug] registerForRemoteNotifications reason=\(reason)")
#endif
            UIApplication.shared.registerForRemoteNotifications()
        }
#endif
    }

    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let environment = Self.currentEnvironment
        UserDefaults.standard.set(token, forKey: Self.deviceTokenDefaultsKey)
        UserDefaults.standard.set(environment, forKey: Self.environmentDefaultsKey)
#if DEBUG
        print("[PushTokenDebug] didRegister tokenPrefix=\(String(token.prefix(12))) environment=\(environment)")
#endif
        Task { await upsertCurrentTokenIfPossible(reason: "didRegisterForRemoteNotifications") }
    }

    func handleRegistrationFailure(_ error: Error) {
#if DEBUG
        print("[PushTokenDebug] registrationFailed error=\(error.localizedDescription)")
#endif
    }

    func upsertCurrentTokenIfPossible(reason: String) async {
        guard let token = Self.storedToken, !token.isEmpty else {
#if DEBUG
            print("[PushTokenDebug] upsertSkipped reason=\(reason) missingToken=true")
#endif
            return
        }
        guard let session = try? await supabase.auth.session else {
#if DEBUG
            print("[PushTokenDebug] upsertSkipped reason=\(reason) missingSession=true")
#endif
            return
        }
        let userID = session.user.id

        let row = UserPushTokenUpsertRow(
            user_id: userID.uuidString.lowercased(),
            token: token,
            environment: Self.storedEnvironment,
            last_seen_at: SupabaseTimestampParsing.encodeTimestamptz(Date())
        )

        do {
            try await supabase
                .from("user_push_tokens")
                .upsert(row, onConflict: "user_id,token,environment")
                .execute()
#if DEBUG
            print("[PushTokenDebug] upsertSucceeded userId=\(row.user_id) environment=\(row.environment) reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[PushTokenDebug] upsertFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    func deleteCurrentTokenForCurrentSession(reason: String) async {
        guard let token = Self.storedToken, !token.isEmpty else { return }
        guard let session = try? await supabase.auth.session else { return }
        let userID = session.user.id

        do {
            try await supabase
                .from("user_push_tokens")
                .delete()
                .eq("user_id", value: userID.uuidString.lowercased())
                .eq("token", value: token)
                .eq("environment", value: Self.storedEnvironment)
                .execute()
#if DEBUG
            print("[PushTokenDebug] deleteSucceeded userId=\(userID.uuidString.lowercased()) reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[PushTokenDebug] deleteFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
    }

    private static var storedToken: String? {
        UserDefaults.standard.string(forKey: deviceTokenDefaultsKey)
    }

    private static var storedEnvironment: String {
        UserDefaults.standard.string(forKey: environmentDefaultsKey) ?? currentEnvironment
    }

    private static var currentEnvironment: String {
#if DEBUG
        return "sandbox"
#else
        return "production"
#endif
    }

    private static func canRegisterRemoteNotifications(status: UNAuthorizationStatus) -> Bool {
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
}

private struct UserPushTokenUpsertRow: Encodable {
    let user_id: String
    let token: String
    let platform: String = "ios"
    let environment: String
    let is_active: Bool = true
    let invalidated_at: String? = nil
    let last_seen_at: String
}
