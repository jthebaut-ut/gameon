import Foundation
import CoreLocation
import SwiftUI
import Supabase

private struct VenueEventAdminArchivePatch: Encodable {
    let admin_status: String
}

private struct ReleaseOrDeleteBusinessVenueParams: Encodable {
    let p_venue_id: UUID
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
    case missingVenue
    case serverRejected

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in as the business owner to manage this venue."
        case .missingVenue:
            return "Select a venue first."
        case .serverRejected:
            return "The venue change did not complete. Please try again."
        }
    }
}

// Venue-owner auth, `venue_claims` workflow, venue profile CRUD in `venues`, photo uploads, and related listings.

extension MapViewModel {

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
            return
        }

        guard let coverData = coverPhotoJPEGData, !coverData.isEmpty else {
#if DEBUG
            print("[BusinessSignup] validation failed main venue photo missing coverPhotoExists=false")
#endif
            await MainActor.run { venueAuthErrorMessage = "Main venue photo is required." }
            return
        }

        if let formError = validationErrorForAddLocationClaimForm(signup.firstLocation, requireCoverPhotoURL: false) {
#if DEBUG
            print("[BusinessSignup] validation failed form_fields message=\(formError)")
#endif
            await MainActor.run { venueAuthErrorMessage = formError }
            return
        }
        guard !businessName.isEmpty else {
#if DEBUG
            print("[BusinessSignup] validation failed business_name_empty")
#endif
            await MainActor.run { venueAuthErrorMessage = "Please enter your business name." }
            return
        }

#if DEBUG
        print("[BusinessSignup] validation passed proceeding to auth.signUp")
#endif

        if await activeFanUserProfileExistsForEmail(ownerEmail) {
#if DEBUG
            print("[AuthAccountTypeGate] business registration blocked fanEmail=\(ownerEmail)")
#endif
            await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
            return
        }

        do {
#if DEBUG
            print("[BusinessSignup] auth signup started email=\(ownerEmail)")
#endif
            _ = try await supabase.auth.signUp(
                email: ownerEmail,
                password: password
            )
        } catch {
#if DEBUG
            print("[BusinessSignup] auth signup error localized=\(error.localizedDescription) full=\(error)")
#endif
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

        guard let session = try? await supabase.auth.session else {
#if DEBUG
            print("[BusinessSignup] auth signup no session after signUp (email confirmation or client state); signing out")
            print("[AuthStateDebug] forcedLogoutReason=businessSignupNoSessionAfterSignUp")
#endif
            try? await supabase.auth.signOut()
            await MainActor.run {
                clearAuthenticatedSessionCaches()
                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                authSessionState = .signedOut
#if DEBUG
                print("[AuthStateDebug] authStateTransition=businessSignupNoSessionAfterSignUp->signedOut")
#endif
                venueAuthErrorMessage = "Account was created but there is no active session yet. Confirm your email if required, then sign in."
            }
            await persistAccountModeForActiveAuthSession(.fanUser)
            return
        }

        let ownerUserId = session.user.id

#if DEBUG
        let jwtEmail = session.user.email ?? "nil"
        print(
            "[BusinessSignup] auth signup success authenticated_session_user_id=\(ownerUserId.uuidString) owner_user_id=\(ownerUserId.uuidString) jwt_email=\(jwtEmail)"
        )
#endif

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            venueOwnerEmail = ownerEmail
            isVenueOwnerLoggedIn = true
            venueOwnerMode = true
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
            authSessionState = .signedIn
#if DEBUG
            print("[AuthStateDebug] authStateTransition=businessSignup->signedIn")
#endif
        }

        guard let coverURL = await uploadVenuePhoto(data: coverData, fileName: "cover.jpg", assignToCurrentVenueProfile: false) else {
#if DEBUG
            print("[BusinessSignup] cover upload failed post-auth (uploadVenuePhoto returned nil; see ERROR UPLOADING PHOTO log above) cover_upload_url_exists=false")
            print("[AuthStateDebug] forcedLogoutReason=businessSignupCoverUploadFailed")
#endif
            try? await supabase.auth.signOut()
            await MainActor.run {
                clearAuthenticatedSessionCaches()
                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                authSessionState = .signedOut
#if DEBUG
                print("[AuthStateDebug] authStateTransition=businessSignupCoverUploadFailed->signedOut")
#endif
                venueAuthErrorMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
            }
            await persistAccountModeForActiveAuthSession(.fanUser)
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
            print("[AuthStateDebug] forcedLogoutReason=businessSignupBusinessInsertFailed")
#endif
            try? await supabase.auth.signOut()
            await MainActor.run {
                clearAuthenticatedSessionCaches()
                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                authSessionState = .signedOut
#if DEBUG
                print("[AuthStateDebug] authStateTransition=businessSignupBusinessInsertFailed->signedOut")
#endif
                venueAuthErrorMessage =
                    "Could not create your business record. This is usually blocked by database permissions (RLS). An admin must allow authenticated business owners to insert into `businesses`, or creation must run on a secure backend."
            }
            await persistAccountModeForActiveAuthSession(.fanUser)
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
            let inserted: VenueClaimInsertedRow = try await supabase
                .from("venue_claims")
                .insert(claim)
                .select("id,created_at,approval_status")
                .single()
                .execute()
                .value

#if DEBUG
            print(
                "[BusinessSignup] venue_claim insert success claim_id=\(inserted.id.uuidString) approval_status=\(inserted.approval_status ?? "nil") created_at=\(inserted.created_at ?? "nil")"
            )
#endif

            await MainActor.run {
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
#if DEBUG
                print("[AuthStateDebug] forcedLogoutReason=businessLoginNoSessionAfterSignIn")
#endif
                try? await supabase.auth.signOut()
                await MainActor.run {
                    isVenueOwnerLoggedIn = false
                    clearVenueOwnerOwnedBusinessCaches()
                    ownerVenueDatabaseId = nil
                    authSessionState = .signedOut
#if DEBUG
                    print("[AuthStateDebug] authStateTransition=businessLoginNoSessionAfterSignIn->signedOut")
#endif
                    venueAuthErrorMessage = "Unable to login venue owner."
                }
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

                if message.contains("invalid login credentials") {
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

    /// Active venues for this owner: business-linked rows when present, otherwise legacy `owner_email` rows.
    func managedVenuesForOwner() -> [VenueProfileRow] {
        if !ownedBusinessVenues.isEmpty {
            return ownedBusinessVenues
        }
        return legacyOwnerVenuesForEmailFallback
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
        isVenueOwnerBusinessDataLoading = false
        pendingVenueClaimsForSettings = []
        rejectedVenueClaimsForSettings = []
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

        do {
            let rows: [VenueClaimPendingSettingsRow] = try await supabase
                .from("venue_claims")
                .select("id,business_id,venue_id,venue_name,venue_address,venue_address_line2,venue_city,venue_state,venue_country,approval_status,rejection_acknowledged_at,created_at")
                .eq("owner_email", value: email)
                .order("created_at", ascending: false)
                .limit(80)
                .execute()
                .value

            let filteredPending = rows.filter { row in
                Self.isPendingUnapprovedClaimStatus(row.approval_status)
                    && Self.pendingClaimMatchesOwnerBusinesses(row, ownerBusinessIds: businessIds)
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

    /// Persists dismissal of a rejected claim for the signed-in business owner (``rejection_acknowledged_at``); claim row remains for audit.
    func acknowledgeRejectedVenueClaim(claimId: UUID) async {
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

    private static func isVenueClaimRejectionAcknowledged(_ rejectionAcknowledgedAt: String?) -> Bool {
        let t = rejectionAcknowledgedAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !t.isEmpty
    }

    private static func isPendingUnapprovedClaimStatus(_ status: String?) -> Bool {
        let s = status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if isApprovedClaimStatus(status) { return false }
        if s == "released" { return false }
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
            .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
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
            .eq("admin_status", value: "active")
            .execute()
            .value
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
            let inserted: VenueClaimInsertedRow = try await supabase
                .from("venue_claims")
                .insert(claim)
                .select("id,created_at,approval_status")
                .single()
                .execute()
                .value
#if DEBUG
            let vn = claim.venue_name
            print("[AddLocation] submitting full location request business_id=\(businessId.uuidString) venue_name=\(vn) screen_count=\(claim.screen_count) features_len=\(claim.venue_features.count)")
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
            print("ERROR SUBMITTING ADD LOCATION CLAIM:", error)
            return VenueClaimDuplicateCheck.userMessageIfKnownInsertError(error) ?? error.localizedDescription
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
            let a = $0.venue_name ?? ""
            let b = $1.venue_name ?? ""
            if a == b, let ia = $0.id, let ib = $1.id { return ia.uuidString < ib.uuidString }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    private func applySelectedVenueAfterBusinessLoad() {
        let managed = managedVenuesForOwner()
        guard !managed.isEmpty else {
            ownerVenueDatabaseId = nil
            persistSelectedVenueId(nil)
            return
        }

        if managed.count == 1, let id = managed.first?.id {
            ownerVenueDatabaseId = id
            persistSelectedVenueId(id)
#if DEBUG
            print("[BusinessPhaseB2] restored selected venue id=\(id.uuidString)")
#endif
            return
        }

        let managedIds = Set(managed.compactMap(\.id))
        if let persisted = readPersistedSelectedVenueId(), managedIds.contains(persisted) {
            ownerVenueDatabaseId = persisted
#if DEBUG
            print("[BusinessPhaseB2] restored selected venue id=\(persisted.uuidString)")
#endif
            return
        }

        let sortedOwned = sortedManagedVenues(ownedBusinessVenues)
        let pickId: UUID?
        if let first = sortedOwned.first?.id {
            pickId = first
        } else {
            pickId = sortedManagedVenues(managed).first?.id
        }

        if let id = pickId {
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

    func updateManagedVenueProfileCaches(_ saved: VenueProfileRow) {
        guard let savedId = saved.id else { return }
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
        }
        print("[VenuePhotoSaveDebug] cacheUpdatedPhotoURL=\(saved.cover_photo_url ?? "")")
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
    /// local UI is removed optimistically and restored if the RPC fails.
    func releaseOrDeleteBusinessVenue(venueId: UUID) async throws -> BusinessVenueReleaseOrDeleteResult {
        guard hasAuthenticatedVenueOwnerSession else {
            throw BusinessVenueDeletionError.notSignedIn
        }

        let modeDebug = await MainActor.run {
            let rawOrigin = (ownedBusinessVenues + legacyOwnerVenuesForEmailFallback)
                .first { $0.id == venueId }?
                .origin_type?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            let originType = rawOrigin == "community" ? "community" : "business"
            return (
                originType: originType,
                action: originType == "community" ? "release" : "hardDelete"
            )
        }
#if DEBUG
        print("[VenueDeleteModeDebug] originType=\(modeDebug.originType) action=\(modeDebug.action)")
#endif

        let eventIDsBeforeRPC = await MainActor.run {
            Set(venueEventRows.compactMap { row -> UUID? in
                guard row.venue_id == venueId else { return nil }
                return row.id
            })
        }

        await stopVenueOwnerAnalyticsRealtime()
        await removeAllVenueEventCommentsRealtimeListeners()
        for eventID in eventIDsBeforeRPC {
            await stopVenueEventPredictionRealtime(for: eventID)
        }

        let snapshot = await MainActor.run {
            applyOptimisticBusinessVenueDeletion(venueId: venueId, deletedEventIDs: eventIDsBeforeRPC)
        }

        let response: BusinessVenueReleaseOrDeleteResult
        do {
            response = try await supabase
                .rpc(
                    "release_or_delete_business_venue",
                    params: ReleaseOrDeleteBusinessVenueParams(p_venue_id: venueId)
                )
                .execute()
                .value
        } catch {
            await MainActor.run {
                restoreBusinessVenueDeletionSnapshot(snapshot)
            }
            throw error
        }

        guard response.ok else {
            await MainActor.run {
                restoreBusinessVenueDeletionSnapshot(snapshot)
            }
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
        let deletedURLs = deletedVenueImageURLs(venueId: venueId)
        removeVenueFromLocalCollections(venueId: venueId, deletedEventIDs: deletedEventIDs)
        removeLocalVenueRating(venueID: venueId)
        applySelectedVenueAfterBusinessLoad()
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
            let previousApprovedVenueIds = Set(managedVenuesForOwner().compactMap(\.id))
            let authUid = await MainActor.run { currentUserAuthId }

            var businessesFromEmail: [BusinessRow] = []
            if OwnerBusinessEmail.isValidStrict(emailTrimmed) {
                businessesFromEmail = try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
                    .eq("owner_email", value: emailTrimmed)
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            }

            var businessesFromUser: [BusinessRow] = []
            if let authUid {
                businessesFromUser = try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
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
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
                    .eq("owner_email", value: emailTrimmed)
                    .eq("admin_status", value: "archived")
                    .execute()
                    .value
            }

            var archivedFromUser: [BusinessRow] = []
            if let authUid {
                archivedFromUser = try await supabase
                    .from("businesses")
                    .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
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
                    .eq("admin_status", value: "active")
                    .execute()
                    .value
            }

            // Always load `owner_email` venues. Previously we only did this when the business_id query
            // returned zero rows, which hid newly-approved locations that were still keyed by email only.
            let emailVenueRows: [VenueProfileRow] = try await supabase
                .from("venues")
                .select()
                .eq("owner_email", value: emailTrimmed)
                .eq("admin_status", value: "active")
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
                        .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
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
                                .eq("admin_status", value: "active")
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
                    .eq("admin_status", value: "active")
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
            let approvedManagedVenueIds = Set(mergedVenues.compactMap(\.id))
            let newlyApprovedManagedVenueIds = approvedManagedVenueIds.subtracting(previousApprovedVenueIds)
            let coordinateBackfilledVenueIds = await backfillApprovedManagedVenueCoordinatesIfNeeded(mergedVenues)

            await MainActor.run {
                ownedBusinesses = resolvedBusinesses
                archivedOwnedBusinesses = archivedBusinesses
                ownedBusinessVenues = mergedVenues
                legacyOwnerVenuesForEmailFallback = emailVenueRows
#if DEBUG
                print("[BusinessPhaseB1] loaded businesses count=\(resolvedBusinesses.count)")
                print("[BusinessPhaseB1] loaded archived businesses count=\(archivedBusinesses.count)")
                let bizIds = resolvedBusinesses.map(\.id.uuidString).sorted().joined(separator: ",")
                print("[BusinessRefresh] ownedBusinesses ids=\(bizIds.isEmpty ? "(none)" : bizIds)")
                print("[BusinessPhaseB1] loaded venues count=\(mergedVenues.count)")
                for v in mergedVenues {
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
                print("[ManagedVenuesDebug] rowsReturned=\(mergedVenues.count)")
                print("[ManagedVenuesDebug] venueIds=\(managedIds.isEmpty ? "(none)" : managedIds)")
                print("[ManagedVenuesDebug] selectedVenueId=\(sel)")
                for id in approvedManagedVenueIds {
                    print("[ApprovedVenueVisibilityDebug] managedVenueApproved id=\(id.uuidString)")
                }
#endif
                applySelectedVenueAfterBusinessLoad()
            }

            let loadedProfileExists: Bool
            if mergedVenues.isEmpty {
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
            let games: [VenueEventRow] = mergedVenues.isEmpty ? [] : await loadMyVenueGames()
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
#endif
            await MainActor.run {
                clearVenueOwnerOwnedBusinessCaches()
                ownerVenueDatabaseId = nil
                isVenueOwnerBusinessDataLoading = false
            }
        }
    }

    func runDeferredBusinessOwnerHydrationAfterLaunch() async {
        let shouldHydrate = await MainActor.run {
            hasAuthenticatedVenueOwnerSession
        }
        guard shouldHydrate else { return }

        print("[BusinessLaunchPerf] deferredBusinessHydrationStarted=true")

        await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await MainActor.run {
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
                    .eq("admin_status", value: "active")
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
                .eq("admin_status", value: "active")
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

        do {
            let ownerEmailRow = OwnerBusinessEmail.normalized(venueOwnerEmail)
            guard OwnerBusinessEmail.isValidStrict(ownerEmailRow) else { return false }

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
            await loadVenuesFromSupabase(forceRefresh: true)
#if DEBUG
            print("[VenueFeatureDebug] propagatedToDiscover=true")
#endif
            if let saved = await loadVenueProfile() {
                await MainActor.run {
                    updateManagedVenueProfileCaches(saved)
                    applyVenueProfileRowToOwnerState(saved)
                }
#if DEBUG
                print("[VenueFeatureDebug] selectedFeatures=\(saved.features ?? "")")
                print("[VenueFeatureDebug] businessSelectedFeatures=\(saved.features ?? "")")
#endif
                print("[VenuePhotoSaveDebug] savedDatabasePhotoURL=\(saved.cover_photo_url ?? "")")
            }
            return true

        } catch {

            print("ERROR SAVING VENUE PROFILE:", error)

            return false
        }
    }

    // Uploads full + thumbnail JPEGs under the owner’s email folder in `venue-photos`; returns the full image public URL.
    func uploadVenuePhoto(data: Data, fileName: String, assignToCurrentVenueProfile: Bool = true) async -> String? {
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
        cleanupDelayHours: Int = VenueOwnerGameDataRetentionHours.defaultPickerHours,
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
                cleanupDelayHours: cleanupDelayHours,
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
        cleanupDelayHours: Int = VenueOwnerGameDataRetentionHours.defaultPickerHours,
        externalGameID: String? = nil,
        externalSource: String? = nil,
        importedFromAPI: Bool = false,
        externalLeague: String? = nil,
        homeTeam: String? = nil,
        awayTeam: String? = nil
    ) async -> Result<VenueEventRow, Error> {
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

        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameStartTime) {
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: VenueOwnerGameScheduleValidation.futureDateTimeMessage]
                )
            )
        }

        let retentionHours = VenueOwnerGameDataRetentionHours.standardOptions.contains(cleanupDelayHours)
            ? cleanupDelayHours
            : VenueOwnerGameDataRetentionHours.defaultPickerHours
        let trimmedExternalGameID = externalGameID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedExternalSource = externalSource?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedExternalLeague = externalLeague?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedHomeTeam = homeTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let trimmedAwayTeam = awayTeam?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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

            let inserted: [VenueEventRow] = try await supabase
                .from("venue_events")
                .insert(newGame)
                .select()
                .execute()
                .value

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
            logVenueGameExpirationDebug(selectedDurationHours: retentionHours, row: row)
#endif
            print("GAME LISTING SAVED")
            return .success(row)
        } catch {
            print("ERROR SAVING GAME LISTING:", error)
            let message = Self.userFacingVenueGameScheduleOrSaveError(error)
            return .failure(
                NSError(
                    domain: "VenueGameListing",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey: message]
                )
            )
        }
    }

    private static func userFacingVenueGameScheduleOrSaveError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let s = raw.lowercased()
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
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd"
        dateFormatter.timeZone = TimeZone.current
        let eventDate = dateFormatter.string(from: gameDate)

        do {
            var query = supabase
                .from("venue_events")
                .select("id")
                .eq("external_game_id", value: trimmedExternalGameID)
                .eq("event_date", value: eventDate)
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

    private struct VenueEventDuplicateCheckRow: Decodable {
        let id: UUID?
    }

    /// Updates only `event_title` for a venue-owned game (Manage Games title edit).
    func updateVenueGameEventTitle(id: UUID, newTitle: String) async -> String? {
        struct VenueEventTitlePatch: Encodable {
            let event_title: String
        }

        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Title can’t be empty." }

        do {
            let patch = VenueEventTitlePatch(event_title: trimmed)
            let _: [VenueEventRow] = try await supabase
                .from("venue_events")
                .update(patch)
                .eq("id", value: id.uuidString.lowercased())
                .select()
                .execute()
                .value

            return nil
        } catch {
            print("ERROR UPDATING VENUE GAME TITLE:", error)
            return error.localizedDescription
        }
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

    /// Upcoming/active games for Manage Games **Scheduled** tab (`scheduled_start_at` in the future).
    func loadMyVenueScheduledGames() async -> [VenueEventRow] {
        do {
            let iso = ISO8601DateFormatter()
            iso.timeZone = TimeZone.current
            iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            let nowStr = iso.string(from: Date())

            var query = supabase
                .from("venue_events")
                .select()
                .eq("admin_status", value: "active")
                .gte("scheduled_start_at", value: nowStr)

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

            return rows
        } catch {
            print("ERROR LOADING SCHEDULED VENUE GAMES:", error)
            return []
        }
    }

    /// Updates retention for an owned `venue_events` row (`purge_after_at` is generated from `scheduled_start_at` + hours).
    func updateVenueEventCleanupDelay(venueEventId: UUID, hours: Int) async -> String? {
        guard VenueOwnerGameDataRetentionHours.allPersistedValues.contains(hours) else {
            return "Cleanup delay must be one of: \(VenueOwnerGameDataRetentionHours.standardOptions.map(String.init).joined(separator: ", ")) hours (or a legacy saved value)."
        }
        do {
            try await supabase
                .from("venue_events")
                .update(VenueEventCleanupDelayPatch(cleanup_delay_hours: hours))
                .eq("id", value: venueEventId.uuidString.lowercased())
                .execute()

#if DEBUG
            do {
                let refreshed: [VenueEventRow] = try await supabase
                    .from("venue_events")
                    .select()
                    .eq("id", value: venueEventId.uuidString.lowercased())
                    .limit(1)
                    .execute()
                    .value
                if let row = refreshed.first {
                    logVenueGameExpirationDebug(selectedDurationHours: hours, row: row)
                }
            } catch {}
#endif
            return nil
        } catch {
            print("ERROR UPDATING VENUE EVENT CLEANUP DELAY:", error)
            return error.localizedDescription
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
    func logVenueGameExpirationDebug(selectedDurationHours: Int, row: VenueEventRow) {
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
        print("[VenueGameExpirationDebug] selectedDurationHours=\(selectedDurationHours)")
        print("[VenueGameExpirationDebug] game_start_at=\(gameStart)")
        print("[VenueGameExpirationDebug] remove_after_at=\(removeAfter)")
    }
#endif
}
