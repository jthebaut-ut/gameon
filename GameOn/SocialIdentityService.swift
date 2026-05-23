import Foundation
import Supabase

/// Resolves social-facing identities for both regular users (`user_profiles`) and business owners (`businesses`).
struct SocialIdentityService {
    private let client: SupabaseClient
    private static let userProfileSelectColumns =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_deleted,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids"

    init(client: SupabaseClient = supabase) {
        self.client = client
    }

    /// Business owners use `businesses.display_name` and no personal avatar; regular users use `user_profiles`.
    func fetchUserPreviews(
        for userIds: [UUID],
        fallbackDisplayNamesByUserId: [UUID: String] = [:]
    ) async throws -> [UUID: UserPreview] {
        let map = try await fetchIdentityMapByUserId(
            userIds,
            fallbackDisplayNamesByUserId: fallbackDisplayNamesByUserId
        )
        return map.reduce(into: [:]) { result, pair in
            result[pair.key] = pair.value.preview
        }
    }

    /// All active `user_profiles` rows for the given emails (fan + business rows may share a legacy email).
    func fetchUserProfileRows(forEmails emails: [String]) async throws -> [UserProfileRow] {
        let normalizedEmails = Array(
            Set(
                emails
                    .map(OwnerBusinessEmail.normalized)
                    .filter(OwnerBusinessEmail.isValidStrict)
            )
        )
        guard !normalizedEmails.isEmpty else { return [] }

        let profiles: [UserProfileRow] = (try? await client
            .from("user_profiles")
            .select(Self.userProfileSelectColumns)
            .in("email", values: normalizedEmails)
            .execute()
            .value) ?? []

        let businessOwnerUserIDs = (try? await activeBusinessOwnerUserIDs(for: profiles.compactMap(\.id))) ?? []
        return profiles.filter {
            $0.isDeletedAccount || $0.isRegularFanProfile(excludingBusinessOwnerUserIDs: businessOwnerUserIDs)
        }
    }

    private func activeBusinessOwnerUserIDs(for userIds: [UUID]) async throws -> Set<UUID> {
        let ids = Array(Set(userIds))
        guard !ids.isEmpty else { return [] }

        struct Row: Decodable {
            let owner_user_id: UUID?
        }

        let rows: [Row] = try await client
            .from("businesses")
            .select("owner_user_id")
            .in("owner_user_id", values: ids.map { $0.uuidString.lowercased() })
            .eq("admin_status", value: "active")
            .execute()
            .value

        return Set(rows.compactMap(\.owner_user_id))
    }

    private func fetchIdentityMapByUserId(
        _ userIds: [UUID],
        fallbackDisplayNamesByUserId: [UUID: String]
    ) async throws -> [UUID: ResolvedIdentity] {
        let ids = Array(Set(userIds))
        guard !ids.isEmpty else { return [:] }

        let profiles: [UserProfileRow] = (try? await client
            .from("user_profiles")
            .select(Self.userProfileSelectColumns)
            .in("id", values: ids)
            .execute()
            .value) ?? []

        let businesses: [BusinessRow] = (try? await client
            .from("businesses")
            .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
            .in("owner_user_id", values: ids)
            .eq("admin_status", value: "active")
            .execute()
            .value) ?? []
        let profilesById: [UUID: UserProfileRow] = Dictionary(uniqueKeysWithValues: profiles.compactMap { row -> (UUID, UserProfileRow)? in
            guard let id = row.id else { return nil }
            return (id, row)
        })

        var businessesByUserId: [UUID: BusinessRow] = [:]
        for row in businesses {
            guard let userId = row.owner_user_id else { continue }
            if businessesByUserId[userId] == nil || !trimmedNonEmpty(row.display_name).isEmpty {
                businessesByUserId[userId] = row
            }
        }

        let profileEmails = Array(
            Set(
                profiles.compactMap { row -> String? in
                    let email = OwnerBusinessEmail.normalized(row.email ?? "")
                    return OwnerBusinessEmail.isValidStrict(email) ? email : nil
                }
            )
        )
        if !profileEmails.isEmpty {
            let businessesByEmailRows: [BusinessRow] = (try? await client
                .from("businesses")
                .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
                .in("owner_email", values: profileEmails)
                .eq("admin_status", value: "active")
                .execute()
                .value) ?? []

            let businessByEmail = businessesByEmailRows.reduce(into: [String: BusinessRow]()) { result, row in
                let email = OwnerBusinessEmail.normalized(row.owner_email ?? "")
                guard OwnerBusinessEmail.isValidStrict(email) else { return }
                if result[email] == nil || !trimmedNonEmpty(row.display_name).isEmpty {
                    result[email] = row
                }
            }

            for (userId, profile) in profilesById {
                if businessesByUserId[userId] != nil { continue }
                let email = OwnerBusinessEmail.normalized(profile.email ?? "")
                guard OwnerBusinessEmail.isValidStrict(email), let row = businessByEmail[email] else { continue }
                if profile.isBusinessIdentity {
                    businessesByUserId[userId] = row
                    continue
                }
                if row.owner_user_id == userId {
                    businessesByUserId[userId] = row
                }
            }
        }

        let unresolvedFallbackNames = Array(
            Set(
                fallbackDisplayNamesByUserId.values
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        )
        var businessByDisplayName: [String: BusinessRow] = [:]
        if !unresolvedFallbackNames.isEmpty {
            let rows: [BusinessRow] = (try? await client
                .from("businesses")
                .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
                .in("display_name", values: unresolvedFallbackNames)
                .eq("admin_status", value: "active")
                .execute()
                .value) ?? []
            businessByDisplayName = rows.reduce(into: [String: BusinessRow]()) { result, row in
                let key = row.display_name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !key.isEmpty else { return }
                if result[key] == nil {
                    result[key] = row
                }
            }
        }

        var out: [UUID: ResolvedIdentity] = [:]
        for id in ids {
            var identity = resolveIdentity(
                profile: profilesById[id],
                business: businessesByUserId[id],
                fallbackUserId: id,
                fallbackEmail: profilesById[id]?.email
            )
            if identity == nil,
               let fallbackName = fallbackDisplayNamesByUserId[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
               !fallbackName.isEmpty,
               let matchedBusiness = businessByDisplayName[fallbackName] {
                identity = resolveIdentity(
                    profile: profilesById[id],
                    business: matchedBusiness,
                    fallbackUserId: id,
                    fallbackEmail: matchedBusiness.owner_email
                )
            }
            if let identity {
                out[id] = identity
            }
        }
        return out
    }

    private func fetchIdentityMapByEmail(_ emails: [String]) async throws -> [String: ResolvedIdentity] {
        let normalizedEmails = Array(
            Set(
                emails
                    .map(OwnerBusinessEmail.normalized)
                    .filter(OwnerBusinessEmail.isValidStrict)
            )
        )
        guard !normalizedEmails.isEmpty else { return [:] }

        let profiles: [UserProfileRow] = (try? await client
            .from("user_profiles")
            .select(Self.userProfileSelectColumns)
            .in("email", values: normalizedEmails)
            .execute()
            .value) ?? []

        let businesses: [BusinessRow] = (try? await client
            .from("businesses")
            .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
            .in("owner_email", values: normalizedEmails)
            .eq("admin_status", value: "active")
            .execute()
            .value) ?? []

        var businessesByEmail: [String: BusinessRow] = [:]
        for row in businesses {
            let email = OwnerBusinessEmail.normalized(row.owner_email ?? "")
            guard OwnerBusinessEmail.isValidStrict(email) else { continue }
            if businessesByEmail[email] == nil || !trimmedNonEmpty(row.display_name).isEmpty {
                businessesByEmail[email] = row
            }
        }

        var profilesByEmail: [String: UserProfileRow] = [:]
        for row in profiles {
            let email = OwnerBusinessEmail.normalized(row.email ?? "")
            guard OwnerBusinessEmail.isValidStrict(email) else { continue }
            let biz = businessesByEmail[email]
            func profilePriority(_ p: UserProfileRow) -> Int {
                guard let id = p.id else { return 0 }
                if let ownerId = biz?.owner_user_id, ownerId == id { return 2 }
                return p.isBusinessIdentity ? 1 : 0
            }
            if let existing = profilesByEmail[email] {
                if profilePriority(row) > profilePriority(existing) {
                    profilesByEmail[email] = row
                }
            } else {
                profilesByEmail[email] = row
            }
        }

        var out: [String: ResolvedIdentity] = [:]
        for email in normalizedEmails {
            let profile = profilesByEmail[email]
            let business = businessRowForEmailResolution(profile: profile, business: businessesByEmail[email])
            if let identity = resolveIdentity(
                profile: profile,
                business: business,
                fallbackUserId: profile?.id ?? businessesByEmail[email]?.owner_user_id,
                fallbackEmail: email
            ) {
                out[email] = identity
            }
        }
        return out
    }

    /// When a fan profile exists for an email, do not collapse identity to the business row with the same email.
    private func businessRowForEmailResolution(profile: UserProfileRow?, business: BusinessRow?) -> BusinessRow? {
        guard let business else { return nil }
        guard let profile, let pid = profile.id else { return business }
        if profile.isBusinessIdentity { return business }
        if business.owner_user_id == pid { return business }
        return nil
    }

    private func resolveIdentity(
        profile: UserProfileRow?,
        business: BusinessRow?,
        fallbackUserId: UUID?,
        fallbackEmail: String?
    ) -> ResolvedIdentity? {
        let profileEmail = OwnerBusinessEmail.normalized(profile?.email ?? fallbackEmail ?? "")
        if profile?.isDeletedAccount == true || profileEmail.hasSuffix("@deleted.fangeo.local") {
            guard OwnerBusinessEmail.isValidStrict(profileEmail) else { return nil }
            return ResolvedIdentity(
                userId: profile?.id ?? fallbackUserId,
                email: profileEmail,
                displayName: "Deleted User",
                username: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isBusinessAccount: false,
                isDeleted: true,
                liveVisibilityEnabled: false,
                liveVisibilityMode: .allFriends,
                selectedLiveVisibilityFriendIDs: []
            )
        }

        if let business {
            let email = OwnerBusinessEmail.normalized(business.owner_email ?? fallbackEmail ?? "")
            guard OwnerBusinessEmail.isValidStrict(email) else { return nil }
            let name = trimmedNonEmpty(business.display_name).isEmpty ? email : trimmedNonEmpty(business.display_name)
            return ResolvedIdentity(
                userId: business.owner_user_id ?? profile?.id ?? fallbackUserId,
                email: email,
                displayName: name,
                username: nil,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isBusinessAccount: true,
                isDeleted: false,
                liveVisibilityEnabled: true,
                liveVisibilityMode: .allFriends,
                selectedLiveVisibilityFriendIDs: []
            )
        }

        let email = OwnerBusinessEmail.normalized(profile?.email ?? fallbackEmail ?? "")
        guard OwnerBusinessEmail.isValidStrict(email) else { return nil }

        if let status = profile?.admin_status, status != "active" {
            return nil
        }

        let provided = trimmedNonEmpty(profile?.display_name)
        let displayName: String
        if !provided.isEmpty {
            displayName = provided
        } else {
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            displayName = local.isEmpty ? "Player" : local
        }

        let storedUsername = trimmedNonEmpty(profile?.username)

        return ResolvedIdentity(
            userId: profile?.id ?? fallbackUserId,
            email: email,
            displayName: displayName,
            username: storedUsername.isEmpty ? nil : FanGeoHandleRules.normalizeForStorage(storedUsername),
            avatarURL: profile?.avatar_url,
            avatarThumbnailURL: profile?.avatar_thumbnail_url,
            isBusinessAccount: profile?.isBusinessIdentity == true,
            isDeleted: false,
            liveVisibilityEnabled: profile?.isVisibleForLiveFriendPresence ?? true,
            liveVisibilityMode: profile?.liveVisibilityMode ?? .allFriends,
            selectedLiveVisibilityFriendIDs: Array(profile?.selectedLiveVisibilityFriendIDs ?? [])
        )
    }

    private func trimmedNonEmpty(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private struct ResolvedIdentity {
        let userId: UUID?
        let email: String
        let displayName: String
        let username: String?
        let avatarURL: String?
        let avatarThumbnailURL: String?
        let isBusinessAccount: Bool
        let isDeleted: Bool
        let liveVisibilityEnabled: Bool
        let liveVisibilityMode: LiveVisibilityMode
        let selectedLiveVisibilityFriendIDs: [UUID]

        var preview: UserPreview {
            UserPreview(
                id: userId ?? UUID(),
                displayName: displayName,
                username: username,
                email: email,
                avatarURL: avatarURL,
                avatarThumbnailURL: avatarThumbnailURL,
                isBusinessAccount: isBusinessAccount,
                isDeleted: isDeleted
            )
        }

        var userProfileRow: UserProfileRow {
            UserProfileRow(
                id: userId,
                email: email,
                display_name: displayName,
                username: username,
                bio: nil,
                avatar_url: avatarURL,
                avatar_thumbnail_url: avatarThumbnailURL,
                is_business_account: isBusinessAccount,
                admin_status: "active",
                live_visibility_enabled: liveVisibilityEnabled,
                live_visibility_mode: liveVisibilityMode.rawValue,
                selected_live_visibility_friend_ids: selectedLiveVisibilityFriendIDs,
                is_deleted: isDeleted
            )
        }
    }
}
