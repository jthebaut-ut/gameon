import Foundation

struct FanGeoLiveEnergy {
    let isLiveNow: Bool
    let startsSoon: Bool
    let minutesUntilStart: Int?
    let goingCount: Int
    let commentCount: Int
    let friendGoingCount: Int
    let friendAvatarURLs: [String]
    let mutualTeamLabel: String?
    let energyLabel: String?
    let energySubtitle: String?
    let friendPresenceLabel: String?
    let friendProfiles: [UserProfileRow]

    var hasAnySignal: Bool {
        isLiveNow
            || startsSoon
            || goingCount > 0
            || commentCount > 0
            || friendGoingCount > 0
            || energyLabel != nil
    }

    var compactChips: [String] {
        var chips: [String] = []
        if isLiveNow {
            chips.append("🔥 LIVE NOW")
        } else if startsSoon, let minutesUntilStart {
            chips.append("⏱ Starts in \(minutesUntilStart) min")
        }

        if let energyLabel, !chips.contains(energyLabel) {
            chips.append(energyLabel == "Crowd building" ? "🔥 Crowd building" : energyLabel)
        }

        if friendGoingCount > 0 {
            chips.append(friendGoingCount == 1 ? "👥 1 friend" : "👥 \(friendGoingCount) friends")
        } else if goingCount > 0 {
            chips.append(goingCount == 1 ? "👥 1 fan" : "👥 \(goingCount) fans")
        }

        if commentCount > 0 {
            chips.append(commentCount == 1 ? "💬 1 chatting" : "💬 \(commentCount) chatting")
        }

        return Array(chips.prefix(4))
    }
}

enum FanGeoLiveEnergyTiming {
    static let startsSoonWindowMinutes = 60
    static let liveWindowHours = 4

    static func parseScheduledStart(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}
