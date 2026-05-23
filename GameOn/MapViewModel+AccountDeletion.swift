import Foundation
import Supabase

// Fan account deletion via `public.request_delete_my_account()` RPC.

extension MapViewModel {

    struct AccountDeletionResult: Decodable, Equatable {
        let ok: Bool
        let deletedUserId: UUID?
        let normalizedEmail: String?
        let affectedCounts: [String: Int]
        let avatarStoragePaths: [String]

        enum CodingKeys: String, CodingKey {
            case ok
            case deletedUserId = "deleted_user_id"
            case normalizedEmail = "normalized_email"
            case affectedCounts = "affected_counts"
            case avatarStoragePaths = "avatar_storage_paths"
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            ok = try container.decode(Bool.self, forKey: .ok)
            deletedUserId = try container.decodeIfPresent(UUID.self, forKey: .deletedUserId)
            normalizedEmail = try container.decodeIfPresent(String.self, forKey: .normalizedEmail)
            affectedCounts = (try? container.decodeIfPresent([String: Int].self, forKey: .affectedCounts)) ?? [:]
            avatarStoragePaths = (try? container.decodeIfPresent([String].self, forKey: .avatarStoragePaths)) ?? []
        }
    }

    enum AccountDeletionError: LocalizedError {
        case notSignedIn
        case venueOwnerMustUseVenueFlow
        case server(String, detail: String?)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .notSignedIn:
                return "Sign in as a fan to delete your account."
            case .venueOwnerMustUseVenueFlow:
                return "Venue owner deletion is not available yet. Sign in with a fan account or contact support."
            case let .server(code, detail):
                if let detail, !detail.isEmpty {
                    return "Could not delete account (\(code)): \(detail)"
                }
                return "Could not delete account (\(code))."
            case .unexpectedResponse:
                return "Unexpected response from account deletion service."
            }
        }
    }

    /// Calls `request_delete_my_account`, cleans returned avatar objects best-effort, then clears local fan state and signs out.
    /// - Note: Fan sessions only. Venue-owner sessions are rejected until Phase 2B.
    func requestPermanentAccountDeletion() async throws {
#if DEBUG
        print("[AccountDeletionDebug] started=true")
#endif
        guard isLoggedIn, !currentUserEmail.isEmpty else {
#if DEBUG
            print("[AccountDeletionDebug] error=notSignedIn")
#endif
            throw AccountDeletionError.notSignedIn
        }
        guard !isVenueOwnerLoggedIn else {
#if DEBUG
            print("[AccountDeletionDebug] error=venueOwnerMustUseVenueFlow")
#endif
            throw AccountDeletionError.venueOwnerMustUseVenueFlow
        }
        let originalEmail = OwnerBusinessEmail.normalized(currentUserEmail)

        let response: AccountDeletionResult
        do {
            response = try await supabase
                .rpc("request_delete_my_account")
                .execute()
                .value
        } catch {
#if DEBUG
            print("[AccountDeletionDebug] error=rpcFailed \(error.localizedDescription)")
#endif
            throw error
        }

        guard response.ok else {
#if DEBUG
            print("[AccountDeletionDebug] error=unexpectedResponse")
#endif
            throw AccountDeletionError.unexpectedResponse
        }

#if DEBUG
        print("[AccountDeletionDebug] rpcSuccess=true")
        print("[AccountDeletionDebug] affectedCounts=\(response.affectedCounts)")
        print("[AccountDeletionDebug] avatarCleanupStarted=\(!response.avatarStoragePaths.isEmpty)")
#endif
        anonymizeLoadedFanChatAuthorLocally(
            originalEmail: response.normalizedEmail ?? originalEmail,
            deletedUserId: response.deletedUserId
        )
        let avatarCleanupSucceeded = await deleteAccountAvatarStoragePathsBestEffort(response.avatarStoragePaths)
#if DEBUG
        print("[AccountDeletionDebug] avatarCleanupSuccess=\(avatarCleanupSucceeded)")
        print("[AccountDeletionDebug] signOutStarted=true")
#endif

        await forceLogout(reason: "accountDeletionCompleted", source: "MapViewModel.requestDeleteMyAccount")
#if DEBUG
        print("[AccountDeletionDebug] completed=true")
#endif
    }

    private func deleteAccountAvatarStoragePathsBestEffort(_ paths: [String]) async -> Bool {
        let safePaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !safePaths.isEmpty else { return true }

        var allSucceeded = true
        for path in safePaths {
            do {
                try await supabase.storage
                    .from("user-avatars")
                    .remove(paths: [path])
            } catch {
                allSucceeded = false
#if DEBUG
                print("[AccountDeletionDebug] error=avatarCleanupFailed path=\(path) \(error.localizedDescription)")
#endif
            }
        }
        return allSucceeded
    }

    /// Resets fan-specific UI state and profile cache; does not clear venue-owner fields.
    private func clearFanAccountLocalStateAfterDeletion() async {
        await forceLogout(reason: "accountDeletionCompleted", source: "MapViewModel.clearFanAccountLocalStateAfterDeletion")
    }
}
