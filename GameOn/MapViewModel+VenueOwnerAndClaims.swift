import Foundation
import CoreLocation
import SwiftUI
import Supabase

private struct VenueEventAdminArchivePatch: Encodable {
    let admin_status: String
}

private struct VenueAdminStatusPatch: Encodable {
    let admin_status: String
}

private struct ReleaseOrDeleteBusinessVenueParams: Encodable {
    let p_venue_id: UUID
}

private struct BusinessVenueDeleteVerificationRow: Decodable {
    let id: UUID?
    let venue_name: String?
    let business_id: UUID?
    let owner_email: String?
    let admin_status: String?
    let origin_type: String?
}

struct BusinessVenueReleaseOrDeleteResult: Decodable {
    let ok: Bool
    let action: String?
    let venue_retained: Bool?
    let claim_released: Bool?
    let business_fields_cleared: Bool?
    let storage_paths_returned: Int?
    let venue_id: UUID?
    let business_id: UUID?
    let deleted_event_ids: [UUID]?
    let deleted_storage_paths: [String]?

    var releasedCommunityVenue: Bool {
        venue_retained == true || normalizedAction == "release"
    }

    var normalizedAction: String {
        action?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

private struct BusinessVenueDeletionLocalSnapshot {
    let ownerVenueDatabaseId: UUID?
    let ownedBusinessVenues: [VenueProfileRow]
    let legacyOwnerVenuesForEmailFallback: [VenueProfileRow]
    let bars: [BarVenue]
    let selectedBar: BarVenue?
    let selectedEvent: SportsEvent?
    let followingTabSavedVenues: [BarVenue]
    let favoriteVenueIDs: Set<UUID>
    let followingTabGoingItems: [FollowingGoingDisplayItem]
    let followingTabGoingInterestCounts: [UUID: Int]
    let venueEventRows: [VenueEventRow]
    let venueEventIDsByKey: [String: UUID]
    let venueEventInterestIDs: Set<UUID>
    let venueEventInterestCounts: [UUID: Int]
    let goingProfilesByVenueEventID: [UUID: [UserProfileRow]]
    let venueEventPredictionSummaries: [UUID: VenueEventPredictionSummary]
    let ownerVenueName: String
    let ownerVenueAddress: String
    let ownerVenueAddressLine2: String
    let ownerVenueCity: String
    let ownerVenueState: String
    let ownerVenueZipCode: String
    let ownerVenueCountry: String
    let ownerVenuePhoneDialISO: String
    let ownerVenuePhone: String
    let ownerVenueWebsite: String
    let ownerVenueDescription: String
    let ownerVenueFeatures: String
    let ownerVenueSupporterCountry: String
    let ownerVenueScreenCount: Int
    let ownerVenueServesFood: Bool
    let ownerVenueHasWifi: Bool
    let ownerVenueHasGarden: Bool
    let ownerVenueHasProjector: Bool
    let ownerVenuePetFriendly: Bool
    let venueCoverPhotoURL: String
    let venueMenuPhotoURL: String
    let venueCoverPhotoThumbnailURL: String
    let venueMenuPhotoThumbnailURL: String
}

private enum BusinessVenueDeletionError: LocalizedError {
    case notSignedIn
    case missingAuthSession
    case missingVenue
    case serverRejected

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in as the business owner to manage this venue."
        case .missingAuthSession:
            return "Please sign in again to delete this venue."
        case .missingVenue:
            return "Select a venue first."
        case .serverRejected:
            return "The venue change did not complete. Please try again."
        }
    }
}

// Venue-owner auth, `venue_claims` workflow, venue profile CRUD in `venues`, photo uploads, and related listings.

extension MapViewModel {

    static let hostedGameRPCDebugDetailsUserInfoKey = "BusinessHostedGameRPCDebugDetails"
    static let businessLocationRPCDebugDetailsUserInfoKey = "BusinessLocationRPCDebugDetails"

    // MARK: - Discover → claim this business (Phase A; no `venue_id` on insert yet)

    /// Captures public venue context from Discover and prefills owner claim/profile fields; requests Account tab + venue owner auth.
    func beginVenueClaimFromDiscover(bar: BarVenue) {
        pendingClaimVenueID = bar.id
        pendingClaimVenueName = bar.name
        pendingClaimVenueAddress = bar.address
        pendingClaimVenueCity = ""
        pendingClaimVenueState = ""
        pendingClaimVenuePhone = bar.phone
        pendingClaimVenueWebsite = ""
        pendingClaimPrimarySport = bar.primarySport

        ownerVenueName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        ownerVenueAddress = bar.address.trimmingCharacters(in: .whitespacesAndNewlines)
        ownerVenueAddressLine2 = ""
        ownerVenueCity = ""
        ownerVenueState = ""
        ownerVenueZipCode = ""
        ownerVenueCountry = BusinessLocationCountryPolicy.defaultCountryCode
        applyVenueOwnerPhoneFromCombined(bar.phone)
        ownerVenueWebsite = ""
        let sport = bar.primarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        ownerVenuePrimarySport = sport.isEmpty ? "Soccer" : sport

        if let cover = bar.coverPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !cover.isEmpty {
            venueCoverPhotoURL = cover
            venueCoverPhotoThumbnailURL = bar.coverPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        if let menu = bar.menuPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines), !menu.isEmpty {
            venueMenuPhotoURL = menu
            venueMenuPhotoThumbnailURL = bar.menuPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }

        switchToAccountForVenueClaim = true
        openVenueOwnerAuthSheetFromClaimFlow = true
    }

    func clearPendingVenueClaimContext() {
        pendingClaimVenueID = nil
        pendingClaimVenueName = ""
        pendingClaimVenueAddress = ""
        pendingClaimVenueCity = ""
        pendingClaimVenueState = ""
        pendingClaimVenuePhone = ""
        pendingClaimVenueWebsite = ""
        pendingClaimPrimarySport = ""
    }

    private static func companionVenueThumbnailFileName(for fullFileName: String) -> String {
        if let dot = fullFileName.lastIndex(of: "."), dot < fullFileName.endIndex {
            let base = String(fullFileName[..<dot])
            let ext = String(fullFileName[fullFileName.index(after: dot)...])
            return "\(base)_thumb.\(ext)"
        }
        return fullFileName + "_thumb.jpg"
    }

    private static func versionedVenuePhotoFileName(for fileName: String) -> String {
        let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = trimmed.isEmpty ? "venue.jpg" : trimmed
        let version = Int(Date().timeIntervalSince1970 * 1000)
        if let dot = source.lastIndex(of: "."), dot < source.endIndex {
            let base = String(source[..<dot])
            let ext = String(source[source.index(after: dot)...])
            return "\(base)-\(version).\(ext)"
        }
        return "\(source)-\(version).jpg"
    }

    /// True when ``auth.signUp`` failed because the email is already registered (wording varies by Supabase / network).
    private static func isVenueOwnerSignupDuplicateEmailError(_ message: String) -> Bool {
        let m = message
        if m.contains("user already registered") { return true }
        if m.contains("already registered") { return true }
        if m.contains("email address is already registered") { return true }
        if m.contains("email is already") { return true }
        if m.contains("already exists") { return true }
        if m.contains("duplicate") { return true }
        if m.contains("unique violation") { return true }
        // Some auth stacks surface the same phrase as sign-in when the email is taken.
        if m.contains("invalid login credentials") { return true }
        return false
    }

    /// Creates Supabase Auth user, `businesses` row, and first `venue_claims` row (no public `venues` insert). Rolls back auth if `businesses` insert is blocked (e.g. RLS).
    func registerVenueOwner(
        email: String,
        password: String,
        signup: BusinessOwnerSignupPayload,
        coverPhotoJPEGData: Data?,
        menuPhotoJPEGData: Data?,
        recordVenueGuidelinesAcceptance: Bool = false
    ) async {
        print("[EmailConfirmDebug] signupButtonTapped=true")
#if DEBUG
        let coverExists = coverPhotoJPEGData.map { !$0.isEmpty } ?? false
        let menuExists = menuPhotoJPEGData.map { !$0.isEmpty } ?? false
        print(
            "[BusinessSignup] registerVenueOwner entry email=\(OwnerBusinessEmail.normalized(email)) businessDisplayName=\(signup.businessDisplayName) coverPhotoExists=\(coverExists) coverPhotoBytes=\(coverPhotoJPEGData?.count ?? 0) menuPhotoExists=\(menuExists) menuPhotoBytes=\(menuPhotoJPEGData?.count ?? 0)"
        )
#endif

        await MainActor.run { venueAuthErrorMessage = "" }

        let ownerEmail = OwnerBusinessEmail.normalized(email)
        let businessName = signup.businessDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard OwnerBusinessEmail.isValidStrict(ownerEmail) else {
#if DEBUG
            print("[BusinessSignup] validation failed invalid_owner_email")
#endif
            await MainActor.run { venueAuthErrorMessage = OwnerBusinessEmail.invalidOwnerEmailUserMessage }
            print("[EmailConfirmDebug] formValidationFailed reason=invalid_email")
            return
        }

        guard let coverData = coverPhotoJPEGData, !coverData.isEmpty else {
#if DEBUG
            print("[BusinessSignup] validation failed main venue photo missing coverPhotoExists=false")
#endif
            await MainActor.run { venueAuthErrorMessage = "Main venue photo is required." }
            print("[EmailConfirmDebug] formValidationFailed reason=main_photo_required")
            return
        }

        if let formError = validationErrorForAddLocationClaimForm(signup.firstLocation, requireCoverPhotoURL: false) {
#if DEBUG
            print("[BusinessSignup] validation failed form_fields message=\(formError)")
#endif
            await MainActor.run { venueAuthErrorMessage = formError }
            print("[EmailConfirmDebug] formValidationFailed reason=business_form_fields")
            return
        }
        guard !businessName.isEmpty else {
#if DEBUG
            print("[BusinessSignup] validation failed business_name_empty")
#endif
            await MainActor.run { venueAuthErrorMessage = "Please enter your business name." }
            print("[EmailConfirmDebug] formValidationFailed reason=business_name_required")
            return
        }

#if DEBUG
        print("[BusinessSignup] validation passed proceeding to auth.signUp")
#endif
        print("[EmailConfirmDebug] formValidationPassed=true")

        let signUpResponse: AuthResponse
        do {
#if DEBUG
            print("[BusinessSignup] auth signup started email=\(ownerEmail)")
#endif
            print("[EmailConfirmDebug] callingAuthSignUp=true")
            signUpResponse = try await supabase.auth.signUp(
                email: ownerEmail,
                password: password,
                redirectTo: Self.emailVerificationRedirectURL
            )
            print("[EmailConfirmDebug] authSignUpSucceeded=true")
            print("[EmailConfirmDebug] authSignUpUserId=\(signUpResponse.user.id.uuidString.lowercased())")
            print("[EmailConfirmDebug] authSignUpSessionNil=\(signUpResponse.session == nil)")
        } catch {
#if DEBUG
            print("[BusinessSignup] auth signup error localized=\(error.localizedDescription) full=\(error)")
#endif
            print("[EmailConfirmDebug] authSignUpFailed error=\(String(reflecting: error)) localized=\(error.localizedDescription)")
            await MainActor.run {
                let message = error.localizedDescription.lowercased()

                if Self.isVenueOwnerSignupDuplicateEmailError(message) {
                    venueAuthErrorMessage = "An account already exists for this email. Try signing in instead."
                } else if message.contains("email rate limit") {
                    venueAuthErrorMessage = "Email signup rate limit reached. Try again later or disable email confirmation during development."
                } else if message.contains("email signups are disabled") {
                    venueAuthErrorMessage = "Email signups are disabled in Supabase. Enable the Email provider."
                } else {
                    venueAuthErrorMessage = "Could not create business account. Please check your information and try again."
                }
            }

            print("VENUE OWNER REGISTRATION ERROR:", error)
            return
        }

        let signUpSession = signUpResponse.session
        let restoredSession = try? await supabase.auth.session
        guard let session = signUpSession ?? restoredSession,
              Self.userEmailConfirmed(session.user) else {
#if DEBUG
            print("[BusinessSignup] auth signup no session after signUp (email confirmation or client state); signing out")
#endif
            await forceLogout(reason: "businessSignupNeedsEmailConfirmation", source: "MapViewModel.registerVenueOwner")
            await MainActor.run {
                pendingBusinessEmailSignupDraft = PendingBusinessEmailSignupDraft(
                    email: ownerEmail,
                    signup: signup,
                    coverPhotoJPEGData: coverPhotoJPEGData,
                    menuPhotoJPEGData: menuPhotoJPEGData,
                    recordVenueGuidelinesAcceptance: recordVenueGuidelinesAcceptance
                )
                markEmailVerificationPending(email: ownerEmail, kind: .business)
            }
            print("[EmailConfirmDebug] authUserCreatedPending=true")
            print("[EmailConfirmDebug] businessCreationDeferred=true")
            return
        }

        let ownerUserId = session.user.id

        if await businessBanGuardBlocks(
            path: "businessSignup",
            action: "registerVenueOwner",
            ownerEmail: ownerEmail,
            ownerUserId: ownerUserId
        ) {
            return
        }

        if await activeFanUserProfileExistsForEmail(ownerEmail) {
#if DEBUG
            print("[AuthAccountTypeGate] business registration blocked fanEmail=\(ownerEmail)")
#endif
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
            return
        }

#if DEBUG
        let jwtEmail = session.user.email ?? "nil"
        print(
            "[BusinessSignup] auth signup success authenticated_session_user_id=\(ownerUserId.uuidString) owner_user_id=\(ownerUserId.uuidString) jwt_email=\(jwtEmail)"
        )
#endif

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            venueOwnerEmail = ownerEmail
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isLoggedIn = false
            currentUserEmail = ""
            venueAuthErrorMessage = ""
            venueClaimSubmitted = false
            venueIsApproved = false
            venueClaimStatus = "Not submitted"
            venueClaimSubmittedDate = ""
            venueOwnerJustCompletedRegistration = false
            hasUnackedRejectedVenueClaimForOwnerEmail = false
            currentUserAuthId = ownerUserId
        }

        guard let coverURL = await uploadVenuePhoto(data: coverData, fileName: "cover.jpg", assignToCurrentVenueProfile: false) else {
#if DEBUG
            print("[BusinessSignup] cover upload failed post-auth (uploadVenuePhoto returned nil; see ERROR UPLOADING PHOTO log above) cover_upload_url_exists=false")
#endif
            await forceLogout(reason: "businessSignupCoverUploadFailed", source: "MapViewModel.registerVenueOwner")
            await MainActor.run {
                venueAuthErrorMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
            }
            return
        }

        var menuPublic = ""
        if let menuData = menuPhotoJPEGData, !menuData.isEmpty {
            menuPublic = (await uploadVenuePhoto(data: menuData, fileName: "menu.jpg", assignToCurrentVenueProfile: false)) ?? ""
        }

#if DEBUG
        let coverURLNonempty = !coverURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let menuURLNonempty = !menuPublic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        print(
            "[BusinessSignup] after uploads cover_photo_url_nonempty=\(coverURLNonempty) menu_photo_url_nonempty=\(menuURLNonempty) cover_url_prefix=\(String(coverURL.prefix(96))) menu_url_prefix=\(String(menuPublic.prefix(96)))"
        )
#endif

        let loc = signup.firstLocation
        let mergedLocationForm = AddLocationClaimForm(
            venueName: loc.venueName,
            address: loc.address,
            addressLine2: loc.addressLine2,
            city: loc.city,
            state: loc.state,
            country: loc.country,
            zip: loc.zip,
            phone: loc.phone,
            website: loc.website,
            description: loc.description,
            proofNote: loc.proofNote,
            screenCount: loc.screenCount,
            servesFood: loc.servesFood,
            hasWifi: loc.hasWifi,
            hasGarden: loc.hasGarden,
            hasProjector: loc.hasProjector,
            petFriendly: loc.petFriendly,
            familyFriendly: loc.familyFriendly,
            parkingAvailable: loc.parkingAvailable,
            easyParking: loc.easyParking,
            handicapParking: loc.handicapParking,
            liveMusic: loc.liveMusic,
            poolTables: loc.poolTables,
            rooftop: loc.rooftop,
            djNights: loc.djNights,
            karaoke: loc.karaoke,
            cocktails: loc.cocktails,
            craftBeer: loc.craftBeer,
            coverPhotoURL: coverURL,
            menuPhotoURL: menuPublic,
            latitude: loc.latitude,
            longitude: loc.longitude,
            formattedAddress: loc.formattedAddress
        )

        let businessPayload = BusinessInsertPayload(
            display_name: businessName,
            owner_email: ownerEmail,
            owner_user_id: ownerUserId,
            admin_status: "active"
        )

#if DEBUG
        print(
            "[BusinessSignup] business insert payload display_name=\(businessName) owner_email=\(ownerEmail) owner_user_id=\(ownerUserId.uuidString) admin_status=active"
        )
#endif

        let businessId: UUID
        do {
            let inserted: InsertedBusinessIdRow = try await supabase
                .from("businesses")
                .insert(businessPayload)
                .select("id")
                .single()
                .execute()
                .value
            businessId = inserted.id
#if DEBUG
            print("[BusinessSignup] business insert success business_id=\(businessId.uuidString) authenticated_session_user_id=\(ownerUserId.uuidString)")
#endif
        } catch {
#if DEBUG
            print("[BusinessSignup] business insert error localized=\(error.localizedDescription) full=\(error)")
#endif
            await forceLogout(reason: "businessSignupBusinessInsertFailed", source: "MapViewModel.registerVenueOwner")
            await MainActor.run {
                venueAuthErrorMessage =
                    "Could not create your business record. This is usually blocked by database permissions (RLS). An admin must allow authenticated business owners to insert into `businesses`, or creation must run on a secure backend."
            }
            print("BUSINESS INSERT ERROR (signup):", error)
            return
        }

        if let dupMsg = await VenueClaimDuplicateCheck.rpcPreflight(
            supabase: supabase,
            businessId: businessId,
            ownerEmail: ownerEmail,
            venueName: mergedLocationForm.venueName.trimmingCharacters(in: .whitespacesAndNewlines),
            venueAddress: mergedLocationForm.address.trimmingCharacters(in: .whitespacesAndNewlines),
            venueCity: mergedLocationForm.city.trimmingCharacters(in: .whitespacesAndNewlines),
            venueState: mergedLocationForm.state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            venueZip: mergedLocationForm.zip.trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
            await MainActor.run { venueAuthErrorMessage = dupMsg }
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            await refreshPendingVenueClaimsForSettings()
            checkVenueApprovalStatus()
            return
        }

        let claim = await venueClaimInsertForBusinessAddLocation(
            ownerEmail: ownerEmail,
            businessId: businessId,
            form: mergedLocationForm
        )

#if DEBUG
        let claimDebugJSON: String = {
            guard let data = try? JSONEncoder().encode(claim),
                  let s = String(data: data, encoding: .utf8) else {
                return "(encode failed)"
            }
            return s
        }()
        print(
            "[BusinessSignup] venue_claim insert payload json=\(claimDebugJSON)"
        )
#endif

        do {
            let rpcParams = CreateBusinessVenueClaimRPCParams(claim: claim, businessId: businessId)
#if DEBUG
            print("[BusinessLocationRPCParams] orderedKeys=\(rpcParams.debugKeys)")
#endif
            let insertedRows: [VenueClaimInsertedRow] = try await supabase
                .rpc(
                    "create_business_venue_claim",
                    params: rpcParams
                )
                .execute()
                .value
            guard let inserted = insertedRows.first else {
                throw NSError(
                    domain: "BusinessVenueClaim",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Location request submitted, but the app couldn’t read it back. Pull to refresh in a moment."]
                )
            }

#if DEBUG
            print(
                "[BusinessSignup] venue_claim rpc insert success claim_id=\(inserted.id.uuidString) approval_status=\(inserted.approval_status ?? "nil") created_at=\(inserted.created_at ?? "nil")"
            )
            print("[BusinessEntitlementGate] businessId=\(businessId.uuidString.lowercased()) operation=createVenue allowed=true reason=signupRpcInserted")
#endif

            await MainActor.run {
                isVenueOwnerLoggedIn = true
                venueOwnerMode = true
                authSessionState = .signedIn
#if DEBUG
                print("[AuthStateDebug] authStateTransition=businessSignup->signedIn")
#endif
                venueClaimSubmitted = true
                let statusRaw = inserted.approval_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let approved = statusRaw == "approved"
                venueIsApproved = approved
                if approved {
                    venueClaimStatus = "Approved"
                    hasUnackedRejectedVenueClaimForOwnerEmail = false
                } else if statusRaw.contains("reject") {
                    venueClaimStatus = "Rejected"
                    hasUnackedRejectedVenueClaimForOwnerEmail = true
                } else {
                    venueClaimStatus = "Pending Review"
                    hasUnackedRejectedVenueClaimForOwnerEmail = false
                }
                venueClaimSubmittedDate = inserted.created_at ?? ""
                venueAuthErrorMessage = ""
                venueOwnerJustCompletedRegistration = true
            }

#if DEBUG
            print("[BusinessSignup] final success state venueOwnerJustCompletedRegistration=true (success sheet should appear)")
#endif

            let notifyPayload = venueClaimAdminNotifyPayloadFromInsert(
                claim: claim,
                insertedId: inserted.id,
                createdAt: inserted.created_at,
                approvalStatus: inserted.approval_status,
                claimKind: "new_location",
                familyFriendly: mergedLocationForm.familyFriendly,
                parkingAvailable: mergedLocationForm.parkingAvailable
            )
            notifyVenueClaimAdminEmail(payload: notifyPayload)

            await persistAccountModeForActiveAuthSession(.businessOwner)

            clearExplicitLogoutMarkerAfterManualAuthSucceeded()

            if recordVenueGuidelinesAcceptance {
                UserDefaults.standard.set(true, forKey: "venueGuidelinesAccepted")
            }

            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            await refreshPendingVenueClaimsForSettings()

        } catch {
            print("VENUE CLAIM INSERT ERROR (signup):", error)
#if DEBUG
            Self.logVenueSubmissionRPCDebug(
                rpcName: "create_business_venue_claim",
                failingQuerySection: "signupVenueClaimInsert",
                error: error,
                businessId: businessId,
                venueId: claim.venue_id
            )
            print("[BusinessSignup] venue_claim insert error localized=\(error.localizedDescription) full=\(error)")
#endif
            let dup = VenueClaimDuplicateCheck.userMessageIfKnownInsertError(error)
            await MainActor.run {
                venueAuthErrorMessage = dup
                    ?? "Your account and business were created, but submitting the location request failed: \(error.localizedDescription). Use Add location in Settings, or contact support."
            }
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            await refreshPendingVenueClaimsForSettings()
            checkVenueApprovalStatus()
        }
    }

    func completePendingBusinessSignupAfterConfirmation(
        session: Session,
        draft: PendingBusinessEmailSignupDraft
    ) async -> Bool {
        let ownerEmail = OwnerBusinessEmail.normalized(session.user.email ?? draft.email)
        guard OwnerBusinessEmail.isValidStrict(ownerEmail),
              Self.userEmailConfirmed(session.user) else {
            return false
        }

        let signup = draft.signup
        let businessName = signup.businessDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let coverData = draft.coverPhotoJPEGData, !coverData.isEmpty else {
            await MainActor.run {
                venueAuthErrorMessage = "Main venue photo is required."
                emailVerificationError = venueAuthErrorMessage
            }
            return true
        }

        if await activeFanUserProfileExistsForEmail(ownerEmail) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
            return true
        }

        let ownerUserId = session.user.id
        await MainActor.run {
            clearAuthenticatedSessionCaches()
            venueOwnerEmail = ownerEmail
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isLoggedIn = false
            currentUserEmail = ""
            venueAuthErrorMessage = ""
            venueClaimSubmitted = false
            venueIsApproved = false
            venueClaimStatus = "Not submitted"
            venueClaimSubmittedDate = ""
            venueOwnerJustCompletedRegistration = false
            hasUnackedRejectedVenueClaimForOwnerEmail = false
            currentUserAuthId = ownerUserId
        }

        if await businessBanGuardBlocks(path: "businessSignup", action: "completePendingBusinessSignupAfterConfirmation") {
            return true
        }

        guard let coverURL = await uploadVenuePhoto(data: coverData, fileName: "cover.jpg", assignToCurrentVenueProfile: false) else {
            await forceLogout(reason: "businessSignupCoverUploadFailedAfterEmailConfirmation", source: "MapViewModel.completePendingBusinessSignupAfterConfirmation")
            await MainActor.run {
                venueAuthErrorMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                emailVerificationError = venueAuthErrorMessage
            }
            return true
        }

        var menuPublic = ""
        if let menuData = draft.menuPhotoJPEGData, !menuData.isEmpty {
            menuPublic = (await uploadVenuePhoto(data: menuData, fileName: "menu.jpg", assignToCurrentVenueProfile: false)) ?? ""
        }

        let loc = signup.firstLocation
        let mergedLocationForm = AddLocationClaimForm(
            venueName: loc.venueName,
            address: loc.address,
            addressLine2: loc.addressLine2,
            city: loc.city,
            state: loc.state,
            country: loc.country,
            zip: loc.zip,
            phone: loc.phone,
            website: loc.website,
            description: loc.description,
            proofNote: loc.proofNote,
            screenCount: loc.screenCount,
            servesFood: loc.servesFood,
            hasWifi: loc.hasWifi,
            hasGarden: loc.hasGarden,
            hasProjector: loc.hasProjector,
            petFriendly: loc.petFriendly,
            familyFriendly: loc.familyFriendly,
            parkingAvailable: loc.parkingAvailable,
            easyParking: loc.easyParking,
            handicapParking: loc.handicapParking,
            liveMusic: loc.liveMusic,
            poolTables: loc.poolTables,
            rooftop: loc.rooftop,
            djNights: loc.djNights,
            karaoke: loc.karaoke,
            cocktails: loc.cocktails,
            craftBeer: loc.craftBeer,
            coverPhotoURL: coverURL,
            menuPhotoURL: menuPublic,
            latitude: loc.latitude,
            longitude: loc.longitude,
            formattedAddress: loc.formattedAddress
        )

        let businessPayload = BusinessInsertPayload(
            display_name: businessName,
            owner_email: ownerEmail,
            owner_user_id: ownerUserId,
            admin_status: "active"
        )

        let businessId: UUID
        do {
            let inserted: InsertedBusinessIdRow = try await supabase
                .from("businesses")
                .insert(businessPayload)
                .select("id")
                .single()
                .execute()
                .value
            businessId = inserted.id
        } catch {
            await forceLogout(reason: "businessSignupBusinessInsertFailedAfterEmailConfirmation", source: "MapViewModel.completePendingBusinessSignupAfterConfirmation")
            await MainActor.run {
                venueAuthErrorMessage =
                    "Could not create your business record. This is usually blocked by database permissions (RLS). An admin must allow authenticated business owners to insert into `businesses`, or creation must run on a secure backend."
                emailVerificationError = venueAuthErrorMessage
            }
            print("BUSINESS INSERT ERROR (signup after confirmation):", error)
            return true
        }

        if let dupMsg = await VenueClaimDuplicateCheck.rpcPreflight(
            supabase: supabase,
            businessId: businessId,
            ownerEmail: ownerEmail,
            venueName: mergedLocationForm.venueName.trimmingCharacters(in: .whitespacesAndNewlines),
            venueAddress: mergedLocationForm.address.trimmingCharacters(in: .whitespacesAndNewlines),
            venueCity: mergedLocationForm.city.trimmingCharacters(in: .whitespacesAndNewlines),
            venueState: mergedLocationForm.state.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
            venueZip: mergedLocationForm.zip.trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
            await MainActor.run { venueAuthErrorMessage = dupMsg }
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            await refreshPendingVenueClaimsForSettings()
            checkVenueApprovalStatus()
            return true
        }

        let claim = await venueClaimInsertForBusinessAddLocation(
            ownerEmail: ownerEmail,
            businessId: businessId,
            form: mergedLocationForm
        )

        do {
            let rpcParams = CreateBusinessVenueClaimRPCParams(claim: claim, businessId: businessId)
#if DEBUG
            print("[BusinessLocationRPCParams] orderedKeys=\(rpcParams.debugKeys)")
#endif
            let insertedRows: [VenueClaimInsertedRow] = try await supabase
                .rpc(
                    "create_business_venue_claim",
                    params: rpcParams
                )
                .execute()
                .value
            guard let inserted = insertedRows.first else {
                throw NSError(
                    domain: "BusinessVenueClaim",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Location request submitted, but the app couldn’t read it back. Pull to refresh in a moment."]
                )
            }

#if DEBUG
            print("[BusinessEntitlementGate] businessId=\(businessId.uuidString.lowercased()) operation=createVenue allowed=true reason=emailConfirmationSignupRpcInserted")
#endif

            await MainActor.run {
                isVenueOwnerLoggedIn = true
                venueOwnerMode = true
                authSessionState = .signedIn
                venueClaimSubmitted = true
                let statusRaw = inserted.approval_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                let approved = statusRaw == "approved"
                venueIsApproved = approved
                if approved {
                    venueClaimStatus = "Approved"
                    hasUnackedRejectedVenueClaimForOwnerEmail = false
                } else if statusRaw.contains("reject") {
                    venueClaimStatus = "Rejected"
                    hasUnackedRejectedVenueClaimForOwnerEmail = true
                } else {
                    venueClaimStatus = "Pending Review"
                    hasUnackedRejectedVenueClaimForOwnerEmail = false
                }
                venueClaimSubmittedDate = inserted.created_at ?? ""
                venueAuthErrorMessage = ""
                venueOwnerJustCompletedRegistration = true
                pendingBusinessEmailSignupDraft = nil
                pendingEmailVerificationEmail = ""
                pendingEmailVerificationKind = nil
                emailVerificationError = ""
                emailVerificationMessage = "Email verified. Your business account was created."
            }

            let notifyPayload = venueClaimAdminNotifyPayloadFromInsert(
                claim: claim,
                insertedId: inserted.id,
                createdAt: inserted.created_at,
                approvalStatus: inserted.approval_status,
                claimKind: "new_location",
                familyFriendly: mergedLocationForm.familyFriendly,
                parkingAvailable: mergedLocationForm.parkingAvailable
            )
            notifyVenueClaimAdminEmail(payload: notifyPayload)

            await persistAccountModeForActiveAuthSession(.businessOwner)
            clearExplicitLogoutMarkerAfterManualAuthSucceeded()
            if draft.recordVenueGuidelinesAcceptance {
                UserDefaults.standard.set(true, forKey: "venueGuidelinesAccepted")
            }
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            await refreshPendingVenueClaimsForSettings()
        } catch {
            print("VENUE CLAIM INSERT ERROR (signup after confirmation):", error)
#if DEBUG
            Self.logVenueSubmissionRPCDebug(
                rpcName: "create_business_venue_claim",
                failingQuerySection: "emailConfirmationVenueClaimInsert",
                error: error,
                businessId: businessId,
                venueId: claim.venue_id
            )
#endif
            let dup = VenueClaimDuplicateCheck.userMessageIfKnownInsertError(error)
            await MainActor.run {
                venueAuthErrorMessage = dup
                    ?? "Your account and business were created, but submitting the location request failed: \(error.localizedDescription). Use Add location in Settings, or contact support."
                emailVerificationError = venueAuthErrorMessage
            }
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            await refreshPendingVenueClaimsForSettings()
            checkVenueApprovalStatus()
        }

        return true
    }

    // Signs in as venue owner and refreshes claim approval UI via `checkVenueApprovalStatus`.
    func loginVenueOwner(email: String, password: String) async {
        await MainActor.run { venueAuthErrorMessage = "" }

        let ownerEmail = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(ownerEmail) else {
            await MainActor.run {
                venueAuthErrorMessage = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            }
            return
        }

        do {
            _ = try await supabase.auth.signIn(
                email: ownerEmail,
                password: password
            )

            guard let session = try? await supabase.auth.session else {
                await forceLogout(reason: "businessLoginNoSessionAfterSignIn", source: "MapViewModel.loginVenueOwner")
                await MainActor.run {
                    clearVenueOwnerOwnedBusinessCaches()
                    ownerVenueDatabaseId = nil
                    venueAuthErrorMessage = "Unable to login venue owner."
                }
                return
            }

            guard Self.userEmailConfirmed(session.user) else {
                await forceLogout(reason: "businessLoginEmailUnconfirmed", source: "MapViewModel.loginVenueOwner")
                await MainActor.run {
                    clearVenueOwnerOwnedBusinessCaches()
                    ownerVenueDatabaseId = nil
                    venueAuthErrorMessage = "Please verify your email before signing in."
                    markEmailVerificationPending(email: ownerEmail, kind: .business)
                    print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
                }
                return
            }

            if await businessBanGuardBlocks(
                path: "businessLogin",
                action: "emailPassword",
                ownerEmail: ownerEmail,
                ownerUserId: session.user.id
            ) {
                clearExplicitLogoutMarkerAfterManualAuthSucceeded()
                return
            }

            guard await businessAccountAccessIsAllowedForAuthenticatedSession(
                ownerEmail: ownerEmail,
                userId: session.user.id,
                context: "businessLogin"
            ) else {
                return
            }

            if await shouldBlockBusinessOwnerLogin(sessionEmail: ownerEmail, userId: session.user.id) {
#if DEBUG
                print("[AuthAccountTypeGate] business login blocked fanEmail=\(ownerEmail)")
#endif
                await undoPartialSupabaseSessionAfterAccountTypeMismatch()
                await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
                return
            }

            await MainActor.run {
                clearAuthenticatedSessionCaches()
                isVenueOwnerLoggedIn = true
                venueOwnerMode = true
                venueOwnerEmail = ownerEmail
                isLoggedIn = false
                currentUserEmail = ""
                venueAuthErrorMessage = ""
                venueOwnerJustCompletedRegistration = false
                authSessionState = .signedIn
#if DEBUG
                print("[AuthStateDebug] authStateTransition=businessLogin->signedIn")
#endif
            }

            if let session = try? await supabase.auth.session {
                await MainActor.run { currentUserAuthId = session.user.id }
            }

#if DEBUG
            print("[VenueOwnerLoginDebug] login complete email=\(email)")
#endif
            await MainActor.run {
                logBusinessOwnerSessionFlags(context: "after_business_login_initial")
            }

            await persistAccountModeForActiveAuthSession(.businessOwner)

            clearExplicitLogoutMarkerAfterManualAuthSucceeded()

            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            _ = await ensureBusinessOwnerSessionFlagsIfPossible(context: "after_business_login_post_refresh")

            Task {
                await loadFavoriteVenuesFromSupabase()
                await refreshFollowingTabDataGlobally()
            }

        } catch {
            await MainActor.run {
                isVenueOwnerLoggedIn = false
                clearVenueOwnerOwnedBusinessCaches()
                ownerVenueDatabaseId = nil

                let message = error.localizedDescription.lowercased()

                if Self.isUnconfirmedEmailAuthError(error) {
                    venueAuthErrorMessage = "Please verify your email before signing in."
                    markEmailVerificationPending(email: ownerEmail, kind: .business)
                    print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
                } else if message.contains("invalid login credentials") {
                    venueAuthErrorMessage = "Venue owner account not found or incorrect password."
                } else {
                    venueAuthErrorMessage = "Unable to login venue owner."
                }
            }

            print("VENUE LOGIN ERROR:", error)
        }
    }

    // MARK: - Multi-venue owner (Phase B1/B2: businesses, venues, selection)

    private static func selectedVenueUserDefaultsKey(ownerEmail: String) -> String {
        "venueOwnerSelectedVenueId." + ownerEmail.lowercased()
    }

    private func readPersistedSelectedVenueId() -> UUID? {
        let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(email) else { return nil }
        let key = Self.selectedVenueUserDefaultsKey(ownerEmail: email)
        guard let s = UserDefaults.standard.string(forKey: key) else { return nil }
        return UUID(uuidString: s)
    }

    private func persistSelectedVenueId(_ id: UUID?) {
        let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(email) else { return }
        let key = Self.selectedVenueUserDefaultsKey(ownerEmail: email)
        if let id {
            UserDefaults.standard.set(id.uuidString.lowercased(), forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    func restorePersistedSelectedVenueForBusinessLaunch() {
        ownerVenueDatabaseId = readPersistedSelectedVenueId()
        isVenueOwnerBusinessDataLoading = true
    }

    /// Managed venues for this owner: active rows plus `plan_locked` rows that remain visible to the business owner.
    func managedVenuesForOwner() -> [VenueProfileRow] {
        if !ownedBusinessVenues.isEmpty {
            return ownedBusinessVenues
        }
        return legacyOwnerVenuesForEmailFallback
    }

    static func venueAdminStatus(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func venueIsPlanLocked(_ row: VenueProfileRow?) -> Bool {
        venueAdminStatus(row?.admin_status) == "plan_locked"
    }

    static func venueIsActiveForBusinessLimit(_ row: VenueProfileRow) -> Bool {
        let status = venueAdminStatus(row.admin_status)
        return status.isEmpty || status == "active"
    }

    static func venueIsOwnerVisibleManagedStatus(_ row: VenueProfileRow) -> Bool {
        let status = venueAdminStatus(row.admin_status)
        return status.isEmpty || status == "active" || status == "plan_locked"
    }

    func selectedManagedVenueIsPlanLocked() -> Bool {
        guard let selectedVenueID = ownerVenueDatabaseId else { return false }
        return Self.venueIsPlanLocked(managedVenuesForOwner().first(where: { $0.id == selectedVenueID }))
    }

    func managedVenuesContainPlanLocked() -> Bool {
        managedVenuesForOwner().contains { Self.venueIsPlanLocked($0) }
    }

    /// True only when at least one ``public.businesses`` row is loaded for this owner (do not infer from claim approval alone).
    func hasBusinessAccountForOwner() -> Bool {
        !ownedBusinesses.isEmpty
    }

    /// UI-only archived business presence for this owner. Never used to unlock tools or resolve active business ids.
    func hasArchivedBusinessAccountForOwner() -> Bool {
        !archivedOwnedBusinesses.isEmpty
    }

    /// Latest claim row looks rejected and there is no approved managed venue yet (Settings → Business account icon).
    private func businessAccountRejectedWithoutApprovedVenues() -> Bool {
        guard managedVenuesForOwner().isEmpty else { return false }
        return hasActiveVenueClaimRejectionForBusinessUI
    }

    /// Tint for Settings → Business **Business account** row (overall review state).
    ///
    /// - No business record: **orange** (setup warning; same as prior Settings styling).
    /// - Archived business record: **red** (disabled / contact support).
    /// - Pending venue claims: **orange** even when some venues are already approved.
    /// - Rejected latest/tracked claim and no managed venues: **red**.
    /// - Business exists, no pending, at least one managed venue: **green**.
    /// - Otherwise (no approved venues yet, not rejected, no pending list): muted **orange** warning.
    func businessAccountStatusTint() -> Color {
        if hasArchivedBusinessAccountForOwner() { return .red }
        guard hasBusinessAccountForOwner() else { return .orange }
        if !pendingVenueClaimsForSettings.isEmpty { return .orange }
        if businessAccountRejectedWithoutApprovedVenues() { return .red }
        if !managedVenuesForOwner().isEmpty { return .green }
        return Color.orange.opacity(0.55)
    }

    /// SF Symbol for Settings → Business **Business account** row (pairs with ``businessAccountStatusTint()``).
    func businessAccountStatusIconName() -> String {
        if hasArchivedBusinessAccountForOwner() { return "building.2.crop.circle.badge.xmark" }
        guard hasBusinessAccountForOwner() else { return "building.2.fill" }
        if !pendingVenueClaimsForSettings.isEmpty { return "building.2.fill" }
        if businessAccountRejectedWithoutApprovedVenues() { return "building.2.crop.circle.badge.xmark" }
        if !managedVenuesForOwner().isEmpty { return "building.2.fill" }
        return "building.2.crop.circle.badge.exclamationmark"
    }

    func businessSettingsLocationChrome() -> BusinessSettingsLocationChrome {
        if hasArchivedBusinessAccountForOwner() { return .archivedBusinessAccount }
        if !hasBusinessAccountForOwner() { return .needsBusinessAccountFirst }
        if !managedVenuesForOwner().isEmpty { return .approved }
        if !pendingVenueClaimsForSettings.isEmpty { return .pendingReview }
        if hasActiveVenueClaimRejectionForBusinessUI { return .rejected }
        return .noLocationsYet
    }

    /// Single-line copy for Settings → Business → Location status.
    func businessSettingsLocationStatusSubtitle() -> String {
        switch businessSettingsLocationChrome() {
        case .needsBusinessAccountFirst:
            return "Set up your business account first"
        case .archivedBusinessAccount:
            return "Contact support if you believe this is an error."
        case .approved:
            return "Approved"
        case .pendingReview:
            return "Pending review"
        case .rejected:
            return "Rejected"
        case .noLocationsYet:
            return "No locations yet"
        }
    }

    func businessSettingsLocationStatusSystemImage() -> String {
        switch businessSettingsLocationChrome() {
        case .needsBusinessAccountFirst:
            return "exclamationmark.circle"
        case .archivedBusinessAccount:
            return "exclamationmark.triangle.fill"
        case .approved:
            return "checkmark.seal.fill"
        case .pendingReview:
            return "hourglass"
        case .rejected:
            return "xmark.seal.fill"
        case .noLocationsYet:
            return "mappin.slash"
        }
    }

    /// When true, venue name, address, coordinates, and identity metadata must stay read-only in UI and must not be sent on `venues` updates (FanGeo-verified active managed venue).
    ///
    /// Signal: at least one approved managed location (``businessSettingsLocationChrome()`` == ``BusinessSettingsLocationChrome/approved``), selected venue is in ``managedVenuesForOwner()``, and ``VenueProfileRow/admin_status`` is **active** (or omitted / legacy-empty, matching active listings).
    func venueCoreIdentityLockedForSelectedVenue() -> Bool {
        guard businessSettingsLocationChrome() == .approved else { return false }
        guard let vid = ownerVenueDatabaseId else { return false }
        guard let row = managedVenuesForOwner().first(where: { $0.id == vid }) else { return false }
        let admin = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if admin.isEmpty { return true }
        return admin == "active"
    }

    private static func normalizedVenueMatchKey(name: String?, address: String?) -> String {
        let normalizedName = (name ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let normalizedAddress = (address ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return "\(normalizedName)|\(normalizedAddress)"
    }

    private func managedVenueRowMatching(_ bar: BarVenue) -> VenueProfileRow? {
        let managed = managedVenuesForOwner()
        let barKey = Self.normalizedVenueMatchKey(name: bar.name, address: bar.address)
        return managed.first { row in
            if let id = row.id, id == bar.id {
                return true
            }
            let rowKey = Self.normalizedVenueMatchKey(name: row.venue_name, address: row.address)
            return !rowKey.hasPrefix("|") && rowKey == barKey
        }
    }

    private func venueClaimRowMatching(_ bar: BarVenue, rows: [VenueClaimPendingSettingsRow]) -> VenueClaimPendingSettingsRow? {
        let barKey = Self.normalizedVenueMatchKey(name: bar.name, address: bar.address)
        return rows.first { row in
            if let venueId = row.venue_id, venueId == bar.id {
                return true
            }
            let rowKey = Self.normalizedVenueMatchKey(name: row.venue_name, address: row.venue_address)
            return !rowKey.hasPrefix("|") && rowKey == barKey
        }
    }

    func venueOwnershipClaimStatus(for bar: BarVenue) -> VenueOwnershipClaimStatus {
        if let approvedOwnership = approvedVenueOwnershipByVenueID[bar.id] {
            let ownedBusinessIds = Set(ownedBusinesses.map(\.id))
            let normalizedOwnerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
            let approvedOwnerEmail = OwnerBusinessEmail.normalized(approvedOwnership.ownerEmail ?? "")
            let ownedByCurrentBusiness =
                approvedOwnership.businessId.map { ownedBusinessIds.contains($0) } ?? false
                || (!approvedOwnerEmail.isEmpty && approvedOwnerEmail == normalizedOwnerEmail)

            if ownedByCurrentBusiness {
                return .approved
            }
            return .alreadyClaimedByOtherBusiness
        }
        if managedVenueRowMatching(bar) != nil {
            return .approved
        }
        guard hasAuthenticatedVenueOwnerSession else {
            return .unclaimed
        }
        if venueClaimRowMatching(bar, rows: pendingVenueClaimsForSettings) != nil {
            return .pendingReview
        }
        if venueClaimRowMatching(bar, rows: rejectedVenueClaimsForSettings) != nil {
            return .rejected
        }
        return .unclaimed
    }

    func venueIsManagedByAnotherBusiness(_ bar: BarVenue) -> Bool {
        guard let approvedOwnership = approvedVenueOwnershipByVenueID[bar.id] else { return false }

        let ownedBusinessIdSet = Set(ownedBusinesses.map(\.id))
        let normalizedOwnerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        let approvedOwnerEmail = OwnerBusinessEmail.normalized(approvedOwnership.ownerEmail ?? "")
        let ownedByCurrentBusiness =
            approvedOwnership.businessId.map { ownedBusinessIdSet.contains($0) } ?? false
            || (!approvedOwnerEmail.isEmpty && approvedOwnerEmail == normalizedOwnerEmail)
        return !ownedByCurrentBusiness
    }

    private func logVenueClaimSectionVisibility(
        bar: BarVenue,
        claimStatus: VenueOwnershipClaimStatus,
        result: Bool
    ) {
#if DEBUG
        print("[ClaimSectionVisibility] isSignedIn=\(currentUserAuthId != nil)")
        print("[ClaimSectionVisibility] isBusinessOwner=\(hasAuthenticatedVenueOwnerSession)")
        print("[ClaimSectionVisibility] venueId=\(bar.id.uuidString)")
        print("[ClaimSectionVisibility] venueName=\(bar.name)")
        print("[ClaimSectionVisibility] bar.businessId=\(bar.businessId?.uuidString ?? "nil")")
        print("[ClaimSectionVisibility] existingClaimStatus=\(String(describing: claimStatus))")
        print("[ClaimSectionVisibility] managedByAnotherBusiness=\(venueIsManagedByAnotherBusiness(bar))")
        print("[ClaimSectionVisibility] visible=\(result)")
#endif
    }

    func shouldShowVenueOwnershipClaimSection(for bar: BarVenue) -> Bool {
        let claimStatus = venueOwnershipClaimStatus(for: bar)
        let result: Bool

        if !hasAuthenticatedVenueOwnerSession {
            result = false
        } else {
            switch claimStatus {
            case .approved, .pendingReview, .rejected, .alreadyClaimedByOtherBusiness:
                result = true
            case .unclaimed:
                result = !venueIsManagedByAnotherBusiness(bar)
            }
        }

        logVenueClaimSectionVisibility(bar: bar, claimStatus: claimStatus, result: result)
        return result
    }

    func canSubmitVenueOwnershipClaim(for bar: BarVenue) -> Bool {
        let claimStatus = venueOwnershipClaimStatus(for: bar)
        guard hasAuthenticatedVenueOwnerSession else { return false }
        guard !venueIsManagedByAnotherBusiness(bar) else { return false }

        let result: Bool
        switch claimStatus {
        case .unclaimed, .rejected:
            result = true
        case .pendingReview, .approved, .alreadyClaimedByOtherBusiness:
            result = false
        }
        logVenueClaimSectionVisibility(bar: bar, claimStatus: claimStatus, result: result)
        return result
    }

    /// Discover “Claim this business”: hide only when this venue row is one of the owner’s managed locations, or its ``business_id`` matches an owned ``businesses`` row (not merely venue-owner sign-in).
    func venueIsAlreadyManagedBySignedInOwner(bar: BarVenue) -> Bool {
        let venueName = bar.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let managed = managedVenuesForOwner()
        let ownedVenueIds = managed.compactMap(\.id).map(\.uuidString).sorted().joined(separator: ",")
        let ownedBusinessIds = ownedBusinesses.map(\.id.uuidString).sorted().joined(separator: ",")

        guard hasAuthenticatedVenueOwnerSession else {
#if DEBUG
            print("[ClaimVisibility] venueName=\(venueName)")
            print("[ClaimVisibility] venueId=\(bar.id.uuidString)")
            print("[ClaimVisibility] ownedVenueIds=\(ownedVenueIds)")
            print("[ClaimVisibility] ownedBusinessIds=\(ownedBusinessIds)")
            print("[ClaimVisibility] alreadyManaged=false")
#endif
            return false
        }

        let matchesManagedVenue = managedVenueRowMatching(bar) != nil
        let ownedBusinessIdSet = Set(ownedBusinesses.map(\.id))
        let bid = bar.businessId
        let matchesOwnedBusiness = bid.map { ownedBusinessIdSet.contains($0) } ?? false

        let result = matchesManagedVenue || matchesOwnedBusiness
#if DEBUG
        print("[ClaimVisibility] venueName=\(venueName)")
        print("[ClaimVisibility] venueId=\(bar.id.uuidString)")
        print("[ClaimVisibility] ownedVenueIds=\(ownedVenueIds)")
        print("[ClaimVisibility] ownedBusinessIds=\(ownedBusinessIds)")
        print("[ClaimVisibility] alreadyManaged=\(result)")
#endif
        return result
    }

    private func preferredClaimText(_ primary: String?, fallback: String) -> String {
        let trimmed = primary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private func resolveCurrentBusinessIdForClaims() async -> UUID? {
        if let cached = await MainActor.run(body: { currentBusinessIdForAddLocation() }) {
            return cached
        }

        let ownerEmail = await MainActor.run {
            OwnerBusinessEmail.normalized(venueOwnerEmail)
        }
        guard OwnerBusinessEmail.isValidStrict(ownerEmail) else { return nil }

        struct BusinessIdRow: Decodable {
            let id: UUID
        }

        do {
            let rows: [BusinessIdRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_email", value: ownerEmail)
                .eq("admin_status", value: "active")
                .order("created_at", ascending: true)
                .limit(1)
                .execute()
                .value
            return rows.first?.id
        } catch {
#if DEBUG
            print("[ClaimSectionVisibility] resolveCurrentBusinessIdForClaims failed:", error)
#endif
            return nil
        }
    }

    private func fetchVenueRowForClaim(venueId: UUID) async throws -> VenueRow? {
        let rows: [VenueRow] = try await supabase
            .from("venues")
            .select("id,owner_email,business_id,admin_status,supporter_country,venue_name,address,address_line1,address_line2,city,state,zip_code,region,postal_code,country,formatted_address,latitude,longitude,phone,website,description,features,screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,cover_photo_url,menu_photo_url,cover_photo_thumbnail_url,menu_photo_thumbnail_url,businesses!venues_business_id_fkey(owner_email,admin_status)")
            .eq("id", value: venueId)
            .limit(1)
            .execute()
            .value
        return rows.first
    }

    func refreshApprovedVenueOwnershipState(for bar: BarVenue) async {
        struct ApprovedVenueOwnershipRow: Decodable {
            let venue_id: UUID?
            let business_id: UUID?
            let owner_email: String?
            let approval_status: String?
        }

        do {
            let rows: [ApprovedVenueOwnershipRow] = try await supabase
                .from("venue_claims")
                .select("venue_id,business_id,owner_email,approval_status")
                .eq("venue_id", value: bar.id)
                .eq("approval_status", value: "approved")
                .limit(1)
                .execute()
                .value

            await MainActor.run {
                if let approved = rows.first, approved.venue_id == bar.id {
                    approvedVenueOwnershipByVenueID[bar.id] = ApprovedVenueOwnershipSummary(
                        businessId: approved.business_id,
                        ownerEmail: approved.owner_email
                    )
                } else {
                    approvedVenueOwnershipByVenueID.removeValue(forKey: bar.id)
                }
            }
        } catch {
#if DEBUG
            print("[ClaimSectionVisibility] refreshApprovedVenueOwnershipState failed venueId=\(bar.id.uuidString):", error)
#endif
        }
    }

    private func discoverVenueClaimInsert(
        bar: BarVenue,
        venueRow: VenueRow?,
        ownerEmail: String,
        businessId: UUID
    ) -> VenueClaimInsert {
        let venueName = preferredClaimText(venueRow?.venue_name, fallback: bar.name)
        let venueAddress = preferredClaimText(venueRow?.address, fallback: bar.address)
        let venueAddressLine2 = venueRow?.address_line2?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let venueCity = venueRow?.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let venueState = venueRow?.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let venueCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(venueRow?.country ?? BusinessLocationCountryPolicy.defaultCountryCode)
        let venueZip = venueRow?.zip_code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let formattedAddress = venueRow?.formatted_address?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? BusinessVenueAddressFormatter.formattedAddress(
                line1: venueAddress,
                line2: venueAddressLine2,
                locality: venueCity,
                region: venueState,
                postalCode: venueZip,
                countryCode: venueCountry
            )
        let venuePhone = preferredClaimText(venueRow?.phone, fallback: bar.phone)
        let venueWebsite = venueRow?.website?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let venueDescription = venueRow?.description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Ownership request submitted from Venue Detail."
        let venueFeatures = venueRow?.features?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let coverURL = preferredClaimText(
            venueRow?.cover_photo_url,
            fallback: bar.coverPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        )
        let menuURL = preferredClaimText(
            venueRow?.menu_photo_url,
            fallback: preferredClaimText(
                bar.menuPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
                fallback: coverURL
            )
        )

        return VenueClaimInsert(
            owner_email: ownerEmail,
            business_id: businessId,
            venue_id: bar.id,
            venue_name: venueName,
            venue_address: venueAddress,
            venue_address_line2: venueAddressLine2.isEmpty ? nil : venueAddressLine2,
            venue_city: venueCity,
            venue_state: venueState,
            venue_country: venueCountry,
            venue_zip_code: venueZip,
            venue_formatted_address: formattedAddress.isEmpty ? nil : formattedAddress,
            venue_latitude: venueRow?.latitude,
            venue_longitude: venueRow?.longitude,
            venue_phone: venuePhone,
            venue_website: venueWebsite,
            venue_description: venueDescription,
            venue_features: venueFeatures,
            screen_count: venueRow?.screen_count ?? bar.screenCount ?? 1,
            serves_food: venueRow?.serves_food ?? bar.servesFood ?? false,
            has_wifi: venueRow?.has_wifi ?? bar.hasWifi ?? false,
            has_garden: venueRow?.has_garden ?? bar.hasGarden ?? false,
            has_projector: venueRow?.has_projector ?? bar.hasProjector ?? false,
            pet_friendly: venueRow?.pet_friendly ?? bar.petFriendly ?? false,
            cover_photo_url: coverURL,
            menu_photo_url: menuURL,
            proof_note: "Venue-linked ownership request submitted from FanGeo Venue Detail."
        )
    }

    @discardableResult
    func submitVenueOwnershipClaimFromVenueDetail(bar: BarVenue) async -> String? {
        guard hasAuthenticatedVenueOwnerSession else {
            return "Sign in as a business owner to claim this venue."
        }
        if await businessBanGuardBlocks(path: "venueClaim", action: "submitVenueOwnershipClaimFromVenueDetail") {
            return "Your account is suspended."
        }
        guard let businessId = await resolveCurrentBusinessIdForClaims() else {
            return "Finish setting up your business account before claiming venues."
        }
        guard !venueIsManagedByAnotherBusiness(bar) else {
            return "This venue is already managed by another business."
        }

        switch venueOwnershipClaimStatus(for: bar) {
        case .approved:
            return "This venue is already managed by your business."
        case .pendingReview:
            return "This venue claim is already under review."
        case .alreadyClaimedByOtherBusiness:
            return "This venue is already managed by another verified business."
        case .unclaimed, .rejected:
            break
        }

        let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(ownerEmail) else {
            return OwnerBusinessEmail.invalidOwnerEmailUserMessage
        }

        do {
            let venueRow = try await fetchVenueRowForClaim(venueId: bar.id)
            let claim = discoverVenueClaimInsert(
                bar: bar,
                venueRow: venueRow,
                ownerEmail: ownerEmail,
                businessId: businessId
            )

            if let dupMsg = await VenueClaimDuplicateCheck.rpcPreflight(
                supabase: supabase,
                businessId: businessId,
                ownerEmail: ownerEmail,
                venueName: claim.venue_name,
                venueAddress: claim.venue_address,
                venueCity: claim.venue_city,
                venueState: claim.venue_state,
                venueZip: claim.venue_zip_code
            ) {
                await MainActor.run { venueAuthErrorMessage = dupMsg }
                return dupMsg
            }

            let inserted: VenueClaimInsertedRow = try await supabase
                .from("venue_claims")
                .insert(claim)
                .select("id,created_at,approval_status")
                .single()
                .execute()
                .value

            await MainActor.run {
                venueClaimSubmitted = true
                venueClaimStatus = "Pending Review"
                venueClaimSubmittedDate = inserted.created_at ?? venueClaimSubmittedDate
                venueIsApproved = false
                venueAuthErrorMessage = ""
                hasUnackedRejectedVenueClaimForOwnerEmail = false

                let submittedRow = VenueClaimPendingSettingsRow(
                    id: inserted.id,
                    business_id: businessId,
                    venue_id: bar.id,
                    venue_name: claim.venue_name,
                    venue_address: claim.venue_address,
                    venue_address_line2: claim.venue_address_line2,
                    venue_city: claim.venue_city,
                    venue_state: claim.venue_state,
                    venue_country: claim.venue_country,
                    approval_status: inserted.approval_status,
                    rejection_acknowledged_at: nil,
                    created_at: inserted.created_at
                )

                pendingVenueClaimsForSettings.removeAll { existing in
                    existing.venue_id == bar.id
                        || (
                            existing.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(claim.venue_name) == .orderedSame
                            && existing.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(claim.venue_address) == .orderedSame
                        )
                }
                rejectedVenueClaimsForSettings.removeAll { existing in
                    existing.venue_id == bar.id
                        || (
                            existing.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(claim.venue_name) == .orderedSame
                            && existing.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(claim.venue_address) == .orderedSame
                        )
                }
                pendingVenueClaimsForSettings.insert(submittedRow, at: 0)
            }

            let notifyPayload = venueClaimAdminNotifyPayloadFromInsert(
                claim: claim,
                insertedId: inserted.id,
                createdAt: inserted.created_at,
                approvalStatus: inserted.approval_status,
                claimKind: "discover_claim",
                familyFriendly: false,
                parkingAvailable: false
            )
            notifyVenueClaimAdminEmail(payload: notifyPayload)

            await refreshPendingVenueClaimsForSettings()
            await refreshVenueClaimStatusLineFromDatabase()
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
            return nil
        } catch {
            let dup = VenueClaimDuplicateCheck.userMessageIfKnownInsertError(error)
            let message = dup ?? "Could not submit this venue claim. Please try again."
            await MainActor.run { venueAuthErrorMessage = message }
            return message
        }
    }

    func logBusinessSwitcherDebug() {
#if DEBUG
        let managed = managedVenuesForOwner()
        let names = managed.compactMap { row -> String? in
            let n = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return n.isEmpty ? nil : n
        }
        print("[BusinessSwitcher] managed venues count=\(managed.count)")
        print("[BusinessSwitcher] venue names=\(names.joined(separator: ", "))")
        print("[BusinessSwitcher] selected venue id=\(ownerVenueDatabaseId?.uuidString ?? "nil")")
#endif
    }

    /// When ``ownerVenueDatabaseId`` is set, owner game loads filter ``venue_events`` by ``venue_id`` (Phase B3.1); otherwise legacy ``owner_email`` (non-empty ``venueOwnerEmail``).
    func shouldScopeOwnerToolsByVenueId() -> Bool {
        ownerVenueDatabaseId != nil
    }

    /// Clears in-memory business / venue owner lists (e.g. sign-out or failed load).
    func clearVenueOwnerOwnedBusinessCaches() {
        ownedBusinesses = []
        archivedOwnedBusinesses = []
        ownedBusinessVenues = []
        legacyOwnerVenuesForEmailFallback = []
        businessDashboardPreloadSnapshot = nil
        businessDashboardPreloadInFlightKey = nil
        businessDashboardPreloadTask = nil
        clearBusinessFavoriteTeamState()
        isVenueOwnerBusinessDataLoading = false
        pendingVenueClaimsForSettings = []
        rejectedVenueClaimsForSettings = []
        approvedVenueClaimMetadataByVenueID = [:]
        hasUnackedRejectedVenueClaimForOwnerEmail = false
        venueOwnerJustCompletedRegistration = false
    }

    /// True when ``currentBusinessIdForAddLocation()`` can supply a ``business_id`` for an add-location claim (owned businesses and/or managed venues with ``business_id``).
    func canRequestAdditionalLocationForBusiness() -> Bool {
        currentBusinessIdForAddLocation() != nil
    }

    /// Resolves ``public.businesses.id`` for “Add location” inserts: prefers ``ownedBusinesses``; then the selected managed venue’s ``business_id``; then any managed venue’s ``business_id``.
    func currentBusinessIdForAddLocation() -> UUID? {
        let managed = managedVenuesForOwner()
        let sortedOwned = ownedBusinesses.sorted {
            $0.display_name.localizedCaseInsensitiveCompare($1.display_name) == .orderedAscending
        }
        let ownedIds = Set(sortedOwned.map(\.id))

        let selectedVenueBusinessId: UUID? = {
            guard let vid = ownerVenueDatabaseId,
                  let row = managed.first(where: { $0.id == vid }) else { return nil }
            return row.business_id
        }()

        if let firstOwned = sortedOwned.first {
            if sortedOwned.count == 1 {
                if let bid = selectedVenueBusinessId, ownedIds.contains(bid) { return bid }
                return firstOwned.id
            }
            if let bid = selectedVenueBusinessId, ownedIds.contains(bid) { return bid }
            return firstOwned.id
        }

        if let bid = selectedVenueBusinessId { return bid }

        let sortedManaged = managed.sorted { a, b in
            let na = a.venue_name ?? ""
            let nb = b.venue_name ?? ""
            return na.localizedCaseInsensitiveCompare(nb) == .orderedAscending
        }
        return sortedManaged.compactMap(\.business_id).first
    }

    /// Loads pending and rejected ``venue_claims`` for this owner’s email and owned ``businesses`` ids (excludes approved).
    func refreshPendingVenueClaimsForSettings() async {
        let email = await MainActor.run {
            OwnerBusinessEmail.normalized(venueOwnerEmail)
        }
        let canLoad = await MainActor.run {
            isVenueOwnerLoggedIn && OwnerBusinessEmail.isValidStrict(email)
        }
        guard canLoad else {
            await MainActor.run {
                pendingVenueClaimsForSettings = []
                rejectedVenueClaimsForSettings = []
                hasUnackedRejectedVenueClaimForOwnerEmail = false
            }
            return
        }

        let businessIds = await MainActor.run {
            var ids = Set(ownedBusinesses.map(\.id))
            if let bid = currentBusinessIdForAddLocation() {
                ids.insert(bid)
            }
            return ids
        }
        let approvedManagedVenueSnapshot = await MainActor.run {
            managedVenuesForOwner()
        }

        do {
            let rows: [VenueClaimPendingSettingsRow] = try await supabase
                .from("venue_claims")
                .select("id,business_id,venue_id,venue_name,venue_address,venue_address_line2,venue_city,venue_state,venue_country,approval_status,rejection_acknowledged_at,created_at")
                .eq("owner_email", value: email)
                .order("created_at", ascending: false)
                .limit(80)
                .execute()
                .value

            let approvedVenueIDs = Set(
                approvedManagedVenueSnapshot.compactMap(\.id)
                    + rows.compactMap { row -> UUID? in
                        Self.isApprovedClaimStatus(row.approval_status) ? row.venue_id : nil
                    }
            )
            let approvedVenueKeys = Set(
                (
                    approvedManagedVenueSnapshot.map {
                        Self.normalizedVenueMatchKey(name: $0.venue_name, address: $0.address)
                    }
                    + rows.compactMap { row -> String? in
                        guard Self.isApprovedClaimStatus(row.approval_status) else { return nil }
                        return Self.normalizedVenueMatchKey(name: row.venue_name, address: row.venue_address)
                    }
                ).filter { !$0.hasPrefix("|") }
            )

            let filteredPending = rows.filter { row in
                Self.isPendingUnapprovedClaimStatus(row.approval_status)
                    && Self.pendingClaimMatchesOwnerBusinesses(row, ownerBusinessIds: businessIds)
                    && !Self.pendingClaimMatchesApprovedVenue(
                        row,
                        approvedVenueIDs: approvedVenueIDs,
                        approvedVenueKeys: approvedVenueKeys
                    )
            }
            let filteredRejected = rows.filter { row in
                Self.isRejectedClaimStatus(row.approval_status)
                    && !Self.isVenueClaimRejectionAcknowledged(row.rejection_acknowledged_at)
                    && Self.pendingClaimMatchesOwnerBusinesses(row, ownerBusinessIds: businessIds)
            }

            await MainActor.run {
                pendingVenueClaimsForSettings = filteredPending
                rejectedVenueClaimsForSettings = filteredRejected
            }
#if DEBUG
            print("[AddLocation] pending claims count=\(filteredPending.count) rejected=\(filteredRejected.count)")
            for row in filteredPending {
                let id = row.venue_id?.uuidString ?? row.id.uuidString
                print("[ApprovedVenueVisibilityDebug] hiddenPendingVenue id=\(id)")
            }
            print("[ApprovedVenueVisibilityDebug] approvedVenueIDs=\(approvedVenueIDs.map(\.uuidString).sorted().joined(separator: ","))")
#endif
        } catch {
            print("ERROR LOADING PENDING VENUE CLAIMS:", error)
            await MainActor.run {
                pendingVenueClaimsForSettings = []
                rejectedVenueClaimsForSettings = []
                hasUnackedRejectedVenueClaimForOwnerEmail = false
            }
        }
    }

    @discardableResult
    func refreshPendingVenueClaimDirectly(claimId: UUID) async -> Bool {
        guard let rows = await loadVenueClaimRefreshRows(claimId: claimId) else {
            await refreshPendingVenueClaimsForSettings()
            return false
        }
        let row = rows.first
        let approved = row.map { Self.isApprovedClaimStatus($0.approval_status) } ?? false
        let venueID = row?.venue_id
        let businessID = row?.business_id
        let approvalStatus = row?.approval_status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "missing"
        var pendingRemoved = false

        if approved || row == nil {
            pendingRemoved = await MainActor.run {
                let before = pendingVenueClaimsForSettings.count
                pendingVenueClaimsForSettings.removeAll { $0.id == claimId }
                rejectedVenueClaimsForSettings.removeAll { $0.id == claimId }
                return pendingVenueClaimsForSettings.count < before
            }
            await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        } else {
            await refreshPendingVenueClaimsForSettings()
        }
        await refreshVenueClaimStatusLineFromDatabase()

#if DEBUG
        print(
            "[VenueClaimRefreshDebug] claimId=\(claimId.uuidString) venueId=\(venueID?.uuidString ?? "nil") businessId=\(businessID?.uuidString ?? "nil") approval_status=\(approvalStatus) pendingRemoved=\(pendingRemoved)"
        )
#endif
        return pendingRemoved
    }

    @discardableResult
    func resendPendingVenueClaimRequest(claimId: UUID) async -> Bool {
        guard let rows = await loadVenueClaimRefreshRows(claimId: claimId) else {
#if DEBUG
            print("[VenueClaimResendDebug] claimId=\(claimId.uuidString) venueId=nil businessId=nil approval_status=error emailSent=false")
#endif
            await refreshPendingVenueClaimsForSettings()
            return false
        }
        guard let row = rows.first else {
#if DEBUG
            print("[VenueClaimResendDebug] claimId=\(claimId.uuidString) venueId=nil businessId=nil approval_status=missing emailSent=false")
#endif
            await refreshPendingVenueClaimsForSettings()
            return false
        }

        let approvalStatus = row.approval_status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard Self.isPendingUnapprovedClaimStatus(approvalStatus) else {
            let removed = await refreshPendingVenueClaimDirectly(claimId: claimId)
#if DEBUG
            print(
                "[VenueClaimResendDebug] claimId=\(claimId.uuidString) venueId=\(row.venue_id?.uuidString ?? "nil") businessId=\(row.business_id?.uuidString ?? "nil") approval_status=\(approvalStatus.isEmpty ? "nil" : approvalStatus) emailSent=false pendingRemoved=\(removed)"
            )
#endif
            return false
        }

        let payload = venueClaimAdminNotifyPayload(from: row)
        let emailSent = await sendVenueClaimAdminEmail(payload: payload)
        await refreshPendingVenueClaimDirectly(claimId: claimId)
#if DEBUG
        print(
            "[VenueClaimResendDebug] claimId=\(claimId.uuidString) venueId=\(row.venue_id?.uuidString ?? "nil") businessId=\(row.business_id?.uuidString ?? "nil") approval_status=\(approvalStatus.isEmpty ? "nil" : approvalStatus) emailSent=\(emailSent)"
        )
#endif
        return emailSent
    }

    private func loadVenueClaimRefreshRows(claimId: UUID) async -> [VenueClaimRefreshRow]? {
        do {
            return try await supabase
                .from("venue_claims")
                .select("id,business_id,venue_id,owner_email,venue_name,venue_address,venue_address_line2,venue_city,venue_state,venue_country,venue_zip_code,venue_formatted_address,venue_latitude,venue_longitude,venue_phone,venue_website,venue_description,venue_features,screen_count,serves_food,has_wifi,has_garden,has_projector,pet_friendly,cover_photo_url,menu_photo_url,proof_note,approval_status,rejection_acknowledged_at,created_at")
                .eq("id", value: claimId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
        } catch {
#if DEBUG
            print("[VenueClaimRefreshDebug] claimId=\(claimId.uuidString) venueId=nil businessId=nil approval_status=error pendingRemoved=false error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    private struct VenueClaimRefreshRow: Decodable {
        let id: UUID
        let business_id: UUID?
        let venue_id: UUID?
        let owner_email: String?
        let venue_name: String?
        let venue_address: String?
        let venue_address_line2: String?
        let venue_city: String?
        let venue_state: String?
        let venue_country: String?
        let venue_zip_code: String?
        let venue_formatted_address: String?
        let venue_latitude: Double?
        let venue_longitude: Double?
        let venue_phone: String?
        let venue_website: String?
        let venue_description: String?
        let venue_features: String?
        let screen_count: Int?
        let serves_food: Bool?
        let has_wifi: Bool?
        let has_garden: Bool?
        let has_projector: Bool?
        let pet_friendly: Bool?
        let cover_photo_url: String?
        let menu_photo_url: String?
        let proof_note: String?
        let approval_status: String?
        let rejection_acknowledged_at: String?
        let created_at: String?
    }

    /// Persists dismissal of a rejected claim for the signed-in business owner (``rejection_acknowledged_at``); claim row remains for audit.
    func acknowledgeRejectedVenueClaim(claimId: UUID) async {
        if await businessBanGuardBlocks(path: "venueClaim", action: "acknowledgeRejectedVenueClaim") {
            return
        }

        struct Params: Encodable {
            let p_claim_id: UUID
        }
        do {
            try await supabase
                .rpc("acknowledge_venue_claim_rejection", params: Params(p_claim_id: claimId))
                .execute()
            await refreshPendingVenueClaimsForSettings()
            await refreshVenueClaimStatusLineFromDatabase()
        } catch {
            print("[VenueClaimAck] acknowledge rejected claim failed claim_id=\(claimId.uuidString) error=\(error.localizedDescription)")
        }
    }

    func cancelBusinessVenueClaim(claimId: UUID) async -> Bool {
        if await businessBanGuardBlocks(path: "venueClaim", action: "cancelBusinessVenueClaim") {
            return false
        }

        let snapshot = await MainActor.run { () -> (claim: VenueClaimPendingSettingsRow?, businessId: UUID?, ownerEmail: String, businessName: String?) in
            let claim = pendingVenueClaimsForSettings.first(where: { $0.id == claimId })
            let businessId = claim?.business_id ?? currentBusinessIdForAddLocation() ?? ownedBusinesses.first?.id
            let businessName = businessId.flatMap { id in
                ownedBusinesses.first(where: { $0.id == id })?.display_name
            } ?? ownedBusinesses.first?.display_name
            return (
                claim,
                businessId,
                OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(venueOwnerEmail))
                    ? OwnerBusinessEmail.normalized(venueOwnerEmail)
                    : OwnerBusinessEmail.normalized(currentUserEmail),
                businessName?.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }

        guard let claim = snapshot.claim, let businessId = snapshot.businessId else {
#if DEBUG
            print("[BusinessVenueClaimCancel] claimId=\(claimId.uuidString) businessId=nil ownerEmail=\(snapshot.ownerEmail) previousStatus=nil newStatus=nil emailSent=false error=missing_claim_or_business")
#endif
            return false
        }

        let ownerEmail = snapshot.ownerEmail
        let previousStatus = claim.approval_status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "pending"
#if DEBUG
        print("[BusinessVenueClaimCancel] claimId=\(claimId.uuidString) businessId=\(businessId.uuidString) ownerEmail=\(ownerEmail) previousStatus=\(previousStatus)")
#endif

        do {
            let rows: [CancelBusinessVenueClaimResult] = try await supabase
                .rpc(
                    "cancel_business_venue_claim",
                    params: CancelBusinessVenueClaimRPCParams(
                        p_claim_id: claimId,
                        p_business_id: businessId
                    )
                )
                .execute()
                .value
            let result = rows.first
            let rawNewStatus = result?.new_status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let rawCancelledAt = result?.cancelled_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let newStatus = rawNewStatus.isEmpty ? "cancelled" : rawNewStatus
            let cancelledAt = rawCancelledAt.isEmpty ? Self.venueClaimCancelTimestamp() : rawCancelledAt

            await MainActor.run {
                pendingVenueClaimsForSettings.removeAll { $0.id == claimId }
            }

            var payload = VenueClaimAdminNotifyPayload(
                claim_id: claimId.uuidString,
                business_id: businessId.uuidString,
                venue_id: claim.venue_id?.uuidString,
                claim_kind: "cancelled_before_review",
                owner_email: ownerEmail,
                venue_name: claim.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Submitted venue",
                venue_address: claim.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                venue_address_line2: claim.venue_address_line2?.trimmingCharacters(in: .whitespacesAndNewlines),
                venue_city: claim.venue_city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                venue_state: claim.venue_state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                venue_country: claim.venue_country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                venue_zip_code: "",
                venue_formatted_address: nil,
                venue_latitude: nil,
                venue_longitude: nil,
                venue_phone: "",
                venue_website: "",
                venue_description: "",
                venue_features: "",
                screen_count: 0,
                serves_food: false,
                has_wifi: false,
                has_garden: false,
                has_projector: false,
                pet_friendly: false,
                family_friendly: false,
                parking_available: false,
                proof_note: "",
                cover_photo_url: "",
                menu_photo_url: "",
                photo_urls: [],
                created_at: claim.created_at ?? "",
                approval_status: newStatus
            )
            payload.business_name = snapshot.businessName
            payload.previous_status = result?.previous_status ?? previousStatus
            payload.new_status = newStatus
            payload.cancelled_at = cancelledAt
            payload.cancellation_note = "The business owner cancelled this venue request before approval/rejection."

            let emailSent = await sendVenueClaimAdminEmail(payload: payload)
#if DEBUG
            print("[BusinessVenueClaimCancel] claimId=\(claimId.uuidString) businessId=\(businessId.uuidString) ownerEmail=\(ownerEmail) previousStatus=\(previousStatus) newStatus=\(newStatus) emailSent=\(emailSent)")
#endif

            await refreshPendingVenueClaimsForSettings()
            await refreshVenueClaimStatusLineFromDatabase()
            return true
        } catch {
#if DEBUG
            print("[BusinessVenueClaimCancel] claimId=\(claimId.uuidString) businessId=\(businessId.uuidString) ownerEmail=\(ownerEmail) previousStatus=\(previousStatus) newStatus=nil emailSent=false error=\(error.localizedDescription)")
#endif
            await refreshPendingVenueClaimsForSettings()
            await refreshVenueClaimStatusLineFromDatabase()
            return false
        }
    }

    private static func isVenueClaimRejectionAcknowledged(_ rejectionAcknowledgedAt: String?) -> Bool {
        let t = rejectionAcknowledgedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !t.isEmpty
    }

    private static func venueClaimCancelTimestamp() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private static func isPendingUnapprovedClaimStatus(_ status: String?) -> Bool {
        let s = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if isApprovedClaimStatus(status) { return false }
        if s == "released" { return false }
        if s == "business_deleted" { return false }
        if s == "cancelled" || s == "canceled" || s == "withdrawn" { return false }
        if s.contains("reject") { return false }
        return true
    }

    private static func isRejectedClaimStatus(_ status: String?) -> Bool {
        let s = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if s.isEmpty { return false }
        if isApprovedClaimStatus(status) { return false }
        return s.contains("reject")
    }

    private static func isApprovedClaimStatus(_ status: String?) -> Bool {
        let s = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return s == "approved"
    }

    private static func pendingClaimMatchesApprovedVenue(
        _ row: VenueClaimPendingSettingsRow,
        approvedVenueIDs: Set<UUID>,
        approvedVenueKeys: Set<String>
    ) -> Bool {
        if let venueID = row.venue_id, approvedVenueIDs.contains(venueID) {
            return true
        }
        let key = normalizedVenueMatchKey(name: row.venue_name, address: row.venue_address)
        return !key.hasPrefix("|") && approvedVenueKeys.contains(key)
    }

    /// First occurrence wins (stable for UI ordering).
    private static func dedupeVenueProfileRowsPreservingOrder(_ rows: [VenueProfileRow]) -> [VenueProfileRow] {
        var seen = Set<UUID>()
        var out: [VenueProfileRow] = []
        for r in rows {
            guard let id = r.id else { continue }
            if seen.insert(id).inserted {
                out.append(r)
            }
        }
        return out
    }

    private static func dedupeBusinessRowsPreservingOrder(_ rows: [BusinessRow]) -> [BusinessRow] {
        var seen = Set<UUID>()
        var out: [BusinessRow] = []
        for r in rows {
            if seen.insert(r.id).inserted {
                out.append(r)
            }
        }
        return out
    }

    private struct VenueClaimVenueLinkRow: Decodable {
        let venue_id: UUID?
        let business_id: UUID?
        let approval_status: String?
    }

    /// Businesses referenced by approved claims for this owner. Covers community venues where
    /// `venues.business_id` / `venues.owner_email` remain nil and ownership lives only on `venue_claims`.
    private func loadBusinessesLinkedFromApprovedClaims(ownerEmail: String) async throws -> [BusinessRow] {
        let ownerEmailNorm = OwnerBusinessEmail.normalized(ownerEmail)
        guard OwnerBusinessEmail.isValidStrict(ownerEmailNorm) else { return [] }

        let links: [VenueClaimVenueLinkRow] = try await supabase
            .from("venue_claims")
            .select("venue_id,business_id,approval_status")
            .eq("owner_email", value: ownerEmailNorm)
            .limit(120)
            .execute()
            .value

        let businessIds = Array(Set(links.compactMap { row -> UUID? in
            guard Self.isApprovedClaimStatus(row.approval_status) else { return nil }
            return row.business_id
        }))
        guard !businessIds.isEmpty else { return [] }

        return try await supabase
            .from("businesses")
            .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
            .in("id", values: businessIds.map(\.uuidString))
            .eq("admin_status", value: "active")
            .execute()
            .value
    }

    /// Venues referenced by approved claims: by `owner_email`, then by `business_id` for loaded businesses (covers email drift).
    private func loadVenuesLinkedFromApprovedClaims(ownerEmail: String, businessIds: [UUID]) async throws -> [VenueProfileRow] {
        let ownerEmailNorm = OwnerBusinessEmail.normalized(ownerEmail)
        var approvedIds = Set<UUID>()

        if OwnerBusinessEmail.isValidStrict(ownerEmailNorm) {
            let links: [VenueClaimVenueLinkRow] = try await supabase
                .from("venue_claims")
                .select("venue_id,business_id,approval_status")
                .eq("owner_email", value: ownerEmailNorm)
                .limit(120)
                .execute()
                .value
            for row in links {
                guard Self.isApprovedClaimStatus(row.approval_status), let vid = row.venue_id else { continue }
                approvedIds.insert(vid)
            }
        }

        if !businessIds.isEmpty {
            let idStrings = businessIds.map(\.uuidString)
            let links: [VenueClaimVenueLinkRow] = try await supabase
                .from("venue_claims")
                .select("venue_id,business_id,approval_status")
                .in("business_id", values: idStrings)
                .limit(120)
                .execute()
                .value
            for row in links {
                guard Self.isApprovedClaimStatus(row.approval_status), let vid = row.venue_id else { continue }
                approvedIds.insert(vid)
            }
        }

        let unique = Array(approvedIds)
        guard !unique.isEmpty else { return [] }

        let idStrings = unique.map(\.uuidString)
        return try await supabase
            .from("venues")
            .select()
            .in("id", values: idStrings)
            .in("admin_status", values: ["active", "plan_locked"])
            .execute()
            .value
    }

    private func loadApprovedVenueClaimMetadata(
        ownerEmail: String,
        businessIds: [UUID],
        managedVenueRows: [VenueProfileRow]
    ) async -> [UUID: BusinessApprovedVenueClaimMetadata] {
        let ownerEmailNorm = OwnerBusinessEmail.normalized(ownerEmail)
        let managedVenueIds = Set(managedVenueRows.compactMap(\.id))
        let businessIdSet = Set(businessIds)
        guard !managedVenueIds.isEmpty else { return [:] }

        do {
            var rows: [BusinessApprovedVenueClaimMetadata] = []
            if OwnerBusinessEmail.isValidStrict(ownerEmailNorm) {
                let ownerRows: [BusinessApprovedVenueClaimMetadata] = try await supabase
                    .from("venue_claims")
                    .select()
                    .eq("owner_email", value: ownerEmailNorm)
                    .eq("approval_status", value: "approved")
                    .limit(160)
                    .execute()
                    .value
                rows.append(contentsOf: ownerRows)
            }

            if !businessIds.isEmpty {
                let businessRows: [BusinessApprovedVenueClaimMetadata] = try await supabase
                    .from("venue_claims")
                    .select()
                    .in("business_id", values: businessIds.map(\.uuidString))
                    .eq("approval_status", value: "approved")
                    .limit(160)
                    .execute()
                    .value
                rows.append(contentsOf: businessRows)
            }

            let venueRows: [BusinessApprovedVenueClaimMetadata] = try await supabase
                .from("venue_claims")
                .select()
                .in("venue_id", values: managedVenueIds.map(\.uuidString))
                .eq("approval_status", value: "approved")
                .limit(160)
                .execute()
                .value
            rows.append(contentsOf: venueRows)

            let uniqueRows = Dictionary(rows.map { ($0.claimId, $0) }, uniquingKeysWith: { first, _ in first })
                .values
            var bestByVenueID: [UUID: BusinessApprovedVenueClaimMetadata] = [:]
            for row in uniqueRows {
                guard let venueId = row.venueId, managedVenueIds.contains(venueId) else { continue }
                let claimOwnerEmail = OwnerBusinessEmail.normalized(row.ownerEmail ?? "")
                let matchesOwner = OwnerBusinessEmail.isValidStrict(ownerEmailNorm)
                    && claimOwnerEmail == ownerEmailNorm
                let matchesBusiness = row.businessId.map { businessIdSet.contains($0) } ?? false
                guard matchesOwner || matchesBusiness else { continue }

                if let existing = bestByVenueID[venueId],
                   approvedVenueClaimMetadataSortDate(existing) >= approvedVenueClaimMetadataSortDate(row) {
                    continue
                }
                bestByVenueID[venueId] = row
            }

            return bestByVenueID
        } catch {
#if DEBUG
            print("[BusinessApprovedVenuesDebug] metadataLoadError=\(error.localizedDescription)")
#endif
            return [:]
        }
    }

    private func approvedVenueClaimMetadataSortDate(_ metadata: BusinessApprovedVenueClaimMetadata) -> Date {
        let raw = (metadata.approvedAtRaw ?? metadata.createdAtRaw)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            return .distantPast
        }
        return SupabaseTimestampParsing.parseTimestamptz(raw) ?? .distantPast
    }

    private static func pendingClaimMatchesOwnerBusinesses(
        _ row: VenueClaimPendingSettingsRow,
        ownerBusinessIds: Set<UUID>
    ) -> Bool {
        if let bid = row.business_id {
            return ownerBusinessIds.contains(bid)
        }
        // Legacy / Discover claims without `business_id` still belong to this owner email.
        return true
    }

    private struct VenueClaimInsertedRow: Decodable {
        let id: UUID
        let created_at: String?
        let approval_status: String?
    }

    private struct CancelBusinessVenueClaimRPCParams: Encodable {
        let p_claim_id: UUID
        let p_business_id: UUID
    }

    private struct CancelBusinessVenueClaimResult: Decodable {
        let claim_id: UUID?
        let business_id: UUID?
        let previous_status: String?
        let new_status: String?
        let cancelled_at: String?
    }

    private struct CreateBusinessVenueClaimRPCParams: Encodable {
        enum CodingKeys: String, CodingKey {
            case p_business_id
            case p_owner_email
            case p_venue_id
            case p_venue_name
            case p_venue_address
            case p_venue_address_line2
            case p_venue_city
            case p_venue_state
            case p_venue_country
            case p_venue_zip_code
            case p_venue_formatted_address
            case p_venue_latitude
            case p_venue_longitude
            case p_venue_phone
            case p_venue_website
            case p_venue_description
            case p_venue_features
            case p_screen_count
            case p_serves_food
            case p_has_wifi
            case p_has_garden
            case p_has_projector
            case p_pet_friendly
            case p_cover_photo_url
            case p_menu_photo_url
            case p_proof_note
        }

        let p_business_id: UUID
        let p_owner_email: String
        let p_venue_id: UUID?
        let p_venue_name: String
        let p_venue_address: String
        let p_venue_address_line2: String?
        let p_venue_city: String
        let p_venue_state: String
        let p_venue_country: String
        let p_venue_zip_code: String
        let p_venue_formatted_address: String?
        let p_venue_latitude: Double?
        let p_venue_longitude: Double?
        let p_venue_phone: String
        let p_venue_website: String
        let p_venue_description: String
        let p_venue_features: String
        let p_screen_count: Int
        let p_serves_food: Bool
        let p_has_wifi: Bool
        let p_has_garden: Bool
        let p_has_projector: Bool
        let p_pet_friendly: Bool
        let p_cover_photo_url: String
        let p_menu_photo_url: String
        let p_proof_note: String

        init(claim: VenueClaimInsert, businessId: UUID) {
            p_business_id = businessId
            p_owner_email = claim.owner_email
            p_venue_id = claim.venue_id
            p_venue_name = claim.venue_name
            p_venue_address = claim.venue_address
            p_venue_address_line2 = claim.venue_address_line2
            p_venue_city = claim.venue_city
            p_venue_state = claim.venue_state
            p_venue_country = claim.venue_country
            p_venue_zip_code = claim.venue_zip_code
            p_venue_formatted_address = claim.venue_formatted_address
            p_venue_latitude = claim.venue_latitude
            p_venue_longitude = claim.venue_longitude
            p_venue_phone = claim.venue_phone
            p_venue_website = claim.venue_website
            p_venue_description = claim.venue_description
            p_venue_features = claim.venue_features
            p_screen_count = claim.screen_count
            p_serves_food = claim.serves_food
            p_has_wifi = claim.has_wifi
            p_has_garden = claim.has_garden
            p_has_projector = claim.has_projector
            p_pet_friendly = claim.pet_friendly
            p_cover_photo_url = claim.cover_photo_url
            p_menu_photo_url = claim.menu_photo_url
            p_proof_note = claim.proof_note
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(p_business_id, forKey: .p_business_id)
            try container.encode(p_owner_email, forKey: .p_owner_email)
            if let p_venue_id {
                try container.encode(p_venue_id, forKey: .p_venue_id)
            } else {
                try container.encodeNil(forKey: .p_venue_id)
            }
            try container.encode(p_venue_name, forKey: .p_venue_name)
            try container.encode(p_venue_address, forKey: .p_venue_address)
            if let p_venue_address_line2 {
                try container.encode(p_venue_address_line2, forKey: .p_venue_address_line2)
            } else {
                try container.encodeNil(forKey: .p_venue_address_line2)
            }
            try container.encode(p_venue_city, forKey: .p_venue_city)
            try container.encode(p_venue_state, forKey: .p_venue_state)
            try container.encode(p_venue_country, forKey: .p_venue_country)
            try container.encode(p_venue_zip_code, forKey: .p_venue_zip_code)
            if let p_venue_formatted_address {
                try container.encode(p_venue_formatted_address, forKey: .p_venue_formatted_address)
            } else {
                try container.encodeNil(forKey: .p_venue_formatted_address)
            }
            if let p_venue_latitude {
                try container.encode(p_venue_latitude, forKey: .p_venue_latitude)
            } else {
                try container.encodeNil(forKey: .p_venue_latitude)
            }
            if let p_venue_longitude {
                try container.encode(p_venue_longitude, forKey: .p_venue_longitude)
            } else {
                try container.encodeNil(forKey: .p_venue_longitude)
            }
            try container.encode(p_venue_phone, forKey: .p_venue_phone)
            try container.encode(p_venue_website, forKey: .p_venue_website)
            try container.encode(p_venue_description, forKey: .p_venue_description)
            try container.encode(p_venue_features, forKey: .p_venue_features)
            try container.encode(p_screen_count, forKey: .p_screen_count)
            try container.encode(p_serves_food, forKey: .p_serves_food)
            try container.encode(p_has_wifi, forKey: .p_has_wifi)
            try container.encode(p_has_garden, forKey: .p_has_garden)
            try container.encode(p_has_projector, forKey: .p_has_projector)
            try container.encode(p_pet_friendly, forKey: .p_pet_friendly)
            try container.encode(p_cover_photo_url, forKey: .p_cover_photo_url)
            try container.encode(p_menu_photo_url, forKey: .p_menu_photo_url)
            try container.encode(p_proof_note, forKey: .p_proof_note)
        }

        var debugSignature: String {
            [
                "p_business_id:uuid",
                "p_owner_email:text present=\(!p_owner_email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_id:uuid? present=\(p_venue_id != nil)",
                "p_venue_name:text present=\(!p_venue_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_address:text present=\(!p_venue_address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_address_line2:text? present=\(p_venue_address_line2?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)",
                "p_venue_city:text present=\(!p_venue_city.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_state:text present=\(!p_venue_state.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_country:text present=\(!p_venue_country.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_zip_code:text present=\(!p_venue_zip_code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_formatted_address:text? present=\(p_venue_formatted_address?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)",
                "p_venue_latitude:double precision? present=\(p_venue_latitude != nil)",
                "p_venue_longitude:double precision? present=\(p_venue_longitude != nil)",
                "p_venue_phone:text present=\(!p_venue_phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_website:text present=\(!p_venue_website.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_description:text present=\(!p_venue_description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_features:text present=\(!p_venue_features.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_screen_count:integer",
                "p_serves_food:boolean",
                "p_has_wifi:boolean",
                "p_has_garden:boolean",
                "p_has_projector:boolean",
                "p_pet_friendly:boolean",
                "p_cover_photo_url:text present=\(!p_cover_photo_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_menu_photo_url:text present=\(!p_menu_photo_url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_proof_note:text present=\(!p_proof_note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"
            ].joined(separator: ", ")
        }

        var debugKeys: String {
            [
                "p_business_id",
                "p_owner_email",
                "p_venue_id",
                "p_venue_name",
                "p_venue_address",
                "p_venue_address_line2",
                "p_venue_city",
                "p_venue_state",
                "p_venue_country",
                "p_venue_zip_code",
                "p_venue_formatted_address",
                "p_venue_latitude",
                "p_venue_longitude",
                "p_venue_phone",
                "p_venue_website",
                "p_venue_description",
                "p_venue_features",
                "p_screen_count",
                "p_serves_food",
                "p_has_wifi",
                "p_has_garden",
                "p_has_projector",
                "p_pet_friendly",
                "p_cover_photo_url",
                "p_menu_photo_url",
                "p_proof_note"
            ].joined(separator: ",")
        }
    }

    private struct CreateBusinessHostedGameRPCParams: Encodable {
        enum CodingKeys: String, CodingKey {
            case p_business_id
            case p_venue_id
            case p_owner_email
            case p_venue_name
            case p_event_title
            case p_sport
            case p_home_team
            case p_away_team
            case p_external_league
            case p_event_date
            case p_event_time
            case p_external_game_id
            case p_external_source
            case p_imported_from_api
            case p_sound_on
            case p_audio_type
            case p_drink_special
            case p_cover_charge
            case p_expected_crowd
            case p_available_seating
            case p_reservations_available
            case p_waitlist_available
            case p_admin_status
            case p_scheduled_start_at
            case p_cleanup_delay_hours
        }

        let p_business_id: UUID
        let p_venue_id: UUID?
        let p_owner_email: String
        let p_venue_name: String
        let p_event_title: String
        let p_sport: String
        let p_home_team: String
        let p_away_team: String
        let p_external_league: String
        let p_event_date: String
        let p_event_time: String
        let p_external_game_id: String
        let p_external_source: String
        let p_imported_from_api: Bool
        let p_sound_on: Bool
        let p_audio_type: String
        let p_drink_special: String
        let p_cover_charge: String
        let p_expected_crowd: String
        let p_available_seating: String
        let p_reservations_available: Bool
        let p_waitlist_available: Bool
        let p_admin_status: String
        let p_scheduled_start_at: String
        let p_cleanup_delay_hours: Int

        init(game: VenueEventInsert, businessId: UUID) {
            p_business_id = businessId
            p_venue_id = game.venue_id
            p_owner_email = game.owner_email
            p_venue_name = game.venue_name
            p_event_title = game.event_title
            p_sport = game.sport
            p_home_team = game.home_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            p_away_team = game.away_team?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            p_external_league = game.external_league?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            p_event_date = game.event_date
            p_event_time = game.event_time
            p_external_game_id = game.external_game_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let externalSource = game.external_source?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            p_external_source = externalSource.isEmpty ? "manual" : externalSource
            p_imported_from_api = game.imported_from_api
            p_sound_on = game.sound_on
            p_audio_type = game.audio_type
            p_drink_special = game.drink_special
            p_cover_charge = game.cover_charge
            p_expected_crowd = game.expected_crowd
            p_available_seating = game.available_seating
            p_reservations_available = game.reservations_available
            p_waitlist_available = game.waitlist_available
            p_admin_status = game.admin_status
            p_scheduled_start_at = game.scheduled_start_at
            p_cleanup_delay_hours = game.cleanup_delay_hours
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(p_business_id, forKey: .p_business_id)
            if let p_venue_id {
                try container.encode(p_venue_id, forKey: .p_venue_id)
            } else {
                try container.encodeNil(forKey: .p_venue_id)
            }
            try container.encode(p_owner_email, forKey: .p_owner_email)
            try container.encode(p_venue_name, forKey: .p_venue_name)
            try container.encode(p_event_title, forKey: .p_event_title)
            try container.encode(p_sport, forKey: .p_sport)
            try container.encode(p_home_team, forKey: .p_home_team)
            try container.encode(p_away_team, forKey: .p_away_team)
            try container.encode(p_external_league, forKey: .p_external_league)
            try container.encode(p_event_date, forKey: .p_event_date)
            try container.encode(p_event_time, forKey: .p_event_time)
            try container.encode(p_external_game_id, forKey: .p_external_game_id)
            try container.encode(p_external_source, forKey: .p_external_source)
            try container.encode(p_imported_from_api, forKey: .p_imported_from_api)
            try container.encode(p_sound_on, forKey: .p_sound_on)
            try container.encode(p_audio_type, forKey: .p_audio_type)
            try container.encode(p_drink_special, forKey: .p_drink_special)
            try container.encode(p_cover_charge, forKey: .p_cover_charge)
            try container.encode(p_expected_crowd, forKey: .p_expected_crowd)
            try container.encode(p_available_seating, forKey: .p_available_seating)
            try container.encode(p_reservations_available, forKey: .p_reservations_available)
            try container.encode(p_waitlist_available, forKey: .p_waitlist_available)
            try container.encode(p_admin_status, forKey: .p_admin_status)
            try container.encode(p_scheduled_start_at, forKey: .p_scheduled_start_at)
            try container.encode(p_cleanup_delay_hours, forKey: .p_cleanup_delay_hours)
        }

        var debugSignature: String {
            [
                "p_business_id:uuid",
                "p_venue_id:uuid? present=\(p_venue_id != nil)",
                "p_owner_email:text present=\(!p_owner_email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_venue_name:text present=\(!p_venue_name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_event_title:text present=\(!p_event_title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_sport:text present=\(!p_sport.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_home_team:text present=\(!p_home_team.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_away_team:text present=\(!p_away_team.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_external_league:text present=\(!p_external_league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_event_date:text present=\(!p_event_date.isEmpty)",
                "p_event_time:text present=\(!p_event_time.isEmpty)",
                "p_external_game_id:text present=\(!p_external_game_id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_external_source:text present=\(!p_external_source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_imported_from_api:boolean",
                "p_sound_on:boolean",
                "p_audio_type:text present=\(!p_audio_type.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_drink_special:text present=\(!p_drink_special.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_cover_charge:text present=\(!p_cover_charge.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_expected_crowd:text present=\(!p_expected_crowd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_available_seating:text present=\(!p_available_seating.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_reservations_available:boolean",
                "p_waitlist_available:boolean",
                "p_admin_status:text present=\(!p_admin_status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_scheduled_start_at:text present=\(!p_scheduled_start_at.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)",
                "p_cleanup_delay_hours:integer"
            ].joined(separator: ", ")
        }

        var debugKeys: String {
            [
                "p_business_id",
                "p_venue_id",
                "p_owner_email",
                "p_venue_name",
                "p_event_title",
                "p_sport",
                "p_home_team",
                "p_away_team",
                "p_external_league",
                "p_event_date",
                "p_event_time",
                "p_external_game_id",
                "p_external_source",
                "p_imported_from_api",
                "p_sound_on",
                "p_audio_type",
                "p_drink_special",
                "p_cover_charge",
                "p_expected_crowd",
                "p_available_seating",
                "p_reservations_available",
                "p_waitlist_available",
                "p_admin_status",
                "p_scheduled_start_at",
                "p_cleanup_delay_hours"
            ].joined(separator: ",")
        }
    }

    /// Builds the Edge Function payload from the inserted row shape + amenity flags not stored as separate DB columns.
    private func venueClaimAdminNotifyPayloadFromInsert(
        claim: VenueClaimInsert,
        insertedId: UUID,
        createdAt: String?,
        approvalStatus: String?,
        claimKind: String,
        familyFriendly: Bool,
        parkingAvailable: Bool
    ) -> VenueClaimAdminNotifyPayload {
        let cover = claim.cover_photo_url.trimmingCharacters(in: .whitespacesAndNewlines)
        let menu = claim.menu_photo_url.trimmingCharacters(in: .whitespacesAndNewlines)
        return VenueClaimAdminNotifyPayload(
            claim_id: insertedId.uuidString,
            business_id: claim.business_id?.uuidString,
            venue_id: claim.venue_id?.uuidString,
            claim_kind: claimKind,
            owner_email: claim.owner_email,
            venue_name: claim.venue_name,
            venue_address: claim.venue_address,
            venue_address_line2: claim.venue_address_line2,
            venue_city: claim.venue_city,
            venue_state: claim.venue_state,
            venue_country: claim.venue_country,
            venue_zip_code: claim.venue_zip_code,
            venue_formatted_address: claim.venue_formatted_address,
            venue_latitude: claim.venue_latitude,
            venue_longitude: claim.venue_longitude,
            venue_phone: claim.venue_phone,
            venue_website: claim.venue_website,
            venue_description: claim.venue_description,
            venue_features: claim.venue_features,
            screen_count: claim.screen_count,
            serves_food: claim.serves_food,
            has_wifi: claim.has_wifi,
            has_garden: claim.has_garden,
            has_projector: claim.has_projector,
            pet_friendly: claim.pet_friendly,
            family_friendly: familyFriendly,
            parking_available: parkingAvailable,
            proof_note: claim.proof_note,
            cover_photo_url: cover,
            menu_photo_url: menu,
            photo_urls: [cover, menu].filter { !$0.isEmpty },
            created_at: createdAt ?? "",
            approval_status: approvalStatus ?? "pending"
        )
    }

    private func venueClaimAdminNotifyPayload(from row: VenueClaimRefreshRow) -> VenueClaimAdminNotifyPayload {
        let cover = row.cover_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let menu = row.menu_photo_url?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let businessName = row.business_id.flatMap { businessId in
            ownedBusinesses.first(where: { $0.id == businessId })?.display_name
        }
        var payload = VenueClaimAdminNotifyPayload(
            claim_id: row.id.uuidString,
            business_id: row.business_id?.uuidString,
            venue_id: row.venue_id?.uuidString,
            claim_kind: row.venue_id == nil ? "new_location" : "discover_claim",
            owner_email: row.owner_email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? OwnerBusinessEmail.normalized(venueOwnerEmail),
            venue_name: row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Venue request",
            venue_address: row.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            venue_address_line2: row.venue_address_line2?.trimmingCharacters(in: .whitespacesAndNewlines),
            venue_city: row.venue_city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            venue_state: row.venue_state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            venue_country: row.venue_country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? BusinessLocationCountryPolicy.defaultCountryCode,
            venue_zip_code: row.venue_zip_code?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            venue_formatted_address: row.venue_formatted_address?.trimmingCharacters(in: .whitespacesAndNewlines),
            venue_latitude: row.venue_latitude,
            venue_longitude: row.venue_longitude,
            venue_phone: row.venue_phone?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            venue_website: row.venue_website?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            venue_description: row.venue_description?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Venue request resent by business owner.",
            venue_features: row.venue_features?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            screen_count: row.screen_count ?? 0,
            serves_food: row.serves_food ?? false,
            has_wifi: row.has_wifi ?? false,
            has_garden: row.has_garden ?? false,
            has_projector: row.has_projector ?? false,
            pet_friendly: row.pet_friendly ?? false,
            family_friendly: false,
            parking_available: false,
            proof_note: row.proof_note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
            cover_photo_url: cover,
            menu_photo_url: menu,
            photo_urls: [cover, menu].filter { !$0.isEmpty },
            created_at: row.created_at ?? "",
            approval_status: row.approval_status ?? "pending"
        )
        payload.business_name = businessName
        return payload
    }

    /// Fire-and-forget admin email via Edge Function ``notify-venue-claim``.
    private func notifyVenueClaimAdminEmail(payload: VenueClaimAdminNotifyPayload) {
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(payload)
        } catch {
#if DEBUG
            print("[VenueClaimNotify] encode failed:", error)
#endif
            return
        }
#if DEBUG
        print("[VenueClaimNotify] sending notification claim_id=\(payload.claim_id)")
        print("[VenueClaimNotify] business_id=\(payload.business_id ?? "nil")")
        print("[VenueClaimNotify] venue_id=\(payload.venue_id ?? "nil")")
#endif
        Task.detached { [supabase, bodyData] in
            struct NotifyResponse: Decodable { let ok: Bool?; let error: String?; let detail: String? }
            do {
                let response: NotifyResponse = try await supabase.functions.invoke(
                    "notify-venue-claim",
                    options: FunctionInvokeOptions(method: .post, body: bodyData)
                )
#if DEBUG
                _ = response
                print("[VenueClaimNotify] notification sent")
#endif
            } catch let error as FunctionsError {
#if DEBUG
                if case let .httpError(status, data) = error {
                    let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                    print("[VenueClaimNotify] notification failed error=\(error.localizedDescription) httpStatus=\(status) body=\(body) full=\(error)")
                } else {
                    print("[VenueClaimNotify] notification failed error=\(error.localizedDescription) full=\(error)")
                }
#endif
            } catch {
#if DEBUG
                print("[VenueClaimNotify] notification failed error=\(error.localizedDescription) full=\(error)")
#endif
            }
        }
    }

    /// Awaitable variant used when a user-facing flow needs to log whether the admin email queued.
    @discardableResult
    private func sendVenueClaimAdminEmail(payload: VenueClaimAdminNotifyPayload) async -> Bool {
        let bodyData: Data
        do {
            bodyData = try JSONEncoder().encode(payload)
        } catch {
#if DEBUG
            print("[VenueClaimNotify] encode failed:", error)
#endif
            return false
        }

        struct NotifyResponse: Decodable { let ok: Bool?; let error: String?; let detail: String? }
        do {
            let response: NotifyResponse = try await supabase.functions.invoke(
                "notify-venue-claim",
                options: FunctionInvokeOptions(method: .post, body: bodyData)
            )
            return response.ok == true
        } catch let error as FunctionsError {
#if DEBUG
            if case let .httpError(status, data) = error {
                let body = String(data: data, encoding: .utf8) ?? "<non-utf8 body>"
                print("[VenueClaimNotify] notification failed error=\(error.localizedDescription) httpStatus=\(status) body=\(body) full=\(error)")
            } else {
                print("[VenueClaimNotify] notification failed error=\(error.localizedDescription) full=\(error)")
            }
#endif
            return false
        } catch {
#if DEBUG
            print("[VenueClaimNotify] notification failed error=\(error.localizedDescription) full=\(error)")
#endif
            return false
        }
    }

    private func validationErrorForAddLocationClaimForm(
        _ form: AddLocationClaimForm,
        requireCoverPhotoURL: Bool = true
    ) -> String? {
        let trimmedName = form.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = form.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCity = form.city.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedState = form.state.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(form.country)
        let trimmedPhone = form.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProof = form.proofNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let labels = BusinessLocationCountryPolicy.labels(for: trimmedCountry)

        guard !trimmedName.isEmpty,
              !trimmedAddress.isEmpty,
              !trimmedPhone.isEmpty,
              !trimmedDesc.isEmpty,
              !trimmedProof.isEmpty else {
#if DEBUG
            print("[InternationalAddressDebug] addressValidation=missingRequiredBase")
#endif
            return "Please fill in all required fields."
        }

        if !BusinessLocationCountryPolicy.supportedCountryCodes.contains(trimmedCountry) {
            return "Please choose a country."
        }

        if labels.localityRequired && trimmedCity.isEmpty {
            return "Please enter \(labels.locality.lowercased())."
        }

        if labels.regionRequired && trimmedState.isEmpty {
            return "Please enter \(labels.region.lowercased())."
        }

        if trimmedCountry == "US", !trimmedState.isEmpty, (trimmedState.count != 2 || !USStatesForBusinessLocation.validCodes.contains(trimmedState.uppercased())) {
            return "Please choose a valid US state."
        }

        if let phoneErr = BusinessPhoneFields.storageValidationError(combined: trimmedPhone) {
            return phoneErr
        }

        if requireCoverPhotoURL {
            let cover = form.coverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cover.isEmpty else {
                return "Main venue photo is required."
            }
        }
#if DEBUG
        print("[InternationalAddressDebug] addressValidation=passed")
#endif
        return nil
    }

    private static func validBusinessVenueCoordinate(latitude: Double?, longitude: Double?) -> CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        return CLLocationCoordinate2DIsValid(coordinate) ? coordinate : nil
    }

    private static func trimmedNonEmptyBusinessVenueString(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    private func venueClaimInsertForBusinessAddLocation(
        ownerEmail: String,
        businessId: UUID,
        form: AddLocationClaimForm
    ) async -> VenueClaimInsert {
        let email = OwnerBusinessEmail.normalized(ownerEmail)
        let trimmedName = form.venueName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddress = form.address.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAddressLine2 = form.addressLine2.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCity = form.city.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedState = form.state.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(form.country)
        let trimmedZip = form.zip.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPhone = form.phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedWebsite = form.website.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = form.description.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedProof = form.proofNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let cover = form.coverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let menu = form.menuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let screenCount = max(1, min(99, form.screenCount))
        let featuresLine = form.mergedVenueFeaturesLine()
        let formattedAddress = BusinessVenueAddressFormatter.formattedAddress(
            line1: trimmedAddress,
            line2: trimmedAddressLine2,
            locality: trimmedCity,
            region: trimmedState,
            postalCode: trimmedZip,
            countryCode: trimmedCountry
        )
        let geocodeQuery = BusinessVenueAddressFormatter.geocodeQuery(
            line1: trimmedAddress,
            line2: trimmedAddressLine2,
            locality: trimmedCity,
            region: trimmedState,
            postalCode: trimmedZip,
            countryCode: trimmedCountry
        )
        let pinnedCoordinate = Self.validBusinessVenueCoordinate(latitude: form.latitude, longitude: form.longitude)
        let geocodeResult = pinnedCoordinate == nil
            ? await geocodeBusinessVenueAddress(geocodeQuery, fallbackFormattedAddress: formattedAddress)
            : nil
        let resolvedFormattedAddress = Self.trimmedNonEmptyBusinessVenueString(form.formattedAddress)
            ?? geocodeResult?.formattedAddress
            ?? formattedAddress
        let resolvedCoordinate = pinnedCoordinate ?? geocodeResult?.coordinate
#if DEBUG
        if resolvedCoordinate != nil {
            print("[InternationalAddressDebug] coordinatesSaved=true")
        }
#endif

        return VenueClaimInsert(
            owner_email: email,
            business_id: businessId,
            venue_id: nil,
            venue_name: trimmedName,
            venue_address: trimmedAddress,
            venue_address_line2: trimmedAddressLine2.isEmpty ? nil : trimmedAddressLine2,
            venue_city: trimmedCity,
            venue_state: trimmedState,
            venue_country: trimmedCountry,
            venue_zip_code: trimmedZip,
            venue_formatted_address: resolvedFormattedAddress.isEmpty ? nil : resolvedFormattedAddress,
            venue_latitude: resolvedCoordinate?.latitude,
            venue_longitude: resolvedCoordinate?.longitude,
            venue_phone: trimmedPhone,
            venue_website: trimmedWebsite,
            venue_description: trimmedDesc,
            venue_features: featuresLine,
            screen_count: screenCount,
            serves_food: form.servesFood,
            has_wifi: form.hasWifi,
            has_garden: form.hasGarden,
            has_projector: form.hasProjector,
            pet_friendly: form.petFriendly,
            cover_photo_url: cover,
            menu_photo_url: menu,
            proof_note: trimmedProof
        )
    }

    /// Inserts a Phase C1 “add location” claim: ``venue_id`` nil, ``business_id`` set, no ``venues`` row until admin approval.
    func submitAddLocationClaim(form: AddLocationClaimForm) async -> String? {
#if DEBUG
        businessLocationRPCDebugDetails = ""
#endif
        if await businessBanGuardBlocks(path: "addLocation", action: "submitAddLocationClaim") {
            return "Your account is suspended."
        }

        let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(email) else {
            return OwnerBusinessEmail.invalidOwnerEmailUserMessage
        }
        guard let businessId = currentBusinessIdForAddLocation() else {
#if DEBUG
            print("[AddLocation] blocked no business id")
#endif
            return "Could not find a business account for this request."
        }

        let venueListingStatus = await businessVenueGamePostingStatus(storeKitBusinessProActive: false)
        let serverAllowsVenueClaim = venueListingStatus.canAddVenue
        let sessionUserId: UUID?
        do {
            let activeSession = try await supabase.auth.session
            sessionUserId = activeSession.user.id
        } catch {
            sessionUserId = nil
        }
        let currentAuthenticatedUserId = currentUserAuthId ?? sessionUserId
#if DEBUG
        print("[BusinessEntitlementGate] businessId=\(businessId.uuidString.lowercased()) operation=createVenue allowed=\(serverAllowsVenueClaim) reason=\(venueListingStatus.venueLimitReason)")
#endif
        guard serverAllowsVenueClaim else {
            return BusinessLimitCopy.venueLimitReached
        }

        if let err = validationErrorForAddLocationClaimForm(form) {
            return err
        }

        if let dup = await VenueClaimDuplicateCheck.rpcPreflight(
            supabase: supabase,
            businessId: businessId,
            ownerEmail: email,
            venueName: form.venueName.trimmingCharacters(in: .whitespacesAndNewlines),
            venueAddress: form.address.trimmingCharacters(in: .whitespacesAndNewlines),
            venueCity: form.city.trimmingCharacters(in: .whitespacesAndNewlines),
            venueState: form.state.trimmingCharacters(in: .whitespacesAndNewlines),
            venueZip: form.zip.trimmingCharacters(in: .whitespacesAndNewlines)
        ) {
            return dup
        }

        let claim = await venueClaimInsertForBusinessAddLocation(ownerEmail: email, businessId: businessId, form: form)

        do {
            let rpcName = "create_business_venue_claim"
            let rpcParams = CreateBusinessVenueClaimRPCParams(claim: claim, businessId: businessId)
#if DEBUG
            print("[BusinessLocationRPCParams] orderedKeys=\(rpcParams.debugKeys)")
            print("[BusinessLocationRPCStart] businessId=\(businessId.uuidString.lowercased()) venueId=\(claim.venue_id?.uuidString.lowercased() ?? "nil") authUserId=\(currentAuthenticatedUserId?.uuidString.lowercased() ?? "nil") ownerEmail=\(email) canAddVenue=\(serverAllowsVenueClaim) entitlement=\(Self.businessLocationEntitlementDebugSummary(venueListingStatus)) rpcName=\(rpcName) paramsKeys=\(rpcParams.debugKeys)")
#endif
            let insertedRows: [VenueClaimInsertedRow] = try await supabase
                .rpc(
                    rpcName,
                    params: rpcParams
                )
                .execute()
                .value
            guard let inserted = insertedRows.first else {
                throw NSError(
                    domain: "BusinessVenueClaim",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Location request submitted, but the app couldn’t read it back. Pull to refresh in a moment."]
                )
            }
#if DEBUG
            let vn = claim.venue_name
            print("[AddLocation] submitting full location request via RPC business_id=\(businessId.uuidString) venue_name=\(vn) screen_count=\(claim.screen_count) features_len=\(claim.venue_features.count)")
            print("[BusinessEntitlementGate] businessId=\(businessId.uuidString.lowercased()) operation=createVenue allowed=true reason=rpcInserted")
            print("[BusinessLocationRPCSuccess] businessId=\(businessId.uuidString.lowercased()) venueId=\(claim.venue_id?.uuidString.lowercased() ?? "nil") authUserId=\(currentAuthenticatedUserId?.uuidString.lowercased() ?? "nil") ownerEmail=\(email) canAddVenue=\(serverAllowsVenueClaim) entitlement=\(Self.businessLocationEntitlementDebugSummary(venueListingStatus)) rpcName=\(rpcName) paramsKeys=\(rpcParams.debugKeys) returnedRows=\(insertedRows.count)")
#endif
            let notifyPayload = venueClaimAdminNotifyPayloadFromInsert(
                claim: claim,
                insertedId: inserted.id,
                createdAt: inserted.created_at,
                approvalStatus: inserted.approval_status,
                claimKind: "new_location",
                familyFriendly: form.familyFriendly,
                parkingAvailable: form.parkingAvailable
            )
            notifyVenueClaimAdminEmail(payload: notifyPayload)

            await refreshPendingVenueClaimsForSettings()
            return nil
        } catch {
#if DEBUG
            let rpcParams = CreateBusinessVenueClaimRPCParams(claim: claim, businessId: businessId)
            let debugDetails = Self.businessLocationRPCDebugDetails(
                error,
                businessId: businessId,
                venueId: claim.venue_id,
                authUserId: currentAuthenticatedUserId,
                ownerEmail: email,
                canAddVenue: serverAllowsVenueClaim,
                listingStatus: venueListingStatus,
                rpcName: "create_business_venue_claim",
                params: rpcParams
            )
            businessLocationRPCDebugDetails = debugDetails
            Self.logVenueSubmissionRPCDebug(
                rpcName: "create_business_venue_claim",
                failingQuerySection: "submitAddLocationClaim",
                error: error,
                businessId: businessId,
                venueId: claim.venue_id
            )
            print("[BusinessLocationRPCFailure] \(debugDetails.replacingOccurrences(of: "\n", with: " | "))")
#endif
            print("ERROR SUBMITTING ADD LOCATION CLAIM:", error)
            return VenueClaimDuplicateCheck.userMessageIfKnownInsertError(error)
                ?? Self.businessEntitlementGateUserMessage(error)
                ?? error.localizedDescription
        }
    }

    /// Whether games/analytics (and other venue-bound tools) are available: at least one linked or legacy ``managedVenuesForOwner()`` row. Claim approval alone does not unlock tools without a venue row.
    func venueOwnerToolsUnlockedForUI() -> Bool {
        let managed = managedVenuesForOwner()
        if !managed.isEmpty { return true }
        if hasActiveVenueClaimRejectionForBusinessUI { return false }
        return false
    }

#if DEBUG
    func logBusinessAccountStateDebug() {
        let hasBiz = hasBusinessAccountForOwner()
        let loc = businessSettingsLocationStatusSubtitle()
        print("[BusinessState] hasBusiness=\(hasBiz)")
        print("[BusinessState] businessCount=\(ownedBusinesses.count)")
        print("[BusinessState] managedVenuesCount=\(managedVenuesForOwner().count)")
        print("[BusinessState] pendingClaimsCount=\(pendingVenueClaimsForSettings.count) rejectedClaimsCount=\(rejectedVenueClaimsForSettings.count)")
        print("[BusinessState] locationStatus=\(loc)")
    }
#endif

    /// Single venue row when the owner has exactly one actionable location (business-linked first, else legacy email match).
    func primaryOwnedVenueForLegacyCompatibility() -> VenueProfileRow? {
        switch ownedBusinessVenues.count {
        case 1:
            return ownedBusinessVenues.first
        case 0:
            if legacyOwnerVenuesForEmailFallback.count == 1 {
                return legacyOwnerVenuesForEmailFallback.first
            }
            return nil
        default:
            return nil
        }
    }

    private func sortedManagedVenues(_ rows: [VenueProfileRow]) -> [VenueProfileRow] {
        rows.sorted {
            let aLocked = Self.venueIsPlanLocked($0)
            let bLocked = Self.venueIsPlanLocked($1)
            if aLocked != bLocked { return !aLocked && bLocked }
            let a = $0.venue_name ?? ""
            let b = $1.venue_name ?? ""
            if a == b, let ia = $0.id, let ib = $1.id { return ia.uuidString < ib.uuidString }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    private func reconcileBusinessVenueLimitState(
        businesses: [BusinessRow],
        venueRows: [VenueProfileRow],
        approvedMetadata: [UUID: BusinessApprovedVenueClaimMetadata],
        entitlementsByBusinessID: [UUID: BusinessEntitlementSnapshot]
    ) async -> [VenueProfileRow] {
        guard !businesses.isEmpty, !venueRows.isEmpty else { return venueRows }
        var changedVenueIds = Set<UUID>()

        for business in businesses {
            let relatedRows = businessVenueLimitRows(
                for: business,
                allRows: venueRows,
                singleBusinessContext: businesses.count == 1
            )
            let uniqueRows = Self.dedupeVenueProfileRowsPreservingOrder(relatedRows)
            let approvedCount = uniqueRows.compactMap(\.id).count
            guard approvedCount > 0 else { continue }

            let activeCountBefore = uniqueRows.filter(Self.venueIsActiveForBusinessLimit).compactMap(\.id).count
            let status = entitlementsByBusinessID[business.id].map {
                BusinessVenueGamePostingStatus.fromServer($0, activeVenueCount: activeCountBefore)
            } ?? BusinessVenueGamePostingStatus.freeFallback(
                businessId: business.id,
                venuesUsed: activeCountBefore
            )
            let venueLimit = max(0, status.venueLimit)
            let sortedRows = businessVenueLimitSortedRows(uniqueRows, approvedMetadata: approvedMetadata)
            let targetActiveIds: Set<UUID>
            let reason: String

            if status.computedIsPro || status.unlimitedVenues {
                targetActiveIds = Set(sortedRows.compactMap(\.id))
                reason = "pro_reactivation"
            } else if approvedCount > venueLimit {
                if business.free_active_venues_selected_at?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    let currentlyActive = sortedRows.filter(Self.venueIsActiveForBusinessLimit)
                    var selected = Array(currentlyActive.prefix(venueLimit).compactMap(\.id))
                    if selected.count < venueLimit {
                        let selectedSet = Set(selected)
                        let fill = sortedRows
                            .compactMap(\.id)
                            .filter { !selectedSet.contains($0) }
                            .prefix(venueLimit - selected.count)
                        selected.append(contentsOf: fill)
                    }
                    targetActiveIds = Set(selected)
                    reason = "free_selection_persisted"
                } else {
                    targetActiveIds = Set(sortedRows.prefix(venueLimit).compactMap(\.id))
                    reason = "free_downgrade_default_latest"
                }
            } else {
                targetActiveIds = Set(sortedRows.compactMap(\.id))
                reason = "free_within_limit"
            }

            let lockedCount = max(0, approvedCount - targetActiveIds.count)
#if DEBUG
            print("[BusinessVenueLimitDebug] businessId=\(business.id.uuidString.lowercased()) planType=\(status.planType) computedIsPro=\(status.computedIsPro) venueLimit=\(venueLimit) approvedCount=\(approvedCount) activeCount=\(targetActiveIds.count) lockedCount=\(lockedCount)")
#endif

            for row in sortedRows {
                guard let venueId = row.id else { continue }
                let previousStatus = Self.venueAdminStatus(row.admin_status).isEmpty ? "active" : Self.venueAdminStatus(row.admin_status)
                let newStatus = targetActiveIds.contains(venueId) ? "active" : "plan_locked"
                guard previousStatus != newStatus else { continue }
                do {
                    try await supabase
                        .from("venues")
                        .update(VenueAdminStatusPatch(admin_status: newStatus))
                        .eq("id", value: venueId.uuidString.lowercased())
                        .execute()
                    changedVenueIds.insert(venueId)
#if DEBUG
                    let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Venue"
                    print("[BusinessVenueLockDebug] venueId=\(venueId.uuidString.lowercased()) venueName=\(venueName) previousStatus=\(previousStatus) newStatus=\(newStatus) reason=\(reason)")
#endif
                } catch {
#if DEBUG
                    let venueName = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Venue"
                    print("[BusinessVenueLockDebug] venueId=\(venueId.uuidString.lowercased()) venueName=\(venueName) previousStatus=\(previousStatus) newStatus=\(newStatus) reason=\(reason) error=\(error.localizedDescription)")
#endif
                }
            }
        }

        guard !changedVenueIds.isEmpty,
              let refreshed = await reloadManagedVenueRowsByIDs(venueRows.compactMap(\.id)) else {
            return venueRows
        }
        return refreshed
    }

    private func businessVenueLimitRows(
        for business: BusinessRow,
        allRows: [VenueProfileRow],
        singleBusinessContext: Bool
    ) -> [VenueProfileRow] {
        allRows.filter { row in
            if row.business_id == business.id { return true }
            guard singleBusinessContext else { return false }
            let rowBusinessIdMissing = row.business_id == nil
            if rowBusinessIdMissing, row.owner_email == nil { return true }
            let rowOwner = OwnerBusinessEmail.normalized(row.owner_email ?? "")
            let businessOwner = OwnerBusinessEmail.normalized(business.owner_email ?? "")
            return rowBusinessIdMissing && !rowOwner.isEmpty && rowOwner == businessOwner
        }
    }

    private func businessVenueLimitSortedRows(
        _ rows: [VenueProfileRow],
        approvedMetadata: [UUID: BusinessApprovedVenueClaimMetadata]
    ) -> [VenueProfileRow] {
        rows.sorted { lhs, rhs in
            let leftDate = businessVenueLimitSortDate(for: lhs, approvedMetadata: approvedMetadata)
            let rightDate = businessVenueLimitSortDate(for: rhs, approvedMetadata: approvedMetadata)
            switch (leftDate, rightDate) {
            case let (left?, right?):
                if left != right { return left > right }
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                break
            }
            let leftName = lhs.venue_name ?? ""
            let rightName = rhs.venue_name ?? ""
            if leftName != rightName {
                return leftName.localizedCaseInsensitiveCompare(rightName) == .orderedAscending
            }
            return (lhs.id?.uuidString ?? "") < (rhs.id?.uuidString ?? "")
        }
    }

    private func businessVenueLimitSortDate(
        for row: VenueProfileRow,
        approvedMetadata: [UUID: BusinessApprovedVenueClaimMetadata]
    ) -> Date? {
        let metadataRaw = row.id.flatMap { id in
            approvedMetadata[id]?.approvedAtRaw ?? approvedMetadata[id]?.createdAtRaw
        }?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !metadataRaw.isEmpty,
           let date = SupabaseTimestampParsing.parseTimestamptz(metadataRaw) {
            return date
        }
        let createdRaw = row.created_at?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !createdRaw.isEmpty {
            return SupabaseTimestampParsing.parseTimestamptz(createdRaw)
        }
        return nil
    }

    private func reloadManagedVenueRowsByIDs(_ ids: [UUID]) async -> [VenueProfileRow]? {
        let unique = Array(Set(ids))
        guard !unique.isEmpty else { return [] }
        do {
            return try await supabase
                .from("venues")
                .select()
                .in("id", values: unique.map(\.uuidString))
                .in("admin_status", values: ["active", "plan_locked"])
                .execute()
                .value
        } catch {
#if DEBUG
            print("[BusinessVenueLimitDebug] reloadFailed venueCount=\(unique.count) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    func saveFreeActiveVenueSelection(
        businessId: UUID,
        selectedVenueIds: [UUID],
        venueLimit: Int
    ) async -> Bool {
        var seenSelectedVenueIds = Set<UUID>()
        let selected = selectedVenueIds.filter { seenSelectedVenueIds.insert($0).inserted }
        guard !selected.isEmpty, selected.count <= max(0, venueLimit) else { return false }
#if DEBUG
        print("[BusinessActiveVenueSelectionDebug] saveStarted businessId=\(businessId.uuidString.lowercased()) selectedCount=\(selected.count) selectedIds=\(Self.businessActiveVenueSelectionDebugIdList(selected))")
        print("[BusinessActiveVenueSelectionDebug] rpcPayloadVenueIds count=\(selected.count) ids=\(Self.businessActiveVenueSelectionDebugIdList(selected))")
#endif

        struct SaveFreeActiveBusinessVenuesParams: Encodable {
            let p_business_id: UUID
            let p_active_venue_ids: [UUID]
        }
        struct SaveFreeActiveBusinessVenuesResult: Decodable {
            let success: Bool?
            let active_count: Int?
            let locked_count: Int?
        }

        do {
            let rows: [SaveFreeActiveBusinessVenuesResult] = try await supabase
                .rpc(
                    "save_free_active_business_venues",
                    params: SaveFreeActiveBusinessVenuesParams(
                        p_business_id: businessId,
                        p_active_venue_ids: selected
                    )
                )
                .execute()
                .value
            let result = rows.first
            let succeeded = result?.success == true
            if succeeded {
                await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
                let verifiedCounts = await MainActor.run {
                    businessActiveVenueSelectionCountsAfterRefresh(businessId: businessId)
                }
#if DEBUG
                print("[BusinessActiveVenueSelectionDebug] saveSucceeded activeCount=\(result?.active_count ?? selected.count) lockedCount=\(result?.locked_count ?? 0) verifiedActiveCount=\(verifiedCounts.active) verifiedLockedCount=\(verifiedCounts.locked)")
#endif
                return true
            } else {
#if DEBUG
                print("[BusinessActiveVenueSelectionDebug] saveFailed error=rpc_returned_success_false")
#endif
                return false
            }
        } catch let error as FunctionsError {
#if DEBUG
            if case let .httpError(status, data) = error {
                let body = String(data: data, encoding: .utf8) ?? ""
                print("[BusinessActiveVenueSelectionDebug] saveFailed error=httpError status=\(status) body=\(body)")
            } else {
                print("[BusinessActiveVenueSelectionDebug] saveFailed error=\(String(reflecting: error))")
            }
#endif
            return false
        } catch {
#if DEBUG
            let nsError = error as NSError
            print("[BusinessActiveVenueSelectionDebug] saveFailed error=\(error.localizedDescription) domain=\(nsError.domain) code=\(nsError.code) reflected=\(String(reflecting: error))")
#endif
            return false
        }
    }

    private func businessActiveVenueSelectionCountsAfterRefresh(businessId: UUID) -> (active: Int, locked: Int) {
        let rows = managedVenuesForOwner().filter { row in
            row.business_id == businessId
                || (row.business_id == nil && ownedBusinesses.count == 1)
        }
        let active = Set(rows.filter(Self.venueIsActiveForBusinessLimit).compactMap(\.id)).count
        let locked = Set(rows.filter(Self.venueIsPlanLocked).compactMap(\.id)).count
        return (active, locked)
    }

    private static func businessActiveVenueSelectionDebugIdList(_ ids: [UUID]) -> String {
        ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
    }

#if DEBUG
    private static func logBusinessPlanLockTransitions(
        previousStatusByVenueID: [UUID: String],
        currentRows: [VenueProfileRow],
        fallbackBusinessId: UUID?,
        planType: String,
        planStatus: String
    ) {
        let activeVenueCount = Set(currentRows.filter(venueIsActiveForBusinessLimit).compactMap(\.id)).count
        for row in currentRows {
            guard let venueId = row.id else { continue }
            let currentStatusRaw = venueAdminStatus(row.admin_status)
            let currentStatus = currentStatusRaw.isEmpty ? "active" : currentStatusRaw
            let previousStatus = previousStatusByVenueID[venueId] ?? "unknown"
            guard currentStatus == "plan_locked" || previousStatus == "plan_locked" else { continue }
            let downgradeDetected = currentStatus == "plan_locked" && previousStatus != "plan_locked"
            let businessId = row.business_id ?? fallbackBusinessId
            print("[BusinessPlanLock] businessId=\(businessId?.uuidString.lowercased() ?? "nil") venueId=\(venueId.uuidString.lowercased()) previousStatus=\(previousStatus) newStatus=\(currentStatus) activeVenueCount=\(activeVenueCount) planType=\(planType) planStatus=\(planStatus) downgradeDetected=\(downgradeDetected)")
        }
    }
#endif

    private func applySelectedVenueAfterBusinessLoad() {
        let managed = managedVenuesForOwner()
        let activeManaged = managed.filter(Self.venueIsActiveForBusinessLimit)
        guard !activeManaged.isEmpty else {
            let invalidSelection = ownerVenueDatabaseId?.uuidString.lowercased()
                ?? readPersistedSelectedVenueId()?.uuidString.lowercased()
                ?? "nil"
            let availableIds = managed.compactMap(\.id).map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
            ownerVenueDatabaseId = nil
            persistSelectedVenueId(nil)
#if DEBUG
            print("[BusinessVenuePickerDebug] invalidSelectionPrevented selection=\(invalidSelection) availableIds=\(availableIds.isEmpty ? "none" : availableIds)")
#endif
            return
        }

        if activeManaged.count == 1, let id = activeManaged.first?.id {
            ownerVenueDatabaseId = id
            persistSelectedVenueId(id)
#if DEBUG
            print("[BusinessPhaseB2] restored selected venue id=\(id.uuidString)")
#endif
            return
        }

        let activeManagedIds = Set(activeManaged.compactMap(\.id))
        if let persisted = readPersistedSelectedVenueId(), activeManagedIds.contains(persisted) {
            ownerVenueDatabaseId = persisted
#if DEBUG
            print("[BusinessPhaseB2] restored selected venue id=\(persisted.uuidString)")
#endif
            return
        }

        let sortedOwned = sortedManagedVenues(ownedBusinessVenues.filter(Self.venueIsActiveForBusinessLimit))
        let pickId: UUID?
        if let first = sortedOwned.first?.id {
            pickId = first
        } else {
            pickId = sortedManagedVenues(activeManaged).first?.id
        }

        if let id = pickId {
#if DEBUG
            let invalidSelection = ownerVenueDatabaseId?.uuidString.lowercased()
                ?? readPersistedSelectedVenueId()?.uuidString.lowercased()
                ?? "nil"
            let availableIds = activeManaged.compactMap(\.id).map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
            print("[BusinessVenuePickerDebug] invalidSelectionPrevented selection=\(invalidSelection) availableIds=\(availableIds.isEmpty ? "none" : availableIds)")
#endif
            ownerVenueDatabaseId = id
            persistSelectedVenueId(id)
#if DEBUG
            print("[BusinessPhaseB2] restored selected venue id=\(id.uuidString)")
#endif
        } else {
            ownerVenueDatabaseId = nil
            persistSelectedVenueId(nil)
        }
    }

    @MainActor
    func ensureValidSelectedManagedVenueForPresentation(source: String) -> Bool {
        let activeManaged = managedVenuesForOwner().filter(Self.venueIsActiveForBusinessLimit)
        let availableIds = activeManaged.compactMap(\.id)
        let availableIdLog = availableIds.map { $0.uuidString.lowercased() }.sorted().joined(separator: ",")
        let currentId = ownerVenueDatabaseId

        if let currentId, availableIds.contains(currentId) {
            return true
        }

        if let replacementId = sortedManagedVenues(activeManaged).first?.id {
#if DEBUG
            print("[BusinessVenuePickerDebug] invalidSelectionPrevented selection=\(currentId?.uuidString.lowercased() ?? "nil") availableIds=\(availableIdLog.isEmpty ? "none" : availableIdLog)")
#endif
            ownerVenueDatabaseId = replacementId
            persistSelectedVenueId(replacementId)
            return true
        }

#if DEBUG
        print("[BusinessVenuePickerDebug] invalidSelectionPrevented selection=\(currentId?.uuidString.lowercased() ?? "nil") availableIds=\(availableIdLog.isEmpty ? "none" : availableIdLog)")
#endif
        ownerVenueDatabaseId = nil
        persistSelectedVenueId(nil)
        clearStaleBusinessProfileVenueHeaderState()
        return false
    }

    /// Splits a stored `venues.phone` / claim phone string into ``ownerVenuePhoneDialISO`` + national ``ownerVenuePhone`` for editing.
    func applyVenueOwnerPhoneFromCombined(_ stored: String?) {
        let raw = stored?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parsed = BusinessPhoneFields.parse(stored: raw)
        ownerVenuePhoneDialISO = parsed.iso
        ownerVenuePhone = parsed.localDigits
    }

    /// Re-applies server truth for fields that must not change client-side when the venue is FanGeo-approved (see ``venueCoreIdentityLockedForSelectedVenue()``).
    func applyLockedVenueIdentityFromServerRow(_ saved: VenueProfileRow) {
        ownerVenueName = saved.venue_name ?? ""
        ownerVenueAddress = saved.address ?? ""
        ownerVenueAddressLine2 = saved.address_line2 ?? ""
        ownerVenueCity = saved.city ?? ""
        ownerVenueState = saved.state ?? ""
        ownerVenueZipCode = saved.zip_code ?? ""
        ownerVenueCountry = saved.country ?? BusinessLocationCountryPolicy.defaultCountryCode
        ownerVenueSupporterCountry = saved.supporter_country ?? ""
    }

    /// Applies ``VenueProfileRow`` fields into owner-facing ``MapViewModel`` state (photos, name, etc.).
    func applyVenueProfileRowToOwnerState(_ saved: VenueProfileRow) {
        if let id = saved.id {
            ownerVenueDatabaseId = id
        }
        ownerVenueName = saved.venue_name ?? ""
        ownerVenueAddress = saved.address ?? ""
        ownerVenueAddressLine2 = saved.address_line2 ?? ""
        ownerVenueCity = saved.city ?? ""
        ownerVenueState = saved.state ?? ""
        ownerVenueZipCode = saved.zip_code ?? ""
        ownerVenueCountry = saved.country ?? BusinessLocationCountryPolicy.defaultCountryCode
        ownerVenueSupporterCountry = saved.supporter_country ?? ""
#if DEBUG
        print("[VenueSupporterIdentityDebug] load venueId=\(saved.id?.uuidString.lowercased() ?? "nil") supporterCountry=\(ownerVenueSupporterCountry.isEmpty ? "nil" : ownerVenueSupporterCountry)")
#endif
        applyVenueOwnerPhoneFromCombined(saved.phone)
        ownerVenueWebsite = saved.website ?? ""
        ownerVenueDescription = saved.description ?? ""
        ownerVenueFeatures = saved.features ?? ""
        ownerVenueScreenCount = saved.screen_count ?? 1
        ownerVenueServesFood = saved.serves_food ?? false
        ownerVenueHasWifi = saved.has_wifi ?? false
        ownerVenueHasGarden = saved.has_garden ?? false
        ownerVenueHasProjector = saved.has_projector ?? false
        ownerVenuePetFriendly = saved.pet_friendly ?? false
        let savedCover = saved.cover_photo_url ?? ""
        let savedCoverThumb = saved.cover_photo_thumbnail_url ?? ""
        let coverPendingMatchesVenue = pendingVenueCoverPhotoVenueID == nil || pendingVenueCoverPhotoVenueID == saved.id
        if let pending = pendingVenueCoverPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           coverPendingMatchesVenue,
           !pending.isEmpty,
           pending != savedCover {
            venueCoverPhotoURL = pending
            venueCoverPhotoThumbnailURL = pendingVenueCoverPhotoThumbnailURL ?? savedCoverThumb
            print("[VenuePhotoSaveDebug] stalePhotoOverwritePrevented=true")
        } else {
            venueCoverPhotoURL = savedCover
            venueCoverPhotoThumbnailURL = savedCoverThumb
            if pendingVenueCoverPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines) == savedCover {
                pendingVenueCoverPhotoVenueID = nil
                pendingVenueCoverPhotoURL = nil
                pendingVenueCoverPhotoThumbnailURL = nil
            }
        }

        let savedMenu = saved.menu_photo_url ?? ""
        let savedMenuThumb = saved.menu_photo_thumbnail_url ?? ""
        let menuPendingMatchesVenue = pendingVenueMenuPhotoVenueID == nil || pendingVenueMenuPhotoVenueID == saved.id
        if let pending = pendingVenueMenuPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           menuPendingMatchesVenue,
           !pending.isEmpty,
           pending != savedMenu {
            venueMenuPhotoURL = pending
            venueMenuPhotoThumbnailURL = pendingVenueMenuPhotoThumbnailURL ?? savedMenuThumb
            print("[VenuePhotoSaveDebug] stalePhotoOverwritePrevented=true")
        } else {
            venueMenuPhotoURL = savedMenu
            venueMenuPhotoThumbnailURL = savedMenuThumb
            if pendingVenueMenuPhotoURL?.trimmingCharacters(in: .whitespacesAndNewlines) == savedMenu {
                pendingVenueMenuPhotoVenueID = nil
                pendingVenueMenuPhotoURL = nil
                pendingVenueMenuPhotoThumbnailURL = nil
            }
        }
    }

    @discardableResult
    func updateManagedVenueProfileCaches(_ saved: VenueProfileRow) -> Bool {
        guard let savedId = saved.id else { return false }
        var updated = false
        ownedBusinessVenues = ownedBusinessVenues.map { row in
            if row.id == savedId {
                updated = true
                return saved
            }
            return row
        }
        legacyOwnerVenuesForEmailFallback = legacyOwnerVenuesForEmailFallback.map { row in
            if row.id == savedId {
                updated = true
                return saved
            }
            return row
        }
        if !updated, ownedBusinessVenues.isEmpty {
            legacyOwnerVenuesForEmailFallback.append(saved)
            updated = true
        }
        print("[VenuePhotoSaveDebug] cacheUpdatedPhotoURL=\(saved.cover_photo_url ?? "")")
        return updated
    }

    func refreshVenuePhotoDisplayStateAfterProfileSave(_ saved: VenueProfileRow) async {
        guard let venueId = saved.id else { return }

        let oldCoverPhotoURL = venuePhotoDebugCoverURL(for: venueId)
        let oldCacheURLs = venuePhotoCacheInvalidationURLs(for: venueId, saved: nil)
        let businessVenueRowUpdated = updateManagedVenueProfileCaches(saved)
        applyVenueProfileRowToOwnerState(saved)

        var discoverVenueUpdated = false
        bars = bars.map { bar in
            guard bar.id == venueId else { return bar }
            discoverVenueUpdated = true
            return Self.copyBarVenue(bar, applyingVenueProfile: saved)
        }

        if let selected = selectedBar, selected.id == venueId {
            selectedBar = Self.copyBarVenue(selected, applyingVenueProfile: saved)
        }
        let selectedVenueUpdated = selectedBar?.id == venueId

        followingTabSavedVenues = followingTabSavedVenues.map { bar in
            guard bar.id == venueId else { return bar }
            return Self.copyBarVenue(bar, applyingVenueProfile: saved)
        }

        let newCacheURLs = venuePhotoCacheInvalidationURLs(for: venueId, saved: saved)
        let invalidationURLs = Array(Set(oldCacheURLs + newCacheURLs))
        let cacheInvalidated = !invalidationURLs.isEmpty
        if cacheInvalidated {
            await DiscoverMapImageCache.shared.invalidate(urls: invalidationURLs)
        }

#if DEBUG
        print("[VenuePhotoRefreshDebug] venueId=\(venueId.uuidString.lowercased())")
        print("[VenuePhotoRefreshDebug] oldCoverPhotoURL=\(oldCoverPhotoURL)")
        print("[VenuePhotoRefreshDebug] newCoverPhotoURL=\(saved.cover_photo_url ?? "")")
        print("[VenuePhotoRefreshDebug] cacheInvalidated=\(cacheInvalidated)")
        print("[VenuePhotoRefreshDebug] selectedVenueUpdated=\(selectedVenueUpdated)")
        print("[VenuePhotoRefreshDebug] discoverVenueUpdated=\(discoverVenueUpdated)")
        print("[VenuePhotoRefreshDebug] businessVenueRowUpdated=\(businessVenueRowUpdated)")
#endif
    }

    private func venuePhotoDebugCoverURL(for venueId: UUID) -> String {
        let candidates = [
            selectedBar?.id == venueId ? selectedBar?.coverPhotoURL : nil,
            bars.first(where: { $0.id == venueId })?.coverPhotoURL,
            ownedBusinessVenues.first(where: { $0.id == venueId })?.cover_photo_url,
            legacyOwnerVenuesForEmailFallback.first(where: { $0.id == venueId })?.cover_photo_url,
            ownerVenueDatabaseId == venueId ? venueCoverPhotoURL : nil
        ]
        return candidates
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    private func venuePhotoCacheInvalidationURLs(for venueId: UUID, saved: VenueProfileRow?) -> [URL] {
        let managed = ownedBusinessVenues.first(where: { $0.id == venueId })
        let legacy = legacyOwnerVenuesForEmailFallback.first(where: { $0.id == venueId })
        let bar = bars.first(where: { $0.id == venueId })
        let selected = selectedBar?.id == venueId ? selectedBar : nil
        let raw = [
            saved?.cover_photo_url,
            saved?.cover_photo_thumbnail_url,
            saved?.menu_photo_url,
            saved?.menu_photo_thumbnail_url,
            managed?.cover_photo_url,
            managed?.cover_photo_thumbnail_url,
            managed?.menu_photo_url,
            managed?.menu_photo_thumbnail_url,
            legacy?.cover_photo_url,
            legacy?.cover_photo_thumbnail_url,
            legacy?.menu_photo_url,
            legacy?.menu_photo_thumbnail_url,
            bar?.coverPhotoURL,
            bar?.coverPhotoThumbnailURL,
            bar?.menuPhotoURL,
            bar?.menuPhotoThumbnailURL,
            selected?.coverPhotoURL,
            selected?.coverPhotoThumbnailURL,
            selected?.menuPhotoURL,
            selected?.menuPhotoThumbnailURL,
            ownerVenueDatabaseId == venueId ? venueCoverPhotoURL : nil,
            ownerVenueDatabaseId == venueId ? venueCoverPhotoThumbnailURL : nil,
            ownerVenueDatabaseId == venueId ? venueMenuPhotoURL : nil,
            ownerVenueDatabaseId == venueId ? venueMenuPhotoThumbnailURL : nil
        ]

        var seen = Set<String>()
        return raw.compactMap { value -> URL? in
            let trimmed = ImageDisplayURL.canonicalStorageURLString(value)
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return URL(string: trimmed)
        }
    }

    private static func copyBarVenue(_ bar: BarVenue, applyingVenueProfile saved: VenueProfileRow) -> BarVenue {
        let coordinate: CLLocationCoordinate2D = {
            guard let lat = saved.latitude,
                  let lon = saved.longitude else {
                return bar.coordinate
            }
            let candidate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
            return CLLocationCoordinate2DIsValid(candidate) ? candidate : bar.coordinate
        }()

        return BarVenue(
            id: bar.id,
            name: saved.venue_name ?? bar.name,
            address: saved.formatted_address ?? saved.address ?? bar.address,
            phone: saved.phone ?? bar.phone,
            primarySport: bar.primarySport,
            distance: bar.distance,
            rating: bar.rating,
            tags: bar.tags,
            games: bar.games,
            coordinate: coordinate,
            goingCounts: bar.goingCounts,
            screenCount: saved.screen_count ?? bar.screenCount,
            servesFood: saved.serves_food ?? bar.servesFood,
            hasWifi: saved.has_wifi ?? bar.hasWifi,
            hasGarden: saved.has_garden ?? bar.hasGarden,
            hasProjector: saved.has_projector ?? bar.hasProjector,
            petFriendly: saved.pet_friendly ?? bar.petFriendly,
            rawVenueFeatures: saved.features ?? bar.rawVenueFeatures,
            coverPhotoURL: saved.cover_photo_url ?? bar.coverPhotoURL,
            menuPhotoURL: saved.menu_photo_url ?? bar.menuPhotoURL,
            coverPhotoThumbnailURL: saved.cover_photo_thumbnail_url ?? bar.coverPhotoThumbnailURL,
            menuPhotoThumbnailURL: saved.menu_photo_thumbnail_url ?? bar.menuPhotoThumbnailURL,
            ownerEmail: saved.owner_email ?? bar.ownerEmail,
            businessId: saved.business_id ?? bar.businessId,
            adminStatus: saved.admin_status ?? bar.adminStatus,
            communityType: saved.community_type ?? bar.communityType,
            placeType: saved.place_type ?? bar.placeType,
            sportTags: saved.sport_tags ?? bar.sportTags,
            venueOwnerEmailRaw: saved.owner_email ?? bar.venueOwnerEmailRaw,
            businessOwnerEmailRaw: bar.businessOwnerEmailRaw,
            contactEmailRaw: bar.contactEmailRaw,
            supporterCountry: saved.supporter_country ?? bar.supporterCountry,
            originType: saved.origin_type ?? bar.originType
        )
    }

    @MainActor
    func clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: UUID?) {
        let venueToken = deletedSelectedVenue?.uuidString.lowercased() ?? "nil"
#if DEBUG
        print("[VenueOwnerEmptyStateDebug] clearedDeletedSelectedVenue=\(venueToken)")
#endif
        ownerVenueDatabaseId = nil
        persistSelectedVenueId(nil)
        clearStaleBusinessProfileVenueHeaderState()
    }

    @MainActor
    private func clearStaleBusinessProfileVenueHeaderState() {
        clearSelectedVenueDraftFieldsAfterDeletion()
        venueIsApproved = false
        venueClaimStatus = pendingVenueClaimsForSettings.isEmpty ? "Not submitted" : "Pending Review"
#if DEBUG
        print("[BusinessProfileHeaderDebug] clearedStaleVenueHeader=true")
        print("[BusinessProfileHeaderDebug] managedVenueCount=\(managedVenuesForOwner().count)")
#endif
    }

    /// Business self-service release/delete for one managed venue. The RPC does the database work transactionally;
    /// local UI is only removed after the RPC succeeds and verification shows the venue no longer belongs to the business.
    func releaseOrDeleteBusinessVenue(venueId: UUID) async throws -> BusinessVenueReleaseOrDeleteResult {
        let deleteContext = await MainActor.run {
            let managed = (ownedBusinessVenues + legacyOwnerVenuesForEmailFallback)
                .first { $0.id == venueId }
            let rawOrigin = managed?.origin_type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let originType = rawOrigin == "community" ? "community" : "business"
            let business = managed?.business_id.flatMap { businessId in
                ownedBusinesses.first { $0.id == businessId }
            }
            let currentAuthId = currentUserAuthId
            let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
            return (
                originType: originType,
                action: originType == "community" ? "release" : "hardDelete",
                venueName: managed?.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                businessId: managed?.business_id,
                ownerEmail: managed?.owner_email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                adminStatus: Self.venueAdminStatus(managed?.admin_status).isEmpty ? "active" : Self.venueAdminStatus(managed?.admin_status),
                businessOwnerEmail: business?.owner_email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
                businessOwnerUserId: business?.owner_user_id,
                currentAuthId: currentAuthId,
                signedInOwnerEmail: ownerEmail,
                ownsBusiness: business.map {
                    ($0.owner_user_id != nil && $0.owner_user_id == currentAuthId)
                        || OwnerBusinessEmail.normalized($0.owner_email ?? "") == ownerEmail
                } ?? false
            )
        }
#if DEBUG
        print("[VenueDeleteModeDebug] originType=\(deleteContext.originType) action=\(deleteContext.action)")
        print("[BusinessVenueDeleteDebug] ownershipCheck venueId=\(venueId.uuidString.lowercased()) venueName=\(deleteContext.venueName.isEmpty ? "nil" : deleteContext.venueName) businessId=\(deleteContext.businessId?.uuidString.lowercased() ?? "nil") adminStatus=\(deleteContext.adminStatus) rowOwnerEmail=\(deleteContext.ownerEmail.isEmpty ? "nil" : deleteContext.ownerEmail) businessOwnerEmail=\(deleteContext.businessOwnerEmail.isEmpty ? "nil" : deleteContext.businessOwnerEmail) businessOwnerUserId=\(deleteContext.businessOwnerUserId?.uuidString.lowercased() ?? "nil") currentAuthId=\(deleteContext.currentAuthId?.uuidString.lowercased() ?? "nil") signedInOwnerEmail=\(deleteContext.signedInOwnerEmail.isEmpty ? "nil" : deleteContext.signedInOwnerEmail) ownsBusiness=\(deleteContext.ownsBusiness)")
#endif

        let authLogBusinessEmail = deleteContext.businessOwnerEmail.isEmpty
            ? deleteContext.signedInOwnerEmail
            : deleteContext.businessOwnerEmail
        let authSession = await resolveBusinessVenueDeleteAuthSession(businessEmail: authLogBusinessEmail)
        guard authSession != nil else {
            throw BusinessVenueDeletionError.missingAuthSession
        }
        let banOwnerEmail = authLogBusinessEmail
        if await businessBanGuardBlocks(
            path: "businessVenue",
            action: "releaseOrDeleteBusinessVenue",
            businessId: deleteContext.businessId,
            ownerEmail: banOwnerEmail,
            ownerUserId: deleteContext.businessOwnerUserId
        ) {
            throw BusinessVenueDeletionError.serverRejected
        }

        let eventIDsBeforeRPC = await MainActor.run {
            Set(venueEventRows.compactMap { row -> UUID? in
                guard row.venue_id == venueId else { return nil }
                return row.id
            })
        }

        let response: BusinessVenueReleaseOrDeleteResult
        do {
            print("[BusinessVenueDeleteDebug] rpcStarted venueId=\(venueId.uuidString.lowercased())")
            response = try await supabase
                .rpc(
                    "release_or_delete_business_venue",
                    params: ReleaseOrDeleteBusinessVenueParams(p_venue_id: venueId)
                )
                .execute()
                .value
        } catch {
            Self.logBusinessVenueDeleteRpcRawError(error)
            throw error
        }

        guard response.ok else {
            throw BusinessVenueDeletionError.serverRejected
        }

        print("[BusinessVenueDeleteDebug] rpcSucceeded venueId=\(venueId.uuidString.lowercased())")
        let verification = try await verifyBusinessVenueDeletePersisted(venueId: venueId, previousBusinessId: deleteContext.businessId ?? response.business_id)
        guard !verification.stillBelongsToBusiness else {
            throw BusinessVenueDeletionError.serverRejected
        }

#if DEBUG
        if response.releasedCommunityVenue {
            print("[VenueReleaseVerify] venueRetained=\(response.venue_retained == true)")
            print("[VenueReleaseVerify] claimReleased=\(response.claim_released == true)")
            print("[VenueReleaseVerify] businessFieldsCleared=\(response.business_fields_cleared == true)")
            print("[VenueReleaseVerify] storagePathsReturned=\(response.storage_paths_returned ?? response.deleted_storage_paths?.count ?? 0)")
        }
#endif

        await stopVenueOwnerAnalyticsRealtime()
        await removeAllVenueEventCommentsRealtimeListeners()
        await deleteBusinessVenueStorageObjectsBestEffort(paths: response.deleted_storage_paths ?? [])

        let deletedEventIDs = eventIDsBeforeRPC.union(Set(response.deleted_event_ids ?? []))
        for eventID in deletedEventIDs {
            await stopVenueEventPredictionRealtime(for: eventID)
            await stopVenueEventCommentReactionRefresh(for: eventID)
            await stopVenueEventCommentsRealtime(for: eventID)
        }

        let deletedURLs = await MainActor.run {
            finalizeLocalBusinessVenueDeletion(venueId: venueId, deletedEventIDs: deletedEventIDs)
        }
        await DiscoverMapImageCache.shared.invalidate(urls: deletedURLs)

        await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await loadVenuesFromSupabase(forceRefresh: true)
        return response
    }

    private func resolveBusinessVenueDeleteAuthSession(businessEmail: String) async -> Session? {
        let normalizedBusinessEmail = businessEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "nil"
            : businessEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        func logAuthContext(_ session: Session?) {
            let userId = session?.user.id.uuidString.lowercased() ?? "nil"
            let email = OwnerBusinessEmail.normalized(session?.user.email ?? "")
            print("[BusinessVenueDeleteDebug] authContext userId=\(userId) email=\(email.isEmpty ? "nil" : email) businessEmail=\(normalizedBusinessEmail)")
        }

        func applyAuthSession(_ session: Session) async {
            await MainActor.run {
                currentUserAuthId = session.user.id
            }
        }

        func attemptRefresh() async -> Session? {
            do {
                let refreshed = try await supabase.auth.refreshSession()
                print("[BusinessVenueDeleteDebug] authSessionRefreshAttempted result=success")
                await applyAuthSession(refreshed)
                _ = await ensureBusinessOwnerSessionFlagsIfPossible(context: "businessVenueDeleteAuthRefresh")
                logAuthContext(refreshed)
                return refreshed
            } catch {
                print("[BusinessVenueDeleteDebug] authSessionRefreshAttempted result=failure")
                logAuthContext(nil)
                return nil
            }
        }

        do {
            let session = try await supabase.auth.session
            guard session.isExpired else {
                await applyAuthSession(session)
                _ = await ensureBusinessOwnerSessionFlagsIfPossible(context: "businessVenueDeleteAuthActive")
                logAuthContext(session)
                return session
            }

            return await attemptRefresh()
        } catch {
            print("[BusinessVenueDeleteDebug] authSessionMissingBeforeDelete")
            return await attemptRefresh()
        }
    }

    private func verifyBusinessVenueDeletePersisted(
        venueId: UUID,
        previousBusinessId: UUID?
    ) async throws -> (exists: Bool, stillBelongsToBusiness: Bool) {
        let rows: [BusinessVenueDeleteVerificationRow] = try await supabase
            .from("venues")
            .select("id,venue_name,business_id,owner_email,admin_status,origin_type")
            .eq("id", value: venueId.uuidString.lowercased())
            .limit(1)
            .execute()
            .value
        let row = rows.first
        let exists = row != nil
        let stillBelongsToBusiness = row?.business_id != nil && row?.business_id == previousBusinessId
        print("[BusinessVenueDeleteDebug] postDeleteVenueStillExists venueId=\(venueId.uuidString.lowercased()) exists=\(exists)")
        if let row {
            print("[BusinessVenueDeleteDebug] postDeleteVenueStillExistsDetails venueId=\(venueId.uuidString.lowercased()) venueName=\(row.venue_name ?? "nil") businessId=\(row.business_id?.uuidString.lowercased() ?? "nil") ownerEmail=\(row.owner_email ?? "nil") adminStatus=\(row.admin_status ?? "nil") originType=\(row.origin_type ?? "nil") stillBelongsToBusiness=\(stillBelongsToBusiness)")
        }
        return (exists, stillBelongsToBusiness)
    }

    private static func logBusinessVenueDeleteRpcRawError(_ error: Error) {
        if let postgrestError = error as? PostgrestError {
            print("[BusinessVenueDeleteDebug] rpcRawError code=\(postgrestError.code ?? "nil") message=\(postgrestError.message) details=\(postgrestError.detail ?? "nil") hint=\(postgrestError.hint ?? "nil")")
            return
        }
        let nsError = error as NSError
        print("[BusinessVenueDeleteDebug] rpcRawError code=\(nsError.code) message=\(error.localizedDescription) details=\(String(describing: nsError.userInfo)) hint=nil")
    }

    private func deleteBusinessVenueStorageObjectsBestEffort(paths: [String]) async {
        let deletedStoragePaths = paths.filter { !$0.isEmpty }
        guard !deletedStoragePaths.isEmpty else { return }

#if DEBUG
        for path in deletedStoragePaths {
            print("[VenueDeleteStorageDebug] deletingPath=\(path)")
        }
#endif
        do {
            try await supabase.storage
                .from("venue-photos")
                .remove(paths: deletedStoragePaths)
#if DEBUG
            print("[VenueDeleteStorageCleanup] removed count=\(deletedStoragePaths.count)")
#endif
        } catch {
#if DEBUG
            print("[VenueDeleteStorageCleanup] failed count=\(deletedStoragePaths.count) error=\(error.localizedDescription)")
#endif
        }
    }

    @MainActor
    private func applyOptimisticBusinessVenueDeletion(
        venueId: UUID,
        deletedEventIDs: Set<UUID>
    ) -> BusinessVenueDeletionLocalSnapshot {
        let snapshot = BusinessVenueDeletionLocalSnapshot(
            ownerVenueDatabaseId: ownerVenueDatabaseId,
            ownedBusinessVenues: ownedBusinessVenues,
            legacyOwnerVenuesForEmailFallback: legacyOwnerVenuesForEmailFallback,
            bars: bars,
            selectedBar: selectedBar,
            selectedEvent: selectedEvent,
            followingTabSavedVenues: followingTabSavedVenues,
            favoriteVenueIDs: favoriteVenueIDs,
            followingTabGoingItems: followingTabGoingItems,
            followingTabGoingInterestCounts: followingTabGoingInterestCounts,
            venueEventRows: venueEventRows,
            venueEventIDsByKey: venueEventIDsByKey,
            venueEventInterestIDs: venueEventInterestIDs,
            venueEventInterestCounts: venueEventInterestCounts,
            goingProfilesByVenueEventID: goingProfilesByVenueEventID,
            venueEventPredictionSummaries: venueEventPredictionSummaries,
            ownerVenueName: ownerVenueName,
            ownerVenueAddress: ownerVenueAddress,
            ownerVenueAddressLine2: ownerVenueAddressLine2,
            ownerVenueCity: ownerVenueCity,
            ownerVenueState: ownerVenueState,
            ownerVenueZipCode: ownerVenueZipCode,
            ownerVenueCountry: ownerVenueCountry,
            ownerVenuePhoneDialISO: ownerVenuePhoneDialISO,
            ownerVenuePhone: ownerVenuePhone,
            ownerVenueWebsite: ownerVenueWebsite,
            ownerVenueDescription: ownerVenueDescription,
            ownerVenueFeatures: ownerVenueFeatures,
            ownerVenueSupporterCountry: ownerVenueSupporterCountry,
            ownerVenueScreenCount: ownerVenueScreenCount,
            ownerVenueServesFood: ownerVenueServesFood,
            ownerVenueHasWifi: ownerVenueHasWifi,
            ownerVenueHasGarden: ownerVenueHasGarden,
            ownerVenueHasProjector: ownerVenueHasProjector,
            ownerVenuePetFriendly: ownerVenuePetFriendly,
            venueCoverPhotoURL: venueCoverPhotoURL,
            venueMenuPhotoURL: venueMenuPhotoURL,
            venueCoverPhotoThumbnailURL: venueCoverPhotoThumbnailURL,
            venueMenuPhotoThumbnailURL: venueMenuPhotoThumbnailURL
        )

        removeVenueFromLocalCollections(venueId: venueId, deletedEventIDs: deletedEventIDs)
        applySelectedVenueAfterBusinessLoad()
        if ownerVenueDatabaseId == nil {
            clearStaleBusinessProfileVenueHeaderState()
        }
        return snapshot
    }

    @MainActor
    private func restoreBusinessVenueDeletionSnapshot(_ snapshot: BusinessVenueDeletionLocalSnapshot) {
        ownerVenueDatabaseId = snapshot.ownerVenueDatabaseId
        ownedBusinessVenues = snapshot.ownedBusinessVenues
        legacyOwnerVenuesForEmailFallback = snapshot.legacyOwnerVenuesForEmailFallback
        bars = snapshot.bars
        selectedBar = snapshot.selectedBar
        selectedEvent = snapshot.selectedEvent
        followingTabSavedVenues = snapshot.followingTabSavedVenues
        favoriteVenueIDs = snapshot.favoriteVenueIDs
        followingTabGoingItems = snapshot.followingTabGoingItems
        followingTabGoingInterestCounts = snapshot.followingTabGoingInterestCounts
        venueEventRows = snapshot.venueEventRows
        venueEventIDsByKey = snapshot.venueEventIDsByKey
        venueEventInterestIDs = snapshot.venueEventInterestIDs
        venueEventInterestCounts = snapshot.venueEventInterestCounts
        goingProfilesByVenueEventID = snapshot.goingProfilesByVenueEventID
        venueEventPredictionSummaries = snapshot.venueEventPredictionSummaries
        ownerVenueName = snapshot.ownerVenueName
        ownerVenueAddress = snapshot.ownerVenueAddress
        ownerVenueAddressLine2 = snapshot.ownerVenueAddressLine2
        ownerVenueCity = snapshot.ownerVenueCity
        ownerVenueState = snapshot.ownerVenueState
        ownerVenueZipCode = snapshot.ownerVenueZipCode
        ownerVenueCountry = snapshot.ownerVenueCountry
        ownerVenuePhoneDialISO = snapshot.ownerVenuePhoneDialISO
        ownerVenuePhone = snapshot.ownerVenuePhone
        ownerVenueWebsite = snapshot.ownerVenueWebsite
        ownerVenueDescription = snapshot.ownerVenueDescription
        ownerVenueFeatures = snapshot.ownerVenueFeatures
        ownerVenueSupporterCountry = snapshot.ownerVenueSupporterCountry
        ownerVenueScreenCount = snapshot.ownerVenueScreenCount
        ownerVenueServesFood = snapshot.ownerVenueServesFood
        ownerVenueHasWifi = snapshot.ownerVenueHasWifi
        ownerVenueHasGarden = snapshot.ownerVenueHasGarden
        ownerVenueHasProjector = snapshot.ownerVenueHasProjector
        ownerVenuePetFriendly = snapshot.ownerVenuePetFriendly
        venueCoverPhotoURL = snapshot.venueCoverPhotoURL
        venueMenuPhotoURL = snapshot.venueMenuPhotoURL
        venueCoverPhotoThumbnailURL = snapshot.venueCoverPhotoThumbnailURL
        venueMenuPhotoThumbnailURL = snapshot.venueMenuPhotoThumbnailURL
        persistSelectedVenueId(snapshot.ownerVenueDatabaseId)
    }

    @MainActor
    private func finalizeLocalBusinessVenueDeletion(
        venueId: UUID,
        deletedEventIDs: Set<UUID>
    ) -> [URL] {
        let oldVenueId = ownerVenueDatabaseId
        let deletedURLs = deletedVenueImageURLs(venueId: venueId)
        removeVenueFromLocalCollections(venueId: venueId, deletedEventIDs: deletedEventIDs)
        removeLocalVenueRating(venueID: venueId)
        applySelectedVenueAfterBusinessLoad()
#if DEBUG
        print("[BusinessVenueDeleteDebug] selectedVenueAfterDelete oldVenueId=\(oldVenueId?.uuidString.lowercased() ?? "nil") newVenueId=\(ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil")")
#endif
        if ownerVenueDatabaseId == nil {
            clearStaleBusinessProfileVenueHeaderState()
        }
        return deletedURLs
    }

    @MainActor
    private func removeVenueFromLocalCollections(venueId: UUID, deletedEventIDs: Set<UUID>) {
        ownedBusinessVenues.removeAll { $0.id == venueId }
        legacyOwnerVenuesForEmailFallback.removeAll { $0.id == venueId }
        bars.removeAll { $0.id == venueId }
        followingTabSavedVenues.removeAll { $0.id == venueId }
        favoriteVenueIDs.remove(venueId)
        if selectedBar?.id == venueId {
            selectedBar = nil
            clearDiscoverRemotePreviewHold()
        }
        if let selectedEventID = selectedEvent?.id, deletedEventIDs.contains(selectedEventID) {
            selectedEvent = nil
        }

        let loadedDeletedEventIDs = Set(venueEventRows.compactMap { row -> UUID? in
            guard row.venue_id == venueId else { return nil }
            return row.id
        })
        let eventIDs = deletedEventIDs.union(loadedDeletedEventIDs)
        venueEventRows.removeAll { row in
            row.venue_id == venueId || row.id.map { eventIDs.contains($0) } == true
        }
        venueEventIDsByKey = venueEventIDsByKey.filter { !eventIDs.contains($0.value) }
        followingTabGoingItems.removeAll { item in
            eventIDs.contains(item.id) || item.bar.id == venueId
        }
        for eventID in eventIDs {
            followingTabGoingInterestCounts.removeValue(forKey: eventID)
            venueEventInterestIDs.remove(eventID)
            venueEventInterestCounts.removeValue(forKey: eventID)
            venueEventInterestWriteInFlightIDs.remove(eventID)
            venueEventInterestPendingTargets.removeValue(forKey: eventID)
            recentlyConfirmedVenueEventGoingAt.removeValue(forKey: eventID)
            recentlyConfirmedVenueEventNotGoingAt.removeValue(forKey: eventID)
            goingProfilesByVenueEventID.removeValue(forKey: eventID)
            venueEventPredictionSummaries.removeValue(forKey: eventID)
            venueEventComments.removeValue(forKey: eventID)
            venueEventVibeCounts.removeValue(forKey: eventID)
            myVenueEventVibes.removeValue(forKey: eventID)
        }
    }

    @MainActor
    private func deletedVenueImageURLs(venueId: UUID) -> [URL] {
        let managedRow = (ownedBusinessVenues + legacyOwnerVenuesForEmailFallback).first { $0.id == venueId }
        let bar = bars.first { $0.id == venueId }
        let rawURLs = [
            managedRow?.cover_photo_url,
            managedRow?.menu_photo_url,
            managedRow?.cover_photo_thumbnail_url,
            managedRow?.menu_photo_thumbnail_url,
            bar?.coverPhotoURL,
            bar?.menuPhotoURL,
            bar?.coverPhotoThumbnailURL,
            bar?.menuPhotoThumbnailURL,
            ownerVenueDatabaseId == venueId ? venueCoverPhotoURL : nil,
            ownerVenueDatabaseId == venueId ? venueMenuPhotoURL : nil,
            ownerVenueDatabaseId == venueId ? venueCoverPhotoThumbnailURL : nil,
            ownerVenueDatabaseId == venueId ? venueMenuPhotoThumbnailURL : nil
        ]

        var seen = Set<String>()
        return rawURLs.compactMap { raw -> URL? in
            let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return URL(string: trimmed)
        }
    }

    @MainActor
    private func clearSelectedVenueDraftFieldsAfterDeletion() {
        ownerVenueName = ""
        ownerVenueAddress = ""
        ownerVenueAddressLine2 = ""
        ownerVenueCity = ""
        ownerVenueState = ""
        ownerVenueZipCode = ""
        ownerVenueCountry = BusinessLocationCountryPolicy.defaultCountryCode
        ownerVenuePhoneDialISO = BusinessPhoneFields.defaultISO
        ownerVenuePhone = ""
        ownerVenueWebsite = ""
        ownerVenueDescription = ""
        ownerVenueFeatures = ""
        ownerVenueSupporterCountry = ""
        ownerVenueScreenCount = 1
        ownerVenueServesFood = false
        ownerVenueHasWifi = false
        ownerVenueHasGarden = false
        ownerVenueHasProjector = false
        ownerVenuePetFriendly = false
        venueCoverPhotoURL = ""
        venueMenuPhotoURL = ""
        venueCoverPhotoThumbnailURL = ""
        venueMenuPhotoThumbnailURL = ""
        pendingVenueCoverPhotoVenueID = nil
        pendingVenueCoverPhotoURL = nil
        pendingVenueCoverPhotoThumbnailURL = nil
        pendingVenueMenuPhotoVenueID = nil
        pendingVenueMenuPhotoURL = nil
        pendingVenueMenuPhotoThumbnailURL = nil
    }

    func updateVenueSupporterCountry(_ country: String?) async -> Bool {
        if await businessBanGuardBlocks(path: "venueProfile", action: "updateVenueSupporterCountry") {
            return false
        }

        struct Params: Encodable {
            let p_venue_id: UUID
            let p_supporter_country: String?
        }

        let requested = country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalized = VenueSupporterCountryMode.normalizedStorageValue(country)
        if !requested.isEmpty, normalized == nil {
#if DEBUG
            print("[VenueSupporterIdentityDebug] backendGuard=false reason=clientRejectedInvalidValue supporterCountry=\(requested)")
            print("[VenueSupporterIdentityDebug] saveError=invalid_supporter_country")
#endif
            return false
        }

        let ownerEmailRow = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(ownerEmailRow) else { return false }

        var venueId = ownerVenueDatabaseId
        if venueId == nil {
            venueId = await loadVenueProfile()?.id
        }
        guard let venueId else {
#if DEBUG
            print("[VenueSupporterIdentityDebug] save venueId=nil supporterCountry=\(normalized ?? "nil")")
            print("[VenueSupporterIdentityDebug] saveError=missing_venue_id")
#endif
            return false
        }
        if selectedManagedVenueIsPlanLocked() {
#if DEBUG
            print("[VenueSupporterIdentityDebug] save blocked venueId=\(venueId.uuidString.lowercased()) reason=plan_locked")
#endif
            return false
        }
#if DEBUG
        print("[VenueSupporterIdentityDebug] save venueId=\(venueId.uuidString.lowercased()) supporterCountry=\(normalized ?? "nil")")
        print("[VenueSupporterIdentityDebug] backendGuard=rpc_update_venue_supporter_country")
#endif
        do {
            try await supabase
                .rpc(
                    "update_venue_supporter_country",
                    params: Params(
                        p_venue_id: venueId,
                        p_supporter_country: normalized
                    )
                )
                .execute()
#if DEBUG
            print("[VenueSupporterIdentityDebug] saveSuccess=true")
#endif
            await MainActor.run {
                ownerVenueSupporterCountry = normalized ?? ""
            }
            if let saved = await loadVenueProfile() {
                await MainActor.run {
                    applyVenueProfileRowToOwnerState(saved)
                    updateManagedVenueProfileCaches(saved)
                }
            }
            await loadVenuesFromSupabase(forceRefresh: true)
            return true
        } catch {
            print("ERROR UPDATING VENUE SUPPORTER COUNTRY:", error)
#if DEBUG
            print("[VenueSupporterIdentityDebug] saveSuccess=false")
            print("[VenueSupporterIdentityDebug] saveError=\(error.localizedDescription)")
#endif
            return false
        }
    }

    /// User picked a venue from the switcher; persists selection and reloads profile + games lists (DEBUG logs).
    func selectManagedVenue(id: UUID) async {
        guard let selectedRow = managedVenuesForOwner().first(where: { $0.id == id }),
              Self.venueIsActiveForBusinessLimit(selectedRow) else {
#if DEBUG
            let availableIds = managedVenuesForOwner()
                .filter(Self.venueIsActiveForBusinessLimit)
                .compactMap(\.id)
                .map { $0.uuidString.lowercased() }
                .sorted()
                .joined(separator: ",")
            print("[BusinessVenuePickerDebug] invalidSelectionPrevented selection=\(id.uuidString.lowercased()) availableIds=\(availableIds.isEmpty ? "none" : availableIds)")
#endif
            return
        }
        let selectedBusinessId = selectedRow.business_id
        if await businessBanGuardBlocks(
            path: "businessSwitcher",
            action: "selectManagedVenue",
            businessId: selectedBusinessId
        ) {
            return
        }

        await MainActor.run {
            ownerVenueDatabaseId = id
            persistSelectedVenueId(id)
#if DEBUG
            print("[BusinessPhaseB2] selected venue id=\(id.uuidString)")
#endif
        }

        if let row = await loadVenueProfile() {
            await MainActor.run {
                applyVenueProfileRowToOwnerState(row)
            }
#if DEBUG
            print("[BusinessPhaseB2] loaded selected venue profile=true")
#endif
        } else {
#if DEBUG
            print("[BusinessPhaseB2] loaded selected venue profile=false")
#endif
        }

        let games = await loadMyVenueGames()
#if DEBUG
        print("[BusinessPhaseB2] loaded games for selected venue count=\(games.count)")
        logBusinessSwitcherDebug()
#endif
    }

    private func approvedManagedVenueIsActive(_ row: VenueProfileRow) -> Bool {
        let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status.isEmpty || status == "active"
    }

    private func approvedManagedVenueHasValidCoordinates(_ row: VenueProfileRow) -> Bool {
        guard let latitude = row.latitude, let longitude = row.longitude else { return false }
        return CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude))
    }

    private func backfillApprovedManagedVenueCoordinatesIfNeeded(_ rows: [VenueProfileRow]) async -> Set<UUID> {
        if await businessBanGuardBlocks(path: "venueProfile", action: "backfillApprovedManagedVenueCoordinatesIfNeeded") {
            return []
        }

        var patched: Set<UUID> = []
        for row in rows where approvedManagedVenueIsActive(row) {
            guard let venueId = row.id else { continue }
            guard !approvedManagedVenueHasValidCoordinates(row) else { continue }
#if DEBUG
            print("[ApprovedVenueVisibilityDebug] missingCoordinates id=\(venueId.uuidString)")
#endif
            let query = BusinessVenueAddressFormatter.geocodeQuery(
                line1: row.address ?? "",
                line2: row.address_line2 ?? "",
                locality: row.city ?? "",
                region: row.state ?? row.region ?? "",
                postalCode: row.zip_code ?? row.postal_code ?? "",
                countryCode: row.country ?? BusinessLocationCountryPolicy.defaultCountryCode
            )
            guard !query.isEmpty, let coord = await geocodeAddress(query) else { continue }
            do {
                try await supabase
                    .from("venues")
                    .update(VenueCoordinatesPatch(latitude: coord.latitude, longitude: coord.longitude))
                    .eq("id", value: venueId.uuidString.lowercased())
                    .execute()
                patched.insert(venueId)
#if DEBUG
                print("[VenueCoordBackfill] approved venue id=\(venueId.uuidString.lowercased()) geocoded lat=\(coord.latitude) lon=\(coord.longitude)")
#endif
            } catch {
#if DEBUG
                print("[VenueCoordBackfill] approved venue update failed id=\(venueId.uuidString):", error)
#endif
            }
        }
        return patched
    }

    private var businessDashboardPreloadKey: String {
        let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
        let businessId = currentBusinessIdForAddLocation()?.uuidString.lowercased() ?? "nil"
        let venueId = ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil"
        return "\(email)|\(businessId)|\(venueId)"
    }

    func loadBusinessDashboardPreload(force: Bool = false) async -> BusinessDashboardPreloadSnapshot? {
        let requestKey = await MainActor.run { businessDashboardPreloadKey }
        if let task = await MainActor.run(body: { businessDashboardPreloadTask }),
           await MainActor.run(body: { businessDashboardPreloadInFlightKey }) == requestKey {
            return await task.value
        }

        let task = Task { [weak self] in
            await self?.performBusinessDashboardPreload()
        }
        await MainActor.run {
            businessDashboardPreloadInFlightKey = requestKey
            businessDashboardPreloadTask = task
        }

        let snapshot = await task.value
        await MainActor.run {
            if businessDashboardPreloadInFlightKey == requestKey {
                businessDashboardPreloadInFlightKey = nil
                businessDashboardPreloadTask = nil
            }
            if let snapshot {
                businessDashboardPreloadSnapshot = snapshot
            }
        }
        return snapshot
    }

    private func performBusinessDashboardPreload() async -> BusinessDashboardPreloadSnapshot? {
        await refreshBusinessDashboardIdentityForPreload()

        let identity = await MainActor.run {
            (
                key: businessDashboardPreloadKey,
                businessId: currentBusinessIdForAddLocation(),
                selectedVenueId: ownerVenueDatabaseId,
                managedVenues: managedVenuesForOwner(),
                favoriteTeamCount: businessFavoriteTeamIDs.count
            )
        }

        async let entitlementStatus = loadBusinessDashboardEntitlementStatus(businessId: identity.businessId)
        async let scheduledGames = loadMyVenueScheduledGames()
        async let favoriteTeamCount = loadBusinessDashboardFavoriteTeamCount(businessId: identity.businessId)
        async let claimsRefresh: Void = refreshBusinessDashboardClaimStatusForPreload()

        let selectedVenue = identity.managedVenues.first { row in
            row.id == identity.selectedVenueId
        }
        let status = await entitlementStatus
        let games = await scheduledGames
        let teamCount = await favoriteTeamCount
        _ = await claimsRefresh

        return BusinessDashboardPreloadSnapshot(
            key: identity.key,
            businessId: identity.businessId,
            selectedVenueId: identity.selectedVenueId,
            managedVenueCount: identity.managedVenues.count,
            selectedVenue: selectedVenue,
            entitlementStatus: status,
            favoriteTeamCount: max(identity.favoriteTeamCount, teamCount),
            scheduledGames: games,
            loadedAt: Date()
        )
    }

    private func loadBusinessDashboardEntitlementStatus(businessId: UUID?) async -> BusinessVenueGamePostingStatus? {
        guard let businessId else { return nil }
        return await businessVenueGamePostingStatus(
            storeKitBusinessProActive: false,
            businessId: businessId
        )
    }

    private func loadBusinessDashboardFavoriteTeamCount(businessId: UUID?) async -> Int {
        guard let businessId else { return 0 }
        await loadBusinessFavoriteTeams(businessId: businessId)
        return await MainActor.run { businessFavoriteTeamIDs.count }
    }

    private func refreshBusinessDashboardClaimStatusForPreload() async {
        async let pending: Void = refreshPendingVenueClaimsForSettings()
        async let statusLine: Void = refreshVenueClaimStatusLineFromDatabase()
        _ = await (pending, statusLine)
    }

    private func refreshBusinessDashboardIdentityForPreload() async {
        let snapshot = await MainActor.run {
            (
                email: OwnerBusinessEmail.normalized(venueOwnerEmail),
                shouldLoad: isVenueOwnerLoggedIn && OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(venueOwnerEmail)),
                authUid: currentUserAuthId,
                hasCachedIdentity: !ownedBusinesses.isEmpty || !managedVenuesForOwner().isEmpty
            )
        }

        guard snapshot.shouldLoad else {
            await MainActor.run {
                clearVenueOwnerOwnedBusinessCaches()
                ownerVenueDatabaseId = nil
                isVenueOwnerBusinessDataLoading = false
            }
            return
        }

        if snapshot.hasCachedIdentity {
            await MainActor.run {
                applySelectedVenueAfterBusinessLoad()
                isVenueOwnerBusinessDataLoading = false
            }
            return
        }

        await MainActor.run {
            venueOwnerEmail = snapshot.email
            isVenueOwnerBusinessDataLoading = true
        }

        async let activeFromEmail = dashboardFetchBusinesses(
            ownerEmail: snapshot.email,
            ownerUserId: nil,
            adminStatus: "active"
        )
        async let activeFromUser = dashboardFetchBusinesses(
            ownerEmail: nil,
            ownerUserId: snapshot.authUid,
            adminStatus: "active"
        )
        async let archivedFromEmail = dashboardFetchBusinesses(
            ownerEmail: snapshot.email,
            ownerUserId: nil,
            adminStatus: "archived"
        )
        async let archivedFromUser = dashboardFetchBusinesses(
            ownerEmail: nil,
            ownerUserId: snapshot.authUid,
            adminStatus: "archived"
        )
        async let claimLinkedBusinesses = dashboardFetchClaimLinkedBusinesses(ownerEmail: snapshot.email)

        let activeEmailRows = await activeFromEmail
        let activeUserRows = await activeFromUser
        let claimBusinessRows = await claimLinkedBusinesses
        let archivedEmailRows = await archivedFromEmail
        let archivedUserRows = await archivedFromUser

        let initialResolvedBusinesses = Self.dedupeBusinessRowsPreservingOrder(
            activeEmailRows + activeUserRows + claimBusinessRows
        )
        let archivedBusinesses = Self.dedupeBusinessRowsPreservingOrder(
            archivedEmailRows + archivedUserRows
        )
        let initialBusinessIds = initialResolvedBusinesses.map { $0.id }

        async let venueRowsByBusiness = dashboardFetchVenuesByBusinessIds(initialBusinessIds)
        async let emailVenueRows = dashboardFetchVenuesByOwnerEmail(snapshot.email)
        async let userVenueRows = dashboardFetchVenuesByOwnerUserId(snapshot.authUid)
        async let claimLinkedVenues = dashboardFetchClaimLinkedVenues(
            ownerEmail: snapshot.email,
            businessIds: initialBusinessIds
        )

        let businessVenueRows = await venueRowsByBusiness
        let emailVenueRowsValue = await emailVenueRows
        let userVenueRowsValue = await userVenueRows
        let claimVenueRows = await claimLinkedVenues

        var mergedVenues = Self.dedupeVenueProfileRowsPreservingOrder(
            businessVenueRows + emailVenueRowsValue + userVenueRowsValue + claimVenueRows
        )

        var finalResolvedBusinesses = initialResolvedBusinesses
        if finalResolvedBusinesses.isEmpty {
            let linkedBusinessIds = Set(mergedVenues.compactMap { $0.business_id })
            let fromVenueLinks = await dashboardFetchBusinessesByIds(Array(linkedBusinessIds))
            if !fromVenueLinks.isEmpty {
                finalResolvedBusinesses = fromVenueLinks
                let extraVenues = await dashboardFetchVenuesByBusinessIds(fromVenueLinks.map { $0.id })
                mergedVenues = Self.dedupeVenueProfileRowsPreservingOrder(mergedVenues + extraVenues)
            }
        }

        let businessesForState = finalResolvedBusinesses
        let venuesForState = mergedVenues
        await MainActor.run {
            ownedBusinesses = businessesForState
            archivedOwnedBusinesses = archivedBusinesses
            ownedBusinessVenues = venuesForState
            legacyOwnerVenuesForEmailFallback = emailVenueRowsValue
            applySelectedVenueAfterBusinessLoad()
            if let selectedId = ownerVenueDatabaseId,
               let selected = managedVenuesForOwner().first(where: { $0.id == selectedId }) {
                applyVenueProfileRowToOwnerState(selected)
            } else if managedVenuesForOwner().isEmpty {
                clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: nil)
            }
            isVenueOwnerBusinessDataLoading = false
        }
    }

    private func dashboardFetchBusinesses(
        ownerEmail: String?,
        ownerUserId: UUID?,
        adminStatus: String
    ) async -> [BusinessRow] {
        do {
            if let ownerEmail, OwnerBusinessEmail.isValidStrict(ownerEmail) {
                return try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                    .eq("admin_status", value: adminStatus)
                    .eq("owner_email", value: ownerEmail)
                    .execute()
                    .value
            } else if let ownerUserId {
                return try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                    .eq("admin_status", value: adminStatus)
                    .eq("owner_user_id", value: ownerUserId)
                    .execute()
                    .value
            } else {
                return []
            }
        } catch {
#if DEBUG
            print("[BusinessDashboardPreload] business fetch failed status=\(adminStatus):", error)
#endif
            return []
        }
    }

    private func dashboardFetchBusinessesByIds(_ ids: [UUID]) async -> [BusinessRow] {
        guard !ids.isEmpty else { return [] }
        do {
            return try await supabase
                .from("businesses")
                .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                .in("id", values: ids.map(\.uuidString))
                .eq("admin_status", value: "active")
                .execute()
                .value
        } catch {
#if DEBUG
            print("[BusinessDashboardPreload] businesses by id fetch failed:", error)
#endif
            return []
        }
    }

    private func dashboardFetchVenuesByBusinessIds(_ ids: [UUID]) async -> [VenueProfileRow] {
        guard !ids.isEmpty else { return [] }
        do {
            return try await supabase
                .from("venues")
                .select()
                .in("business_id", values: ids.map(\.uuidString))
                .in("admin_status", values: ["active", "plan_locked"])
                .execute()
                .value
        } catch {
#if DEBUG
            print("[BusinessDashboardPreload] venues by business fetch failed:", error)
#endif
            return []
        }
    }

    private func dashboardFetchVenuesByOwnerEmail(_ ownerEmail: String) async -> [VenueProfileRow] {
        guard OwnerBusinessEmail.isValidStrict(ownerEmail) else { return [] }
        do {
            return try await supabase
                .from("venues")
                .select()
                .eq("owner_email", value: ownerEmail)
                .in("admin_status", values: ["active", "plan_locked"])
                .execute()
                .value
        } catch {
#if DEBUG
            print("[BusinessDashboardPreload] venues by email fetch failed:", error)
#endif
            return []
        }
    }

    private func dashboardFetchVenuesByOwnerUserId(_ ownerUserId: UUID?) async -> [VenueProfileRow] {
        guard let ownerUserId else { return [] }
        do {
            return try await supabase
                .from("venues")
                .select()
                .eq("owner_user_id", value: ownerUserId)
                .in("admin_status", values: ["active", "plan_locked"])
                .execute()
                .value
        } catch {
#if DEBUG
            print("[BusinessDashboardPreload] venues by owner user fetch failed:", error)
#endif
            return []
        }
    }

    private func dashboardFetchClaimLinkedBusinesses(ownerEmail: String) async -> [BusinessRow] {
        do {
            return try await loadBusinessesLinkedFromApprovedClaims(ownerEmail: ownerEmail)
        } catch {
#if DEBUG
            print("[BusinessDashboardPreload] claim-linked businesses fetch failed:", error)
#endif
            return []
        }
    }

    private func dashboardFetchClaimLinkedVenues(
        ownerEmail: String,
        businessIds: [UUID]
    ) async -> [VenueProfileRow] {
        do {
            return try await loadVenuesLinkedFromApprovedClaims(
                ownerEmail: ownerEmail,
                businessIds: businessIds
            )
        } catch {
#if DEBUG
            print("[BusinessDashboardPreload] claim-linked venues fetch failed:", error)
#endif
            return []
        }
    }

    /// Loads `businesses` for ``venueOwnerEmail``, then `venues` with `business_id` in those ids; legacy email-only venues when the business-linked set is empty.
    func refreshOwnedBusinessesAndVenuesAfterOwnerLogin() async {
        let emailTrimmed = await MainActor.run { () -> String in
            let canon = OwnerBusinessEmail.normalized(venueOwnerEmail)
            if OwnerBusinessEmail.isValidStrict(canon) {
                venueOwnerEmail = canon
            }
            return canon
        }
        let shouldLoad = await MainActor.run {
            isVenueOwnerLoggedIn && OwnerBusinessEmail.isValidStrict(emailTrimmed)
        }
        guard shouldLoad else {
            await MainActor.run {
                clearVenueOwnerOwnedBusinessCaches()
                ownerVenueDatabaseId = nil
                isVenueOwnerBusinessDataLoading = false
            }
            return
        }

        await MainActor.run {
            isVenueOwnerBusinessDataLoading = true
        }

        do {
            let previousManagedVenueRows = managedVenuesForOwner()
            let previousApprovedVenueIds = Set(previousManagedVenueRows.compactMap(\.id))
            let previousStatusByVenueID = Dictionary(
                uniqueKeysWithValues: previousManagedVenueRows.compactMap { row -> (UUID, String)? in
                    guard let id = row.id else { return nil }
                    let status = Self.venueAdminStatus(row.admin_status)
                    return (id, status.isEmpty ? "active" : status)
                }
            )
            let authUid = await MainActor.run { currentUserAuthId }

            var businessesFromEmail: [BusinessRow] = []
            if OwnerBusinessEmail.isValidStrict(emailTrimmed) {
                businessesFromEmail = try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                    .eq("owner_email", value: emailTrimmed)
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            }

            var businessesFromUser: [BusinessRow] = []
            if let authUid {
                businessesFromUser = try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                    .eq("owner_user_id", value: authUid)
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            }

            let claimLinkedBusinesses = try await loadBusinessesLinkedFromApprovedClaims(ownerEmail: emailTrimmed)
            let businesses = Self.dedupeBusinessRowsPreservingOrder(
                businessesFromEmail + businessesFromUser + claimLinkedBusinesses
            )

            var archivedFromEmail: [BusinessRow] = []
            if OwnerBusinessEmail.isValidStrict(emailTrimmed) {
                archivedFromEmail = try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                    .eq("owner_email", value: emailTrimmed)
                    .eq("admin_status", value: "archived")
                    .execute()
                    .value
            }

            var archivedFromUser: [BusinessRow] = []
            if let authUid {
                archivedFromUser = try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                    .eq("owner_user_id", value: authUid)
                    .eq("admin_status", value: "archived")
                    .execute()
                    .value
            }

            let archivedBusinesses = Self.dedupeBusinessRowsPreservingOrder(archivedFromEmail + archivedFromUser)

            let businessIds = businesses.map(\.id)

            var venueRowsByBusiness: [VenueProfileRow] = []
            if !businessIds.isEmpty {
                let idStrings = businessIds.map(\.uuidString)
                venueRowsByBusiness = try await supabase
                    .from("venues")
                    .select()
                    .in("business_id", values: idStrings)
                    .in("admin_status", values: ["active", "plan_locked"])
                    .execute()
                    .value
            }

            // Always load `owner_email` venues. Previously we only did this when the business_id query
            // returned zero rows, which hid newly-approved locations that were still keyed by email only.
            let emailVenueRows: [VenueProfileRow] = try await supabase
                .from("venues")
                .select()
                .eq("owner_email", value: emailTrimmed)
                .in("admin_status", values: ["active", "plan_locked"])
                .execute()
                .value

            // Venues can be linked to a business via `venues.business_id` while `businesses.owner_email`
            // does not match this login (e.g. admin-linked accounts). Resolve businesses from venue ids so
            // `ownedBusinesses` is non-empty for Add location and claims filtering.
            var resolvedBusinesses = businesses
            if resolvedBusinesses.isEmpty {
                let bids = Set((venueRowsByBusiness + emailVenueRows).compactMap(\.business_id))
                if !bids.isEmpty {
                    let idStrings = bids.map(\.uuidString)
                    let fromVenueLinks: [BusinessRow] = try await supabase
                        .from("businesses")
                        .select("id,display_name,owner_email,owner_user_id,admin_status,created_at,entitlement_updated_at,free_active_venues_selected_at")
                        .in("id", values: idStrings)
                        .eq("admin_status", value: "active")
                        .execute()
                        .value
                    if !fromVenueLinks.isEmpty {
                        resolvedBusinesses = fromVenueLinks
                        let resolvedIds = resolvedBusinesses.map(\.id)
                        if Set(resolvedIds) != Set(businessIds), !resolvedIds.isEmpty {
                            let newIdStrings = resolvedIds.map(\.uuidString)
                            let extraBizVenues: [VenueProfileRow] = try await supabase
                                .from("venues")
                                .select()
                                .in("business_id", values: newIdStrings)
                                .in("admin_status", values: ["active", "plan_locked"])
                                .execute()
                                .value
                            venueRowsByBusiness = Self.dedupeVenueProfileRowsPreservingOrder(
                                venueRowsByBusiness + extraBizVenues
                            )
                        }
                    }
                }
            }

            var venueRowsByOwnerUser: [VenueProfileRow] = []
            if let authUid {
                venueRowsByOwnerUser = try await supabase
                    .from("venues")
                    .select()
                    .eq("owner_user_id", value: authUid)
                    .in("admin_status", values: ["active", "plan_locked"])
                    .execute()
                    .value
            }

            let claimLinkedVenues = try await loadVenuesLinkedFromApprovedClaims(
                ownerEmail: emailTrimmed,
                businessIds: resolvedBusinesses.map(\.id)
            )
            let mergedVenues = Self.dedupeVenueProfileRowsPreservingOrder(
                venueRowsByBusiness + emailVenueRows + venueRowsByOwnerUser + claimLinkedVenues
            )
            let approvedVenueClaimMetadata = await loadApprovedVenueClaimMetadata(
                ownerEmail: emailTrimmed,
                businessIds: resolvedBusinesses.map(\.id),
                managedVenueRows: mergedVenues
            )
            var entitlementsByBusinessID: [UUID: BusinessEntitlementSnapshot] = [:]
            for business in resolvedBusinesses {
                if let entitlement = await loadBusinessEntitlements(businessId: business.id) {
                    entitlementsByBusinessID[business.id] = entitlement
                }
            }
            let reconciledVenues = await reconcileBusinessVenueLimitState(
                businesses: resolvedBusinesses,
                venueRows: mergedVenues,
                approvedMetadata: approvedVenueClaimMetadata,
                entitlementsByBusinessID: entitlementsByBusinessID
            )
            let approvedManagedVenueIds = Set(reconciledVenues.compactMap(\.id))
            let newlyApprovedManagedVenueIds = approvedManagedVenueIds.subtracting(previousApprovedVenueIds)
            let coordinateBackfilledVenueIds = await backfillApprovedManagedVenueCoordinatesIfNeeded(reconciledVenues)
#if DEBUG
            let firstBusinessId = resolvedBusinesses.first?.id
            Self.logBusinessPlanLockTransitions(
                previousStatusByVenueID: previousStatusByVenueID,
                currentRows: reconciledVenues,
                fallbackBusinessId: firstBusinessId,
                planType: firstBusinessId.flatMap { entitlementsByBusinessID[$0]?.plan_type } ?? "unknown",
                planStatus: firstBusinessId.flatMap { entitlementsByBusinessID[$0]?.plan_status } ?? "unknown"
            )
#endif

            await MainActor.run {
                ownedBusinesses = resolvedBusinesses
                archivedOwnedBusinesses = archivedBusinesses
                ownedBusinessVenues = reconciledVenues
                legacyOwnerVenuesForEmailFallback = emailVenueRows
                approvedVenueClaimMetadataByVenueID = approvedVenueClaimMetadata
#if DEBUG
                print("[BusinessPhaseB1] loaded businesses count=\(resolvedBusinesses.count)")
                print("[BusinessPhaseB1] loaded archived businesses count=\(archivedBusinesses.count)")
                let bizIds = resolvedBusinesses.map(\.id.uuidString).sorted().joined(separator: ",")
                print("[BusinessRefresh] ownedBusinesses ids=\(bizIds.isEmpty ? "(none)" : bizIds)")
                print("[BusinessPhaseB1] loaded venues count=\(reconciledVenues.count)")
                for v in reconciledVenues {
                    let vid = v.id?.uuidString ?? "nil"
                    let name = v.venue_name ?? ""
                    let bid = v.business_id?.uuidString ?? "nil"
                    let adm = v.admin_status ?? "nil"
                    print("[BusinessRefresh] loaded venue id=\(vid) name=\(name) business_id=\(bid) admin_status=\(adm)")
                }
                print("[BusinessRefresh] managedVenues count=\(managedVenuesForOwner().count)")
                let managedIds = managedVenuesForOwner().compactMap(\.id).map(\.uuidString).sorted().joined(separator: ",")
                let sel = ownerVenueDatabaseId?.uuidString ?? "nil"
                print("[ManagedVenuesDebug] businessIds=\(bizIds.isEmpty ? "(none)" : bizIds)")
                print("[ManagedVenuesDebug] ownerEmail=\(emailTrimmed)")
                print("[ManagedVenuesDebug] rowsReturned=\(reconciledVenues.count)")
                print("[ManagedVenuesDebug] venueIds=\(managedIds.isEmpty ? "(none)" : managedIds)")
                print("[ManagedVenuesDebug] selectedVenueId=\(sel)")
                for id in approvedManagedVenueIds {
                    print("[ApprovedVenueVisibilityDebug] managedVenueApproved id=\(id.uuidString)")
                }
#endif
                applySelectedVenueAfterBusinessLoad()
            }

            let loadedProfileExists: Bool
            if reconciledVenues.isEmpty {
                await MainActor.run {
#if DEBUG
                    print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
                    clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: nil)
                }
                loadedProfileExists = false
            } else {
                let profile = await loadVenueProfile()
                await MainActor.run {
                    if let p = profile {
                        applyVenueProfileRowToOwnerState(p)
                    }
                }
                loadedProfileExists = profile != nil
            }
#if DEBUG
            print("[BusinessPhaseB2] loaded selected venue profile=\(loadedProfileExists)")
#endif
            let games: [VenueEventRow] = reconciledVenues.isEmpty ? [] : await loadMyVenueGames()
#if DEBUG
            print("[BusinessPhaseB2] loaded games for selected venue count=\(games.count)")
#endif
#if DEBUG
            await MainActor.run {
                isVenueOwnerBusinessDataLoading = false
                print("[VenueOwnerLoginDebug] business count=\(ownedBusinesses.count)")
                print("[VenueOwnerLoginDebug] venue count=\(ownedBusinessVenues.count)")
                print("[VenueOwnerLoginDebug] sheet state=refreshDone loading=false unlocked=\(venueOwnerToolsUnlockedForUI())")
            }
#else
            await MainActor.run {
                isVenueOwnerBusinessDataLoading = false
            }
#endif
            await refreshPendingVenueClaimsForSettings()
            await refreshVenueClaimStatusLineFromDatabase()
#if DEBUG
            await MainActor.run {
                print("[BusinessRefresh] pendingClaims=\(pendingVenueClaimsForSettings.count) rejectedClaims=\(rejectedVenueClaimsForSettings.count)")
                print("[BusinessRefresh] locationStatus=\(businessSettingsLocationStatusSubtitle())")
            }
#endif
            if !approvedManagedVenueIds.isEmpty,
               (!newlyApprovedManagedVenueIds.isEmpty || !coordinateBackfilledVenueIds.isEmpty || hasAuthenticatedVenueOwnerSession) {
                await refreshDiscoverPublicVisibilityAfterApprovedVenueStatusChange()
            }
        } catch {
#if DEBUG
            print("[BusinessPhaseB1] load failed:", error)
            print("[BusinessAuthCleanupDebug] ownerDataRefreshFailedPreservedSession=true error=\(error.localizedDescription)")
#endif
            await MainActor.run {
                isVenueOwnerBusinessDataLoading = false
            }
        }
    }

    func runDeferredBusinessOwnerHydrationAfterLaunch() async {
        let shouldHydrate = await MainActor.run {
            hasAuthenticatedVenueOwnerSession || isBusinessOwnerSessionRestorePending
        }
        guard shouldHydrate else { return }

        print("[BusinessLaunchPerf] deferredBusinessHydrationStarted=true")

        await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await MainActor.run {
            if isBusinessOwnerSessionRestorePending, hasAuthenticatedVenueOwnerSession {
                isBusinessOwnerSessionRestorePending = false
#if DEBUG
                print("[BusinessSessionRestoreDebug] restoreCompleted=deferredBusinessHydration")
#endif
            }
            checkVenueApprovalStatus()
        }

        print("[BusinessLaunchPerf] deferredBusinessHydrationCompleted=true")
    }

    // Loads the latest `venue_claims` row for `venueOwnerEmail` to drive pending/approved UI and prefilled venue fields.
    func checkVenueApprovalStatus() {
        Task {
#if DEBUG
            print("[VenueOwnerLoginDebug] checking claim status")
#endif
            await refreshVenueClaimStatusLineFromDatabase()
        }
    }

    /// Same data as ``checkVenueApprovalStatus()`` but awaitable (Settings refresh, pull-to-refresh style flows).
    func refreshVenueClaimStatusLineFromDatabase() async {
#if DEBUG
        print("[VenueOwnerLoginDebug] checking claim status")
#endif
        let email = await MainActor.run { () -> String in
            let canon = OwnerBusinessEmail.normalized(venueOwnerEmail)
            if OwnerBusinessEmail.isValidStrict(canon) {
                venueOwnerEmail = canon
            }
            return canon
        }
        guard OwnerBusinessEmail.isValidStrict(email) else { return }

        do {
            let claims: [VenueClaimRow] = try await supabase
                .from("venue_claims")
                .select()
                .eq("owner_email", value: email)
                .order("created_at", ascending: false)
                .limit(50)
                .execute()
                .value

            let hasUnackedRejected = claims.contains { row in
                Self.isRejectedClaimStatus(row.approval_status)
                    && !Self.isVenueClaimRejectionAcknowledged(row.rejection_acknowledged_at)
            }
            let hasPending = claims.contains { Self.isPendingUnapprovedClaimStatus($0.approval_status) }
            let hasApprovedRow = claims.contains { Self.isApprovedClaimStatus($0.approval_status) }

            let primaryForDisplay = claims.first { row in
                !(Self.isRejectedClaimStatus(row.approval_status)
                    && Self.isVenueClaimRejectionAcknowledged(row.rejection_acknowledged_at))
            } ?? claims.first

            await MainActor.run {
                guard let primary = primaryForDisplay else {
                    venueClaimSubmitted = false
                    venueClaimStatus = "Not Submitted"
                    venueIsApproved = false
                    venueClaimSubmittedDate = ""
                    hasUnackedRejectedVenueClaimForOwnerEmail = false
                    ownerVenueName = ""
                    ownerVenueAddress = ""
                    ownerVenuePhoneDialISO = BusinessPhoneFields.defaultISO
                    ownerVenuePhone = ""
                    ownerVenueWebsite = ""
                    venueProofNote = ""
#if DEBUG
                    print("[VenueOwnerLoginDebug] claim status result=submitted:false approved:false status=no_rows")
#endif
                    return
                }

                venueClaimSubmitted = !claims.isEmpty
                hasUnackedRejectedVenueClaimForOwnerEmail = hasUnackedRejected

                if hasPending {
                    venueClaimStatus = "Pending Review"
                    venueIsApproved = false
                } else if hasUnackedRejected {
                    venueClaimStatus = "Rejected"
                    venueIsApproved = false
                } else if hasApprovedRow {
                    venueClaimStatus = "Approved"
                    venueIsApproved = true
                } else {
                    venueClaimStatus = "Not Submitted"
                    venueIsApproved = false
                }

                venueClaimSubmittedDate = primary.created_at ?? ""
                ownerVenueName = primary.venue_name ?? ""
                ownerVenueAddress = primary.venue_address ?? ""
                ownerVenueAddressLine2 = primary.venue_address_line2 ?? ""
                ownerVenueCity = primary.venue_city ?? ""
                ownerVenueState = primary.venue_state ?? ""
                ownerVenueZipCode = primary.venue_zip_code ?? ""
                ownerVenueCountry = primary.venue_country ?? BusinessLocationCountryPolicy.defaultCountryCode
                applyVenueOwnerPhoneFromCombined(primary.venue_phone)
                ownerVenueWebsite = primary.venue_website ?? ""
                venueProofNote = primary.proof_note ?? ""
#if DEBUG
                let low = primary.approval_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                print("[VenueOwnerLoginDebug] claim status result=submitted:\(venueClaimSubmitted) status=\(venueClaimStatus) primary_status=\(low) claims_count=\(claims.count)")
#endif
            }
        } catch {
            print("ERROR CHECKING APPROVAL:", error)
#if DEBUG
            print("[VenueOwnerLoginDebug] claim status result=error \(error.localizedDescription)")
#endif
            await MainActor.run {
                hasUnackedRejectedVenueClaimForOwnerEmail = false
            }
        }
    }

    // Inserts a new claim record from the owner onboarding form for admin review.
    func submitVenueClaim() {
        Task {
            do {
                if await businessBanGuardBlocks(path: "venueClaim", action: "submitVenueClaim") {
                    return
                }

                // Backend safety: required-field validation guard (UI should already enforce this).
                let trimmedName = ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedAddress = ownerVenueAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedAddressLine2 = ownerVenueAddressLine2.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedCity = ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedState = ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedZip = ownerVenueZipCode.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(ownerVenueCountry)
                let addressLabels = BusinessLocationCountryPolicy.labels(for: trimmedCountry)
                let trimmedPhone = BusinessPhoneFields.combinedStorage(
                    iso: ownerVenuePhoneDialISO,
                    local: ownerVenuePhone
                ).trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedDesc = ownerVenueDescription.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedCover = venueCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedMenu = venueMenuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)

                guard !trimmedName.isEmpty,
                      !trimmedAddress.isEmpty,
                      !trimmedPhone.isEmpty,
                      !trimmedDesc.isEmpty else {
                    await MainActor.run {
                        venueAuthErrorMessage = "Complete all required fields before submitting."
                    }
                    return
                }

                if !BusinessLocationCountryPolicy.supportedCountryCodes.contains(trimmedCountry)
                    || (addressLabels.localityRequired && trimmedCity.isEmpty)
                    || (addressLabels.regionRequired && trimmedState.isEmpty) {
                    await MainActor.run {
                        venueAuthErrorMessage = "Complete the required address fields before submitting."
                    }
                    return
                }

                guard !trimmedCover.isEmpty, !trimmedMenu.isEmpty else {
                    await MainActor.run {
                        venueAuthErrorMessage = "Please upload a venue photo and one other venue image before submitting."
                    }
                    return
                }

                let ownerEmail = await MainActor.run { OwnerBusinessEmail.normalized(venueOwnerEmail) }
                guard OwnerBusinessEmail.isValidStrict(ownerEmail) else {
                    await MainActor.run {
                        venueAuthErrorMessage = OwnerBusinessEmail.invalidOwnerEmailUserMessage
                    }
                    return
                }

                let linkedVenueId = pendingClaimVenueID
                let formattedAddress = BusinessVenueAddressFormatter.formattedAddress(
                    line1: trimmedAddress,
                    line2: trimmedAddressLine2,
                    locality: trimmedCity,
                    region: trimmedState,
                    postalCode: trimmedZip,
                    countryCode: trimmedCountry
                )
                let geocodeQuery = BusinessVenueAddressFormatter.geocodeQuery(
                    line1: trimmedAddress,
                    line2: trimmedAddressLine2,
                    locality: trimmedCity,
                    region: trimmedState,
                    postalCode: trimmedZip,
                    countryCode: trimmedCountry
                )
                let geocodeResult = await geocodeBusinessVenueAddress(
                    geocodeQuery,
                    fallbackFormattedAddress: formattedAddress
                )

#if DEBUG
                print("[ClaimPhaseB] submitting venue claim venue_id=\(linkedVenueId?.uuidString ?? "nil")")
#endif

                if let dupMsg = await VenueClaimDuplicateCheck.rpcPreflight(
                    supabase: supabase,
                    businessId: nil,
                    ownerEmail: ownerEmail,
                    venueName: trimmedName,
                    venueAddress: trimmedAddress,
                    venueCity: trimmedCity,
                    venueState: trimmedState,
                    venueZip: trimmedZip
                ) {
                    await MainActor.run { venueAuthErrorMessage = dupMsg }
                    return
                }

                let claim = VenueClaimInsert(
                    owner_email: ownerEmail,
                    business_id: nil,
                    venue_id: linkedVenueId,
                    venue_name: trimmedName,
                    venue_address: trimmedAddress,
                    venue_address_line2: trimmedAddressLine2.isEmpty ? nil : trimmedAddressLine2,
                    venue_city: trimmedCity,
                    venue_state: trimmedState,
                    venue_country: trimmedCountry,
                    venue_zip_code: trimmedZip,
                    venue_formatted_address: (geocodeResult?.formattedAddress ?? formattedAddress).isEmpty ? nil : (geocodeResult?.formattedAddress ?? formattedAddress),
                    venue_latitude: geocodeResult?.coordinate.latitude,
                    venue_longitude: geocodeResult?.coordinate.longitude,
                    venue_phone: trimmedPhone,
                    venue_website: ownerVenueWebsite,
                    venue_description: trimmedDesc,
                    venue_features: ownerVenueFeatures,
                    screen_count: ownerVenueScreenCount,
                    serves_food: ownerVenueServesFood,
                    has_wifi: ownerVenueHasWifi,
                    has_garden: ownerVenueHasGarden,
                    has_projector: ownerVenueHasProjector,
                    pet_friendly: ownerVenuePetFriendly,
                    cover_photo_url: trimmedCover,
                    menu_photo_url: trimmedMenu,
                    proof_note: venueProofNote
                )

                let inserted: VenueClaimInsertedRow = try await supabase
                    .from("venue_claims")
                    .insert(claim)
                    .select("id,created_at,approval_status")
                    .single()
                    .execute()
                    .value

                await MainActor.run {
                    venueClaimSubmitted = true
                    let statusRaw = inserted.approval_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                    let approved = statusRaw == "approved"
                    venueIsApproved = approved
                    venueClaimStatus = approved ? "Approved" : "Pending Review"
                    venueClaimSubmittedDate = inserted.created_at ?? venueClaimSubmittedDate
                    venueAuthErrorMessage = ""
                    hasUnackedRejectedVenueClaimForOwnerEmail = false
                    let submittedRow = VenueClaimPendingSettingsRow(
                        id: inserted.id,
                        business_id: nil,
                        venue_id: linkedVenueId,
                        venue_name: trimmedName,
                        venue_address: trimmedAddress,
                        venue_address_line2: trimmedAddressLine2.isEmpty ? nil : trimmedAddressLine2,
                        venue_city: trimmedCity,
                        venue_state: trimmedState,
                        venue_country: trimmedCountry,
                        approval_status: inserted.approval_status,
                        rejection_acknowledged_at: nil,
                        created_at: inserted.created_at
                    )
                    pendingVenueClaimsForSettings.removeAll { existing in
                        existing.venue_id == linkedVenueId
                            || (
                                existing.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
                                && existing.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedAddress) == .orderedSame
                            )
                    }
                    rejectedVenueClaimsForSettings.removeAll { existing in
                        existing.venue_id == linkedVenueId
                            || (
                                existing.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedName) == .orderedSame
                                && existing.venue_address?.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(trimmedAddress) == .orderedSame
                            )
                    }
                    pendingVenueClaimsForSettings.insert(submittedRow, at: 0)
                    clearPendingVenueClaimContext()
                }

#if DEBUG
                print("VenueClaim: inserted id=\(inserted.id.uuidString) status=\(inserted.approval_status ?? "unknown") created_at=\(inserted.created_at ?? "")")
#endif

                let notifyPayload = venueClaimAdminNotifyPayloadFromInsert(
                    claim: claim,
                    insertedId: inserted.id,
                    createdAt: inserted.created_at,
                    approvalStatus: inserted.approval_status,
                    claimKind: linkedVenueId != nil ? "discover_claim" : "owner_venue_claim",
                    familyFriendly: false,
                    parkingAvailable: false
                )
                notifyVenueClaimAdminEmail(payload: notifyPayload)

                await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
                await refreshPendingVenueClaimsForSettings()
                await refreshVenueClaimStatusLineFromDatabase()

            } catch {
                print("ERROR SAVING VENUE CLAIM:", error)
                let dup = VenueClaimDuplicateCheck.userMessageIfKnownInsertError(error)
                await MainActor.run {
                    venueAuthErrorMessage = dup ?? "Could not save your venue request. Please try again."
                }
            }
        }
    }

    func approveVenueClaim(_ claim: VenueClaim) {
        guard let index = venueClaims.firstIndex(where: { $0.id == claim.id }) else { return }
        venueClaims[index].status = .approved
    }

    func rejectVenueClaim(_ claim: VenueClaim) {
        guard let index = venueClaims.firstIndex(where: { $0.id == claim.id }) else { return }
        venueClaims[index].status = .rejected
    }

    func loadRecentVenueEvents() {
        Task {
            do {

                let recentEvents: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .select()
                    .eq("admin_status", value: "active")
                    .gte("event_date", value: tenDaysAgoString())
                    .execute()
                    .value

                print("RECENT EVENTS:", recentEvents)

            } catch {
                print("ERROR LOADING RECENT EVENTS:", error)
            }
        }
    }

    /// Loads the signed-in owner’s venue profile: by ``ownerVenueDatabaseId`` when set (Phase A3-prep / multi-venue), otherwise legacy single-row lookup by ``owner_email``.
    func loadVenueProfile() async -> VenueProfileRow? {
        do {
            if let vid = ownerVenueDatabaseId {
#if DEBUG
                print("[BusinessPhaseB3] using venue_id path screen=loadVenueProfile")
#endif
                let byId: [VenueProfileRow] = try await supabase
                    .from("venues")
                    .select()
                    .eq("id", value: vid.uuidString.lowercased())
                    .in("admin_status", values: ["active", "plan_locked"])
                    .limit(1)
                    .execute()
                    .value
                if let row = byId.first {
                    print("[VenuePhotoSaveDebug] reloadPhotoURL=\(row.cover_photo_url ?? "")")
                    return row
                }
                return nil
            }

            let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
            guard OwnerBusinessEmail.isValidStrict(email) else { return nil }

#if DEBUG
            print("[BusinessPhaseB3] using owner_email fallback screen=loadVenueProfile")
#endif
            let rows: [VenueProfileRow] = try await supabase
                .from("venues")
                .select()
                .eq("owner_email", value: email)
                .in("admin_status", values: ["active", "plan_locked"])
                .limit(1)
                .execute()
                .value
            if let row = rows.first {
                print("[VenuePhotoSaveDebug] reloadPhotoURL=\(row.cover_photo_url ?? "")")
            }
            return rows.first

        } catch {
            print("ERROR LOADING VENUE PROFILE:", error)
            return nil
        }
    }

    // Geocodes the address; updates `venues` by id when ``ownerVenueDatabaseId`` is set (Phase A3-prep), else legacy upsert on `owner_email`.
    func saveVenueProfile(
        streetAddress: String,
        addressLine2: String,
        city: String,
        state: String,
        zipCode: String,
        country: String,
        pinnedLatitude: Double? = nil,
        pinnedLongitude: Double? = nil,
        pinnedFormattedAddress: String? = nil,
        screenCount: Int,
        servesFood: Bool,
        hasWifi: Bool,
        hasGarden: Bool,
        hasProjector: Bool,
        petFriendly: Bool
    ) async -> Bool {
        if await businessBanGuardBlocks(path: "venueProfile", action: "saveVenueProfile") {
            return false
        }

        do {
            let ownerEmailRow = OwnerBusinessEmail.normalized(venueOwnerEmail)
            guard OwnerBusinessEmail.isValidStrict(ownerEmailRow) else { return false }
            if selectedManagedVenueIsPlanLocked() {
#if DEBUG
                print("[VenueDetailsLock] save blocked reason=plan_locked venueId=\(ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil")")
#endif
                return false
            }

            let pendingCoverMatchesSelectedVenue = pendingVenueCoverPhotoVenueID == nil || pendingVenueCoverPhotoVenueID == ownerVenueDatabaseId
            let pendingMenuMatchesSelectedVenue = pendingVenueMenuPhotoVenueID == nil || pendingVenueMenuPhotoVenueID == ownerVenueDatabaseId
            let pendingCoverForSave = pendingCoverMatchesSelectedVenue ? pendingVenueCoverPhotoURL : nil
            let pendingMenuForSave = pendingMenuMatchesSelectedVenue ? pendingVenueMenuPhotoURL : nil
            let pendingCoverThumbForSave = pendingCoverMatchesSelectedVenue ? pendingVenueCoverPhotoThumbnailURL : nil
            let pendingMenuThumbForSave = pendingMenuMatchesSelectedVenue ? pendingVenueMenuPhotoThumbnailURL : nil
            let coverPhotoURLForSave = (pendingCoverForSave ?? venueCoverPhotoURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let menuPhotoURLForSave = (pendingMenuForSave ?? venueMenuPhotoURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let coverThumb = (pendingCoverThumbForSave ?? venueCoverPhotoThumbnailURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let menuThumb = (pendingMenuThumbForSave ?? venueMenuPhotoThumbnailURL)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            print("[VenuePhotoSaveDebug] pendingPhotoURL=\(pendingVenueCoverPhotoURL ?? "")")
            print("[VenuePhotoSaveDebug] savePayloadPhotoURL=\(coverPhotoURLForSave)")

            let phoneForSave = BusinessPhoneFields.combinedStorage(
                iso: ownerVenuePhoneDialISO,
                local: ownerVenuePhone
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            let supporterCountryForSave = VenueSupporterCountryMode.normalizedStorageValue(ownerVenueSupporterCountry)

            let identityLocked = venueCoreIdentityLockedForSelectedVenue()
#if DEBUG
            print("[VenueFeatureDebug] sourceOfTruth=venues.features,venues.screen_count,venues.serves_food,venues.has_wifi,venues.has_garden,venues.has_projector,venues.pet_friendly")
            print("[VenueFeatureDebug] businessSelectedFeatures=\(ownerVenueFeatures)")
            print("[VenueFeatureDebug] sqlNeeded=false")
#endif

            if identityLocked, let venueId = ownerVenueDatabaseId {
#if DEBUG
                print("[VenueDetailsLock] approved venue identity fields locked")
                print("[VenueDetailsLock] saving editable fields only")
#endif
                let baseline = await loadVenueProfile()
                if let baseline {
                    await MainActor.run {
                        applyLockedVenueIdentityFromServerRow(baseline)
                    }
                }

                let operationalPatch = VenueProfileOperationalUpdate(
                    supporter_country: supporterCountryForSave,
                    phone: phoneForSave,
                    website: ownerVenueWebsite,
                    description: ownerVenueDescription,
                    features: ownerVenueFeatures,
                    screen_count: screenCount,
                    serves_food: servesFood,
                    has_wifi: hasWifi,
                    has_garden: hasGarden,
                    has_projector: hasProjector,
                    pet_friendly: petFriendly,
                    cover_photo_url: coverPhotoURLForSave,
                    menu_photo_url: menuPhotoURLForSave,
                    cover_photo_thumbnail_url: coverThumb.isEmpty ? nil : coverThumb,
                    menu_photo_thumbnail_url: menuThumb.isEmpty ? nil : menuThumb
                )
#if DEBUG
                print("[BusinessPhaseB3] using venue_id path screen=saveVenueProfile operational-only locked=true")
#endif
                try await supabase
                    .from("venues")
                    .update(operationalPatch)
                    .eq("id", value: venueId.uuidString.lowercased())
                    .execute()

                if let baseline,
                   baseline.latitude == nil || baseline.longitude == nil {
                    let lockedAddress = BusinessVenueAddressFormatter.geocodeQuery(
                        line1: baseline.address ?? "",
                        line2: baseline.address_line2 ?? "",
                        locality: baseline.city ?? "",
                        region: baseline.state ?? "",
                        postalCode: baseline.zip_code ?? "",
                        countryCode: baseline.country ?? BusinessLocationCountryPolicy.defaultCountryCode
                    )

                    if !lockedAddress.isEmpty, let coord = await geocodeAddress(lockedAddress) {
#if DEBUG
                        print("[VenueCoordBackfill] locked venue id=\(venueId.uuidString.lowercased()) geocoded lat=\(coord.latitude) lon=\(coord.longitude)")
#endif
                        try await supabase
                            .from("venues")
                            .update(VenueCoordinatesPatch(latitude: coord.latitude, longitude: coord.longitude))
                            .eq("id", value: venueId.uuidString.lowercased())
                            .execute()
                    }
                }
            } else {
                let countryCode = BusinessLocationCountryPolicy.normalizedStoredCountryCode(country)
                let addressLabels = BusinessLocationCountryPolicy.labels(for: countryCode)
                let streetTrimmed = streetAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                let cityTrimmed = city.trimmingCharacters(in: .whitespacesAndNewlines)
                let stateTrimmed = state.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !streetTrimmed.isEmpty,
                      BusinessLocationCountryPolicy.supportedCountryCodes.contains(countryCode),
                      (!addressLabels.localityRequired || !cityTrimmed.isEmpty),
                      (!addressLabels.regionRequired || !stateTrimmed.isEmpty) else {
#if DEBUG
                    print("[InternationalAddressDebug] addressValidation=failed")
#endif
                    return false
                }
#if DEBUG
                print("[InternationalAddressDebug] addressValidation=passed")
#endif
                let addressLine2Trimmed = addressLine2.trimmingCharacters(in: .whitespacesAndNewlines)
                let fallbackFormattedAddress = BusinessVenueAddressFormatter.formattedAddress(
                    line1: streetTrimmed,
                    line2: addressLine2Trimmed,
                    locality: cityTrimmed,
                    region: stateTrimmed,
                    postalCode: zipCode,
                    countryCode: countryCode
                )
                let geocodeQuery = BusinessVenueAddressFormatter.geocodeQuery(
                    line1: streetTrimmed,
                    line2: addressLine2Trimmed,
                    locality: cityTrimmed,
                    region: stateTrimmed,
                    postalCode: zipCode,
                    countryCode: countryCode
                )

                print("GEOCODING ADDRESS:", geocodeQuery)

                let pinnedCoordinate = Self.validBusinessVenueCoordinate(latitude: pinnedLatitude, longitude: pinnedLongitude)
                let geocodeResult = pinnedCoordinate == nil
                    ? await geocodeBusinessVenueAddress(
                        geocodeQuery,
                        fallbackFormattedAddress: fallbackFormattedAddress
                    )
                    : nil
                let coordinate = pinnedCoordinate ?? geocodeResult?.coordinate
                let pinnedFormatted = Self.trimmedNonEmptyBusinessVenueString(pinnedFormattedAddress)
                let formattedAddress = pinnedFormatted ?? geocodeResult?.formattedAddress ?? fallbackFormattedAddress
#if DEBUG
                print("[InternationalAddressDebug] formattedAddress=\(formattedAddress)")
                print("[InternationalAddressDebug] latitude=\(coordinate?.latitude.description ?? "nil")")
                print("[InternationalAddressDebug] longitude=\(coordinate?.longitude.description ?? "nil")")
                if coordinate != nil {
                    print("[InternationalAddressDebug] coordinatesSaved=true")
                }
#endif

                let profile = VenueProfileInsert(
                    owner_email: ownerEmailRow,
                    venue_name: ownerVenueName,
                    supporter_country: supporterCountryForSave,
                    address: streetTrimmed,
                    address_line1: streetTrimmed,
                    address_line2: addressLine2Trimmed.isEmpty ? nil : addressLine2Trimmed,
                    city: cityTrimmed,
                    state: stateTrimmed,
                    zip_code: zipCode,
                    region: stateTrimmed.isEmpty ? nil : stateTrimmed,
                    postal_code: zipCode.isEmpty ? nil : zipCode,
                    country: countryCode,
                    formatted_address: formattedAddress.isEmpty ? nil : formattedAddress,
                    phone: phoneForSave,
                    website: ownerVenueWebsite,
                    description: ownerVenueDescription,
                    features: ownerVenueFeatures,
                    screen_count: screenCount,
                    serves_food: servesFood,
                    has_wifi: hasWifi,
                    has_garden: hasGarden,
                    has_projector: hasProjector,
                    pet_friendly: petFriendly,
                    latitude: coordinate?.latitude,
                    longitude: coordinate?.longitude,
                    cover_photo_url: coverPhotoURLForSave,
                    menu_photo_url: menuPhotoURLForSave,
                    cover_photo_thumbnail_url: coverThumb.isEmpty ? nil : coverThumb,
                    menu_photo_thumbnail_url: menuThumb.isEmpty ? nil : menuThumb
                )

                if let venueId = ownerVenueDatabaseId {
                    let patch = VenueProfileUpdate(
                        owner_email: ownerEmailRow,
                        venue_name: ownerVenueName,
                        supporter_country: supporterCountryForSave,
                        address: streetTrimmed,
                        address_line1: streetTrimmed,
                        address_line2: addressLine2Trimmed.isEmpty ? nil : addressLine2Trimmed,
                        city: cityTrimmed,
                        state: stateTrimmed,
                        zip_code: zipCode,
                        region: stateTrimmed.isEmpty ? nil : stateTrimmed,
                        postal_code: zipCode.isEmpty ? nil : zipCode,
                        country: countryCode,
                        formatted_address: formattedAddress.isEmpty ? nil : formattedAddress,
                        phone: phoneForSave,
                        website: ownerVenueWebsite,
                        description: ownerVenueDescription,
                        features: ownerVenueFeatures,
                        screen_count: screenCount,
                        serves_food: servesFood,
                        has_wifi: hasWifi,
                        has_garden: hasGarden,
                        has_projector: hasProjector,
                        pet_friendly: petFriendly,
                        latitude: coordinate?.latitude,
                        longitude: coordinate?.longitude,
                        cover_photo_url: coverPhotoURLForSave,
                        menu_photo_url: menuPhotoURLForSave,
                        cover_photo_thumbnail_url: coverThumb.isEmpty ? nil : coverThumb,
                        menu_photo_thumbnail_url: menuThumb.isEmpty ? nil : menuThumb
                    )
#if DEBUG
                    print("[BusinessPhaseB3] using venue_id path screen=saveVenueProfile")
#endif
                    try await supabase
                        .from("venues")
                        .update(patch)
                        .eq("id", value: venueId.uuidString.lowercased())
                        .execute()
                } else {
#if DEBUG
                    print("[BusinessPhaseB3] using owner_email fallback screen=saveVenueProfile")
#endif
                    try await supabase
                        .from("venues")
                        .upsert(profile, onConflict: "owner_email")
                        .execute()
                }
            }

            print("VENUE PROFILE SAVED")
            if let saved = await loadVenueProfile() {
                await refreshVenuePhotoDisplayStateAfterProfileSave(saved)
#if DEBUG
                print("[VenueFeatureDebug] selectedFeatures=\(saved.features ?? "")")
                print("[VenueFeatureDebug] businessSelectedFeatures=\(saved.features ?? "")")
#endif
                print("[VenuePhotoSaveDebug] savedDatabasePhotoURL=\(saved.cover_photo_url ?? "")")
            }
            await loadVenuesFromSupabase(forceRefresh: true)
#if DEBUG
            print("[VenueFeatureDebug] propagatedToDiscover=true")
#endif
            return true

        } catch {

            print("ERROR SAVING VENUE PROFILE:", error)

            return false
        }
    }

    // Uploads full + thumbnail JPEGs under the owner’s email folder in `venue-photos`; returns the full image public URL.
    func uploadVenuePhoto(data: Data, fileName: String, assignToCurrentVenueProfile: Bool = true) async -> String? {
        if await businessBanGuardBlocks(path: "venuePhoto", action: "uploadVenuePhoto") {
            return nil
        }

        do {
            let session = try? await supabase.auth.session
            print("CURRENT SUPABASE USER:", session?.user.email ?? "NO USER")
            print("VENUE OWNER EMAIL:", venueOwnerEmail)

            let safeEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
                .replacingOccurrences(of: "@", with: "_")
                .replacingOccurrences(of: ".", with: "_")

            let fieldName = fileName.lowercased().contains("menu") ? "menu_photo_url" : "cover_photo_url"
            print("[VenuePhotoSaveDebug] uploadStarted field=\(fieldName)")

            let storedFileName = Self.versionedVenuePhotoFileName(for: fileName)
            let pathFull = "\(safeEmail)/\(storedFileName)"
            let thumbName = Self.companionVenueThumbnailFileName(for: storedFileName)
            let pathThumb = "\(safeEmail)/\(thumbName)"

            let oldFull: String
            let oldThumb: String
            if fileName.lowercased().contains("menu") {
                oldFull = venueMenuPhotoURL
                oldThumb = venueMenuPhotoThumbnailURL
            } else {
                oldFull = venueCoverPhotoURL
                oldThumb = venueCoverPhotoThumbnailURL
            }

            let uploadFull = ImageCompression.jpegDataForUpload(from: data, preset: .venuePhoto)
            let uploadThumb = ImageCompression.jpegDataForUpload(from: data, preset: .venuePhotoThumbnail)

            try await supabase.storage
                .from("venue-photos")
                .upload(
                    pathFull,
                    data: uploadFull,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )

            try await supabase.storage
                .from("venue-photos")
                .upload(
                    pathThumb,
                    data: uploadThumb,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )

            let publicFull = try supabase.storage
                .from("venue-photos")
                .getPublicURL(path: pathFull)
            let publicThumb = try supabase.storage
                .from("venue-photos")
                .getPublicURL(path: pathThumb)

            let fullStr = publicFull.absoluteString
            let thumbStr = publicThumb.absoluteString

            await deleteReplacedStorageObjectIfNeeded(oldPublicURL: oldFull, newPublicURL: fullStr, bucket: "venue-photos")
            await deleteReplacedStorageObjectIfNeeded(oldPublicURL: oldThumb, newPublicURL: thumbStr, bucket: "venue-photos")

            let cacheURLs = [oldFull, oldThumb, fullStr, thumbStr].compactMap { raw -> URL? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : URL(string: trimmed)
            }
            await DiscoverMapImageCache.shared.invalidate(urls: cacheURLs)
#if DEBUG
            print("[VenuePhotoDisplayDebug] cacheInvalidatedForPhotoChange=true")
#endif

            if assignToCurrentVenueProfile {
                if fieldName == "menu_photo_url" {
                    venueMenuPhotoURL = fullStr
                    venueMenuPhotoThumbnailURL = thumbStr
                    pendingVenueMenuPhotoVenueID = ownerVenueDatabaseId
                    pendingVenueMenuPhotoURL = fullStr
                    pendingVenueMenuPhotoThumbnailURL = thumbStr
                } else {
                    venueCoverPhotoURL = fullStr
                    venueCoverPhotoThumbnailURL = thumbStr
                    pendingVenueCoverPhotoVenueID = ownerVenueDatabaseId
                    pendingVenueCoverPhotoURL = fullStr
                    pendingVenueCoverPhotoThumbnailURL = thumbStr
                }
            }

            let pendingLogURL = assignToCurrentVenueProfile
                ? (fieldName == "cover_photo_url" ? pendingVenueCoverPhotoURL ?? "" : pendingVenueMenuPhotoURL ?? "")
                : fullStr
            print("[VenuePhotoSaveDebug] uploadCompleted url=\(fullStr)")
            print("[VenuePhotoSaveDebug] pendingPhotoURL=\(pendingLogURL)")

            return fullStr

        } catch {
            print("ERROR UPLOADING PHOTO:", error)
            return nil
        }
    }

    func saveVenueGameListing(
        gameTitle: String,
        sport: String,
        gameDate: Date,
        gameStartTime: Date,
        soundOn: Bool,
        audioType: VenueAudioType,
        teamFanbase: String,
        atmosphere: String,
        crowdLevel: String,
        liveOccupancy: String,
        seating: String,
        numberOfTVs: String,
        drinkSpecial: String,
        coverCharge: String,
        reservationInfo: String,
        socialCoordination: String,
        externalGameID: String? = nil,
        externalSource: String? = nil,
        importedFromAPI: Bool = false,
        externalLeague: String? = nil,
        homeTeam: String? = nil,
        awayTeam: String? = nil
    ) {
        Task {
            _ = await saveVenueGameListingAsync(
                gameTitle: gameTitle,
                sport: sport,
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                soundOn: soundOn,
                audioType: audioType,
                teamFanbase: teamFanbase,
                atmosphere: atmosphere,
                crowdLevel: crowdLevel,
                liveOccupancy: liveOccupancy,
                seating: seating,
                numberOfTVs: numberOfTVs,
                drinkSpecial: drinkSpecial,
                coverCharge: coverCharge,
                reservationInfo: reservationInfo,
                socialCoordination: socialCoordination,
                externalGameID: externalGameID,
                externalSource: externalSource,
                importedFromAPI: importedFromAPI,
                externalLeague: externalLeague,
                homeTeam: homeTeam,
                awayTeam: awayTeam
            )
        }
    }

    /// ISO 8601 string with `TimeZone.current` offset for `public.venue_events.scheduled_start_at`.
    func venueEventScheduledStartTimestamptzString(gameDate: Date, gameStartTime: Date) -> String {
        let combined = VenueOwnerGameScheduleValidation.combinedLocalStart(gameDate: gameDate, gameStartTime: gameStartTime)
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone.current
        f.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        return f.string(from: combined)
    }

    /// Same insert as ``saveVenueGameListing``. On success returns ``.success`` with the inserted row (and updates local Discover/calendar state). On failure returns ``.failure`` with a user-facing ``LocalizedError``.
    func saveVenueGameListingAsync(
        gameTitle: String,
        sport: String,
        gameDate: Date,
        gameStartTime: Date,
        soundOn: Bool,
        audioType: VenueAudioType,
        teamFanbase: String,
        atmosphere: String,
        crowdLevel: String,
        liveOccupancy: String,
        seating: String,
        numberOfTVs: String,
        drinkSpecial: String,
        coverCharge: String,
        reservationInfo: String,
        socialCoordination: String,
        externalGameID: String? = nil,
        externalSource: String? = nil,
        importedFromAPI: Bool = false,
        externalLeague: String? = nil,
        homeTeam: String? = nil,
        awayTeam: String? = nil
    ) async -> Result<VenueEventRow, Error> {
        if await businessBanGuardBlocks(path: "venueGame", action: "saveVenueGameListingAsync") {
            return .failure(
                NSError(
                    domain: "BusinessBanGuard",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Your account is suspended."]
                )
            )
        }

        let ownerRowEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(ownerRowEmail) else {
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: OwnerBusinessEmail.invalidOwnerEmailUserMessage]
                )
            )
        }

        let businessId = currentBusinessIdForAddLocation()
        guard let businessId else {
#if DEBUG
            print("[BusinessEntitlementGate] operation=hostGame allowed=false reason=missingBusinessId")
#endif
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: "Could not verify your business account. Please refresh your business profile and try again."]
                )
            )
        }

        if selectedManagedVenueIsPlanLocked() {
#if DEBUG
            print("[BusinessEntitlementGate] businessId=\(businessId.uuidString.lowercased()) operation=hostGame allowed=false reason=plan_locked venueId=\(ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil")")
#endif
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: BusinessLimitCopy.planLockedVenueHostedGameBlocked]
                )
            )
        }

        let hostingStatus = await businessVenueGamePostingStatus(storeKitBusinessProActive: false)
        let serverAllowsHostedGame = hostingStatus.canHostBusinessGames
        let sessionUserId: UUID?
        do {
            let activeSession = try await supabase.auth.session
            sessionUserId = activeSession.user.id
        } catch {
            sessionUserId = nil
        }
        let currentAuthenticatedUserId = currentUserAuthId ?? sessionUserId
#if DEBUG
        print("[BusinessEntitlementGate] businessId=\(businessId.uuidString.lowercased()) operation=hostGame allowed=\(serverAllowsHostedGame) reason=\(hostingStatus.canHostBusinessGamesReason)")
#endif
        guard serverAllowsHostedGame else {
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 403,
                    userInfo: [NSLocalizedDescriptionKey: BusinessLimitCopy.hostedGameLimitReached]
                )
            )
        }

        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameStartTime) {
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: VenueOwnerGameScheduleValidation.futureDateTimeMessage]
                )
            )
        }

        let retentionHours = VenueOwnerGameDataRetentionHours.fixedHoursAfterStart
        let trimmedExternalGameID = externalGameID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedExternalSource = externalSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedExternalLeague = externalLeague?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedHomeTeam = homeTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedAwayTeam = awayTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var rpcDebugParams: CreateBusinessHostedGameRPCParams?

        do {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.timeZone = TimeZone.current

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.timeZone = TimeZone.current

#if DEBUG
            let vidForLog = ownerVenueDatabaseId?.uuidString ?? "nil"
            print("[BusinessGamePublish] venue_id=\(vidForLog) venue_name=\(ownerVenueName)")
#endif

            let newGame = VenueEventInsert(
                venue_id: ownerVenueDatabaseId,
                owner_email: ownerRowEmail,
                venue_name: ownerVenueName,
                event_title: gameTitle,
                sport: sport,
                home_team: trimmedHomeTeam.isEmpty ? nil : trimmedHomeTeam,
                away_team: trimmedAwayTeam.isEmpty ? nil : trimmedAwayTeam,
                external_league: trimmedExternalLeague.isEmpty ? nil : trimmedExternalLeague,
                event_date: dateFormatter.string(from: gameDate),
                event_time: timeFormatter.string(from: gameStartTime),
                external_game_id: trimmedExternalGameID.isEmpty ? nil : trimmedExternalGameID,
                external_source: trimmedExternalSource.isEmpty ? nil : trimmedExternalSource,
                imported_from_api: importedFromAPI,
                sound_on: soundOn,
                audio_type: audioType.rawValue,
                drink_special: drinkSpecial,
                cover_charge: coverCharge,
                expected_crowd: crowdLevel,
                available_seating: seating,
                reservations_available: !reservationInfo.isEmpty,
                waitlist_available: !reservationInfo.isEmpty,
                admin_status: "active",
                scheduled_start_at: venueEventScheduledStartTimestamptzString(gameDate: gameDate, gameStartTime: gameStartTime),
                cleanup_delay_hours: retentionHours
            )

            let rpcName = "create_business_hosted_game"
            let rpcParams = CreateBusinessHostedGameRPCParams(game: newGame, businessId: businessId)
            rpcDebugParams = rpcParams
#if DEBUG
            print("[HostedGameRPCParams] orderedKeys=\(rpcParams.debugKeys)")
            print("[HostedGameRPCStart] businessId=\(businessId.uuidString.lowercased()) venueId=\(ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil") authUserId=\(currentAuthenticatedUserId?.uuidString.lowercased() ?? "nil") ownerEmail=\(ownerRowEmail) canHostBusinessGames=\(serverAllowsHostedGame) entitlement=\(Self.businessHostedGameEntitlementDebugSummary(hostingStatus)) rpcName=\(rpcName) paramsKeys=\(rpcParams.debugKeys)")
#endif
            let inserted: [VenueEventRow] = try await supabase
                .rpc(
                    rpcName,
                    params: rpcParams
                )
                .execute()
                .value
#if DEBUG
            print("[BusinessEntitlementGate] businessId=\(businessId.uuidString.lowercased()) operation=hostGame allowed=true reason=rpcInserted")
            print("[HostedGameRPCSuccess] businessId=\(businessId.uuidString.lowercased()) venueId=\(ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil") authUserId=\(currentAuthenticatedUserId?.uuidString.lowercased() ?? "nil") ownerEmail=\(ownerRowEmail) canHostBusinessGames=\(serverAllowsHostedGame) entitlement=\(Self.businessHostedGameEntitlementDebugSummary(hostingStatus)) rpcName=\(rpcName) paramsKeys=\(rpcParams.debugKeys) returnedRows=\(inserted.count)")
#endif

            guard let row = inserted.first else {
                return .failure(
                    NSError(
                        domain: "VenueGameListing",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Game saved, but the app couldn’t read it back. Pull to refresh in a moment."]
                    )
                )
            }

            await applyCreatedVenueEventLocally(row)

            Task { [weak self] in
                await self?.refreshDiscoverCoreInBackground(forceVenueRefresh: true)
            }

#if DEBUG
            let vidStr = row.venue_id?.uuidString ?? "nil"
            let adm = row.admin_status ?? "nil"
            let eid = row.id?.uuidString ?? "nil"
            print("[BusinessGamePublish] inserted event id=\(eid) title=\(row.event_title ?? "") date=\(row.event_date ?? "") sport=\(row.sport ?? "")")
            print("[VenueGameSave] insert ok venue_id=\(vidStr) venue_name=\(row.venue_name ?? "") event_date=\(row.event_date ?? "") sport=\(row.sport ?? "") admin_status=\(adm)")
            print(
                "[VenueEventsWriteAudit] table=venue_events venue_id=\(vidStr) event_date=\(row.event_date ?? "nil") event_time=\(row.event_time ?? "nil") scheduled_start_at=\(row.scheduled_start_at ?? "nil") sport=\(row.sport ?? "nil") admin_status=\(adm) status=(not sent by client) is_visible=(not in VenueEventInsert/VenueEventRow client model)"
            )
            print(
                "[DiscoverDotsSave] table=venue_events op=insert venue_id=\(vidStr) event_id=\(eid) event_date=\(row.event_date ?? "nil") scheduled_start_at=\(row.scheduled_start_at ?? "nil") sport=\(row.sport ?? "nil") admin_status=\(adm) (no status/is_visible columns on client venue_events model)"
            )
            logVenueGameExpirationDebug(durationHours: retentionHours, row: row)
#endif
            print("GAME LISTING SAVED")
            return .success(row)
        } catch {
#if DEBUG
            let debugDetails = Self.businessHostedGameRPCDebugDetails(
                error,
                businessId: businessId,
                venueId: ownerVenueDatabaseId,
                authUserId: currentAuthenticatedUserId,
                ownerEmail: ownerRowEmail,
                canHostBusinessGames: serverAllowsHostedGame,
                hostingStatus: hostingStatus,
                rpcName: "create_business_hosted_game",
                params: rpcDebugParams
            )
            print("[HostedGameRPCFailure] \(debugDetails.replacingOccurrences(of: "\n", with: " | "))")
            logBusinessHostedGameRPCDebug(
                error,
                businessId: businessId,
                venueId: ownerVenueDatabaseId,
                authUserId: currentAuthenticatedUserId,
                ownerEmail: ownerRowEmail,
                canHostBusinessGames: serverAllowsHostedGame,
                hostingStatus: hostingStatus,
                params: rpcDebugParams
            )
#endif
            print("ERROR SAVING GAME LISTING:", error)
            let message = Self.userFacingVenueGameScheduleOrSaveError(error)
            var userInfo: [String: Any] = [NSLocalizedDescriptionKey: message]
#if DEBUG
            userInfo[Self.hostedGameRPCDebugDetailsUserInfoKey] = debugDetails
#endif
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 3,
                    userInfo: userInfo
                )
            )
        }
    }

#if DEBUG
    private func logBusinessHostedGameRPCDebug(
        _ error: Error,
        businessId: UUID,
        venueId: UUID?,
        authUserId: UUID?,
        ownerEmail: String,
        canHostBusinessGames: Bool,
        hostingStatus: BusinessVenueGamePostingStatus,
        params: CreateBusinessHostedGameRPCParams?
    ) {
        let details = Self.businessHostedGameRPCDebugDetails(
            error,
            businessId: businessId,
            venueId: venueId,
            authUserId: authUserId,
            ownerEmail: ownerEmail,
            canHostBusinessGames: canHostBusinessGames,
            hostingStatus: hostingStatus,
            rpcName: "create_business_hosted_game",
            params: params
        )
        for line in details.split(separator: "\n", omittingEmptySubsequences: false) {
            print("[BusinessHostedGameRPCDebug] \(line)")
        }
    }

    private static func businessHostedGameEntitlementDebugSummary(_ status: BusinessVenueGamePostingStatus) -> String {
        [
            "businessId=\(status.businessId?.uuidString.lowercased() ?? "nil")",
            "businessProActive=\(status.computedIsPro)",
            "isBusinessPro=\(status.isBusinessPro)",
            "planType=\(status.planType)",
            "planStatus=\(status.planStatus)",
            "proExpiresAt=\(status.proExpiresAt ?? "nil")",
            "unlimitedHosting=\(status.unlimitedHosting)",
            "monthlyHostLimit=\(status.monthlyHostLimit)",
            "monthlyHostedGameCount=\(status.monthlyHostedGameCount)",
            "canHostBusinessGames=\(status.canHostBusinessGames)",
            "reason=\(status.canHostBusinessGamesReason)"
        ].joined(separator: " ")
    }

    private static func businessLocationEntitlementDebugSummary(_ status: BusinessVenueGamePostingStatus) -> String {
        [
            "businessId=\(status.businessId?.uuidString.lowercased() ?? "nil")",
            "businessProActive=\(status.computedIsPro)",
            "isBusinessPro=\(status.isBusinessPro)",
            "planType=\(status.planType)",
            "planStatus=\(status.planStatus)",
            "proExpiresAt=\(status.proExpiresAt ?? "nil")",
            "unlimitedVenues=\(status.unlimitedVenues)",
            "activeVenueLimit=\(status.activeVenueLimit.map(String.init) ?? "unlimited")",
            "activeVenueCount=\(status.activeVenueCount)",
            "canAddVenue=\(status.canAddVenue)",
            "reason=\(status.venueLimitReason)"
        ].joined(separator: " ")
    }

    private static func businessLocationRPCDebugDetails(
        _ error: Error,
        businessId: UUID,
        venueId: UUID?,
        authUserId: UUID?,
        ownerEmail: String,
        canAddVenue: Bool,
        listingStatus: BusinessVenueGamePostingStatus,
        rpcName: String,
        params: CreateBusinessVenueClaimRPCParams?
    ) -> String {
        let nsError = error as NSError
        let missingRPC = businessEntitlementGateErrorIsMissingRpc(error)
        return [
            "rpcName=\(rpcName)",
            "failingQuerySection=submitAddLocationClaim",
            "postgresError=\(error.localizedDescription)",
            "businessId=\(businessId.uuidString.lowercased())",
            "venueId=\(venueId?.uuidString.lowercased() ?? "nil")",
            "authUserId=\(authUserId?.uuidString.lowercased() ?? "nil")",
            "ownerEmail=\(ownerEmail)",
            "canAddVenue=\(canAddVenue)",
            "entitlement=\(businessLocationEntitlementDebugSummary(listingStatus))",
            "localizedDescription=\(error.localizedDescription)",
            "fullReflectedError=\(String(reflecting: error))",
            "nsErrorDomain=\(nsError.domain)",
            "nsErrorCode=\(nsError.code)",
            "nsErrorUserInfo=\(String(describing: nsError.userInfo))",
            "missingRPCDetection=\(missingRPC)",
            "paramsKeys=\(params?.debugKeys ?? "unavailable-before-rpc-params-built")",
            "paramsShape=\(params?.debugSignature ?? "unavailable-before-rpc-params-built")",
            "expectedSQLSignature=create_business_venue_claim(p_business_id uuid, p_owner_email text, p_venue_id uuid, p_venue_name text, p_venue_address text, p_venue_address_line2 text, p_venue_city text, p_venue_state text, p_venue_country text, p_venue_zip_code text, p_venue_formatted_address text, p_venue_latitude double precision, p_venue_longitude double precision, p_venue_phone text, p_venue_website text, p_venue_description text, p_venue_features text, p_screen_count integer, p_serves_food boolean, p_has_wifi boolean, p_has_garden boolean, p_has_projector boolean, p_pet_friendly boolean, p_cover_photo_url text, p_menu_photo_url text, p_proof_note text)",
            "schemaCacheReloadSQL=NOTIFY pgrst, 'reload schema';"
        ].joined(separator: "\n")
    }

    private static func logVenueSubmissionRPCDebug(
        rpcName: String,
        failingQuerySection: String,
        error: Error,
        businessId: UUID,
        venueId: UUID?
    ) {
        print("[VenueSubmissionRPCDebug] rpcName=\(rpcName)")
        print("[VenueSubmissionRPCDebug] failingQuerySection=\(failingQuerySection)")
        print("[VenueSubmissionRPCDebug] postgresError=\(error.localizedDescription)")
        print("[VenueSubmissionRPCDebug] businessId=\(businessId.uuidString.lowercased())")
        print("[VenueSubmissionRPCDebug] venueId=\(venueId?.uuidString.lowercased() ?? "nil")")
    }

    private static func businessHostedGameRPCDebugDetails(
        _ error: Error,
        businessId: UUID,
        venueId: UUID?,
        authUserId: UUID?,
        ownerEmail: String,
        canHostBusinessGames: Bool,
        hostingStatus: BusinessVenueGamePostingStatus,
        rpcName: String,
        params: CreateBusinessHostedGameRPCParams?
    ) -> String {
        let nsError = error as NSError
        let missingRPC = businessEntitlementGateErrorIsMissingRpc(error)
        return [
            "businessId=\(businessId.uuidString.lowercased())",
            "venueId=\(venueId?.uuidString.lowercased() ?? "nil")",
            "authUserId=\(authUserId?.uuidString.lowercased() ?? "nil")",
            "ownerEmail=\(ownerEmail)",
            "canHostBusinessGames=\(canHostBusinessGames)",
            "entitlement=\(businessHostedGameEntitlementDebugSummary(hostingStatus))",
            "rpcName=\(rpcName)",
            "localizedDescription=\(error.localizedDescription)",
            "fullReflectedError=\(String(reflecting: error))",
            "nsErrorDomain=\(nsError.domain)",
            "nsErrorCode=\(nsError.code)",
            "nsErrorUserInfo=\(String(describing: nsError.userInfo))",
            "missingRPCDetection=\(missingRPC)",
            "paramsKeys=\(params?.debugKeys ?? "unavailable-before-rpc-params-built")",
            "paramsShape=\(params?.debugSignature ?? "unavailable-before-rpc-params-built")",
            "expectedSQLSignature=create_business_hosted_game(p_business_id uuid, p_venue_id uuid, p_owner_email text, p_venue_name text, p_event_title text, p_sport text, p_home_team text, p_away_team text, p_external_league text, p_event_date text, p_event_time text, p_external_game_id text, p_external_source text, p_imported_from_api boolean, p_sound_on boolean, p_audio_type text, p_drink_special text, p_cover_charge text, p_expected_crowd text, p_available_seating text, p_reservations_available boolean, p_waitlist_available boolean, p_admin_status text, p_scheduled_start_at text, p_cleanup_delay_hours integer)",
            "schemaCacheReloadSQL=NOTIFY pgrst, 'reload schema';"
        ].joined(separator: "\n")
    }
#endif

    private static func userFacingVenueGameScheduleOrSaveError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let s = raw.lowercased()
        if let entitlementMessage = businessEntitlementGateUserMessage(error) {
            return entitlementMessage
        }
        if s.contains("idx_venue_events_unique_external_game_per_venue_day")
            || (s.contains("duplicate") && s.contains("external_game")) {
            return "This game already exists for this venue."
        }
        if s.contains("check")
            || s.contains("constraint")
            || s.contains("violates")
            || s.contains("date")
            || s.contains("time")
            || s.contains("future")
            || s.contains("past") {
            return VenueOwnerGameScheduleValidation.futureDateTimeMessage
        }
        return raw.isEmpty ? "Unable to save the game right now. Please try again." : raw
    }

    private static func businessEntitlementGateUserMessage(_ error: Error) -> String? {
        let s = error.localizedDescription.lowercased()
        if s.contains("free businesses can list 1 venue")
            || s.contains("free businesses can list 5 venues")
            || s.contains("venue listings")
            || s.contains("active venue") {
            return BusinessLimitCopy.venueLimitReached
        }
        if s.contains("free businesses can host 5 games")
            || s.contains("unlimited hosting")
            || s.contains("monthly host") {
            return BusinessLimitCopy.hostedGameLimitReached
        }
        if s.contains("plan_locked")
            || s.contains("locked under the current business plan") {
            return BusinessLimitCopy.planLockedVenueHostedGameBlocked
        }
        if s.contains("create_business_venue_claim"),
           businessEntitlementGateErrorIsMissingRpc(error) {
            return BusinessLimitCopy.backendCompatibilityRequired
        }
        if s.contains("create_business_hosted_game"),
           businessEntitlementGateErrorIsMissingRpc(error) {
            return BusinessLimitCopy.backendCompatibilityRequired
        }
        return nil
    }

    private static func businessEntitlementGateErrorIsMissingRpc(_ error: Error) -> Bool {
        let s = error.localizedDescription.lowercased()
        return s.contains("could not find the function")
            || s.contains("schema cache")
            || s.contains("undefined function")
            || s.contains("pgrst202")
    }

    func venueGameImportDuplicateExists(
        externalGameID: String?,
        externalSource: String?,
        venueId: UUID?,
        gameDate: Date
    ) async -> Bool {
        let trimmedExternalGameID = externalGameID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmedExternalGameID.isEmpty else {
#if DEBUG
            print("[BusinessGameImportDebug] duplicateCheckResult=false reason=missing_external_id")
#endif
            return false
        }

        let trimmedExternalSource = externalSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _ = gameDate

        do {
            var query = supabase
                .from("venue_events")
                .select("id")
                .eq("external_game_id", value: trimmedExternalGameID)
                .eq("admin_status", value: "active")

            if !trimmedExternalSource.isEmpty {
                query = query.eq("external_source", value: trimmedExternalSource)
            }
            if let venueId {
                query = query.eq("venue_id", value: venueId.uuidString.lowercased())
            } else {
                let ownerRowEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
                if OwnerBusinessEmail.isValidStrict(ownerRowEmail) {
                    query = query.eq("owner_email", value: ownerRowEmail)
                } else {
#if DEBUG
                    print("[BusinessGameImportDebug] duplicateCheckResult=false reason=missing_venue_scope")
#endif
                    return false
                }
            }

            let rows: [VenueEventDuplicateCheckRow] = try await query.limit(1).execute().value
            let exists = !rows.isEmpty
#if DEBUG
            print("[BusinessGameImportDebug] duplicateCheckResult=\(exists)")
#endif
            return exists
        } catch {
#if DEBUG
            print("[BusinessGameImportDebug] duplicateCheckResult=false error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    func venueGameManualDuplicateExists(
        venueId: UUID?,
        gameTitle: String,
        sport: String,
        homeTeam: String?,
        awayTeam: String?,
        gameDate: Date,
        gameStartTime: Date
    ) async -> Bool {
        let normalizedSport = Self.normalizedHostedGameIdentityComponent(sport)
        let normalizedHomeTeam = Self.normalizedHostedGameIdentityComponent(homeTeam)
        let normalizedAwayTeam = Self.normalizedHostedGameIdentityComponent(awayTeam)
        let normalizedTitle = Self.normalizedHostedGameIdentityComponent(gameTitle)
        guard !normalizedSport.isEmpty, (!normalizedTitle.isEmpty || (!normalizedHomeTeam.isEmpty && !normalizedAwayTeam.isEmpty)) else {
            return false
        }

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        let eventDate = dateFormatter.string(from: gameDate)

        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "h:mm a"
        timeFormatter.timeZone = TimeZone.current
        let eventTime = timeFormatter.string(from: gameStartTime)

        do {
            var query = supabase
                .from("venue_events")
                .select("id,venue_id,owner_email,venue_name,event_title,sport,home_team,away_team,event_date,event_time,scheduled_start_at,cleanup_delay_hours,purge_after_at,external_league,external_game_id,external_source,imported_from_api,admin_status,created_at")
                .eq("event_date", value: eventDate)
                .eq("event_time", value: eventTime)
                .eq("admin_status", value: "active")

            if let venueId {
                query = query.eq("venue_id", value: venueId.uuidString.lowercased())
            } else {
                let ownerRowEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
                if OwnerBusinessEmail.isValidStrict(ownerRowEmail) {
                    query = query.eq("owner_email", value: ownerRowEmail)
                } else {
#if DEBUG
                    print("[BusinessManualGameDuplicateDebug] duplicateCheckResult=false reason=missing_venue_scope")
#endif
                    return false
                }
            }

            let rows: [VenueEventRow] = try await query.limit(50).execute().value
            return rows.contains { row in
                Self.manualHostedGameIdentityMatches(
                    row: row,
                    normalizedSport: normalizedSport,
                    normalizedHomeTeam: normalizedHomeTeam,
                    normalizedAwayTeam: normalizedAwayTeam,
                    normalizedTitle: normalizedTitle
                )
            }
        } catch {
#if DEBUG
            print("[BusinessManualGameDuplicateDebug] duplicateCheckResult=false error=\(error.localizedDescription)")
#endif
            return false
        }
    }

    private static func manualHostedGameIdentityMatches(
        row: VenueEventRow,
        normalizedSport: String,
        normalizedHomeTeam: String,
        normalizedAwayTeam: String,
        normalizedTitle: String
    ) -> Bool {
        guard row.imported_from_api != true else { return false }
        let externalGameID = row.external_game_id?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let externalSource = row.external_source?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard externalGameID.isEmpty, externalSource.isEmpty || externalSource == "manual" else { return false }
        guard Self.normalizedHostedGameIdentityComponent(row.sport) == normalizedSport else { return false }

        let rowHomeTeam = Self.normalizedHostedGameIdentityComponent(row.home_team)
        let rowAwayTeam = Self.normalizedHostedGameIdentityComponent(row.away_team)
        if !normalizedHomeTeam.isEmpty,
           !normalizedAwayTeam.isEmpty,
           !rowHomeTeam.isEmpty,
           !rowAwayTeam.isEmpty {
            return rowHomeTeam == normalizedHomeTeam && rowAwayTeam == normalizedAwayTeam
        }

        guard !normalizedTitle.isEmpty else { return false }
        return Self.normalizedHostedGameIdentityComponent(row.event_title) == normalizedTitle
    }

    private static func normalizedHostedGameIdentityComponent(_ value: String?) -> String {
        let folded = (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        return folded
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private struct VenueEventDuplicateCheckRow: Decodable {
        let id: UUID?
    }

    /// Updates only `event_title` for imported games; manual games may also correct stored participant/team names.
    func updateVenueGameEventTitle(id: UUID, newTitle: String) async -> String? {
        await updateVenueGameEventDetails(
            id: id,
            newTitle: newTitle,
            homeTeam: nil,
            awayTeam: nil,
            allowTeamEdits: false
        )
    }

    func updateVenueGameEventDetails(
        id: UUID,
        newTitle: String,
        homeTeam: String?,
        awayTeam: String?,
        allowTeamEdits: Bool
    ) async -> String? {
        struct VenueEventTitlePatch: Encodable {
            let event_title: String
        }
        struct VenueEventManualDetailsPatch: Encodable {
            enum CodingKeys: String, CodingKey {
                case event_title
                case home_team
                case away_team
            }

            let event_title: String
            let home_team: String?
            let away_team: String?

            func encode(to encoder: Encoder) throws {
                var container = encoder.container(keyedBy: CodingKeys.self)
                try container.encode(event_title, forKey: .event_title)
                if let home_team {
                    try container.encode(home_team, forKey: .home_team)
                } else {
                    try container.encodeNil(forKey: .home_team)
                }
                if let away_team {
                    try container.encode(away_team, forKey: .away_team)
                } else {
                    try container.encodeNil(forKey: .away_team)
                }
            }
        }

        if await businessBanGuardBlocks(path: "venueGame", action: "updateVenueGameEventTitle") {
            return "Your account is suspended."
        }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Title can’t be empty." }

        do {
            let existingRows: [VenueEventRow] = try await supabase
                .from("venue_events")
                .select("id,venue_id,owner_email,venue_name,event_title,sport,home_team,away_team,event_date,event_time,scheduled_start_at,cleanup_delay_hours,purge_after_at,external_league,external_game_id,external_source,imported_from_api,admin_status,created_at")
                .eq("id", value: id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            guard let existing = existingRows.first else {
                return "Could not find that hosted game."
            }

            let canEditTeams = allowTeamEdits && Self.venueEventAllowsManualTeamEdits(existing)
            if canEditTeams {
                let patch = VenueEventManualDetailsPatch(
                    event_title: trimmed,
                    home_team: Self.trimmedNilableVenueGameTeam(homeTeam),
                    away_team: Self.trimmedNilableVenueGameTeam(awayTeam)
                )
                let _: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .update(patch)
                    .eq("id", value: id.uuidString.lowercased())
                    .select()
                    .execute()
                    .value
            } else {
                let patch = VenueEventTitlePatch(event_title: trimmed)
                let _: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .update(patch)
                    .eq("id", value: id.uuidString.lowercased())
                    .select()
                    .execute()
                    .value
            }

            return nil
        } catch {
            print("ERROR UPDATING VENUE GAME DETAILS:", error)
            return error.localizedDescription
        }
    }

    private static func venueEventAllowsManualTeamEdits(_ row: VenueEventRow) -> Bool {
        if row.imported_from_api == true { return false }
        let externalSource = row.external_source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let externalGameID = row.external_game_id?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return externalGameID.isEmpty
            && (externalSource.isEmpty || externalSource == "manual")
    }

    private static func trimmedNilableVenueGameTeam(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    func updateVenueGameListing(
        id: UUID,
        gameTitle: String,
        sport: String,
        gameDate: Date,
        gameStartTime: Date,
        soundOn: Bool,
        audioType: VenueAudioType,
        teamFanbase: String,
        atmosphere: String,
        crowdLevel: String,
        liveOccupancy: String,
        seating: String,
        numberOfTVs: String,
        drinkSpecial: String,
        coverCharge: String,
        reservationInfo: String,
        socialCoordination: String
    ) async {
        if await businessBanGuardBlocks(path: "venueGame", action: "updateVenueGameListing") {
            return
        }

        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameStartTime) {
            print("VENUE GAME UPDATE BLOCKED: past schedule — \(VenueOwnerGameScheduleValidation.futureDateTimeMessage)")
            return
        }

        do {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd"
            dateFormatter.timeZone = TimeZone.current

            let timeFormatter = DateFormatter()
            timeFormatter.dateFormat = "h:mm a"
            timeFormatter.timeZone = TimeZone.current

            struct VenueEventUpdate: Encodable {
                let event_title: String
                let sport: String
                let event_date: String
                let event_time: String
                let sound_on: Bool
                let audio_type: String
                let drink_special: String
                let cover_charge: String
                let expected_crowd: String
                let available_seating: String
                let reservations_available: Bool
                let waitlist_available: Bool
            }

            let updatedGame = VenueEventUpdate(
                event_title: gameTitle,
                sport: sport,
                event_date: dateFormatter.string(from: gameDate),
                event_time: timeFormatter.string(from: gameStartTime),
                sound_on: soundOn,
                audio_type: audioType.rawValue,
                drink_special: drinkSpecial,
                cover_charge: coverCharge,
                expected_crowd: crowdLevel,
                available_seating: liveOccupancy,
                reservations_available: !reservationInfo.isEmpty,
                waitlist_available: !socialCoordination.isEmpty
            )

            print("UPDATING GAME ID:", id)
            print("NEW TITLE:", gameTitle)

            let updatedRows: [VenueEventRow] = try await supabase
                .from("venue_events")
                .update(updatedGame)
                .eq("id", value: id.uuidString.lowercased())
                .select()
                .execute()
                .value

            print("UPDATED ROW COUNT:", updatedRows.count)
            print("UPDATED ROWS:", updatedRows)

#if DEBUG
            if let u = updatedRows.first {
                let vidStr = u.venue_id?.uuidString ?? "nil"
                let eid = u.id?.uuidString ?? "nil"
                let adm = u.admin_status ?? "nil"
                print(
                    "[DiscoverDotsSave] table=venue_events op=update venue_id=\(vidStr) event_id=\(eid) event_date=\(u.event_date ?? "nil") scheduled_start_at=\(u.scheduled_start_at ?? "nil") sport=\(u.sport ?? "nil") admin_status=\(adm) (no status/is_visible columns on client venue_events model)"
                )
            }
#endif

        } catch {
            print("ERROR UPDATING VENUE GAME:", error)
            let message = Self.userFacingVenueGameScheduleOrSaveError(error)
            print("VENUE GAME UPDATE FAILED:", message)
        }
    }
    
    
    func loadMyVenueGames() async -> [VenueEventRow] {
        do {
            var query = supabase
                .from("venue_events")
                .select()
                .eq("admin_status", value: "active")

            if let vid = ownerVenueDatabaseId {
#if DEBUG
                print("[BusinessPhaseB3] using venue_id path screen=loadMyVenueGames")
#endif
                query = query.eq("venue_id", value: vid.uuidString.lowercased())
            } else {
                let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
                guard OwnerBusinessEmail.isValidStrict(email) else { return [] }
#if DEBUG
                print("[BusinessPhaseB3] using owner_email fallback screen=loadMyVenueGames")
#endif
                query = query.eq("owner_email", value: email)
            }

            let rows: [VenueEventRow] = try await query
                .order("event_date", ascending: true)
                .execute()
                .value

            return rows
        } catch {
            print("ERROR LOADING MY VENUE GAMES:", error)
            return []
        }
    }

    /// Active + archived rows for **Venue Analytics** (past, cancelled, and engagement history). Does not affect Discover fetches.
    func loadMyVenueGamesForAnalytics() async -> [VenueEventRow] {
        do {
            var query = supabase
                .from("venue_events")
                .select()
                .in("admin_status", values: ["active", "archived"])

            if let vid = ownerVenueDatabaseId {
                query = query.eq("venue_id", value: vid.uuidString.lowercased())
            } else {
                let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
                guard OwnerBusinessEmail.isValidStrict(email) else { return [] }
                query = query.eq("owner_email", value: email)
            }

            let rows: [VenueEventRow] = try await query
                .order("event_date", ascending: false)
                .execute()
                .value

            return rows
        } catch {
            print("ERROR LOADING VENUE GAMES FOR ANALYTICS:", error)
            return []
        }
    }

    /// Upcoming/active games for Manage Games **Scheduled** tab, visible until the fixed venue auto-close window.
    func loadMyVenueScheduledGames() async -> [VenueEventRow] {
        do {
            let iso = ISO8601DateFormatter()
            iso.timeZone = TimeZone.current
            iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let now = Date()
            let lowerBound = now.addingTimeInterval(-Double(VenueOwnerGameDataRetentionHours.fixedHoursAfterStart) * 3600)
            let lowerBoundStr = iso.string(from: lowerBound)

            var query = supabase
                .from("venue_events")
                .select()
                .eq("admin_status", value: "active")
                .gte("scheduled_start_at", value: lowerBoundStr)

            if let vid = ownerVenueDatabaseId {
                query = query.eq("venue_id", value: vid.uuidString.lowercased())
            } else {
                let email = OwnerBusinessEmail.normalized(venueOwnerEmail)
                guard OwnerBusinessEmail.isValidStrict(email) else { return [] }
                query = query.eq("owner_email", value: email)
            }

            let rows: [VenueEventRow] = try await query
                .order("scheduled_start_at", ascending: true)
                .execute()
                .value

            return rows.filter { row in
                guard let start = VenueGameExpiration.scheduledStartDate(for: row),
                      let expiration = Calendar.current.date(
                        byAdding: .hour,
                        value: VenueOwnerGameDataRetentionHours.fixedHoursAfterStart,
                        to: start
                      ) else {
                    return true
                }
                return expiration > now
            }
        } catch {
            print("ERROR LOADING SCHEDULED VENUE GAMES:", error)
            return []
        }
    }

    /// Purged-game metadata for the business **History** tab (requires RLS on `business_game_history`).
    func loadBusinessGameHistory(businessId: UUID, year: Int) async throws -> [BusinessGameHistoryRow] {
        let cal = Calendar.current
        guard let yearStart = cal.date(from: DateComponents(year: year, month: 1, day: 1, hour: 0, minute: 0, second: 0)),
              let nextYearStart = cal.date(from: DateComponents(year: year + 1, month: 1, day: 1, hour: 0, minute: 0, second: 0))
        else {
            return []
        }

        let iso = ISO8601DateFormatter()
        iso.timeZone = TimeZone.current
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let lower = iso.string(from: yearStart)
        let upper = iso.string(from: nextYearStart)

        return try await supabase
            .from("business_game_history")
            .select()
            .eq("business_id", value: businessId.uuidString.lowercased())
            .gte("scheduled_start_at", value: lower)
            .lt("scheduled_start_at", value: upper)
            .order("scheduled_start_at", ascending: false)
            .execute()
            .value
    }

    /// Soft-cancels a venue game for the signed-in owner: sets `admin_status` to **archived** (Discover queries use `active` only).
    /// Returns `nil` on success or an error message.
    func deleteVenueGame(_ game: VenueEventRow) async -> String? {
        if await businessBanGuardBlocks(path: "venueGame", action: "deleteVenueGame") {
            return "Your account is suspended."
        }

        guard let id = game.id else { return "This game can’t be removed (missing id)." }

#if DEBUG
        print("[BusinessGameCancel] requested event_id=\(id.uuidString.lowercased())")
#endif

        do {
            try await supabase
                .from("venue_events")
                .update(VenueEventAdminArchivePatch(admin_status: "archived"))
                .eq("id", value: id.uuidString.lowercased())
                .execute()

#if DEBUG
            print("[BusinessGameCancel] database update/delete completed event_id=\(id.uuidString.lowercased())")
#endif

            await applyCancelledVenueEventLocally(
                removedEventId: id,
                venueId: game.venue_id,
                venueName: game.venue_name,
                eventTitle: game.event_title,
                eventDate: game.event_date
            )

            return nil
        } catch {
#if DEBUG
            print("[BusinessGameCancel] failed event_id=\(id.uuidString.lowercased()) error=\(error)")
#endif
            print("ERROR ARCHIVING VENUE GAME:", error)
            return error.localizedDescription
        }
    }

    // MARK: - Venue owner analytics (interest counts for owned events)

    /// Fetches `venue_event_interests` rows for the given events and merges counts into `venueEventInterestCounts`
    /// without replacing counts for unrelated events (unlike ``loadVisibleVenueEventInterests()``).
    func loadInterestCountsForVenueEventIDs(_ eventIDs: [UUID]) async {
        guard !eventIDs.isEmpty else { return }

        let unique = Array(Set(eventIDs))
        let chunkSize = 90

        do {
            var counts: [UUID: Int] = [:]

            var index = 0
            while index < unique.count {
                let end = min(index + chunkSize, unique.count)
                let chunk = Array(unique[index..<end])
                index = end

                let idStrings = chunk.map { $0.uuidString.lowercased() }
                let rows: [VenueEventInterestRow] = try await supabase
                    .from("venue_event_interests")
                    .select("venue_event_id")
                    .in("venue_event_id", values: idStrings)
                    .execute()
                    .value

                for row in rows {
                    guard let eventID = row.venue_event_id else { continue }
                    counts[eventID, default: 0] += 1
                }
            }

            await MainActor.run {
                for id in unique {
                    #if DEBUG
                    let oldValue = venueEventInterestCounts[id] ?? 0
                    let newValue = counts[id] ?? 0
                    print("[RealtimeChainDebug] uiStateUpdated table=venue_event_interests key=\(id.uuidString.lowercased()).ownerAnalyticsCount oldValue=\(oldValue) newValue=\(newValue)")
                    #endif
                    venueEventInterestCounts[id] = counts[id] ?? 0
                }
            }
        } catch {
            #if DEBUG
            print("ERROR LOADING INTEREST COUNTS FOR VENUE EVENT IDS:", error)
            #endif
        }
    }

    /// Engagement score for owner analytics: going/interested count + fan updates + all vibe taps.
    func venueOwnerEngagementScore(venueEventID: UUID) -> Int {
        let going = interestCountForVenueEvent(venueEventID)
        let comments = venueEventComments[venueEventID]?.count ?? 0
        let vibeTaps = venueEventVibeCounts[venueEventID]?.values.reduce(0, +) ?? 0
        return going + comments + vibeTaps
    }

    /// Trend label buckets for venue-owner analytics (distinct from map pin copy).
    func venueOwnerEngagementTrendLabel(score: Int) -> String {
        if score >= 40 {
            return "👑 Trending now"
        }
        if score >= 16 {
            return "🚀 Hot"
        }
        if score >= 6 {
            return "🔥 Active"
        }
        return "✨ Starting up"
    }

#if DEBUG
    /// Debug-only: logs canonical start + purge threshold (`purge_after_at` from API when returned, else derived from `scheduled_start_at` + `cleanup_delay_hours`).
    func logVenueGameExpirationDebug(durationHours: Int, row: VenueEventRow) {
        let gameStart = row.scheduled_start_at ?? "nil"
        let removeAfter: String = {
            if let p = row.purge_after_at, !p.isEmpty { return p }
            guard let sched = row.scheduled_start_at,
                  let h = row.cleanup_delay_hours,
                  let start = PickupGameModels.parseSupabaseTimestamptz(sched)
            else { return "nil" }
            let end = start.addingTimeInterval(Double(h) * 3600)
            let f = ISO8601DateFormatter()
            f.timeZone = TimeZone(secondsFromGMT: 0)
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.string(from: end)
        }()
        print("[VenueGameExpirationDebug] durationHours=\(durationHours)")
        print("[VenueGameExpirationDebug] game_start_at=\(gameStart)")
        print("[VenueGameExpirationDebug] remove_after_at=\(removeAfter)")
    }
#endif
}
