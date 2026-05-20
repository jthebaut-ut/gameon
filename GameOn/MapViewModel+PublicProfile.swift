import Foundation

extension MapViewModel {
    /// Cached `user_profiles` hints for public profile (pickup roster, comments-by-email map, etc.).
    func cachedUserProfileRowForPublicProfile(userId: UUID) -> UserProfileRow? {
        if userId == currentUserAuthId {
            return currentUserProfileRowForPublicProfileCache()
        }
        if let row = pickupJoinRequesterProfileByUserId[userId] {
            return row
        }
        return userProfilesByEmail.values.first { $0.id == userId }
    }

    /// Fresh signed-in fan row for public-profile loads (bio must match `user_profiles.bio`).
    func currentUserProfileRowForPublicProfileCache() -> UserProfileRow? {
        guard let authId = currentUserAuthId else { return nil }
        let email = OwnerBusinessEmail.normalized(currentUserEmail)
        guard OwnerBusinessEmail.isValidStrict(email) else { return nil }
        let trimmedBio = currentUserBio.trimmingCharacters(in: .whitespacesAndNewlines)
        return UserProfileRow(
            id: authId,
            email: email,
            display_name: currentUserDisplayName,
            username: currentUserUsername.isEmpty ? nil : currentUserUsername,
            bio: trimmedBio.isEmpty ? nil : trimmedBio,
            avatar_url: currentUserAvatarURL,
            avatar_thumbnail_url: currentUserAvatarThumbnailURL,
            is_business_account: false,
            admin_status: "active",
            live_visibility_enabled: currentUserLiveVisibilityEnabled,
            live_visibility_mode: currentUserLiveVisibilityMode.rawValue,
            selected_live_visibility_friend_ids: Array(currentUserSelectedLiveVisibilityFriendIDs),
            discoverable_by_fans: currentUserDiscoverableByFans
        )
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
