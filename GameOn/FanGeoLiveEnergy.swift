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
    let socialPresenceProfiles: [UserProfileRow]
    let socialPresenceLabel: String?

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

struct VenueGamePreviewEnergy {
    let score: Int
    let label: String?
    let subtitle: String
    let fireCount: Int
    let seatsCount: Int
    let tvCount: Int
    let soundCount: Int
    let crowdCount: Int
    let goingCount: Int
    let friendGoingCount: Int
    let commentCount: Int

    var hasBadge: Bool { label != nil }
    var isHighEnergy: Bool { score >= 51 }

    static func evaluate(
        fireCount: Int,
        seatsCount: Int,
        tvCount: Int,
        soundCount: Int,
        crowdCount: Int,
        goingCount: Int,
        friendGoingCount: Int,
        commentCount: Int,
        isLiveNow: Bool,
        startsSoon: Bool
    ) -> VenueGamePreviewEnergy {
        let liveNowBoost = isLiveNow ? 18 : (startsSoon ? 8 : 0)
        let score = fireCount * 8
            + crowdCount * 6
            + goingCount * 5
            + friendGoingCount * 12
            + commentCount * 2
            + tvCount * 2
            + soundCount * 2
            + seatsCount
            + liveNowBoost

        return VenueGamePreviewEnergy(
            score: score,
            label: label(for: score),
            subtitle: subtitle(
                score: score,
                goingCount: goingCount,
                friendGoingCount: friendGoingCount,
                commentCount: commentCount,
                isLiveNow: isLiveNow,
                startsSoon: startsSoon
            ),
            fireCount: fireCount,
            seatsCount: seatsCount,
            tvCount: tvCount,
            soundCount: soundCount,
            crowdCount: crowdCount,
            goingCount: goingCount,
            friendGoingCount: friendGoingCount,
            commentCount: commentCount
        )
    }

    private static func label(for score: Int) -> String? {
        switch score {
        case 81...:
            return "🚀 Trending Now"
        case 51...80:
            return "🔥 Packed Crowd"
        case 26...50:
            return "⚡ Live Energy"
        case 10...25:
            return "🟢 Active Fan Zone"
        default:
            return nil
        }
    }

    private static func subtitle(
        score: Int,
        goingCount: Int,
        friendGoingCount: Int,
        commentCount: Int,
        isLiveNow: Bool,
        startsSoon: Bool
    ) -> String {
        var parts: [String] = []
        if goingCount > 0 {
            parts.append(goingCount == 1 ? "1 going" : "\(goingCount) going")
        }
        if friendGoingCount > 0 {
            parts.append(friendGoingCount == 1 ? "1 friend there" : "\(friendGoingCount) friends there")
        }
        if commentCount > 0 {
            parts.append(commentCount == 1 ? "1 chatting" : "\(commentCount) chatting")
        }
        if !parts.isEmpty {
            return parts.prefix(3).joined(separator: " • ")
        }
        if isLiveNow { return "Fans reacting now" }
        if startsSoon { return "Crowd building" }
        if score >= 26 { return "Live updates active" }
        if score >= 10 { return "Crowd building" }
        return "Quiet for now"
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
