import Foundation
import Supabase

// End-user Supabase Auth (sign up / sign in / session) and `user_profiles` load/save, avatar upload, and profile caching.

extension MapViewModel {

    /// Last explicit account surface the user chose (fan vs business owner vs local admin UI). Drives cold-start session restoration together with ``storedAccountAuthUserIdKey``.
    enum StoredAccountMode: String, Sendable {
        case fanUser
        case businessOwner
        case admin
    }

    private static let storedAccountModeKey = "GameOn.storedAccountMode"
    private static let storedAccountAuthUserIdKey = "GameOn.storedAccountAuthUserId"

    /// When true, cold-start must not treat a still-cached Supabase session as a signed-in user until the next successful manual sign-in.
    private static let didExplicitlyLogoutKey = "didExplicitlyLogout"

    /// Clears ``didExplicitlyLogoutKey`` after email/password (or sign-up) auth establishes a session.
    func clearExplicitLogoutMarkerAfterManualAuthSucceeded() {
        UserDefaults.standard.set(false, forKey: Self.didExplicitlyLogoutKey)
#if DEBUG
        print("[Auth] manual login succeeded, logout marker cleared")
#endif
    }

    private func readPersistedAccountMode() -> (mode: StoredAccountMode, authUserId: String?) {
        let raw = UserDefaults.standard.string(forKey: Self.storedAccountModeKey)
        let mode = StoredAccountMode(rawValue: raw ?? "") ?? .fanUser
        let uid = UserDefaults.standard.string(forKey: Self.storedAccountAuthUserIdKey)
        return (mode, uid)
    }

    func clearPersistedAccountMode() {
        UserDefaults.standard.removeObject(forKey: Self.storedAccountModeKey)
        UserDefaults.standard.removeObject(forKey: Self.storedAccountAuthUserIdKey)
    }

    func logBusinessOwnerSessionFlags(context: String) {
#if DEBUG
        let normalizedOwnerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        print("[BusinessSessionFlags] context=\(context)")
        print("[BusinessSessionFlags] isVenueOwnerLoggedIn=\(isVenueOwnerLoggedIn)")
        print("[BusinessSessionFlags] venueOwnerMode=\(venueOwnerMode)")
        print("[BusinessSessionFlags] currentUserAuthId=\(currentUserAuthId?.uuidString ?? "nil")")
        print("[BusinessSessionFlags] venueOwnerEmail=\(normalizedOwnerEmail)")
        print("[BusinessSessionFlags] hasAuthenticatedVenueOwnerSession=\(hasAuthenticatedVenueOwnerSession)")
#endif
    }

    private func hasActiveBusinessAccount(ownerEmail: String) async -> Bool {
        let normalized = OwnerBusinessEmail.normalized(ownerEmail)
        guard OwnerBusinessEmail.isValidStrict(normalized) else { return false }

        if ownedBusinesses.contains(where: {
            OwnerBusinessEmail.normalized($0.owner_email ?? "") == normalized && $0.admin_status == "active"
        }) {
            return true
        }

        struct BusinessExistenceRow: Decodable {
            let id: UUID
        }

        do {
            let rows: [BusinessExistenceRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_email", value: normalized)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
#if DEBUG
            print("[BusinessSessionFlags] hasActiveBusinessAccount failed email=\(normalized):", error)
#endif
            return false
        }
    }

    @discardableResult
    func ensureBusinessOwnerSessionFlagsIfPossible(context: String) async -> Bool {
        logBusinessOwnerSessionFlags(context: "\(context)_before")

        if hasAuthenticatedVenueOwnerSession {
            logBusinessOwnerSessionFlags(context: "\(context)_already_valid")
            return true
        }

        guard let authId = currentUserAuthId else {
            logBusinessOwnerSessionFlags(context: "\(context)_missing_auth_id")
            return false
        }

        let normalizedOwnerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
        guard OwnerBusinessEmail.isValidStrict(normalizedOwnerEmail) else {
            logBusinessOwnerSessionFlags(context: "\(context)_invalid_owner_email")
            return false
        }

        guard await hasActiveBusinessAccount(ownerEmail: normalizedOwnerEmail) else {
            logBusinessOwnerSessionFlags(context: "\(context)_no_business_account")
            return false
        }

        isVenueOwnerLoggedIn = true
        venueOwnerMode = true
        isLoggedIn = false
        isAdminLoggedIn = false
        currentUserAuthId = authId
        venueOwnerEmail = normalizedOwnerEmail
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""

        await persistAccountModeForActiveAuthSession(.businessOwner)
        logBusinessOwnerSessionFlags(context: "\(context)_restored")
        return true
    }

    private func restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
        session: Session,
        sessionEmail: String,
        context: String
    ) async -> Bool {
        logBusinessOwnerSessionFlags(context: "\(context)_before")

        guard !hasAuthenticatedVenueOwnerSession else {
            logBusinessOwnerSessionFlags(context: "\(context)_already_valid")
            return true
        }

        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
            logBusinessOwnerSessionFlags(context: "\(context)_invalid_session_email")
            return false
        }

        guard await hasActiveBusinessAccount(ownerEmail: sessionEmail) else {
            logBusinessOwnerSessionFlags(context: "\(context)_no_business_account")
            return false
        }

        venueOwnerEmail = sessionEmail
        isVenueOwnerLoggedIn = true
        venueOwnerMode = true
        isLoggedIn = false
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        isAdminLoggedIn = false
        currentUserAuthId = session.user.id

        await persistAccountModeForActiveAuthSession(.businessOwner)
        await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        checkVenueApprovalStatus()
        logBusinessOwnerSessionFlags(context: "\(context)_restored")
        return true
    }

    func clearCurrentUserProfileLocalCache() {
        UserDefaults.standard.removeObject(forKey: "cachedUserDisplayName")
        UserDefaults.standard.removeObject(forKey: "cachedUserAvatarURL")
        UserDefaults.standard.removeObject(forKey: "cachedUserAvatarThumbnailURL")
    }

    /// Clears authenticated/private session caches that must never survive logout, session loss, or account switching.
    /// Intentionally does not mutate the high-level signed-in flags; callers clear caches first, then update flags.
    func clearAuthenticatedSessionCaches() {
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserAuthId = nil

        favoriteVenueIDs = []
        interestedVenueEventKeys = []
        favoriteVenueWriteInFlightIDs = []
        venueEventInterestWriteInFlightIDs = []
        venueEventInterestIDs = []
        venueEventInterestCounts = [:]
        socialActionToastDismissTask?.cancel()
        socialActionToastDismissTask = nil
        socialActionToastText = nil
        socialActionToastIsError = false
        followingMapNavigationMessage = nil
        clearFollowingTabCaches()
        clearFollowingInterestedOnlyDefaults()

        goingUserProfiles = []
        goingProfilesByVenueEventID = [:]
        commentIDsReportedByCurrentUser = []
        userProfilesByEmail = [:]
        myVenueEventVibes = [:]
        venueUserStarRatings = [:]
        venueRatingContributionCount = [:]
        Task { [weak self] in
            await self?.removeAllVenueEventCommentsRealtimeListeners()
        }

        venueOwnerEmail = ""
        ownerVenueDatabaseId = nil
        isVenueOwnerBusinessDataLoading = false
        clearVenueOwnerOwnedBusinessCaches()
        venueClaimSubmitted = false
        venueClaimStatus = "Not submitted"
        venueIsApproved = false
        venueClaimSubmittedDate = ""
        venueOwnerJustCompletedRegistration = false
        hasUnackedRejectedVenueClaimForOwnerEmail = false
        approvedVenueOwnershipByVenueID = [:]
        venueBusinessEmail = ""
        venueClaims = []

        reportedComments = []
        reportedCommentDisplays = []

        authErrorMessage = ""
        userPasswordResetMessage = ""
        userPasswordResetError = ""
        venueAuthErrorMessage = ""
        venuePasswordResetMessage = ""
        venuePasswordResetError = ""

        bumpCurrentUserAvatarDisplayRefresh()
        clearCurrentUserProfileLocalCache()
        privateSessionClearNonce = UUID()
    }

    /// Sign-out/session-loss cleanup for venue-owner drafts and claim context in addition to the shared cache reset.
    func clearVenueOwnerDraftState() {
        clearPendingVenueClaimContext()
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
        ownerVenueScreenCount = 1
        ownerVenueServesFood = false
        ownerVenueHasWifi = false
        ownerVenueHasGarden = false
        ownerVenueHasProjector = false
        ownerVenuePetFriendly = false
        venueCoverPhotoURL = ""
        venueCoverPhotoThumbnailURL = ""
        venueCrowdPhotoURL = ""
        venueTVWallPhotoURL = ""
        venueMenuPhotoURL = ""
        venueMenuPhotoThumbnailURL = ""
        venueSpecialsPhotoURL = ""
        venueProofNote = ""
        switchToAccountForVenueClaim = false
        openVenueOwnerAuthSheetFromClaimFlow = false
    }

    /// Persists the account mode and, when a Supabase session exists, the auth user id (so a different account on the same device does not restore the wrong mode).
    func persistAccountModeForActiveAuthSession(_ mode: StoredAccountMode) async {
        let uid: String?
        if let session = try? await supabase.auth.session {
            uid = session.user.id.uuidString.lowercased()
        } else {
            uid = nil
        }
        await MainActor.run {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.storedAccountModeKey)
            if let uid {
                UserDefaults.standard.set(uid, forKey: Self.storedAccountAuthUserIdKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.storedAccountAuthUserIdKey)
            }
        }
    }

    /// Venue owner “Log out” from Settings clears owner UI state but keeps Supabase signed in; fan mode becomes the restored surface on next launch.
    func venueOwnerLocalSignOutPreservingSupabaseSession() {
        clearAuthenticatedSessionCaches()
        clearVenueOwnerDraftState()
        isVenueOwnerLoggedIn = false
        venueOwnerMode = false
        isLoggedIn = false
        Task {
            await persistAccountModeForActiveAuthSession(.fanUser)
        }
    }

    func adminDashboardLoginTapped() {
        isAdminLoggedIn = true
        Task {
            await persistAccountModeForActiveAuthSession(.admin)
        }
    }

    func adminDashboardLogoutTapped() {
        isAdminLoggedIn = false
        Task {
            await persistAccountModeForActiveAuthSession(.fanUser)
        }
    }

    private static let userProfileSelectColumns = "id,email,display_name,avatar_url,avatar_thumbnail_url,admin_status"

    private static func logPostgrestError(_ prefix: String, _ error: Error) {
        print("\(prefix):", error)
        if let pe = error as? PostgrestError {
            print(
                "\(prefix) PostgrestError code=\(pe.code ?? "nil") message=\(pe.message) detail=\(pe.detail ?? "nil") hint=\(pe.hint ?? "nil")"
            )
        }
        let ns = error as NSError
        print("\(prefix) NSError domain=\(ns.domain) code=\(ns.code) userInfo=\(ns.userInfo)")
    }

    /// Ensures `public.user_profiles` has a row with `id == auth.uid`; inserts a minimal row if missing. Does not use email as PK or random UUIDs.
    func ensureUserProfileExists() async {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return
        }

        let authId = session.user.id
#if DEBUG
        print("[ProfileBootstrap] auth uid = \(authId)")
#endif

        do {
            let existing: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,display_name,avatar_url,avatar_thumbnail_url")
                .eq("id", value: authId)
                .limit(1)
                .execute()
                .value

            if existing.first != nil {
#if DEBUG
                print("[ProfileBootstrap] profile found")
#endif
                await MainActor.run { currentUserAuthId = authId }
                return
            }
        } catch {
            Self.logPostgrestError("[ProfileBootstrap] error querying user_profiles by id", error)
            return
        }

#if DEBUG
        print("[ProfileBootstrap] profile missing -> creating")
#endif

        let emailFromSession = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let emailForRow: String
        if !emailFromSession.isEmpty {
            emailForRow = emailFromSession
        } else {
            let fallback = await MainActor.run {
                OwnerBusinessEmail.normalized(currentUserEmail)
            }
            guard !fallback.isEmpty else {
#if DEBUG
                print("[ProfileBootstrap] cannot insert user_profiles: no email on session or in memory")
#endif
                return
            }
            emailForRow = fallback
        }

        let row = UserProfileBootstrapInsert(
            id: authId,
            email: emailForRow,
            display_name: "",
            avatar_url: "",
            avatar_thumbnail_url: nil
        )

        do {
            try await supabase
                .from("user_profiles")
                .insert(row)
                .execute()
#if DEBUG
            print("[ProfileBootstrap] profile created successfully")
#endif
            await MainActor.run { currentUserAuthId = authId }
        } catch {
            Self.logPostgrestError("[ProfileBootstrap] insert failed", error)
            if let pe = error as? PostgrestError, pe.code == "23505" {
#if DEBUG
                print("[ProfileBootstrap] profile already exists (unique violation); continuing")
#endif
                await MainActor.run { currentUserAuthId = authId }
            }
        }
    }

    func bumpCurrentUserAvatarDisplayRefresh() {
        currentUserAvatarDisplayRefreshToken = UUID()
    }

    /// Public URLs for a full-size avatar and its list thumbnail (see ``ImageCompression/UploadPreset-swift.enum.avatarThumbnail``).
    struct UploadedAvatarURLs: Sendable {
        let fullURL: String
        let thumbnailURL: String
    }

    private static func companionAvatarThumbnailFileName(for fullFileName: String) -> String {
        if let dot = fullFileName.lastIndex(of: "."), dot < fullFileName.endIndex {
            let base = String(fullFileName[..<dot])
            let ext = String(fullFileName[fullFileName.index(after: dot)...])
            return "\(base)_thumb.\(ext)"
        }
        return fullFileName + "_thumb.jpg"
    }

    func registerUser(email: String, password: String, recordFanGuidelinesAcceptance: Bool = false) async {
        let fanEmail = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(fanEmail) else {
            await MainActor.run { authErrorMessage = OwnerBusinessEmail.invalidOwnerEmailUserMessage }
            return
        }

        do {
            _ = try await supabase.auth.signUp(
                email: fanEmail,
                password: password
            )

            await MainActor.run {
                clearAuthenticatedSessionCaches()
                currentUserEmail = fanEmail
                currentUserDisplayName = ""
                currentUserAvatarURL = ""
                currentUserAvatarThumbnailURL = ""

                isLoggedIn = true
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                bumpCurrentUserAvatarDisplayRefresh()
            }
            if let session = try? await supabase.auth.session {
                await MainActor.run { currentUserAuthId = session.user.id }
            }

            await persistAccountModeForActiveAuthSession(.fanUser)

            if (try? await supabase.auth.session) != nil {
                clearExplicitLogoutMarkerAfterManualAuthSucceeded()
            }

            if recordFanGuidelinesAcceptance {
                UserDefaults.standard.set(true, forKey: "fanGuidelinesAccepted")
            }

            Task { await refreshUserPersonalizationInBackground() }
        } catch {
            print("User registration failed:", error)
        }
    }

    func loginUser(email: String, password: String) async {
        let fanEmail = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(fanEmail) else {
            await MainActor.run { authErrorMessage = OwnerBusinessEmail.invalidOwnerEmailUserMessage }
            return
        }

        do {
            _ = try await supabase.auth.signIn(
                email: fanEmail,
                password: password
            )

            if !(await checkCurrentUserAdminStatus()) {
                return
            }

            await MainActor.run {
                clearAuthenticatedSessionCaches()
                currentUserEmail = fanEmail
                currentUserDisplayName = ""
                currentUserAvatarURL = ""
                currentUserAvatarThumbnailURL = ""

                isLoggedIn = true
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false

                authErrorMessage = ""
                bumpCurrentUserAvatarDisplayRefresh()
            }

            if let session = try? await supabase.auth.session {
                await MainActor.run { currentUserAuthId = session.user.id }
            }

            await persistAccountModeForActiveAuthSession(.fanUser)

            clearExplicitLogoutMarkerAfterManualAuthSucceeded()

            Task { await refreshUserPersonalizationInBackground() }
        } catch {
            await MainActor.run {
                isLoggedIn = false
                currentUserAuthId = nil

                let message = error.localizedDescription.lowercased()

                if message.contains("invalid login credentials") {
                    authErrorMessage = "No account found or incorrect password."
                } else {
                    authErrorMessage = "Unable to login."
                }
            }

            print("LOGIN ERROR:", error)
        }
    }

    /// Verifies the signed-in fan profile has not been disabled by an admin.
    /// Returns `false` after signing out and clearing local state when `admin_status == disabled`.
    @discardableResult
    func checkCurrentUserAdminStatus() async -> Bool {
        guard let session = try? await supabase.auth.session else { return true }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: session.user.id)
                .limit(1)
                .execute()
                .value

            if rows.first?.admin_status == "disabled" {
                await handleDisabledCurrentUser()
                return false
            }

            return true
        } catch {
            print("ERROR CHECKING USER ADMIN STATUS:", error)
            return true
        }
    }

    private func handleDisabledCurrentUser() async {
        do {
            try await supabase.auth.signOut()
        } catch {
            print("DISABLED USER SIGNOUT FAILED:", error)
        }

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            clearVenueOwnerDraftState()
            isLoggedIn = false
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            authErrorMessage = "This account has been disabled by FanGeo support."
        }

        clearPersistedAccountMode()
    }

    func logoutUser() async {
#if DEBUG
        print("[Auth] logout requested")
#endif

        do {
            try await supabase.auth.signOut()
#if DEBUG
            print("[Auth] Supabase signOut completed")
#endif
        } catch {
            print("Logout failed:", error)
#if DEBUG
            print("[Auth] Supabase signOut failed (continuing local teardown): \(error.localizedDescription)")
#endif
        }

        await stopVenueOwnerAnalyticsRealtime()
        await removeAllVenueEventCommentsRealtimeListeners()

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            clearVenueOwnerDraftState()
            isLoggedIn = false
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isAdminLoggedIn = false
        }

        clearPersistedAccountMode()
        UserDefaults.standard.set(true, forKey: Self.didExplicitlyLogoutKey)

#if DEBUG
        print("[Auth] local auth state cleared")
        print("[Auth] explicit logout marker set")
#endif
    }

    func hasValidSession() async -> Bool {
        if UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) {
            return false
        }

        do {
            _ = try await supabase.auth.session
            return true
        } catch {
            return false
        }
    }

    /// Strict-normalized email from the active Supabase session (same key used by ``favorite_venues`` / ``venue_event_interests``).
    func strictNormalizedSessionEmailForSocialTables() async -> String? {
        guard let session = try? await supabase.auth.session else { return nil }
        let e = OwnerBusinessEmail.normalized(session.user.email ?? "")
        guard OwnerBusinessEmail.isValidStrict(e) else { return nil }
        return e
    }

    private func applyFanUserSessionRestoreAfterBootstrap(
        session: Session,
        sessionEmail: String,
        clearVenueOwnerCaches: Bool
    ) async {
        await MainActor.run {
            currentUserDisplayName = UserDefaults.standard.string(forKey: "cachedUserDisplayName") ?? ""
            currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarURL"))
            currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL"))
            currentUserEmail = sessionEmail
            isLoggedIn = !sessionEmail.isEmpty
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            venueOwnerEmail = ""
            isAdminLoggedIn = false
            currentUserAuthId = session.user.id
            if clearVenueOwnerCaches {
                clearVenueOwnerOwnedBusinessCaches()
                ownerVenueDatabaseId = nil
            }
        }
#if DEBUG
        print("[AuthRestore] restoredFanUser email=\(sessionEmail)")
#endif
    }

    /// Reads Supabase session and applies cached profile URLs from `UserDefaults` only. Does **not** load profile, favorites, or following (see ``refreshUserPersonalizationInBackground()``).
    func bootstrapAuthSessionOnly() async {
        if UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) {
#if DEBUG
            print("[Auth] startup session restore skipped due to explicit logout")
#endif
            do {
                try await supabase.auth.signOut()
            } catch {
#if DEBUG
                print("[Auth] signOut during explicit-logout bootstrap failed: \(error.localizedDescription)")
#endif
            }

            await stopVenueOwnerAnalyticsRealtime()
            await removeAllVenueEventCommentsRealtimeListeners()

            await MainActor.run {
                clearAuthenticatedSessionCaches()
                clearVenueOwnerDraftState()
                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                isAdminLoggedIn = false
            }
            clearPersistedAccountMode()
            return
        }

        do {
            let session = try await supabase.auth.session
            let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
            let sessionUid = session.user.id.uuidString.lowercased()
            logBusinessOwnerSessionFlags(context: "bootstrap_session_loaded")

            if !(await checkCurrentUserAdminStatus()) {
                print("SESSION RESTORE BLOCKED: disabled account")
                return
            }

            let persisted = readPersistedAccountMode()
#if DEBUG
            print("[AuthRestore] storedAccountMode=\(persisted.mode.rawValue)")
#endif
            let storedId = persisted.authUserId?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            let idMismatch = !storedId.isEmpty && storedId != sessionUid

            if idMismatch {
#if DEBUG
                print("[AuthRestore] auth uid mismatch session=\(sessionUid) stored=\(storedId) -> fan restore")
#endif
                await MainActor.run {
                    clearCurrentUserProfileLocalCache()
                }
                await persistAccountModeForActiveAuthSession(.fanUser)
                await applyFanUserSessionRestoreAfterBootstrap(
                    session: session,
                    sessionEmail: sessionEmail,
                    clearVenueOwnerCaches: true
                )
                print("SESSION RESTORED:", sessionEmail)
                return
            }

            switch persisted.mode {
            case .admin:
#if DEBUG
                print("[AuthRestore] restoredAdmin (local admin UI)")
#endif
                await MainActor.run {
                    isAdminLoggedIn = true
                    isLoggedIn = false
                    isVenueOwnerLoggedIn = false
                    venueOwnerMode = false
                    venueOwnerEmail = ""
                    currentUserEmail = ""
                    currentUserDisplayName = UserDefaults.standard.string(forKey: "cachedUserDisplayName") ?? ""
                    currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarURL"))
                    currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL"))
                    currentUserAuthId = session.user.id
                    clearVenueOwnerOwnedBusinessCaches()
                    ownerVenueDatabaseId = nil
                }
                print("SESSION RESTORED:", sessionEmail)
                return

            case .businessOwner:
                guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
#if DEBUG
                    print("[AuthRestore] businessOwner restore missing_or_invalid session email -> fan")
#endif
                    await persistAccountModeForActiveAuthSession(.fanUser)
                    await applyFanUserSessionRestoreAfterBootstrap(
                        session: session,
                        sessionEmail: sessionEmail,
                        clearVenueOwnerCaches: true
                    )
                    print("SESSION RESTORED:", sessionEmail)
                    return
                }
#if DEBUG
                print("[AuthRestore] restoredBusinessOwner email=\(sessionEmail)")
#endif
                _ = await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                    session: session,
                    sessionEmail: sessionEmail,
                    context: "bootstrap_restore_business_owner"
                )
                print("SESSION RESTORED:", sessionEmail)
                return

            case .fanUser:
                if await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                    session: session,
                    sessionEmail: sessionEmail,
                    context: "bootstrap_restore_business_owner_fallback"
                ) {
                    print("SESSION RESTORED:", sessionEmail)
                    return
                }
                await applyFanUserSessionRestoreAfterBootstrap(
                    session: session,
                    sessionEmail: sessionEmail,
                    clearVenueOwnerCaches: false
                )
                logBusinessOwnerSessionFlags(context: "bootstrap_restore_fan_user")
                print("SESSION RESTORED:", sessionEmail)
                return
            }

        } catch {
            await MainActor.run {
                clearAuthenticatedSessionCaches()
                clearVenueOwnerDraftState()
                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                isAdminLoggedIn = false
            }
            clearPersistedAccountMode()
            print("NO ACTIVE SESSION")
        }
    }

    /// Profile bootstrap, fan profile row, favorites, and Following-tab caches. Runs after Discover core so map/calendar are not blocked.
    func refreshUserPersonalizationInBackground() async {
        let t0 = Date()
        do {
            _ = try await supabase.auth.session
        } catch {
            await MainActor.run {
                clearAuthenticatedSessionCaches()
                clearVenueOwnerDraftState()
                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                isAdminLoggedIn = false
            }
            clearPersistedAccountMode()
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization loaded ms=\(ms) (no session)")
            #endif
            return
        }

        guard await checkCurrentUserAdminStatus() else {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization blocked ms=\(ms) (disabled account)")
            #endif
            return
        }

        let skipPersonalization = await MainActor.run {
            isAdminLoggedIn
        }
        if skipPersonalization {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization skipped ms=\(ms) (admin)")
            #endif
            return
        }

        await ensureUserProfileExists()
        await loadUserProfile()
        await loadFavoriteVenuesFromSupabase()
        await refreshFollowingTabDataGlobally()

        #if DEBUG
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        print("[Background] personalization loaded ms=\(ms)")
        #endif
    }

    // Called on app launch when something needs the legacy “await everything” behavior: session + personalization in sequence.
    func restoreSession() async {
        await bootstrapAuthSessionOnly()
        guard await checkCurrentUserAdminStatus() else { return }
        await refreshUserPersonalizationInBackground()
    }

    // Fetches the row for the current user by `auth.uid` when a session exists; otherwise falls back to email (e.g. venue-owner context without fan session).
    func loadUserProfile() async {
        if let session = try? await supabase.auth.session {
            guard await checkCurrentUserAdminStatus() else { return }

            let authId = session.user.id
            do {
                let rows: [UserProfileRow] = try await supabase
                    .from("user_profiles")
                    .select(Self.userProfileSelectColumns)
                    .eq("id", value: authId)
                    .limit(1)
                    .execute()
                    .value

                if let profile = rows.first {
                    await MainActor.run {
                        if let em = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines), !em.isEmpty {
                            currentUserEmail = em
                        }
                        currentUserDisplayName = profile.display_name ?? ""
                        currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_url)
                        currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_thumbnail_url)
                        currentUserAuthId = authId
                        cacheCurrentUserProfileLocally()
                    }

                    print("USER PROFILE LOADED")
                } else {
                    await MainActor.run {
                        currentUserDisplayName = ""
                        currentUserAvatarURL = ""
                        currentUserAvatarThumbnailURL = ""
                    }

                    print("NO USER PROFILE FOUND")
                }

            } catch {
                print("ERROR LOADING USER PROFILE:", error)
            }
            return
        }

        let email = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail

        guard !email.isEmpty else {
            print("NO USER EMAIL FOR PROFILE LOAD")
            return
        }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("email", value: email)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value

            if let profile = rows.first {
                await MainActor.run {
                    currentUserDisplayName = profile.display_name ?? ""
                    currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_url)
                    currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_thumbnail_url)
                    cacheCurrentUserProfileLocally()
                }

                print("USER PROFILE LOADED")
            } else {
                await MainActor.run {
                    currentUserDisplayName = ""
                    currentUserAvatarURL = ""
                    currentUserAvatarThumbnailURL = ""
                }

                print("NO USER PROFILE FOUND")
            }

        } catch {
            print("ERROR LOADING USER PROFILE:", error)
        }
    }

    /// Upserts `user_profiles` keyed by authenticated user id. Returns `nil` on success, or a user-visible error string.
    @discardableResult
    func saveUserProfile(displayName: String, avatarURL: String, avatarThumbnailURL: String? = nil) async -> String? {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
#if DEBUG
            print("[ProfileSave] no authenticated session; skipping user_profiles upsert")
#endif
            return "You need to be signed in to save your profile."
        }

        let authId = session.user.id
        let emailFromSession = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let emailForRow: String
        if !emailFromSession.isEmpty {
            emailForRow = emailFromSession
        } else {
            let fallback = OwnerBusinessEmail.normalized(currentUserEmail)
            guard !fallback.isEmpty else {
#if DEBUG
                print("[ProfileSave] auth user id = \(authId)")
                print("[ProfileSave] profile upsert id = \(authId)")
                print("[ProfileSave] current email = (empty — cannot upsert user_profiles without email)")
#endif
                return "You need to be signed in to save your profile."
            }
            emailForRow = fallback
        }

#if DEBUG
        print("[ProfileSave] auth user id = \(authId)")
        print("[ProfileSave] profile upsert id = \(authId)")
        print("[ProfileSave] current email = \(emailForRow)")
#endif

        if let cached = currentUserAuthId, cached != authId {
#if DEBUG
            print("[ProfileSave] warning: currentUserAuthId \(cached) differs from session \(authId); using session id")
#endif
        }
        await MainActor.run { currentUserAuthId = authId }

        if Self.normalizedDisplayNameForUniqueness(displayName) != nil {
            struct RpcParams: Encodable {
                let p_display_name: String
                let p_exclude_user_id: UUID
            }
            do {
                let available: Bool = try await supabase
                    .rpc(
                        "check_display_name_normalized_available",
                        params: RpcParams(p_display_name: displayName, p_exclude_user_id: authId)
                    )
                    .execute()
                    .value
                if available == false {
                    return "This avatar name is already taken. Please choose another."
                }
            } catch {
#if DEBUG
                print("[ProfileSave] display name availability RPC failed:", error)
#endif
                return "Could not verify whether this name is available. Please try again."
            }
        }

        do {
            let canonFull = ImageDisplayURL.canonicalStorageURLString(avatarURL)

            let resolvedThumb: String? = {
                if let t = avatarThumbnailURL {
                    let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !x.isEmpty else { return nil }
                    let c = ImageDisplayURL.canonicalStorageURLString(x)
                    return c.isEmpty ? nil : c
                }
                let x = currentUserAvatarThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !x.isEmpty else { return nil }
                let c = ImageDisplayURL.canonicalStorageURLString(x)
                return c.isEmpty ? nil : c
            }()

            let profile = UserProfileInsert(
                id: authId,
                email: emailForRow,
                display_name: displayName,
                avatar_url: canonFull,
                avatar_thumbnail_url: resolvedThumb
            )

            try await supabase
                .from("user_profiles")
                .upsert(profile, onConflict: "id")
                .execute()

            await MainActor.run {
                if currentUserEmail != emailForRow {
                    currentUserEmail = emailForRow
                }
                currentUserDisplayName = displayName
                currentUserAvatarURL = canonFull
                currentUserAvatarThumbnailURL = resolvedThumb ?? ""
                cacheCurrentUserProfileLocally()
                bumpCurrentUserAvatarDisplayRefresh()
            }

            print("USER PROFILE SAVED")
            return nil

        } catch {
            print("ERROR SAVING USER PROFILE:", error)
            if Self.isDuplicateDisplayNameConstraintViolation(error) {
                return "This avatar name is already taken. Please choose another."
            }
            return "Couldn’t save your profile. Please try again."
        }
    }

    /// Same normalization as ``display_name_normalized`` in Postgres: `lower(trim)`; empty → unavailable for uniqueness checks.
    private static func normalizedDisplayNameForUniqueness(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return s.isEmpty ? nil : s
    }

    private static func isDuplicateDisplayNameConstraintViolation(_ error: Error) -> Bool {
        let d = error.localizedDescription.lowercased()
        let isDup = d.contains("23505") || d.contains("duplicate key")
        guard isDup else { return false }
        return d.contains("display_name_normalized")
            || d.contains("uq_user_profiles_display_name_normalized")
            || d.contains("avatar_name_normalized")
            || d.contains("uq_user_profiles_avatar_name_normalized")
    }

    /// Uploads full + thumbnail JPEGs to `user-avatars` under `{auth_user_uuid}/` (RLS: first path segment must equal `auth.uid()`).
    func uploadUserAvatar(data: Data, fileName: String) async -> UploadedAvatarURLs? {
        do {
            let session = try await supabase.auth.session
            let authUserId = session.user.id
#if DEBUG
            print("[ProfileSave] auth user id = \(authUserId) (avatar storage path prefix)")
#endif
            let folder = authUserId.uuidString.lowercased()

            let normalizedFileName = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedFileName.isEmpty else {
                print("INVALID AVATAR FILE NAME")
                return nil
            }

            let pathFull = "\(folder)/\(normalizedFileName)"
            let thumbName = Self.companionAvatarThumbnailFileName(for: normalizedFileName)
            let pathThumb = "\(folder)/\(thumbName)"

            let oldFull = ImageDisplayURL.canonicalStorageURLString(currentUserAvatarURL)
            let oldThumb = ImageDisplayURL.canonicalStorageURLString(currentUserAvatarThumbnailURL)

            let uploadFull = ImageCompression.jpegDataForUpload(from: data, preset: .avatar)
            let uploadThumb = ImageCompression.jpegDataForUpload(from: data, preset: .avatarThumbnail)

            try await supabase.storage
                .from("user-avatars")
                .upload(
                    pathFull,
                    data: uploadFull,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )

            try await supabase.storage
                .from("user-avatars")
                .upload(
                    pathThumb,
                    data: uploadThumb,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )

            let publicFull = try supabase.storage
                .from("user-avatars")
                .getPublicURL(path: pathFull)
            let publicThumb = try supabase.storage
                .from("user-avatars")
                .getPublicURL(path: pathThumb)

            let fullStr = ImageDisplayURL.canonicalStorageURLString(publicFull.absoluteString)
            let thumbStr = ImageDisplayURL.canonicalStorageURLString(publicThumb.absoluteString)

            await deleteReplacedStorageObjectIfNeeded(oldPublicURL: oldFull.isEmpty ? nil : oldFull, newPublicURL: fullStr, bucket: "user-avatars")
            await deleteReplacedStorageObjectIfNeeded(oldPublicURL: oldThumb.isEmpty ? nil : oldThumb, newPublicURL: thumbStr, bucket: "user-avatars")

            return UploadedAvatarURLs(fullURL: fullStr, thumbnailURL: thumbStr)

        } catch {
            print("ERROR UPLOADING USER AVATAR:", error)
            print("hint: Require a signed-in Supabase session with a user id; path must be user-avatars/{auth.uid}/… and Storage RLS must allow that folder.")
            return nil
        }
    }

    // Batch-loads display names/avatars for a set of emails (e.g. “who’s going”) into `userProfilesByEmail`.
    func loadUserProfilesForEmails(_ emails: [String]) async {
        let uniqueEmails = Array(Set(emails)).filter { !$0.isEmpty }

        guard !uniqueEmails.isEmpty else { return }

        do {
            let rows = try await SocialIdentityService().fetchUserProfileRows(forEmails: uniqueEmails)

            await MainActor.run {
                for profile in rows {
                    if let email = profile.email {
                        userProfilesByEmail[email] = profile
                    }
                }
            }

        } catch {
            print("ERROR LOADING USER PROFILES FOR EMAILS:", error)
        }
    }

    func cacheCurrentUserProfileLocally() {
        UserDefaults.standard.set(currentUserDisplayName, forKey: "cachedUserDisplayName")
        UserDefaults.standard.set(currentUserAvatarURL, forKey: "cachedUserAvatarURL")
        UserDefaults.standard.set(currentUserAvatarThumbnailURL, forKey: "cachedUserAvatarThumbnailURL")
    }

    enum PasswordResetAccountKind {
        case fan
        case venueOwner
    }

    /// Sends Supabase Auth password recovery email; routes feedback to fan vs venue-owner UI strings on ``MapViewModel``.
    func sendPasswordResetEmail(_ email: String, accountKind: PasswordResetAccountKind) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetError = "Enter an email address."
                    userPasswordResetMessage = ""
                case .venueOwner:
                    venuePasswordResetError = "Enter an email address."
                    venuePasswordResetMessage = ""
                }
            }
            return
        }

        do {
            try await supabase.auth.resetPasswordForEmail(trimmed)
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetMessage = "Check your email for a reset link."
                    userPasswordResetError = ""
                case .venueOwner:
                    venuePasswordResetMessage = "Check your email for a reset link."
                    venuePasswordResetError = ""
                }
            }
        } catch {
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetMessage = ""
                    userPasswordResetError = error.localizedDescription
                case .venueOwner:
                    venuePasswordResetMessage = ""
                    venuePasswordResetError = error.localizedDescription
                }
            }
        }
    }
}
