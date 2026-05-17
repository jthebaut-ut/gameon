import Foundation

struct FanReputationScores: Equatable {
    let fanReputation: Int
    let venueReputation: Int
    let pickupReputation: Int
}

struct FanReputationPrivileges: Equatable {
    let isVerifiedOrganizer: Bool
    let canCreateLargerPickupGames: Bool
    let hasHighlightedVenueIdentity: Bool
    let hasSubtleHighlightedComments: Bool
}

struct FanReputationProfile: Equatable {
    let title: String
    let subtitle: String
    let profileSubtitle: String
    let contextLine: String
    let whyEarnedText: String
    let progressFraction: Double
    let scores: FanReputationScores
    let privileges: FanReputationPrivileges
}

struct FanReputationSignals: Equatable {
    let fanXP: FanXPState
    let favoriteTeams: [FavoriteTeam]
    let localContext: String?
    let savedVenueCount: Int
    let venuePlanCount: Int
    let pickupHostedCount: Int
    let pickupJoinedCount: Int
    let organizerStats: PickupCreatorPublicRatingStats?
    let commentCount: Int
    let reactionCount: Int

    init(
        fanXP: FanXPState,
        favoriteTeams: [FavoriteTeam] = [],
        localContext: String? = nil,
        savedVenueCount: Int = 0,
        venuePlanCount: Int = 0,
        pickupHostedCount: Int = 0,
        pickupJoinedCount: Int = 0,
        organizerStats: PickupCreatorPublicRatingStats? = nil,
        commentCount: Int = 0,
        reactionCount: Int = 0
    ) {
        self.fanXP = fanXP
        self.favoriteTeams = favoriteTeams
        self.localContext = localContext
        self.savedVenueCount = savedVenueCount
        self.venuePlanCount = venuePlanCount
        self.pickupHostedCount = pickupHostedCount
        self.pickupJoinedCount = pickupJoinedCount
        self.organizerStats = organizerStats
        self.commentCount = commentCount
        self.reactionCount = reactionCount
    }
}

enum FanReputationEngine {
    private static let titles = [
        "Rookie Fan",
        "Local Fan",
        "Game Regular",
        "Superfan",
        "Fan Leader",
        "Venue Regular",
        "Verified Organizer",
        "Home Crowd"
    ]

    static func evaluate(_ signals: FanReputationSignals, shouldLog: Bool = true) -> FanReputationProfile {
        let savedVenueCount = max(0, signals.savedVenueCount)
        let venuePlanCount = max(0, signals.venuePlanCount)
        let pickupHostedCount = max(0, signals.pickupHostedCount)
        let pickupJoinedCount = max(0, signals.pickupJoinedCount)
        let commentCount = max(0, signals.commentCount)
        let reactionCount = max(0, signals.reactionCount)
        let ratingCount = max(0, signals.organizerStats?.ratingCount ?? 0)
        let averageRating = max(0, signals.organizerStats?.avgRating ?? 0)
        let favoriteTeamCount = signals.favoriteTeams.count

        let fanReputation = max(0, signals.fanXP.totalXP)
            + favoriteTeamCount * 80
            + venuePlanCount * 60
            + commentCount * 45
            + reactionCount * 20
        let venueReputation = savedVenueCount * 160
            + venuePlanCount * 120
            + min(commentCount, 20) * 20
        let pickupReputation = pickupHostedCount * 220
            + pickupJoinedCount * 90
            + ratingCount * 120
            + (averageRating >= 4.5 && ratingCount >= 3 ? 250 : 0)

        let scores = FanReputationScores(
            fanReputation: fanReputation,
            venueReputation: venueReputation,
            pickupReputation: pickupReputation
        )

        let verifiedOrganizer = ratingCount >= 8 && averageRating >= 4.5
        let title = selectedTitle(
            fanReputation: fanReputation,
            venueReputation: venueReputation,
            pickupReputation: pickupReputation,
            savedVenueCount: savedVenueCount,
            venuePlanCount: venuePlanCount,
            pickupHostedCount: pickupHostedCount,
            verifiedOrganizer: verifiedOrganizer
        )
        let identityContext = primaryIdentityContext(
            favoriteTeams: signals.favoriteTeams,
            localContext: signals.localContext
        )
        let subtitle = subtitleForTitle(
            title,
            savedVenueCount: savedVenueCount,
            venuePlanCount: venuePlanCount,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount,
            ratingCount: ratingCount,
            favoriteTeams: signals.favoriteTeams,
            identityContext: identityContext
        )
        let profileSubtitle = [title, identityContext]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
        let whyEarnedText = whyEarnedText(
            title: title,
            savedVenueCount: savedVenueCount,
            venuePlanCount: venuePlanCount,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount,
            ratingCount: ratingCount,
            commentCount: commentCount,
            reactionCount: reactionCount,
            favoriteTeamCount: favoriteTeamCount
        )
        let profile = FanReputationProfile(
            title: title,
            subtitle: subtitle,
            profileSubtitle: profileSubtitle.isEmpty ? title : profileSubtitle,
            contextLine: contextLine(
                savedVenueCount: savedVenueCount,
                venuePlanCount: venuePlanCount,
                pickupHostedCount: pickupHostedCount,
                pickupJoinedCount: pickupJoinedCount,
                commentCount: commentCount,
                reactionCount: reactionCount,
                favoriteTeamCount: favoriteTeamCount
            ),
            whyEarnedText: whyEarnedText,
            progressFraction: passiveProgressFraction(
                fanReputation: fanReputation,
                venueReputation: venueReputation,
                pickupReputation: pickupReputation
            ),
            scores: scores,
            privileges: FanReputationPrivileges(
                isVerifiedOrganizer: title == "Verified Organizer",
                canCreateLargerPickupGames: verifiedOrganizer,
                hasHighlightedVenueIdentity: title == "Venue Regular" || title == "Home Crowd",
                hasSubtleHighlightedComments: title == "Superfan" || title == "Fan Leader" || title == "Home Crowd"
            )
        )

        if shouldLog {
            log(profile)
        }

        return profile
    }

    static func log(_ profile: FanReputationProfile) {
#if DEBUG
        print("[FanReputationDebug] calculatedFanReputation=\(profile.scores.fanReputation)")
        print("[FanReputationDebug] calculatedVenueReputation=\(profile.scores.venueReputation)")
        print("[FanReputationDebug] calculatedPickupReputation=\(profile.scores.pickupReputation)")
        print("[FanReputationDebug] selectedPrimaryTitle=\(profile.title)")
        print("[FanReputationDebug] profileSubtitle=\(profile.profileSubtitle)")
#endif
    }

    static func localContext(latitude: Double?, longitude: Double?) -> String? {
        guard let latitude, let longitude else { return nil }
        if (40.55...40.90).contains(latitude), (-112.15...(-111.65)).contains(longitude) {
            return "Salt Lake City"
        }
        if (36.9...42.1).contains(latitude), (-114.2...(-108.9)).contains(longitude) {
            return "Utah"
        }
        return nil
    }

    private static func selectedTitle(
        fanReputation: Int,
        venueReputation: Int,
        pickupReputation: Int,
        savedVenueCount: Int,
        venuePlanCount: Int,
        pickupHostedCount: Int,
        verifiedOrganizer: Bool
    ) -> String {
        if fanReputation >= 8_000, venueReputation >= 1_000 { return titles[7] }
        if verifiedOrganizer || (pickupHostedCount >= 6 && pickupReputation >= 1_500) { return titles[6] }
        if savedVenueCount >= 4 || venueReputation >= 800 { return titles[5] }
        if pickupReputation >= 850 || fanReputation >= 5_000 { return titles[4] }
        if fanReputation >= 2_000 { return titles[3] }
        if savedVenueCount + venuePlanCount >= 3 { return titles[2] }
        if fanReputation >= 350 || savedVenueCount > 0 || venuePlanCount > 0 { return titles[1] }
        return titles[0]
    }

    private static func primaryIdentityContext(favoriteTeams: [FavoriteTeam], localContext: String?) -> String? {
        if let team = favoriteTeams.first {
            return team.name
        }
        return localContext
    }

    private static func subtitleForTitle(
        _ title: String,
        savedVenueCount: Int,
        venuePlanCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int,
        ratingCount: Int,
        favoriteTeams: [FavoriteTeam],
        identityContext: String?
    ) -> String {
        switch title {
        case "Verified Organizer":
            if ratingCount > 0 { return "Trusted pickup organizer" }
            return "Hosting local pickup games"
        case "Venue Regular":
            return savedVenueCount > 0
                ? "Active at \(savedVenueCount) sports \(savedVenueCount == 1 ? "venue" : "venues")"
                : "Known around local sports venues"
        case "Fan Leader":
            if pickupHostedCount > 0 { return "Bringing local fans together" }
            return "A familiar voice in the community"
        case "Superfan":
            return "Active in local fan discussions"
        case "Game Regular":
            return venuePlanCount > 0 ? "Shows up for local games" : "Building a game-day rhythm"
        case "Local Fan":
            return identityContext ?? "Building local sports presence"
        case "Home Crowd":
            return "A steady presence in the local scene"
        default:
            if let team = favoriteTeams.first { return "\(team.name) fan profile" }
            if pickupJoinedCount > 0 { return "Getting into local pickup" }
            return "Building local sports presence"
        }
    }

    private static func whyEarnedText(
        title: String,
        savedVenueCount: Int,
        venuePlanCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int,
        ratingCount: Int,
        commentCount: Int,
        reactionCount: Int,
        favoriteTeamCount: Int
    ) -> String {
        if title == "Verified Organizer", ratingCount > 0 {
            return "Earned from pickup host ratings and consistent organizer activity."
        }
        if savedVenueCount >= 4 {
            return "Earned from repeat venue activity and local game plans."
        }
        if pickupHostedCount > 0 {
            return "Earned from hosting pickup games and showing up locally."
        }
        if commentCount + reactionCount > 0 {
            return "Earned from fan discussions and social engagement."
        }
        if favoriteTeamCount > 0 {
            return "Earned from your team identity and FanGeo activity."
        }
        if venuePlanCount > 0 || pickupJoinedCount > 0 {
            return "Earned from game plans and local sports activity."
        }
        return "Reputation grows quietly as you show up around FanGeo."
    }

    private static func contextLine(
        savedVenueCount: Int,
        venuePlanCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int,
        commentCount: Int,
        reactionCount: Int,
        favoriteTeamCount: Int
    ) -> String {
        if savedVenueCount > 0 {
            return "Active at \(savedVenueCount) \(savedVenueCount == 1 ? "venue" : "venues")"
        }
        if pickupHostedCount > 0 {
            return "Hosted \(pickupHostedCount) pickup \(pickupHostedCount == 1 ? "game" : "games")"
        }
        if pickupJoinedCount > 0 {
            return "Joined local pickup games"
        }
        if venuePlanCount > 0 {
            return "Local game plans added"
        }
        if commentCount + reactionCount > 0 {
            return "Active in fan discussions"
        }
        if favoriteTeamCount > 0 {
            return "Team identity added"
        }
        return "Building local sports presence"
    }

    private static func passiveProgressFraction(
        fanReputation: Int,
        venueReputation: Int,
        pickupReputation: Int
    ) -> Double {
        let strongest = max(fanReputation, venueReputation, pickupReputation)
        let anchors = [0, 350, 900, 2_000, 5_000, 8_000]
        let current = anchors.last(where: { strongest >= $0 }) ?? 0
        let next = anchors.first(where: { $0 > strongest }) ?? anchors.last ?? 8_000
        guard next > current else { return 1 }
        return min(1, max(0.08, Double(strongest - current) / Double(next - current)))
    }
}
