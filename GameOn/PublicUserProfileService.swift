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
    let fanXP: FanXPState
    let reputation: FanReputationProfile
    let organizerStats: PickupCreatorPublicRatingStats?
    let favoriteTeams: [FavoriteTeam]
    let isBusinessAccount: Bool
    /// True when `user_profiles` row was loaded from network or cache (not purely synthetic).
    let hasResolvedIdentity: Bool
}

enum PublicUserProfileService {
    private static let profileSelect =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids"

    /// Always returns a displayable profile; optional sections use safe fallbacks.
    static func load(userId: UUID, cachedProfile: UserProfileRow? = nil) async -> PublicUserProfileData {
#if DEBUG
        print("[PublicProfileLoadDebug] requestedUserId=\(userId.uuidString.lowercased())")
#endif

        var profileQuerySuccess = false
        var xpQuerySuccess = false
        var decodeError: String?
        var missingField: String?

        var row: UserProfileRow? = cachedProfile
        if let cached = cachedProfile, cached.id == userId {
            profileQuerySuccess = true
#if DEBUG
            print("[PublicProfileLoadDebug] profileQuerySuccess=true source=cache")
#endif
        } else {
            row = nil
        }

        if row == nil {
            let fetched = await fetchProfileRow(userId: userId)
            row = fetched.row
            profileQuerySuccess = fetched.success
            decodeError = fetched.decodeError
            missingField = fetched.missingField
#if DEBUG
            print("[PublicProfileLoadDebug] profileQuerySuccess=\(profileQuerySuccess)")
            if let decodeError { print("[PublicProfileLoadDebug] decodeError=\(decodeError)") }
            if let missingField { print("[PublicProfileLoadDebug] missingField=\(missingField)") }
#endif
        }

        let (fanXP, xpLoaded) = await loadPublicXP(userId: userId)
        xpQuerySuccess = xpLoaded
#if DEBUG
        print("[PublicProfileLoadDebug] xpQuerySuccess=\(xpQuerySuccess)")
#endif

        let organizerStats = await fetchOrganizerStats(userId: userId)
        let favoriteTeams = await fetchPublicFavoriteTeams(userId: userId)

        let isBusiness = await resolveIsBusinessAccount(userId: userId, profileRow: row)

        let built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: fanXP,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            isBusinessAccount: isBusiness,
            hasResolvedIdentity: profileQuerySuccess
        )

#if DEBUG
        let chipNote = "see_preview_friendState_log"
        print("[PublicProfileLoadDebug] friendState=\(chipNote)")
        print(
            "[PublicProfileLoadDebug] finalProfile userId=\(built.userId.uuidString.lowercased()) name=\(built.displayName) handle=\(built.publicHandleLine) reputation=\(built.reputation.title) resolvedIdentity=\(built.hasResolvedIdentity) business=\(built.isBusinessAccount)"
        )
#endif

        return built
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
                if row.id == userId {
                    return ProfileFetchResult(row: row, success: true, decodeError: nil, missingField: nil)
                }
                return ProfileFetchResult(
                    row: row,
                    success: true,
                    decodeError: nil,
                    missingField: "id_mismatch"
                )
            }

            return ProfileFetchResult(row: nil, success: false, decodeError: nil, missingField: "no_rows")
        } catch {
            let err = String(describing: error)
            return ProfileFetchResult(row: nil, success: false, decodeError: err, missingField: nil)
        }
    }

    // MARK: - XP (read-only; never fails the sheet)

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
            print("[PublicProfileLoadDebug] xpQuery decode/network error=\(error.localizedDescription)")
#endif
        }

        return (FanXPState.rookie, false)
    }

    // MARK: - Assembly

    private static func fetchPublicFavoriteTeams(userId: UUID) async -> [FavoriteTeam] {
        let ids = await FavoriteTeamsSyncService.fetchTeamIDs(userId: userId)
        let teams = FavoriteTeamsStore.resolvedTeams(fromIDs: ids)
#if DEBUG
        print(
            "[PublicProfileTeamsDebug] userId=\(userId.uuidString.lowercased()) teamIds=\(ids.count) resolved=\(teams.count)"
        )
#endif
        return teams
    }

    private static func buildProfileData(
        userId: UUID,
        row: UserProfileRow?,
        fanXP: FanXPState,
        organizerStats: PickupCreatorPublicRatingStats?,
        favoriteTeams: [FavoriteTeam],
        isBusinessAccount: Bool,
        hasResolvedIdentity: Bool
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
                organizerStats: organizerStats
            )
        )

        return PublicUserProfileData(
            userId: userId,
            displayName: resolvedName,
            publicHandleLine: handleLine,
            bio: trimmedBio.isEmpty ? nil : trimmedBio,
            avatarURL: avatarFull.isEmpty ? nil : avatarFull,
            avatarThumbnailURL: avatarThumb.isEmpty ? nil : avatarThumb,
            fanXP: fanXP,
            reputation: reputation,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            isBusinessAccount: isBusinessAccount,
            hasResolvedIdentity: hasResolvedIdentity
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

            let stats = rows.first?.toPublicStats()
                ?? PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
            PickupOrganizerReputationDebug.log(creatorUserId: userId, stats: stats)
            return stats
        } catch {
#if DEBUG
            print("[PublicProfileLoadDebug] organizer_stats_skipped userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)")
#endif
            let fallback = PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
            PickupOrganizerReputationDebug.log(creatorUserId: userId, stats: fallback)
            return fallback
        }
    }
}
