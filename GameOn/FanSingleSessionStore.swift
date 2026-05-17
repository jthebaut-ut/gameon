import Foundation

/// Local persistence for fan single-device session instance id.
enum FanSingleSessionStore {
    static let localSessionIdKey = "GameOn.fan.activeSessionInstanceId"

    static func localSessionId() -> String? {
        let raw = UserDefaults.standard.string(forKey: localSessionIdKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else { return nil }
        return raw.lowercased()
    }

    static func saveLocalSessionId(_ id: UUID) {
        UserDefaults.standard.set(id.uuidString.lowercased(), forKey: localSessionIdKey)
    }

    static func clearLocalSessionId() {
        UserDefaults.standard.removeObject(forKey: localSessionIdKey)
    }
}
