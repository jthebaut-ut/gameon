import Foundation
import Supabase

extension MapViewModel {
    @MainActor
    func loadFanIdentityPreferencesFromProfile() async {
        guard let authId = currentUserAuthId else { return }
        struct Row: Decodable {
            let fan_identity_preferences: FanIdentityPreferences?
        }
        do {
            let rows: [Row] = try await supabase
                .from("user_profiles")
                .select("fan_identity_preferences")
                .eq("id", value: authId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            currentUserFanIdentityPreferences = rows.first?.fan_identity_preferences ?? .empty
        } catch {
#if DEBUG
            print("[FanIdentityPrefs] load_failed error=\(error.localizedDescription)")
#endif
        }
    }

    /// Persists JSONB preferences for the signed-in fan.
    @discardableResult
    func saveFanIdentityPreferences(_ preferences: FanIdentityPreferences) async -> String? {
        guard let authId = currentUserAuthId else {
            return "Sign in to save your fan identity."
        }

        struct Patch: Encodable {
            let fan_identity_preferences: FanIdentityPreferences
        }

        let payloadIDs = FanOpenToCatalog.canonicalizeItemIDs(preferences.openToItems)
        if let payloadData = try? JSONEncoder().encode(
            ["open_to_items": payloadIDs]
        ),
           let payloadJSON = String(data: payloadData, encoding: .utf8) {
            print("[OpenToDebug] savePayload= \(payloadJSON)")
        }

        do {
            try await supabase
                .from("user_profiles")
                .update(Patch(fan_identity_preferences: preferences))
                .eq("id", value: authId.uuidString.lowercased())
                .execute()
            await MainActor.run {
                currentUserFanIdentityPreferences = preferences
                publicProfileOpenToRevision &+= 1
            }
            print("[OpenToDebug] savedPreferences= ids=\(preferences.resolvedOpenToItemIDs)")
            return nil
        } catch {
#if DEBUG
            print("[FanIdentityPrefs] save_failed error=\(error.localizedDescription)")
#endif
            return "Couldn't save fan identity. Please try again."
        }
    }
}
