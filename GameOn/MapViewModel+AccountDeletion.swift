import Foundation
import Supabase

// Phase 2A: fan account deletion via Edge Function `delete-account` (no service_role in app).

extension MapViewModel {

    /// JSON body from `delete-account` Edge Function (success and error shapes).
    private struct DeleteAccountResponse: Decodable {
        let ok: Bool
        let error: String?
        let detail: String?
        let deletedUserId: String?

        enum CodingKeys: String, CodingKey {
            case ok
            case error
            case detail
            case deletedUserId = "deleted_user_id"
        }
    }

    enum AccountDeletionError: LocalizedError {
        case notSignedIn
        case venueOwnerMustUseVenueFlow
        case server(String, detail: String?)
        case functionsFailure(FunctionsError)
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
            case .functionsFailure(let err):
                return err.localizedDescription
            case .unexpectedResponse:
                return "Unexpected response from account deletion service."
            }
        }
    }

    /// Calls the `delete-account` Edge Function with the current session JWT, then clears local fan state and signs out.
    /// - Note: Fan sessions only. Venue-owner sessions are rejected until Phase 2B.
    func requestPermanentAccountDeletion() async throws {
        guard isLoggedIn, !currentUserEmail.isEmpty else {
            throw AccountDeletionError.notSignedIn
        }
        guard !isVenueOwnerLoggedIn else {
            throw AccountDeletionError.venueOwnerMustUseVenueFlow
        }

        let response: DeleteAccountResponse
        do {
            response = try await supabase.functions.invoke(
                "delete-account",
                options: FunctionInvokeOptions(method: .post)
            )
        } catch let error as FunctionsError {
            if case let .httpError(_, data) = error,
               let body = try? JSONDecoder().decode(DeleteAccountResponse.self, from: data) {
                throw AccountDeletionError.server(body.error ?? "http_error", detail: body.detail)
            }
            throw AccountDeletionError.functionsFailure(error)
        }

        guard response.ok else {
            throw AccountDeletionError.server(response.error ?? "unknown", detail: response.detail)
        }

        await clearFanAccountLocalStateAfterDeletion()

        do {
            try await supabase.auth.signOut()
        } catch {
#if DEBUG
            print("AccountDeletion: signOut after delete (expected to fail sometimes):", error)
#endif
        }
    }

    /// Resets fan-specific UI state and profile cache; does not clear venue-owner fields.
    private func clearFanAccountLocalStateAfterDeletion() async {
        await MainActor.run {
            UserDefaults.standard.removeObject(forKey: "cachedUserDisplayName")
            UserDefaults.standard.removeObject(forKey: "cachedUserAvatarURL")

            currentUserEmail = ""
            currentUserDisplayName = ""
            currentUserAvatarURL = ""
            goingUserProfiles = []
            goingProfilesByVenueEventID = [:]
            isLoggedIn = false

            favoriteVenueIDs = []
            interestedVenueEventKeys = []
            venueEventInterestIDs = []
            venueEventInterestCounts = [:]
            myVenueEventVibes = [:]
            userProfilesByEmail = [:]

            authErrorMessage = ""
            userPasswordResetMessage = ""
            userPasswordResetError = ""
        }
    }
}
