import Foundation

/// Copy for business (venue-owner) sessions blocked from fan-only participation features.
enum BusinessFanGateCopy {
    static let actionTapBlocked =
        "Business accounts can't use this fan feature. Please sign in with a regular FanGeo account."
    static let followingLockedBody =
        "Business accounts can't use fan-only Going features. Sign in with a regular FanGeo account to save venues, join games, and manage games to play."
    static let pickupFanOnly = "Pickup games are for regular FanGeo accounts."
    static let commentsViewOnlyForBusiness =
        "Business accounts can read fan updates here. Posting updates is available on a regular FanGeo account."
    /// Chat tab: Add friend by email/display name search (fan-only; same gate as ``canUseFanSocialFeatures``).
    static let addFriendLookupBlockedForBusiness =
        "Business accounts can’t use Add friend by search. Sign in with a regular FanGeo account to find fans by email or display name."
}

extension MapViewModel {

    /// Fan-only social participation (saved venues, going, ratings, pickup join, Following tab lists). Does **not** include private DM/chat.
    var canUseFanSocialFeatures: Bool {
        isLoggedIn && !currentUserIsBusinessAccount && !isVenueOwnerLoggedIn && !hasAuthenticatedVenueOwnerSession
    }

    var canFavoriteVenues: Bool { canUseFanSocialFeatures }
    var canMarkGoing: Bool { canUseFanSocialFeatures }
    var canRateVenues: Bool { canUseFanSocialFeatures }
    var canJoinPickupGames: Bool { canUseFanSocialFeatures }
    var canUseFollowingTab: Bool { canUseFanSocialFeatures }

    /// Private chat / DMs: any signed-in context that has Supabase auth (fan, business, or linked session).
    var canUsePrivateChat: Bool {
        isLoggedIn || isVenueOwnerLoggedIn || hasAuthenticatedVenueOwnerSession
    }

    /// Pickup create/join UI, organizer tooling, and join-request badges (alias kept for existing call sites).
    var canFanUsePickupGamesUI: Bool { canJoinPickupGames }

    /// Venue event “I’m going” / interest mutations (server-backed).
    var canMarkInterest: Bool { canMarkGoing }

#if DEBUG
    func logBusinessUserGateBlocked(action: String) {
        print("[BusinessUserGate] blocked action=\(action)")
    }
#else
    func logBusinessUserGateBlocked(action: String) {
        _ = action
    }
#endif
}
