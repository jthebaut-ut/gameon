import Foundation
import Supabase

/// Friend CTA state for ``PublicUserProfilePreviewView`` (derived from ``ChatViewModel/FriendshipChipKind``).
enum PublicProfileFriendButtonState: Equatable {
    case hidden
    case messageFriend
    case requestFriendship
    case friendshipRequested
}

/// Loaded public-safe profile payload (no email shown in UI).
struct PublicUserProfileData: Equatable {
    let userId: UUID
    let displayName: String
    /// @handle line; may use temporary email-prefix fallback when username unset (email never shown).
    let publicHandleLine: String
    let bio: String?
    let avatarURL: String?
    let avatarThumbnailURL: String?
    let reputation: FanReputationProfile
    let organizerStats: PickupCreatorPublicRatingStats?
    let favoriteTeams: [FavoriteTeam]
    let isBusinessAccount: Bool
    /// True when `user_profiles` row was loaded from network or cache (not purely synthetic).
    let hasResolvedIdentity: Bool
    /// False when target is undiscoverable, blocked, or missing.
    let isPubliclyVisible: Bool
    let memberSinceLabel: String?
    let openToItems: [PublicProfileOpenToItem]
    let mutualFansCount: Int
    let mutualFanAvatars: [PublicProfileMutualFanAvatar]
    let sharedTeamsCount: Int
    let venueCount: Int
    let venueCards: [PublicProfileVenueCard]
    let pickupHostedCount: Int
    let pickupJoinedCount: Int
    let socialHighlightLabels: [String]
}

enum PublicUserProfileService {
    private static let profileSelect =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids,discoverable_by_fans"

    /// Always returns a displayable profile; optional sections use safe fallbacks.
    static func load(userId: UUID, cachedProfile: UserProfileRow? = nil) async -> PublicUserProfileData {
#if DEBUG
        print("[PublicProfileLoadDebug] requestedUserId=\(userId.uuidString.lowercased())")
#endif

        if let identity = await fetchPublicIdentityRPC(targetUserId: userId), identity.visible {
            return await assembleFromIdentityRPC(identity, userId: userId, cachedProfile: cachedProfile)
        }

        if let identity = await fetchPublicIdentityRPC(targetUserId: userId), !identity.visible {
            return hiddenProfile(userId: userId)
        }

        return await loadLegacy(userId: userId, cachedProfile: cachedProfile)
    }

    static func userProfileRow(from preview: UserPreview) -> UserProfileRow {
        UserProfileRow(
            id: preview.id,
            email: preview.email,
            display_name: preview.displayName,
            username: preview.username,
            bio: nil,
            avatar_url: preview.avatarURL,
            avatar_thumbnail_url: preview.avatarThumbnailURL,
            is_business_account: preview.isBusinessAccount,
            admin_status: "active",
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: []
        )
    }

    static func friendButtonState(
        for userId: UUID,
        chipKind: ChatViewModel.FriendshipChipKind,
        isBlocked: Bool,
        isSelf: Bool,
        isBusiness: Bool
    ) -> PublicProfileFriendButtonState {
        if isSelf || isBlocked || isBusiness { return .hidden }
        switch chipKind {
        case .friends:
            return .messageFriend
        case .addFriend, .declinedOutgoing:
            return .requestFriendship
        case .pendingOutgoing, .pendingIncoming:
            return .friendshipRequested
        }
    }

    // MARK: - RPC

    private struct PublicIdentityRPCResponse: Decodable {
        let visible: Bool
        let user_id: UUID?
        let display_name: String?
        let username: String?
        let bio: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let member_since: String?
        let favorite_team_ids: [String]?
        let mutual_fans_count: Int?
        let shared_teams_count: Int?
        let venue_count: Int?
        let pickup_hosted_count: Int?
        let pickup_joined_count: Int?
        let mutual_fan_avatars: [MutualFanRow]?
        let venue_cards: [VenueCardRow]?

        struct MutualFanRow: Decodable {
            let user_id: UUID?
            let display_name: String?
            let avatar_url: String?
        }

        struct VenueCardRow: Decodable {
            let venue_id: UUID?
            let venue_name: String?
            let city_label: String?
        }
    }

    private static func fetchPublicIdentityRPC(targetUserId: UUID) async -> PublicIdentityRPCResponse? {
        struct Params: Encodable {
            let p_target_user_id: UUID
        }

        do {
            let payload: PublicIdentityRPCResponse = try await supabase
                .rpc(
                    "get_public_fan_identity_profile",
                    params: Params(p_target_user_id: targetUserId)
                )
                .execute()
                .value
#if DEBUG
            print(
                "[PublicProfileLoadDebug] identityRPC visible=\(payload.visible) mutual=\(payload.mutual_fans_count ?? 0) venues=\(payload.venue_count ?? 0)"
            )
#endif
            return payload
        } catch {
#if DEBUG
            print("[PublicProfileLoadDebug] identityRPC_failed error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private static func assembleFromIdentityRPC(
        _ rpc: PublicIdentityRPCResponse,
        userId: UUID,
        cachedProfile: UserProfileRow?
    ) async -> PublicUserProfileData {
        let teamIDs = rpc.favorite_team_ids ?? []
        let favoriteTeams = FavoriteTeamsStore.resolvedTeams(fromIDs: teamIDs)

        let row = UserProfileRow(
            id: userId,
            email: cachedProfile?.email,
            display_name: rpc.display_name,
            username: rpc.username,
            bio: rpc.bio,
            avatar_url: rpc.avatar_url,
            avatar_thumbnail_url: rpc.avatar_thumbnail_url,
            is_business_account: false,
            admin_status: "active",
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: [],
            discoverable_by_fans: true
        )

        let organizerStats = await fetchOrganizerStats(userId: userId)
        let venueCount = max(0, rpc.venue_count ?? 0)
        let pickupHosted = max(0, rpc.pickup_hosted_count ?? 0)
        let pickupJoined = max(0, rpc.pickup_joined_count ?? 0)

        var built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: FanXPState.rookie,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            isBusinessAccount: false,
            hasResolvedIdentity: true,
            isPubliclyVisible: true,
            memberSinceLabel: PublicProfileMemberSinceFormatter.label(from: rpc.member_since),
            openToItems: PublicProfileOpenToBuilder.items(
                favoriteTeams: favoriteTeams,
                venueCount: venueCount,
                pickupHostedCount: pickupHosted,
                pickupJoinedCount: pickupJoined
            ),
            mutualFansCount: max(0, rpc.mutual_fans_count ?? 0),
            mutualFanAvatars: (rpc.mutual_fan_avatars ?? []).compactMap { avatarRow in
                guard let id = avatarRow.user_id else { return nil }
                let name = (avatarRow.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return PublicProfileMutualFanAvatar(
                    userId: id,
                    displayName: name.isEmpty ? "Fan" : name,
                    avatarURL: ImageDisplayURL.canonicalStorageURLString(avatarRow.avatar_url)
                )
            },
            sharedTeamsCount: max(0, rpc.shared_teams_count ?? 0),
            venueCount: venueCount,
            venueCards: (rpc.venue_cards ?? []).map { card in
                PublicProfileVenueCard(
                    venueId: card.venue_id,
                    venueName: (card.venue_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    cityLabel: (card.city_label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                )
            },
            pickupHostedCount: pickupHosted,
            pickupJoinedCount: pickupJoined
        )

        built = PublicUserProfileData(
            userId: built.userId,
            displayName: built.displayName,
            publicHandleLine: built.publicHandleLine,
            bio: built.bio,
            avatarURL: built.avatarURL,
            avatarThumbnailURL: built.avatarThumbnailURL,
            reputation: built.reputation,
            organizerStats: built.organizerStats,
            favoriteTeams: built.favoriteTeams,
            isBusinessAccount: built.isBusinessAccount,
            hasResolvedIdentity: built.hasResolvedIdentity,
            isPubliclyVisible: true,
            memberSinceLabel: built.memberSinceLabel,
            openToItems: built.openToItems,
            mutualFansCount: built.mutualFansCount,
            mutualFanAvatars: built.mutualFanAvatars,
            sharedTeamsCount: built.sharedTeamsCount,
            venueCount: built.venueCount,
            venueCards: built.venueCards.filter { !$0.venueName.isEmpty },
            pickupHostedCount: built.pickupHostedCount,
            pickupJoinedCount: built.pickupJoinedCount,
            socialHighlightLabels: socialHighlights(
                venueCount: venueCount,
                pickupHosted: pickupHosted,
                pickupJoined: pickupJoined,
                sharedTeams: built.sharedTeamsCount
            )
        )

#if DEBUG
        print(
            "[PublicProfileLoadDebug] finalProfile userId=\(built.userId.uuidString.lowercased()) name=\(built.displayName) handle=\(built.publicHandleLine) reputation=\(built.reputation.title)"
        )
#endif

        return built
    }

    private static func hiddenProfile(userId: UUID) -> PublicUserProfileData {
        PublicUserProfileData(
            userId: userId,
            displayName: "Fan",
            publicHandleLine: "",
            bio: nil,
            avatarURL: nil,
            avatarThumbnailURL: nil,
            reputation: FanReputationEngine.evaluate(FanReputationSignals(fanXP: .rookie)),
            organizerStats: nil,
            favoriteTeams: [],
            isBusinessAccount: false,
            hasResolvedIdentity: false,
            isPubliclyVisible: false,
            memberSinceLabel: nil,
            openToItems: [],
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: 0,
            venueCards: [],
            pickupHostedCount: 0,
            pickupJoinedCount: 0,
            socialHighlightLabels: []
        )
    }

    // MARK: - Legacy fallback

    private static func loadLegacy(userId: UUID, cachedProfile: UserProfileRow?) async -> PublicUserProfileData {
        var profileQuerySuccess = false
        var row: UserProfileRow? = cachedProfile
        if let cached = cachedProfile, cached.id == userId {
            profileQuerySuccess = true
        } else {
            row = nil
        }

        if row == nil {
            let fetched = await fetchProfileRow(userId: userId)
            row = fetched.row
            profileQuerySuccess = fetched.success
        }

        let (fanXP, _) = await loadPublicXP(userId: userId)
        let organizerStats = await fetchOrganizerStats(userId: userId)
        let favoriteTeams = await fetchPublicFavoriteTeams(userId: userId)
        let isBusiness = await resolveIsBusinessAccount(userId: userId, profileRow: row)
        let discoverable = row?.discoverableByFans ?? true

        if isBusiness || discoverable == false {
            return hiddenProfile(userId: userId)
        }

        let venueCount = 0
        let pickupHosted = 0
        let pickupJoined = 0

        var built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: fanXP,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            isBusinessAccount: isBusiness,
            hasResolvedIdentity: profileQuerySuccess,
            isPubliclyVisible: true,
            memberSinceLabel: nil,
            openToItems: PublicProfileOpenToBuilder.items(
                favoriteTeams: favoriteTeams,
                venueCount: venueCount,
                pickupHostedCount: pickupHosted,
                pickupJoinedCount: pickupJoined
            ),
            mutualFansCount: 0,
            mutualFanAvatars: [],
            sharedTeamsCount: 0,
            venueCount: venueCount,
            venueCards: [],
            pickupHostedCount: pickupHosted,
            pickupJoinedCount: pickupJoined
        )

        built = PublicUserProfileData(
            userId: built.userId,
            displayName: built.displayName,
            publicHandleLine: built.publicHandleLine,
            bio: built.bio,
            avatarURL: built.avatarURL,
            avatarThumbnailURL: built.avatarThumbnailURL,
            reputation: built.reputation,
            organizerStats: built.organizerStats,
            favoriteTeams: built.favoriteTeams,
            isBusinessAccount: built.isBusinessAccount,
            hasResolvedIdentity: built.hasResolvedIdentity,
            isPubliclyVisible: true,
            memberSinceLabel: built.memberSinceLabel,
            openToItems: built.openToItems,
            mutualFansCount: built.mutualFansCount,
            mutualFanAvatars: built.mutualFanAvatars,
            sharedTeamsCount: built.sharedTeamsCount,
            venueCount: built.venueCount,
            venueCards: built.venueCards,
            pickupHostedCount: built.pickupHostedCount,
            pickupJoinedCount: built.pickupJoinedCount,
            socialHighlightLabels: socialHighlights(
                venueCount: venueCount,
                pickupHosted: pickupHosted,
                pickupJoined: pickupJoined,
                sharedTeams: 0
            )
        )

        return built
    }

    private static func socialHighlights(
        venueCount: Int,
        pickupHosted: Int,
        pickupJoined: Int,
        sharedTeams: Int
    ) -> [String] {
        var labels: [String] = []
        if sharedTeams > 0 {
            labels.append(sharedTeams == 1 ? "1 shared favorite team" : "\(sharedTeams) shared favorite teams")
        }
        if venueCount > 0 {
            labels.append(venueCount == 1 ? "Visits favorite venues" : "Visits \(venueCount) favorite venues")
        }
        if pickupHosted > 0 {
            labels.append(pickupHosted == 1 ? "Hosts pickup games" : "Hosts pickup games regularly")
        } else if pickupJoined > 0 {
            labels.append("Joins local pickup games")
        }
        return Array(labels.prefix(3))
    }

    // MARK: - Profile row fetch

    private struct ProfileFetchResult {
        let row: UserProfileRow?
        let success: Bool
        let decodeError: String?
        let missingField: String?
    }

    private static func fetchProfileRow(userId: UUID) async -> ProfileFetchResult {
        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(profileSelect)
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let row = rows.first {
                return ProfileFetchResult(row: row, success: true, decodeError: nil, missingField: nil)
            }
            return ProfileFetchResult(row: nil, success: false, decodeError: nil, missingField: "no_rows")
        } catch {
            return ProfileFetchResult(row: nil, success: false, decodeError: String(describing: error), missingField: nil)
        }
    }

    private static func loadPublicXP(userId: UUID) async -> (FanXPState, Bool) {
        struct Row: Decodable {
            let total_xp: Int?
            let level: Int?
            let title: String?
        }

        do {
            let rows: [Row] = try await supabase
                .from("user_xp")
                .select("total_xp,level,title")
                .eq("user_id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let row = rows.first {
                return (
                    FanXPState(
                        totalXP: row.total_xp ?? 0,
                        level: max(1, row.level ?? 1),
                        title: (row.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? FanXPLevelCalculator.titleForLevel(max(1, row.level ?? 1))
                            : row.title!
                    ),
                    true
                )
            }
        } catch {
#if DEBUG
            print("[PublicProfileLoadDebug] xpQuery error=\(error.localizedDescription)")
#endif
        }

        return (FanXPState.rookie, false)
    }

    private static func fetchPublicFavoriteTeams(userId: UUID) async -> [FavoriteTeam] {
        let ids = await FavoriteTeamsSyncService.fetchTeamIDs(userId: userId)
        return FavoriteTeamsStore.resolvedTeams(fromIDs: ids)
    }

    private static func buildProfileData(
        userId: UUID,
        row: UserProfileRow?,
        fanXP: FanXPState,
        organizerStats: PickupCreatorPublicRatingStats?,
        favoriteTeams: [FavoriteTeam],
        isBusinessAccount: Bool,
        hasResolvedIdentity: Bool,
        isPubliclyVisible: Bool,
        memberSinceLabel: String?,
        openToItems: [PublicProfileOpenToItem],
        mutualFansCount: Int,
        mutualFanAvatars: [PublicProfileMutualFanAvatar],
        sharedTeamsCount: Int,
        venueCount: Int,
        venueCards: [PublicProfileVenueCard],
        pickupHostedCount: Int,
        pickupJoinedCount: Int
    ) -> PublicUserProfileData {
        let emailNorm = OwnerBusinessEmail.normalized(row?.email ?? "")
        let display = (row?.display_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

        let resolvedName: String
        if !display.isEmpty {
            resolvedName = display
        } else if OwnerBusinessEmail.isValidStrict(emailNorm) {
            let local = emailNorm.split(separator: "@").first.map(String.init) ?? ""
            resolvedName = local.isEmpty ? "Fan" : local
        } else {
            resolvedName = "Fan"
        }

        let storedUsername = (row?.username ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let handleLine: String
        if !storedUsername.isEmpty {
            handleLine = FanGeoHandleRules.displayHandle(stored: storedUsername)
        } else if OwnerBusinessEmail.isValidStrict(emailNorm) {
            handleLine = FanGeoHandleRules.temporaryFallbackHandle(email: emailNorm)
        } else {
            handleLine = "@fan"
        }

        let avatarFull = ImageDisplayURL.canonicalStorageURLString(row?.avatar_url)
        let avatarThumb = ImageDisplayURL.canonicalStorageURLString(row?.avatar_thumbnail_url)
        let trimmedBio = row?.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let reputation = FanReputationEngine.evaluate(
            FanReputationSignals(
                fanXP: fanXP,
                favoriteTeams: favoriteTeams,
                savedVenueCount: venueCount,
                pickupHostedCount: pickupHostedCount,
                pickupJoinedCount: pickupJoinedCount,
                organizerStats: organizerStats
            ),
            shouldLog: false
        )

        return PublicUserProfileData(
            userId: userId,
            displayName: resolvedName,
            publicHandleLine: handleLine,
            bio: trimmedBio.isEmpty ? nil : trimmedBio,
            avatarURL: avatarFull.isEmpty ? nil : avatarFull,
            avatarThumbnailURL: avatarThumb.isEmpty ? nil : avatarThumb,
            reputation: reputation,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            isBusinessAccount: isBusinessAccount,
            hasResolvedIdentity: hasResolvedIdentity,
            isPubliclyVisible: isPubliclyVisible,
            memberSinceLabel: memberSinceLabel,
            openToItems: openToItems,
            mutualFansCount: mutualFansCount,
            mutualFanAvatars: mutualFanAvatars,
            sharedTeamsCount: sharedTeamsCount,
            venueCount: venueCount,
            venueCards: venueCards,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount,
            socialHighlightLabels: socialHighlights(
                venueCount: venueCount,
                pickupHosted: pickupHostedCount,
                pickupJoined: pickupJoinedCount,
                sharedTeams: sharedTeamsCount
            )
        )
    }

    private static func resolveIsBusinessAccount(userId: UUID, profileRow: UserProfileRow?) async -> Bool {
        if profileRow?.is_business_account == true { return true }

        struct BizRow: Decodable {
            let id: UUID?
        }

        let rows: [BizRow] = (try? await supabase
            .from("businesses")
            .select("id")
            .eq("owner_user_id", value: userId.uuidString.lowercased())
            .eq("admin_status", value: "active")
            .limit(1)
            .execute()
            .value) ?? []

        return rows.first?.id != nil
    }

    private static func fetchOrganizerStats(userId: UUID) async -> PickupCreatorPublicRatingStats? {
        struct Params: Encodable {
            let p_creator_user_id: UUID
        }

        do {
            let rows: [PickupCreatorPublicRatingStatsRPCRow] = try await supabase
                .rpc("pickup_creator_public_rating_stats", params: Params(p_creator_user_id: userId))
                .execute()
                .value

            return rows.first?.toPublicStats()
                ?? PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        } catch {
            return PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        }
    }
}
