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
struct PublicUserProfileData {
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
    let primaryFavoriteTeamID: String?
    let nationalTeam: NationalTeamIdentity?
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
    let homeCrowd: HomeCrowdVenueSummary?
    let pickupHostedCount: Int
    let pickupJoinedCount: Int
    let socialHighlightLabels: [String]
    let personalityTags: [String]
    let sharedTeamNames: [String]
}

/// Compact venue chip for public profile cards (city only — no coordinates).
struct PublicProfileVenueCard: Equatable, Identifiable {
    let venueId: UUID?
    let venueName: String
    let cityLabel: String
    let thumbnailURL: String?

    var id: String {
        venueId?.uuidString.lowercased() ?? "\(venueName)-\(cityLabel)"
    }
}

/// Mutual friend avatar for stacked display.
struct PublicProfileMutualFanAvatar: Equatable, Identifiable {
    let userId: UUID
    let displayName: String
    let avatarURL: String?

    var id: UUID { userId }
}

enum PublicUserProfileService {
    private static let profileSelect =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_deleted,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids,discoverable_by_fans,created_at,national_team_country_code,national_team_country_name,national_team_flag,national_team_supporter_label,national_team_updated_at"

    /// Always returns a displayable profile; optional sections use safe fallbacks.
    static func load(userId: UUID, cachedProfile: UserProfileRow? = nil) async -> PublicUserProfileData {
#if DEBUG
        print("[PublicProfileLoadDebug] requestedUserId=\(userId.uuidString.lowercased())")
#endif
        if cachedProfile?.isDeletedAccount == true {
            return hiddenProfile(userId: userId)
        }

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
            selected_live_visibility_friend_ids: [],
            is_deleted: preview.isDeleted
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
        let primary_favorite_team_id: String?
        let mutual_fans_count: Int?
        let shared_teams_count: Int?
        let venue_count: Int?
        let pickup_hosted_count: Int?
        let pickup_joined_count: Int?
        let mutual_fan_avatars: [MutualFanRow]?
        let venue_cards: [VenueCardRow]?
        let fan_identity_preferences: FanIdentityPreferences?
        let shared_team_ids: [String]?
        let home_crowd_venue: HomeCrowdVenueSummary?
        let national_team_country_code: String?
        let national_team_country_name: String?
        let national_team_flag: String?
        let national_team_supporter_label: String?

        struct MutualFanRow: Decodable {
            let user_id: UUID?
            let display_name: String?
            let avatar_url: String?
        }

        struct VenueCardRow: Decodable {
            let venue_id: UUID?
            let venue_name: String?
            let city_label: String?
            let thumbnail_url: String?
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            visible = try c.decode(Bool.self, forKey: .visible)
            user_id = try? c.decode(UUID.self, forKey: .user_id)
            display_name = try? c.decode(String.self, forKey: .display_name)
            username = try? c.decode(String.self, forKey: .username)
            bio = try? c.decode(String.self, forKey: .bio)
            avatar_url = try? c.decode(String.self, forKey: .avatar_url)
            avatar_thumbnail_url = try? c.decode(String.self, forKey: .avatar_thumbnail_url)
            member_since = try? c.decode(String.self, forKey: .member_since)
            favorite_team_ids = try? c.decode([String].self, forKey: .favorite_team_ids)
            primary_favorite_team_id = try? c.decode(String.self, forKey: .primary_favorite_team_id)
            mutual_fans_count = try? c.decode(Int.self, forKey: .mutual_fans_count)
            shared_teams_count = try? c.decode(Int.self, forKey: .shared_teams_count)
            venue_count = try? c.decode(Int.self, forKey: .venue_count)
            pickup_hosted_count = try? c.decode(Int.self, forKey: .pickup_hosted_count)
            pickup_joined_count = try? c.decode(Int.self, forKey: .pickup_joined_count)
            mutual_fan_avatars = try? c.decode([MutualFanRow].self, forKey: .mutual_fan_avatars)
            venue_cards = try? c.decode([VenueCardRow].self, forKey: .venue_cards)
            shared_team_ids = try? c.decode([String].self, forKey: .shared_team_ids)
            national_team_country_code = try? c.decode(String.self, forKey: .national_team_country_code)
            national_team_country_name = try? c.decode(String.self, forKey: .national_team_country_name)
            national_team_flag = try? c.decode(String.self, forKey: .national_team_flag)
            national_team_supporter_label = try? c.decode(String.self, forKey: .national_team_supporter_label)
            if c.contains(.home_crowd_venue) {
                if (try? c.decodeNil(forKey: .home_crowd_venue)) == true {
                    home_crowd_venue = nil
                    print("[HomeCrowdDebug] publicRpcHomeCrowd= null")
                } else if let nested = try? c.superDecoder(forKey: .home_crowd_venue),
                          let lenient = HomeCrowdVenueSummary.decodeLenient(from: nested) {
                    home_crowd_venue = lenient
                    print(
                        "[HomeCrowdDebug] publicRpcHomeCrowd= venueId=\(lenient.venueId.uuidString.lowercased()) name=\(lenient.name) source=lenient"
                    )
                } else if let decoded = try? c.decode(HomeCrowdVenueSummary.self, forKey: .home_crowd_venue) {
                    home_crowd_venue = decoded
                    print(
                        "[HomeCrowdDebug] publicRpcHomeCrowd= venueId=\(decoded.venueId.uuidString.lowercased()) name=\(decoded.name) source=strict"
                    )
                } else {
                    home_crowd_venue = nil
                    print("[HomeCrowdDebug] publicRpcHomeCrowdDecodeFailed")
                }
            } else {
                home_crowd_venue = nil
                print("[HomeCrowdDebug] publicRpcHomeCrowd= missing_key")
            }

            if let prefs = try? c.decode(FanIdentityPreferences.self, forKey: .fan_identity_preferences) {
                fan_identity_preferences = prefs
            } else {
                fan_identity_preferences = nil
                print("[OpenToDebug] publicRpcPreferencesDecodeFailed")
            }
        }

        private enum CodingKeys: String, CodingKey {
            case visible
            case user_id
            case display_name
            case username
            case bio
            case avatar_url
            case avatar_thumbnail_url
            case member_since
            case favorite_team_ids
            case primary_favorite_team_id
            case mutual_fans_count
            case shared_teams_count
            case venue_count
            case pickup_hosted_count
            case pickup_joined_count
            case mutual_fan_avatars
            case venue_cards
            case fan_identity_preferences
            case shared_team_ids
            case home_crowd_venue
            case national_team_country_code
            case national_team_country_name
            case national_team_flag
            case national_team_supporter_label
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
            let prefs = payload.fan_identity_preferences ?? .empty
            print(
                "[OpenToDebug] publicRpcPreferences= ids=\(prefs.resolvedOpenToItemIDs) keyPresent=\(prefs.openToItemsKeyPresent)"
            )
            return payload
        } catch {
#if DEBUG
            print("[PublicProfileLoadDebug] identityRPC_failed error=\(error.localizedDescription)")
#endif
            print("[OpenToDebug] publicRpcPreferences= decode_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func fetchFanIdentityPreferences(userId: UUID) async -> FanIdentityPreferences? {
        struct Row: Decodable {
            let fan_identity_preferences: FanIdentityPreferences?
        }

        do {
            let rows: [Row] = try await supabase
                .from("user_profiles")
                .select("fan_identity_preferences")
                .eq("id", value: userId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            return rows.first?.fan_identity_preferences
        } catch {
            print("[OpenToDebug] fetchFanIdentityPreferences failed userId=\(userId.uuidString.lowercased()) error=\(error.localizedDescription)")
            return nil
        }
    }

    private static func resolvePublicHomeCrowd(_ rpcVenue: HomeCrowdVenueSummary?) -> HomeCrowdVenueSummary? {
        guard let rpcVenue else {
            print("[HomeCrowdDebug] decodedPublicHomeCrowd= nil")
            logRenderedHomeCrowd(nil)
            return nil
        }
        let trimmedName = rpcVenue.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            print(
                "[HomeCrowdDebug] decodedPublicHomeCrowd= rejected_empty_name venueId=\(rpcVenue.venueId.uuidString.lowercased())"
            )
            logRenderedHomeCrowd(nil)
            return nil
        }
        let normalized = normalizedHomeCrowdSummary(rpcVenue)
        print(
            "[HomeCrowdDebug] decodedPublicHomeCrowd= venueId=\(normalized.venueId.uuidString.lowercased()) name=\(normalized.name)"
        )
        logRenderedHomeCrowd(normalized.venueId)
        return normalized
    }

    private static func logRenderedHomeCrowd(_ venueId: UUID?) {
        let value = venueId?.uuidString.lowercased() ?? "nil"
        print("[HomeCrowdDebug] renderedHomeCrowd venueId=\(value)")
    }

    private static func fetchPublicHomeCrowdForLegacyProfile(userId: UUID) async -> HomeCrowdVenueSummary? {
        if let identity = await fetchPublicIdentityRPC(targetUserId: userId), identity.visible,
           let crowd = resolvePublicHomeCrowd(identity.home_crowd_venue) {
            print("[HomeCrowdDebug] legacyHomeCrowd= source=identity_rpc")
            return crowd
        }

        if let dedicated = await HomeCrowdService.fetchPublicHomeCrowdForFan(targetUserId: userId),
           let crowd = resolvePublicHomeCrowd(dedicated) {
            print("[HomeCrowdDebug] legacyHomeCrowd= source=dedicated_rpc")
            return crowd
        }

        if let pointer = await HomeCrowdService.fetchPublicHomeCrowdPointer(targetUserId: userId) {
            if let summary = await HomeCrowdService.fetchVenueSummaryForPublicProfile(
                venueId: pointer.venue_id,
                setAt: pointer.home_crowd_set_at,
                excludeUserId: userId
            ), let crowd = resolvePublicHomeCrowd(summary) {
                print("[HomeCrowdDebug] legacyHomeCrowd= source=venue_summary_rpc")
                return crowd
            }

            if let tableSummary = await HomeCrowdService.fetchVenueSummaryFromTable(
                venueId: pointer.venue_id,
                setAt: pointer.home_crowd_set_at
            ), let crowd = resolvePublicHomeCrowd(tableSummary) {
                print("[HomeCrowdDebug] legacyHomeCrowd= source=venues_table")
                return crowd
            }
        }

        print("[HomeCrowdDebug] legacyHomeCrowd= nil")
        logRenderedHomeCrowd(nil)
        return nil
    }

    private static func resolvePublicOpenToItems(
        preferences: FanIdentityPreferences,
        favoriteTeams: [FavoriteTeam],
        venueCount: Int,
        pickupHostedCount: Int,
        pickupJoinedCount: Int
    ) -> [PublicProfileOpenToItem] {
        print("[OpenToDebug] decodedOpenToItems= \(preferences.resolvedOpenToItemIDs)")
        let items = PublicProfileOpenToBuilder.items(
            preferences: preferences,
            favoriteTeams: favoriteTeams,
            venueCount: venueCount,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount
        )
        print("[OpenToDebug] renderedOpenToCount= \(items.count)")
        return items
    }

    private static func assembleFromIdentityRPC(
        _ rpc: PublicIdentityRPCResponse,
        userId: UUID,
        cachedProfile: UserProfileRow?
    ) async -> PublicUserProfileData {
        var teamIDs = rpc.favorite_team_ids ?? []
        let rpcPrimaryRaw = rpc.primary_favorite_team_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var primaryTeamID: String? = !rpcPrimaryRaw.isEmpty && teamIDs.contains(rpcPrimaryRaw)
            ? rpcPrimaryRaw
            : nil
        if primaryTeamID == nil, !teamIDs.isEmpty {
            let selection = await fetchPublicFavoriteTeamSelection(userId: userId)
            if !selection.teamIDs.isEmpty {
                teamIDs = selection.teamIDs
                primaryTeamID = selection.primaryTeamID
            }
        }
        let favoriteTeams = FavoriteTeamsStore.resolvedTeams(fromIDs: teamIDs)

        let resolvedBio = resolveProfileBio(rpcBio: rpc.bio, cachedBio: cachedProfile?.bio)
#if DEBUG
        print("[ProfileBioDebug] publicProfileLoadedBio=\(resolvedBio ?? "")")
#endif

        let row = UserProfileRow(
            id: userId,
            email: cachedProfile?.email,
            display_name: rpc.display_name,
            username: rpc.username,
            bio: resolvedBio,
            avatar_url: rpc.avatar_url,
            avatar_thumbnail_url: rpc.avatar_thumbnail_url,
            is_business_account: false,
            admin_status: "active",
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: [],
            discoverable_by_fans: true,
            national_team_country_code: rpc.national_team_country_code,
            national_team_country_name: rpc.national_team_country_name,
            national_team_flag: rpc.national_team_flag,
            national_team_supporter_label: rpc.national_team_supporter_label
        )

        let organizerStats = await fetchOrganizerStats(userId: userId)
        let venueCount = max(0, rpc.venue_count ?? 0)
        let pickupHosted = max(0, rpc.pickup_hosted_count ?? 0)
        let pickupJoined = max(0, rpc.pickup_joined_count ?? 0)
        var preferences = rpc.fan_identity_preferences ?? .empty
        if preferences.resolvedOpenToItemIDs.isEmpty,
           let fetched = await fetchFanIdentityPreferences(userId: userId) {
            preferences = fetched
            print("[OpenToDebug] publicRpcPreferences= used_profile_fetch ids=\(preferences.resolvedOpenToItemIDs)")
        }
        let sharedTeamNames = FavoriteTeamsStore.resolvedTeams(fromIDs: rpc.shared_team_ids ?? [])
            .map { ($0.shortCode?.isEmpty == false) ? $0.shortCode! : $0.name }
        let built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: FanXPState.rookie,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            primaryFavoriteTeamID: primaryTeamID,
            isBusinessAccount: false,
            hasResolvedIdentity: true,
            isPubliclyVisible: true,
            memberSinceLabel: resolveMemberSinceLabel(
                rpcMemberSince: rpc.member_since,
                profileCreatedAt: cachedProfile?.created_at
            ),
            openToItems: resolvePublicOpenToItems(
                preferences: preferences,
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
            venueCards: (rpc.venue_cards ?? []).compactMap { card in
                let name = (card.venue_name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return nil }
                let thumb = ImageDisplayURL.canonicalStorageURLString(card.thumbnail_url)
                return PublicProfileVenueCard(
                    venueId: card.venue_id,
                    venueName: name,
                    cityLabel: (card.city_label ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    thumbnailURL: thumb.isEmpty ? nil : thumb
                )
            },
            homeCrowd: resolvePublicHomeCrowd(rpc.home_crowd_venue),
            pickupHostedCount: pickupHosted,
            pickupJoinedCount: pickupJoined,
            sharedTeamNames: sharedTeamNames
        )

        logRenderedHomeCrowd(built.homeCrowd?.venueId)
        if let homeId = built.homeCrowd?.venueId {
            print("[HomeCrowd] publicProfile venueId=\(homeId.uuidString.lowercased())")
        }

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
            primaryFavoriteTeamID: nil,
            nationalTeam: nil,
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
            homeCrowd: nil,
            pickupHostedCount: 0,
            pickupJoinedCount: 0,
            socialHighlightLabels: [],
            personalityTags: [],
            sharedTeamNames: []
        )
    }

    // MARK: - Legacy fallback

    private static func loadLegacy(userId: UUID, cachedProfile: UserProfileRow?) async -> PublicUserProfileData {
        let fetched = await fetchProfileRow(userId: userId)
        let row: UserProfileRow?
        if let fetchedRow = fetched.row {
            row = fetchedRow
        } else if let cached = cachedProfile, cached.id == userId {
            row = cached
        } else {
            row = nil
        }
        let profileQuerySuccess = fetched.success || row != nil
#if DEBUG
        let loadedBio = row?.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        print("[ProfileBioDebug] publicProfileLoadedBio=\(loadedBio)")
#endif

        if row?.isDeletedAccount == true {
            return hiddenProfile(userId: userId)
        }

        let (fanXP, _) = await loadPublicXP(userId: userId)
        let organizerStats = await fetchOrganizerStats(userId: userId)
        let favoriteSelection = await fetchPublicFavoriteTeamSelection(userId: userId)
        let favoriteTeams = FavoriteTeamsStore.resolvedTeams(fromIDs: favoriteSelection.teamIDs)
        let isBusiness = await resolveIsBusinessAccount(userId: userId, profileRow: row)
        let discoverable = row?.discoverableByFans ?? true

        if isBusiness || discoverable == false {
            return hiddenProfile(userId: userId)
        }

        let venueCount = 0
        let pickupHosted = 0
        let pickupJoined = 0
        let preferences = await fetchFanIdentityPreferences(userId: userId) ?? .empty
        if preferences.resolvedOpenToItemIDs.isEmpty {
            print("[OpenToDebug] legacyLoadPreferences= empty_or_unavailable")
        } else {
            print("[OpenToDebug] legacyLoadPreferences= ids=\(preferences.resolvedOpenToItemIDs)")
        }

        let legacyHomeCrowd = await fetchPublicHomeCrowdForLegacyProfile(userId: userId)

        let built = buildProfileData(
            userId: userId,
            row: row,
            fanXP: fanXP,
            organizerStats: organizerStats,
            favoriteTeams: favoriteTeams,
            primaryFavoriteTeamID: favoriteSelection.primaryTeamID,
            isBusinessAccount: isBusiness,
            hasResolvedIdentity: profileQuerySuccess,
            isPubliclyVisible: true,
            memberSinceLabel: resolveMemberSinceLabel(
                rpcMemberSince: nil,
                profileCreatedAt: row?.created_at
            ),
            openToItems: resolvePublicOpenToItems(
                preferences: preferences,
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
            homeCrowd: legacyHomeCrowd,
            pickupHostedCount: pickupHosted,
            pickupJoinedCount: pickupJoined,
            sharedTeamNames: []
        )

        logRenderedHomeCrowd(built.homeCrowd?.venueId)
        return built
    }

    /// Resolves hero member-since from RPC `member_since` or `user_profiles.created_at` fallback.
    private static func resolveMemberSinceLabel(
        rpcMemberSince: String?,
        profileCreatedAt: String?
    ) -> String? {
        let candidates: [(source: String, raw: String?)] = [
            ("rpc_member_since", rpcMemberSince),
            ("profile_created_at", profileCreatedAt)
        ]

        for candidate in candidates {
            guard let raw = candidate.raw?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else { continue }
            if let label = PublicProfileMemberSinceFormatter.label(from: raw) {
                print("[PublicProfileMemberSince] rendered value=\(label) source=\(candidate.source)")
                return label
            }
            print(
                "[PublicProfileMemberSince] missing reason=unparseable source=\(candidate.source) raw=\(raw.prefix(48))"
            )
        }

        let rpcPresent = !(rpcMemberSince?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let profilePresent = !(profileCreatedAt?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !rpcPresent && !profilePresent {
            print("[PublicProfileMemberSince] missing reason=no_timestamp_fields")
        } else {
            print("[PublicProfileMemberSince] missing reason=all_candidates_unparseable")
        }
        return nil
    }

    private static func normalizedHomeCrowdSummary(_ summary: HomeCrowdVenueSummary) -> HomeCrowdVenueSummary {
        let thumb = ImageDisplayURL.canonicalStorageURLString(summary.thumbnailURL)
        return HomeCrowdVenueSummary(
            venueId: summary.venueId,
            name: summary.name,
            locationLabel: summary.locationLabel,
            thumbnailURL: thumb.isEmpty ? nil : thumb,
            setAtRaw: summary.setAtRaw,
            fanCount: summary.fanCount,
            fanAvatars: summary.fanAvatars
        )
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

    private static func fetchPublicFavoriteTeamSelection(userId: UUID) async -> FavoriteTeamsSyncService.FavoriteTeamSelection {
        await FavoriteTeamsSyncService.fetchTeamSelection(userId: userId)
    }

    private static func resolveProfileBio(rpcBio: String?, cachedBio: String?) -> String? {
        let rpcTrimmed = rpcBio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !rpcTrimmed.isEmpty { return rpcTrimmed }
        let cachedTrimmed = cachedBio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return cachedTrimmed.isEmpty ? nil : cachedTrimmed
    }

    private static func buildProfileData(
        userId: UUID,
        row: UserProfileRow?,
        fanXP: FanXPState,
        organizerStats: PickupCreatorPublicRatingStats?,
        favoriteTeams: [FavoriteTeam],
        primaryFavoriteTeamID: String?,
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
        homeCrowd: HomeCrowdVenueSummary?,
        pickupHostedCount: Int,
        pickupJoinedCount: Int,
        sharedTeamNames: [String]
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
            primaryFavoriteTeamID: {
                let raw = primaryFavoriteTeamID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !raw.isEmpty, favoriteTeams.contains(where: { $0.id == raw }) else { return nil }
                return raw
            }(),
            nationalTeam: row?.nationalTeamIdentity,
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
            homeCrowd: homeCrowd,
            pickupHostedCount: pickupHostedCount,
            pickupJoinedCount: pickupJoinedCount,
            socialHighlightLabels: socialHighlights(
                venueCount: venueCount,
                pickupHosted: pickupHostedCount,
                pickupJoined: pickupJoinedCount,
                sharedTeams: sharedTeamsCount
            ),
            personalityTags: [],
            sharedTeamNames: sharedTeamNames
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
