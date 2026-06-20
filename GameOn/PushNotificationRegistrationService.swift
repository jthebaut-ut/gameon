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

    func refreshPushTokenRegistration(reason: String) async {
        await upsertCurrentTokenIfPossible(reason: reason)
        await registerForRemoteNotificationsIfAuthorized(reason: reason)
    }

    func registerForRemoteNotificationsIfAuthorized(reason: String) async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        guard Self.canRegisterRemoteNotifications(status: settings.authorizationStatus) else {
            print("[PushTokenDebug] registerSkipped reason=\(reason) permission=\(Self.authorizationStatusDescription(settings.authorizationStatus))")
            return
        }

#if canImport(UIKit)
        await MainActor.run {
            print("[PushTokenDebug] registerForRemoteNotifications reason=\(reason)")
            UIApplication.shared.registerForRemoteNotifications()
        }
#endif
    }

    func handleDeviceToken(_ deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        let environment = Self.resolvedEnvironment()
        UserDefaults.standard.set(token, forKey: Self.deviceTokenDefaultsKey)
        UserDefaults.standard.set(environment, forKey: Self.environmentDefaultsKey)
        print("[PushTokenDebug] didRegister tokenPrefix=\(String(token.prefix(12))) environment=\(environment)")
        Task { await upsertCurrentTokenIfPossible(reason: "didRegisterForRemoteNotifications") }
    }

    func handleRegistrationFailure(_ error: Error) {
        print("[PushTokenDebug] registrationFailed error=\(error.localizedDescription)")
    }

    func upsertCurrentTokenIfPossible(reason: String) async {
        guard let token = Self.storedToken, !token.isEmpty else {
            print("[PushTokenDebug] upsertSkipped reason=\(reason) missingToken=true")
            return
        }
        guard let session = try? await supabase.auth.session else {
            print("[PushTokenDebug] upsertSkipped reason=\(reason) missingSession=true")
            return
        }
        let userID = session.user.id
        let environment = Self.resolvedEnvironment()
        UserDefaults.standard.set(environment, forKey: Self.environmentDefaultsKey)
        let lastSeenAt = SupabaseTimestampParsing.encodeTimestamptz(Date())

        let row = UserPushTokenUpsertRow(
            user_id: userID.uuidString.lowercased(),
            token: token,
            environment: environment,
            last_seen_at: lastSeenAt
        )

        do {
            await invalidateMismatchedEnvironmentRows(
                userID: row.user_id,
                token: token,
                storingEnvironment: environment,
                reason: reason
            )
            try await supabase
                .from("user_push_tokens")
                .upsert(row, onConflict: "user_id,token,environment")
                .execute()
            try await supabase
                .from("user_push_tokens")
                .update(
                    PushTokenReactivationPatch(
                        is_active: true,
                        last_seen_at: lastSeenAt
                    )
                )
                .eq("user_id", value: row.user_id)
                .eq("token", value: token)
                .eq("environment", value: environment)
                .execute()
            print(
                "[PushTokenDebug] upsertSucceeded userId=\(row.user_id) environment=\(row.environment) " +
                "tokenPrefix=\(String(token.prefix(12))) reactivated=true reason=\(reason)"
            )
        } catch {
            print("[PushTokenDebug] upsertFailed reason=\(reason) error=\(error.localizedDescription)")
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
        resolvedEnvironment()
    }

    private static var buildConfiguration: String {
#if DEBUG
        return "Debug"
#else
        return "Release"
#endif
    }

    private static var buildConfigurationDefaultEnvironment: String {
#if DEBUG
        return "sandbox"
#else
        return "production"
#endif
    }

    private static func resolvedEnvironment() -> String {
        let entitlement = apsEnvironmentEntitlement()
        let environment: String
        switch entitlement {
        case "development":
            environment = "sandbox"
        case "production":
            environment = "production"
        default:
            environment = buildConfigurationDefaultEnvironment
        }

        print("[PushTokenDebug] buildConfiguration=\(buildConfiguration)")
        print("[PushTokenDebug] apsEnvironmentEntitlement=\(entitlement ?? "nil")")
        print("[PushTokenDebug] storingEnvironment=\(environment)")
        return environment
    }

    private static func apsEnvironmentEntitlement() -> String? {
        guard let profileURL = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: profileURL),
              let profile = String(data: data, encoding: .ascii) ?? String(data: data, encoding: .utf8),
              let keyRange = profile.range(of: "<key>aps-environment</key>") else {
            return nil
        }
        let suffix = profile[keyRange.upperBound...]
        guard let valueStart = suffix.range(of: "<string>")?.upperBound,
              let valueEnd = suffix[valueStart...].range(of: "</string>")?.lowerBound else {
            return nil
        }
        return String(suffix[valueStart..<valueEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func invalidateMismatchedEnvironmentRows(
        userID: String,
        token: String,
        storingEnvironment: String,
        reason: String
    ) async {
        do {
            try await supabase
                .from("user_push_tokens")
                .update(PushTokenInvalidationPatch(
                    is_active: false,
                    invalidated_at: SupabaseTimestampParsing.encodeTimestamptz(Date())
                ))
                .eq("user_id", value: userID)
                .eq("token", value: token)
                .neq("environment", value: storingEnvironment)
                .execute()
#if DEBUG
            print("[PushTokenDebug] invalidatedMismatchedEnvironmentRows userId=\(userID) storingEnvironment=\(storingEnvironment) reason=\(reason)")
#endif
        } catch {
#if DEBUG
            print("[PushTokenDebug] invalidateMismatchedEnvironmentRowsFailed reason=\(reason) error=\(error.localizedDescription)")
#endif
        }
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

private struct PushTokenReactivationPatch: Encodable {
    let is_active: Bool
    let last_seen_at: String

    enum CodingKeys: String, CodingKey {
        case is_active
        case invalidated_at
        case last_seen_at
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(is_active, forKey: .is_active)
        try container.encodeNil(forKey: .invalidated_at)
        try container.encode(last_seen_at, forKey: .last_seen_at)
    }
}

private struct PushTokenInvalidationPatch: Encodable {
    let is_active: Bool
    let invalidated_at: String
}
