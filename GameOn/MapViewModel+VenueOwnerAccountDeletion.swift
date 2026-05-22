import Foundation
import Supabase

private struct BusinessAccountDeletionParams: Encodable {
    let p_business_id: UUID
}

struct BusinessAccountDeletionPreviewVenue: Decodable, Identifiable, Equatable {
    let id: UUID
    let venueId: UUID?
    let venueName: String?
    let originType: String?
    let approvalStatus: String?
    let label: String?

    enum CodingKeys: String, CodingKey {
        case id
        case venueId = "venue_id"
        case venueName = "venue_name"
        case originType = "origin_type"
        case approvalStatus = "approval_status"
        case label
    }

    var displayName: String {
        let trimmed = venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unnamed venue" : trimmed
    }
}

struct BusinessAccountDeletionPreviewEvent: Decodable, Identifiable, Equatable {
    let id: UUID
    let venueName: String?
    let eventTitle: String?
    let sport: String?
    let league: String?
    let eventDate: String?
    let eventTime: String?
    let scheduledStartAt: String?
    let status: String?

    enum CodingKeys: String, CodingKey {
        case id
        case venueName = "venue_name"
        case eventTitle = "event_title"
        case sport
        case league
        case eventDate = "event_date"
        case eventTime = "event_time"
        case scheduledStartAt = "scheduled_start_at"
        case status
    }

    var displayVenueName: String {
        let trimmed = venueName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Unknown venue" : trimmed
    }

    var displayTitle: String {
        let trimmed = eventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Untitled game" : trimmed
    }
}

struct BusinessAccountDeletionPreview: Decodable, Equatable {
    let ok: Bool
    let businessId: UUID?
    let businessName: String?
    let businessVenuesToDelete: [BusinessAccountDeletionPreviewVenue]
    let communityVenuesToRelease: [BusinessAccountDeletionPreviewVenue]
    let pendingBusinessVenuesToDelete: [BusinessAccountDeletionPreviewVenue]
    let pendingCommunityClaimsToCancel: [BusinessAccountDeletionPreviewVenue]
    let gamesEventsToRemove: [BusinessAccountDeletionPreviewEvent]
    let businessVenueCount: Int
    let communityVenueCount: Int
    let eventCount: Int
    let photoCount: Int
    let pendingClaimCount: Int

    enum CodingKeys: String, CodingKey {
        case ok
        case businessId = "business_id"
        case businessName = "business_name"
        case businessVenuesToDelete = "business_venues_to_delete"
        case communityVenuesToRelease = "community_venues_to_release"
        case pendingBusinessVenuesToDelete = "pending_business_venues_to_delete"
        case pendingCommunityClaimsToCancel = "pending_community_claims_to_cancel"
        case gamesEventsToRemove = "games_events_to_remove"
        case businessVenueCount = "business_venue_count"
        case communityVenueCount = "community_venue_count"
        case eventCount = "event_count"
        case photoCount = "photo_count"
        case pendingClaimCount = "pending_claim_count"
    }
}

struct BusinessAccountDeletionResult: Decodable, Equatable {
    let ok: Bool
    let businessId: UUID?
    let businessName: String?
    let releasedVenueIds: [UUID]?
    let hardDeletedVenueIds: [UUID]?
    let deletedEventIds: [UUID]?
    let deletedStoragePaths: [String]?
    let businessVenueCount: Int?
    let communityVenueCount: Int?
    let eventCount: Int?
    let photoCount: Int?
    let pendingClaimCount: Int?

    enum CodingKeys: String, CodingKey {
        case ok
        case businessId = "business_id"
        case businessName = "business_name"
        case releasedVenueIds = "released_venue_ids"
        case hardDeletedVenueIds = "hard_deleted_venue_ids"
        case deletedEventIds = "deleted_event_ids"
        case deletedStoragePaths = "deleted_storage_paths"
        case businessVenueCount = "business_venue_count"
        case communityVenueCount = "community_venue_count"
        case eventCount = "event_count"
        case photoCount = "photo_count"
        case pendingClaimCount = "pending_claim_count"
    }
}

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
        case missingBusiness

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
            case .missingBusiness:
                return "No active business account was found for deletion."
            }
        }
    }

    func businessAccountDeletionPreview(businessId: UUID) async throws -> BusinessAccountDeletionPreview {
        try await validateBusinessDeletionSession()
        let response: BusinessAccountDeletionPreview = try await supabase
            .rpc(
                "business_account_deletion_preview",
                params: BusinessAccountDeletionParams(p_business_id: businessId)
            )
            .execute()
            .value
        return response
    }

    func deleteBusinessAccountCascade(businessId: UUID) async throws -> BusinessAccountDeletionResult {
        try await validateBusinessDeletionSession()

        let eventIDsBeforeRPC = await MainActor.run {
            Set(venueEventRows.compactMap(\.id))
        }

        await stopVenueOwnerAnalyticsRealtime()
        await removeAllVenueEventCommentsRealtimeListeners()
        for eventID in eventIDsBeforeRPC {
            await stopVenueEventPredictionRealtime(for: eventID)
        }

        let response: BusinessAccountDeletionResult = try await supabase
            .rpc(
                "delete_business_account_cascade",
                params: BusinessAccountDeletionParams(p_business_id: businessId)
            )
            .execute()
            .value

        guard response.ok else {
            throw VenueOwnerAccountDeletionError.server("serverRejected", detail: nil)
        }

        let deletedEventIDs = Set(response.deletedEventIds ?? [])
        for eventID in eventIDsBeforeRPC.union(deletedEventIDs) {
            await stopVenueEventPredictionRealtime(for: eventID)
            await stopVenueEventCommentReactionRefresh(for: eventID)
            await stopVenueEventCommentsRealtime(for: eventID)
        }

        await deleteBusinessAccountStorageObjectsBestEffort(paths: response.deletedStoragePaths ?? [])
#if DEBUG
        print("[BusinessDeletionStateDebug] businessDeleted=true")
#endif
        await clearBusinessAccountLocalStateAfterDeletion()
        await logoutUser()
#if DEBUG
        print("[BusinessDeletionStateDebug] signedOutAfterBusinessDelete=true")
#endif
        await loadVenuesFromSupabase(forceRefresh: true)
        return response
    }

    private func validateBusinessDeletionSession() async throws {
        let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard isVenueOwnerLoggedIn, OwnerBusinessEmail.isValidStrict(ownerEmail) else {
            throw VenueOwnerAccountDeletionError.notVenueOwnerSignedIn
        }

        let session = try await supabase.auth.session
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")

        guard OwnerBusinessEmail.isValidStrict(sessionEmail), sessionEmail == ownerEmail else {
            throw VenueOwnerAccountDeletionError.emailMismatch
        }
    }

    private func deleteBusinessAccountStorageObjectsBestEffort(paths: [String]) async {
        let deletedStoragePaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !deletedStoragePaths.isEmpty else { return }

#if DEBUG
        for path in deletedStoragePaths {
            print("[BusinessAccountDeleteStorageDebug] deletingPath=\(path)")
        }
#endif

        do {
            try await supabase.storage
                .from("venue-photos")
                .remove(paths: deletedStoragePaths)
#if DEBUG
            print("[BusinessAccountDeleteStorageCleanup] removed count=\(deletedStoragePaths.count)")
#endif
        } catch {
#if DEBUG
            print("[BusinessAccountDeleteStorageCleanup] failed count=\(deletedStoragePaths.count) error=\(error.localizedDescription)")
#endif
        }
    }

    private func clearBusinessAccountLocalStateAfterDeletion() async {
        await MainActor.run {
            clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: ownerVenueDatabaseId)
            clearVenueOwnerOwnedBusinessCaches()
            pendingVenueClaimsForSettings = []
            rejectedVenueClaimsForSettings = []
            venueClaims = []
            approvedVenueOwnershipByVenueID = [:]
            hasUnackedRejectedVenueClaimForOwnerEmail = false
            venueClaimSubmitted = false
            venueClaimStatus = "Not submitted"
            venueIsApproved = false
            selectedBar = nil
            selectedEvent = nil
            venueEventRows = []
            venueEventIDsByKey = [:]
            venueEventInterestIDs = []
            venueEventInterestCounts = [:]
            goingProfilesByVenueEventID = [:]
            venueEventPredictionSummaries = [:]
        }
    }

    /// Calls the `delete-venue-owner-account` Edge Function and clears local venue-owner state on success.
    /// - Important: This requires the current Supabase session email to match `venueOwnerEmail`.
    func requestPermanentVenueOwnerAccountDeletion() async throws {
        let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard isVenueOwnerLoggedIn, OwnerBusinessEmail.isValidStrict(ownerEmail) else {
            throw VenueOwnerAccountDeletionError.notVenueOwnerSignedIn
        }

        let session = try await supabase.auth.session
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")

        guard OwnerBusinessEmail.isValidStrict(sessionEmail), sessionEmail == ownerEmail else {
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
            clearAuthenticatedSessionCaches()
            clearVenueOwnerDraftState()
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            venueAuthErrorMessage = ""
        }

        clearPersistedAccountMode()
    }
}

