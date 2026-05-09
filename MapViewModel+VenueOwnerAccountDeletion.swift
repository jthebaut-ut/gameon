import Foundation
import Supabase

// Phase 2B: venue owner account deletion via Edge Function `delete-venue-owner-account`.
// - Preserves venue pins by clearing `venues.owner_email` instead of deleting venue rows.
// - Uses Edge Function + service role on backend; no admin keys in the iOS app.

extension MapViewModel {

    private struct DeleteVenueOwnerAccountResponse: Decodable {
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

    enum VenueOwnerAccountDeletionError: LocalizedError {
        case notVenueOwnerSignedIn
        case emailMismatch
        case server(String, detail: String?)
        case functionsFailure(FunctionsError)

        var errorDescription: String? {
            switch self {
            case .notVenueOwnerSignedIn:
                return "Sign in as a venue owner to delete the venue owner account."
            case .emailMismatch:
                return "The signed-in session does not match this venue owner email. Please sign in again and retry."
            case let .server(code, detail):
                if let detail, !detail.isEmpty {
                    return "Could not delete venue owner account (\(code)): \(detail)"
                }
                return "Could not delete venue owner account (\(code))."
            case .functionsFailure(let err):
                return err.localizedDescription
            }
        }
    }

    /// Calls the `delete-venue-owner-account` Edge Function and clears local venue-owner state on success.
    /// - Important: This requires the current Supabase session email to match `venueOwnerEmail`.
    func requestPermanentVenueOwnerAccountDeletion() async throws {
        guard isVenueOwnerLoggedIn, !venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VenueOwnerAccountDeletionError.notVenueOwnerSignedIn
        }

        let session = try await supabase.auth.session
        let sessionEmail = (session.user.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let ownerEmail = venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        guard !sessionEmail.isEmpty, sessionEmail == ownerEmail else {
            throw VenueOwnerAccountDeletionError.emailMismatch
        }

        let response: DeleteVenueOwnerAccountResponse
        do {
            response = try await supabase.functions.invoke(
                "delete-venue-owner-account",
                options: FunctionInvokeOptions(method: .post)
            )
        } catch let error as FunctionsError {
            if case let .httpError(_, data) = error,
               let body = try? JSONDecoder().decode(DeleteVenueOwnerAccountResponse.self, from: data) {
                throw VenueOwnerAccountDeletionError.server(body.error ?? "http_error", detail: body.detail)
            }
            throw VenueOwnerAccountDeletionError.functionsFailure(error)
        }

        guard response.ok else {
            throw VenueOwnerAccountDeletionError.server(response.error ?? "unknown", detail: response.detail)
        }

        await clearVenueOwnerLocalStateAfterDeletion()

        do {
            try await supabase.auth.signOut()
        } catch {
#if DEBUG
            print("VenueOwnerDeletion: signOut after delete (expected to fail sometimes):", error)
#endif
        }
    }

    private func clearVenueOwnerLocalStateAfterDeletion() async {
        await MainActor.run {
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            venueOwnerEmail = ""

            venueClaimSubmitted = false
            venueClaimStatus = "Not submitted"
            venueIsApproved = false
            venueClaimSubmittedDate = ""
            venueAuthErrorMessage = ""

            ownerVenueName = ""
            ownerVenueAddress = ""
            ownerVenueCity = ""
            ownerVenueState = "UT"
            ownerVenueZipCode = ""
            ownerVenuePhone = ""
            ownerVenueWebsite = ""
            ownerVenueDescription = ""
            ownerVenueFeatures = ""
            ownerVenuePrimarySport = "Soccer"

            venueCoverPhotoURL = ""
            venueMenuPhotoURL = ""
            venueCrowdPhotoURL = ""
            venueTVWallPhotoURL = ""
            venueSpecialsPhotoURL = ""
            venueProofNote = ""

            venuePasswordResetMessage = ""
            venuePasswordResetError = ""
        }
    }
}

