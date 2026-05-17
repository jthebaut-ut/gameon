import Foundation

extension MapViewModel {
    /// Cached `user_profiles` hints for public profile (pickup roster, comments-by-email map, etc.).
    func cachedUserProfileRowForPublicProfile(userId: UUID) -> UserProfileRow? {
        if let row = pickupJoinRequesterProfileByUserId[userId] {
            return row
        }
        return userProfilesByEmail.values.first { $0.id == userId }
    }

    /// Opens the root-level public profile presenter for another user (never for self).
    func presentPublicProfile(userId: UUID, context: String = "", activeSheet: String? = nil) {
        guard userId != currentUserAuthId else { return }

        let sheetHint = activeSheet ?? context

        publicProfilePresentationContext = context
        publicProfileSheetUserId = userId

#if DEBUG
        print("[PublicProfileTapDebug] userId=\(userId.uuidString.lowercased()) context=\(context) authenticated=\(isAuthenticatedForSocialFeatures)")
        print("[PublicProfilePresentationDebug] tapContext=\(context)")
        print("[PublicProfilePresentationDebug] presenter=custom_overlay")
        print("[PublicProfilePresentationDebug] swiftUIModalUsed=false")
        print("[PublicProfilePresentationDebug] activeSheet=\(sheetHint)")
        print("[PublicProfilePresentationDebug] presentedImmediately=true")
        print("[PublicProfilePresentationDebug] queued=false")
#endif
    }

    func dismissPublicProfile() {
        publicProfileSheetUserId = nil
        publicProfilePresentationContext = nil
#if DEBUG
        print("[PublicProfilePresentationDebug] presenter=custom_overlay")
        print("[PublicProfilePresentationDebug] swiftUIModalUsed=false")
        print("[PublicProfilePresentationDebug] overlayWindowUsed=false")
#endif
    }
}
