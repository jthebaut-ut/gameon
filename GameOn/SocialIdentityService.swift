import Foundation
import Supabase

/// Resolves social-facing identities for both regular users (`user_profiles`) and business owners (`businesses`).
struct SocialIdentityService {
    private let client: SupabaseClient

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

    /// Returns synthetic profile rows keyed by email so existing social/comment UI can keep using `UserProfileRow`.
    func fetchUserProfileRows(forEmails emails: [String]) async throws -> [UserProfileRow] {
        let map = try await fetchIdentityMapByEmail(emails)
        return map.values.map(\.userProfileRow)
    }

    private func fetchIdentityMapByUserId(
        _ userIds: [UUID],
        fallbackDisplayNamesByUserId: [UUID: String]
    ) async throws -> [UUID: ResolvedIdentity] {
        let ids = Array(Set(userIds))
        guard !ids.isEmpty else { return [:] }

        let profiles: [UserProfileRow] = (try? await client
            .from("user_profiles")
            .select("id,email,display_name,avatar_url,avatar_thumbnail_url,admin_status")
            .in("id", values: ids)
            .eq("admin_status", value: "active")
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
                businessesByUserId[userId] = row
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
            .select("id,email,display_name,avatar_url,avatar_thumbnail_url,admin_status")
            .in("email", values: normalizedEmails)
            .eq("admin_status", value: "active")
            .execute()
            .value) ?? []

        let businesses: [BusinessRow] = (try? await client
            .from("businesses")
            .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
            .in("owner_email", values: normalizedEmails)
            .eq("admin_status", value: "active")
            .execute()
            .value) ?? []

        var profilesByEmail: [String: UserProfileRow] = [:]
        for row in profiles {
            let email = OwnerBusinessEmail.normalized(row.email ?? "")
            guard OwnerBusinessEmail.isValidStrict(email) else { continue }
            profilesByEmail[email] = row
        }

        var businessesByEmail: [String: BusinessRow] = [:]
        for row in businesses {
            let email = OwnerBusinessEmail.normalized(row.owner_email ?? "")
            guard OwnerBusinessEmail.isValidStrict(email) else { continue }
            if businessesByEmail[email] == nil || !trimmedNonEmpty(row.display_name).isEmpty {
                businessesByEmail[email] = row
            }
        }

        var out: [String: ResolvedIdentity] = [:]
        for email in normalizedEmails {
            if let identity = resolveIdentity(
                profile: profilesByEmail[email],
                business: businessesByEmail[email],
                fallbackUserId: profilesByEmail[email]?.id ?? businessesByEmail[email]?.owner_user_id,
                fallbackEmail: email
            ) {
                out[email] = identity
            }
        }
        return out
    }

    private func resolveIdentity(
        profile: UserProfileRow?,
        business: BusinessRow?,
        fallbackUserId: UUID?,
        fallbackEmail: String?
    ) -> ResolvedIdentity? {
        if let business {
            let email = OwnerBusinessEmail.normalized(business.owner_email ?? fallbackEmail ?? "")
            guard OwnerBusinessEmail.isValidStrict(email) else { return nil }
            let name = trimmedNonEmpty(business.display_name).isEmpty ? email : trimmedNonEmpty(business.display_name)
            return ResolvedIdentity(
                userId: business.owner_user_id ?? profile?.id ?? fallbackUserId,
                email: email,
                displayName: name,
                avatarURL: nil,
                avatarThumbnailURL: nil,
                isBusinessAccount: true
            )
        }

        let email = OwnerBusinessEmail.normalized(profile?.email ?? fallbackEmail ?? "")
        guard OwnerBusinessEmail.isValidStrict(email) else { return nil }

        let provided = trimmedNonEmpty(profile?.display_name)
        let displayName: String
        if !provided.isEmpty {
            displayName = provided
        } else {
            let local = email.split(separator: "@").first.map(String.init) ?? ""
            displayName = local.isEmpty ? "Player" : local
        }

        return ResolvedIdentity(
            userId: profile?.id ?? fallbackUserId,
            email: email,
            displayName: displayName,
            avatarURL: profile?.avatar_url,
            avatarThumbnailURL: profile?.avatar_thumbnail_url,
            isBusinessAccount: false
        )
    }

    private func trimmedNonEmpty(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private struct ResolvedIdentity {
        let userId: UUID?
        let email: String
        let displayName: String
        let avatarURL: String?
        let avatarThumbnailURL: String?
        let isBusinessAccount: Bool

        var preview: UserPreview {
            UserPreview(
                id: userId ?? UUID(),
                displayName: displayName,
                email: email,
                avatarURL: avatarURL,
                avatarThumbnailURL: avatarThumbnailURL,
                isBusinessAccount: isBusinessAccount
            )
        }

        var userProfileRow: UserProfileRow {
            UserProfileRow(
                id: userId,
                email: email,
                display_name: displayName,
                avatar_url: avatarURL,
                avatar_thumbnail_url: avatarThumbnailURL,
                is_business_account: isBusinessAccount,
                admin_status: "active"
            )
        }
    }
}
