import Foundation

extension MapViewModel {
    /// Cached `user_profiles` hints for public profile (pickup roster, comments-by-email map, etc.).
    func cachedUserProfileRowForPublicProfile(userId: UUID) -> UserProfileRow? {
        if let row = pickupJoinRequesterProfileByUserId[userId] {
            return row
        }
        return userProfilesByEmail.values.first { $0.id == userId }
    }
    /// Opens the global public profile sheet for another user (never for self).
    func presentPublicProfile(userId: UUID, context: String = "") {
        guard userId != currentUserAuthId else { return }
#if DEBUG
        print(
            "[PublicProfileTapDebug] userId=\(userId.uuidString.lowercased()) context=\(context) authenticated=\(isAuthenticatedForSocialFeatures)"
        )
#endif
        publicProfileSheetUserId = userId
    }

    func dismissPublicProfile() {
        publicProfileSheetUserId = nil
    }
}
