import Foundation
import SwiftUI

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

enum VenueEnergyTier: String {
    case quiet = "Low Activity"
    case activeFanZone = "Active Fan Zone"
    case liveEnergy = "Live Energy"
    case packedCrowd = "Packed Crowd"
    case trendingNow = "Trending Now"

    static func tier(for score: Int) -> VenueEnergyTier {
        switch score {
        case 81...:
            return .trendingNow
        case 51...80:
            return .packedCrowd
        case 26...50:
            return .liveEnergy
        case 10...25:
            return .activeFanZone
        default:
            return .quiet
        }
    }
}

struct VenueEnergyColorPalette {
    let tier: VenueEnergyTier
    let accent: Color
    let text: Color
    let backgroundColors: [Color]
    let borderColors: [Color]
    let fanChatBorderColors: [Color]
    let topEdgeColors: [Color]
    let auraColor: Color
    let glowColor: Color
    let glowRadius: CGFloat
}

func energyAccentColor(for score: Int) -> Color {
    venueEnergyColorPalette(for: score).accent
}

func energyGradient(for score: Int) -> LinearGradient {
    let palette = venueEnergyColorPalette(for: score)
    return LinearGradient(
        colors: palette.backgroundColors,
        startPoint: .leading,
        endPoint: .trailing
    )
}

func venueEnergyColorPalette(for score: Int) -> VenueEnergyColorPalette {
    switch score {
    case 81...:
        let red = Color(red: 0.95, green: 0.22, blue: 0.18)
        let orange = Color(red: 1.00, green: 0.47, blue: 0.18)
        let pink = Color(red: 0.95, green: 0.24, blue: 0.48)
        return VenueEnergyColorPalette(
            tier: .trendingNow,
            accent: orange,
            text: red,
            backgroundColors: [red.opacity(0.18), orange.opacity(0.16), pink.opacity(0.14)],
            borderColors: [red.opacity(0.50), orange.opacity(0.44), pink.opacity(0.38)],
            fanChatBorderColors: [red.opacity(0.28), orange.opacity(0.24), pink.opacity(0.22)],
            topEdgeColors: [red.opacity(0.60), orange.opacity(0.50), pink.opacity(0.44)],
            auraColor: orange.opacity(0.10),
            glowColor: orange.opacity(0.24),
            glowRadius: 14
        )
    case 51...80:
        let orange = Color(red: 0.96, green: 0.45, blue: 0.12)
        let amber = Color(red: 1.00, green: 0.67, blue: 0.24)
        return VenueEnergyColorPalette(
            tier: .packedCrowd,
            accent: orange,
            text: orange,
            backgroundColors: [orange.opacity(0.16), amber.opacity(0.12)],
            borderColors: [orange.opacity(0.46), amber.opacity(0.34)],
            fanChatBorderColors: [orange.opacity(0.25), amber.opacity(0.18)],
            topEdgeColors: [orange.opacity(0.50), amber.opacity(0.36)],
            auraColor: orange.opacity(0.08),
            glowColor: orange.opacity(0.18),
            glowRadius: 11
        )
    case 26...50:
        let blue = Color(red: 0.08, green: 0.44, blue: 0.92)
        let cyan = Color(red: 0.17, green: 0.72, blue: 0.90)
        return VenueEnergyColorPalette(
            tier: .liveEnergy,
            accent: blue,
            text: blue,
            backgroundColors: [blue.opacity(0.13), cyan.opacity(0.11)],
            borderColors: [blue.opacity(0.36), cyan.opacity(0.30)],
            fanChatBorderColors: [blue.opacity(0.21), cyan.opacity(0.18)],
            topEdgeColors: [blue.opacity(0.38), cyan.opacity(0.28)],
            auraColor: cyan.opacity(0.06),
            glowColor: cyan.opacity(0.14),
            glowRadius: 8
        )
    case 10...25:
        let blue = Color(red: 0.16, green: 0.46, blue: 0.86)
        let green = Color(red: 0.12, green: 0.62, blue: 0.42)
        return VenueEnergyColorPalette(
            tier: .activeFanZone,
            accent: green,
            text: green,
            backgroundColors: [blue.opacity(0.09), green.opacity(0.11)],
            borderColors: [blue.opacity(0.24), green.opacity(0.28)],
            fanChatBorderColors: [blue.opacity(0.14), green.opacity(0.16)],
            topEdgeColors: [blue.opacity(0.22), green.opacity(0.22)],
            auraColor: green.opacity(0.04),
            glowColor: green.opacity(0.08),
            glowRadius: 5
        )
    default:
        return VenueEnergyColorPalette(
            tier: .quiet,
            accent: .secondary,
            text: .secondary,
            backgroundColors: [.secondary.opacity(0.07), .secondary.opacity(0.05)],
            borderColors: [.secondary.opacity(0.16), .secondary.opacity(0.10)],
            fanChatBorderColors: [.secondary.opacity(0.10), .secondary.opacity(0.08)],
            topEdgeColors: [.secondary.opacity(0.12), .secondary.opacity(0.08)],
            auraColor: .clear,
            glowColor: .clear,
            glowRadius: 0
        )
    }
}

enum FanGeoLiveEnergyTiming {
    static let startsSoonWindowMinutes = 60
    static let liveWindowHours = 4

    private static let fractionalScheduledStartFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let plainScheduledStartFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let scheduledStartFormatterLock = NSLock()

    static func parseScheduledStart(_ raw: String?, eventId: UUID? = nil) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }

        scheduledStartFormatterLock.lock()
        defer { scheduledStartFormatterLock.unlock() }

        if let date = fractionalScheduledStartFormatter.date(from: raw) {
            return date
        }

        if let date = plainScheduledStartFormatter.date(from: raw) {
            return date
        }

        logInvalidScheduledStart(raw, eventId: eventId)
        return nil
    }

    private static func logInvalidScheduledStart(_ raw: String, eventId: UUID?) {
#if DEBUG
        print("[LiveEnergyCrashGuard] invalidScheduledStart=\(raw) eventId=\(eventId?.uuidString.lowercased() ?? "nil")")
#endif
    }
}
