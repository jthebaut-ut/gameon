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

    private func hasActiveBusinessAccount(ownerEmail: String, ownerUserId: UUID?) async -> Bool {
        let normalized = OwnerBusinessEmail.normalized(ownerEmail)
        guard OwnerBusinessEmail.isValidStrict(normalized) else { return false }

        if ownedBusinesses.contains(where: {
            OwnerBusinessEmail.normalized($0.owner_email ?? "") == normalized && $0.admin_status == "active"
        }) {
            return true
        }
        if let ownerUserId,
           ownedBusinesses.contains(where: { $0.owner_user_id == ownerUserId && $0.admin_status == "active" }) {
            return true
        }

        struct BusinessExistenceRow: Decodable {
            let id: UUID
        }

        do {
            let byEmail: [BusinessExistenceRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_email", value: normalized)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value
            if !byEmail.isEmpty { return true }

            if let ownerUserId {
                let byUser: [BusinessExistenceRow] = try await supabase
                    .from("businesses")
                    .select("id")
                    .eq("owner_user_id", value: ownerUserId)
                    .eq("admin_status", value: "active")
                    .limit(1)
                    .execute()
                    .value
                if !byUser.isEmpty { return true }
            }
            return false
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

        guard await hasActiveBusinessAccount(ownerEmail: normalizedOwnerEmail, ownerUserId: authId) else {
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
        currentUserBio = ""
        currentUserIsBusinessAccount = true
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true

        await persistAccountModeForActiveAuthSession(.businessOwner)
        restorePersistedSelectedVenueForBusinessLaunch()
        print("[BusinessLaunchPerf] criticalBootstrapMinimal=true")
        Task { [weak self] in
            await self?.runDeferredBusinessOwnerHydrationAfterLaunch()
        }
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

        guard await hasActiveBusinessAccount(ownerEmail: sessionEmail, ownerUserId: session.user.id) else {
            logBusinessOwnerSessionFlags(context: "\(context)_no_business_account")
            return false
        }

        venueOwnerEmail = sessionEmail
        isVenueOwnerLoggedIn = true
        venueOwnerMode = true
        isLoggedIn = false
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserBio = ""
        currentUserIsBusinessAccount = true
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true
        isAdminLoggedIn = false
        currentUserAuthId = session.user.id

        await persistAccountModeForActiveAuthSession(.businessOwner)
        restorePersistedSelectedVenueForBusinessLaunch()
        print("[BusinessLaunchPerf] criticalBootstrapMinimal=true")
        logBusinessOwnerSessionFlags(context: "\(context)_restored")
        return true
    }

    func clearCurrentUserProfileLocalCache() {
        UserDefaults.standard.removeObject(forKey: "cachedUserDisplayName")
        UserDefaults.standard.removeObject(forKey: "cachedUserUsername")
        UserDefaults.standard.removeObject(forKey: "cachedUserBio")
        UserDefaults.standard.removeObject(forKey: "cachedUserAvatarURL")
        UserDefaults.standard.removeObject(forKey: "cachedUserAvatarThumbnailURL")
        UserDefaults.standard.removeObject(forKey: "cachedUserLiveVisibilityEnabled")
        UserDefaults.standard.removeObject(forKey: "cachedUserLiveVisibilityMode")
        UserDefaults.standard.removeObject(forKey: "cachedUserSelectedLiveVisibilityFriendIDs")
        UserDefaults.standard.removeObject(forKey: "cachedUserDiscoverableByFans")
    }

    /// Clears authenticated/private session caches that must never survive logout, session loss, or account switching.
    /// Intentionally does not mutate the high-level signed-in flags; callers clear caches first, then update flags.
    func clearAuthenticatedSessionCaches() {
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserUsername = ""
        currentUserBio = ""
        currentUserIsBusinessAccount = false
        currentUserFanXP = .rookie
        currentUserFanIdentityPreferences = .empty
        currentUserHomeCrowdVenueId = nil
        currentUserHomeCrowdVenue = nil
        discoverFocusVenueId = nil
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true
        isUpdatingLiveVisibilitySetting = false
        isUpdatingProfileDiscoverabilitySetting = false
        currentUserAuthId = nil
        clearUnseenPokesBadgeState()

        favoriteVenueIDs = []
        interestedVenueEventKeys = []
        favoriteVenueWriteInFlightIDs = []
        venueEventInterestWriteInFlightIDs = []
        recentlyConfirmedVenueEventGoingAt = [:]
        recentlyConfirmedVenueEventNotGoingAt = [:]
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
        // Keep public pickup pins on Discover after sign-out; refresh will reconcile from Supabase.
        markPickupDiscoverMapDataDirtyForNextRefresh()
        selectedPickupGameForMap = nil
        myPickupGamesForSettings = []
        myRemovedPickupGamesForSettings = []
        pickupOrganizerJoinStatsByGameId = [:]
        pickupOrganizerWithdrawnRequestsByGameId = [:]
        pickupOrganizerApprovedJoinerUserIdsByGameId = [:]
        pendingPickupGameJoinRequestCount = 0
        myPickupGameJoinRequestCards = []
        pickupGamesFollowingTabCache.removeAll()
        pickupJoinRequestLatestByPickupGameIdForFan.removeAll()
        pickupCreatorPublicRatingStatsByUserId = [:]
        pickupGameIdsWithMyCreatorRating = []
        pickupMyLatestJoinRequestByGameId = [:]
        pickupCreatorDisplayNameByUserId = [:]
        pickupCreatorAvatarThumbnailURLByUserId = [:]
        pickupCreatorAvatarURLByUserId = [:]
        pickupCreatorEmailByUserId = [:]
        pickupCreatorAvatarTokenByUserId = [:]
        commentIDsReportedByCurrentUser = []
        userProfilesByEmail = [:]
        myVenueEventVibes = [:]
        venueEventVibeWriteInFlightKeys = []
        venueUserStarRatings = [:]
        venueRatingContributionCount = [:]
        Task { [weak self] in
            await self?.removeAllVenueEventCommentsRealtimeListeners()
            await self?.stopPickupJoinRequestBadgeRealtime()
            await self?.stopFollowingPickupRealtime()
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
        discoverCalendarGuestUserPinnedDateThisSession = false
        privateSessionClearNonce = UUID()
    }

    /// Sign-out/session-loss cleanup for venue-owner drafts and claim context in addition to the shared cache reset.
    func clearVenueOwnerDraftState() {
        clearPendingVenueClaimContext()
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

    private static let userProfileSelectColumns =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_business_account,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids,discoverable_by_fans"

    private static let userProfileIdentitySelectColumns =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url"

    private struct UserProfileIdentityRow: Decodable {
        let id: UUID?
        let email: String?
        let display_name: String?
        let username: String?
        let bio: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
    }

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

    private static func liveVisibilityErrorText(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [
            error.localizedDescription,
            ns.domain,
            "\(ns.code)"
        ]
        if let pe = error as? PostgrestError {
            parts.append(pe.code ?? "")
            parts.append(pe.message)
            parts.append(pe.detail ?? "")
            parts.append(pe.hint ?? "")
        }
        return parts.joined(separator: " ").lowercased()
    }

    private static func isMissingLiveVisibilityAudienceColumnsError(_ error: Error) -> Bool {
        let text = liveVisibilityErrorText(error)
        let mentionsColumn = text.contains("live_visibility_mode")
            || text.contains("selected_live_visibility_friend_ids")
        return mentionsColumn
            && (
                text.contains("column")
                || text.contains("schema cache")
                || text.contains("pgrst204")
                || text.contains("not find")
                || text.contains("does not exist")
            )
    }

    private static func isMissingLiveVisibilityEnabledColumnError(_ error: Error) -> Bool {
        let text = liveVisibilityErrorText(error)
        return text.contains("live_visibility_enabled")
            && (
                text.contains("column")
                || text.contains("schema cache")
                || text.contains("pgrst204")
                || text.contains("not find")
                || text.contains("does not exist")
            )
    }

    private static func trimmedNonEmpty(_ raw: String?) -> String {
        raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func emailLocalDisplayFallback(for email: String) -> String {
        let local = OwnerBusinessEmail.normalized(email)
            .split(separator: "@")
            .first
            .map(String.init) ?? ""
        guard !local.isEmpty else { return "" }
        return local.prefix(1).uppercased() + local.dropFirst()
    }

    private static func isEmailFallbackDisplayName(_ displayName: String, email: String) -> Bool {
        let candidate = displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !candidate.isEmpty else { return false }
        let normalizedEmail = OwnerBusinessEmail.normalized(email)
        let local = normalizedEmail.split(separator: "@").first.map(String.init)?.lowercased() ?? ""
        guard !local.isEmpty else { return false }
        return candidate == local || candidate == emailLocalDisplayFallback(for: normalizedEmail).lowercased()
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
        print("[ProfilePersistenceDebug] loadingProfileForUserId=\(authId.uuidString.lowercased())")
#endif

        do {
            let existing: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: authId)
                .limit(1)
                .execute()
                .value

            if existing.first != nil {
#if DEBUG
                print("[ProfileBootstrap] profile found")
                print("[ProfilePersistenceDebug] existingProfileFound=true")
#endif
                await MainActor.run { currentUserAuthId = authId }
                return
            }
#if DEBUG
            print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
        } catch {
#if DEBUG
            print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
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
            bio: nil,
            avatar_url: "",
            avatar_thumbnail_url: nil,
            live_visibility_enabled: true,
            live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
            selected_live_visibility_friend_ids: [],
            discoverable_by_fans: true
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

        if await businessAccountExistsForOwnerEmailOnly(fanEmail) {
#if DEBUG
            print("[AuthAccountTypeGate] fan registration blocked businessEmail=\(fanEmail)")
#endif
            await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
            return
        }

        do {
            _ = try await supabase.auth.signUp(
                email: fanEmail,
                password: password
            )

            if let session = try? await supabase.auth.session,
               await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: session.user.id) {
#if DEBUG
                print("[AuthAccountTypeGate] fan registration blocked businessEmail=\(fanEmail)")
#endif
                await undoPartialSupabaseSessionAfterAccountTypeMismatch()
                await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
                return
            }

            await MainActor.run {
                clearAuthenticatedSessionCaches()
                currentUserEmail = fanEmail
                currentUserDisplayName = ""
                currentUserUsername = ""
                currentUserBio = ""
                currentUserIsBusinessAccount = false
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

            await registerFanActiveSessionOnLogin()

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

            guard let session = try? await supabase.auth.session else {
                try? await supabase.auth.signOut()
                await MainActor.run {
                    isLoggedIn = false
                    currentUserAuthId = nil
                    authErrorMessage = "Unable to login."
                }
                return
            }

            if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: session.user.id) {
#if DEBUG
                print("[AuthAccountTypeGate] fan login blocked businessEmail=\(fanEmail)")
#endif
                await undoPartialSupabaseSessionAfterAccountTypeMismatch()
                await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
                return
            }

            if !(await checkCurrentUserAdminStatus()) {
                return
            }

            await MainActor.run {
                clearAuthenticatedSessionCaches()
                currentUserEmail = fanEmail
                currentUserDisplayName = ""
                currentUserUsername = ""
                currentUserBio = ""
                currentUserIsBusinessAccount = false
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

            await registerFanActiveSessionOnLogin()
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
        await clearFanActiveSessionOnLogout()

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
    /// Falls back to ``currentUserEmail`` when the JWT omits `user.email` (mirrors profile bootstrap / save), but **not** for an active business-owner session.
    func strictNormalizedSessionEmailForSocialTables() async -> String? {
        guard let session = try? await supabase.auth.session else { return nil }
        let fromSession = OwnerBusinessEmail.normalized(session.user.email ?? "")
        if OwnerBusinessEmail.isValidStrict(fromSession) {
            return fromSession
        }
        guard !hasAuthenticatedVenueOwnerSession else { return nil }
        let fallback = OwnerBusinessEmail.normalized(currentUserEmail)
        guard OwnerBusinessEmail.isValidStrict(fallback) else { return nil }
        return fallback
    }

    private func applyFanUserSessionRestoreAfterBootstrap(
        session: Session,
        sessionEmail: String,
        clearVenueOwnerCaches: Bool
    ) async {
        await MainActor.run {
            currentUserDisplayName = UserDefaults.standard.string(forKey: "cachedUserDisplayName") ?? ""
            currentUserUsername = UserDefaults.standard.string(forKey: "cachedUserUsername") ?? ""
            currentUserBio = UserDefaults.standard.string(forKey: "cachedUserBio") ?? ""
            currentUserIsBusinessAccount = false
            currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarURL"))
            currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL"))
            currentUserLiveVisibilityEnabled = UserDefaults.standard.object(forKey: "cachedUserLiveVisibilityEnabled") as? Bool ?? true
            currentUserLiveVisibilityMode = cachedLiveVisibilityMode()
            currentUserSelectedLiveVisibilityFriendIDs = cachedSelectedLiveVisibilityFriendIDs()
            currentUserDiscoverableByFans = UserDefaults.standard.object(forKey: "cachedUserDiscoverableByFans") as? Bool ?? true
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
            guard let session = try await supabaseResolvedAuthSession() else {
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
                return
            }
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
                    currentUserBio = UserDefaults.standard.string(forKey: "cachedUserBio") ?? ""
                    currentUserIsBusinessAccount = false
                    currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarURL"))
                    currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL"))
                    currentUserLiveVisibilityEnabled = UserDefaults.standard.object(forKey: "cachedUserLiveVisibilityEnabled") as? Bool ?? true
                    currentUserLiveVisibilityMode = cachedLiveVisibilityMode()
                    currentUserSelectedLiveVisibilityFriendIDs = cachedSelectedLiveVisibilityFriendIDs()
                    currentUserDiscoverableByFans = UserDefaults.standard.object(forKey: "cachedUserDiscoverableByFans") as? Bool ?? true
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
                Task {
                    await self.enforceFanSingleSessionOnForeground()
                    await self.startFanSingleSessionRealtimeIfNeeded()
                }
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
            guard try await supabaseResolvedAuthSession() != nil else {
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
        await loadFanIdentityPreferencesFromProfile()
        await loadHomeCrowdFromProfile()
        await refreshProfileXP()
        await loadFavoriteVenuesFromSupabase()
        await loadFavoriteTeamsFromSupabase()
        await enforceFanSingleSessionOnForeground()
        await startFanSingleSessionRealtimeIfNeeded()
        await refreshFollowingTabDataGlobally()
        await loadPendingPickupGameJoinRequestCountForCreator()

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
#if DEBUG
            print("[ProfilePersistenceDebug] loadingProfileForUserId=\(authId.uuidString.lowercased())")
#endif
            do {
                let rows: [UserProfileRow] = try await supabase
                    .from("user_profiles")
                    .select(Self.userProfileSelectColumns)
                    .eq("id", value: authId)
                    .limit(1)
                    .execute()
                    .value

                if let profile = rows.first {
#if DEBUG
                    print("[ProfilePersistenceDebug] existingProfileFound=true")
#endif
                    await MainActor.run {
                        if let em = profile.email?.trimmingCharacters(in: .whitespacesAndNewlines), !em.isEmpty {
                            currentUserEmail = em
                        }
                        currentUserDisplayName = profile.display_name ?? ""
                        currentUserUsername = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        currentUserBio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        currentUserIsBusinessAccount = profile.isBusinessIdentity
                        currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_url)
                        currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_thumbnail_url)
                        currentUserLiveVisibilityEnabled = profile.isVisibleForLiveFriendPresence
                        currentUserLiveVisibilityMode = profile.liveVisibilityMode
                        currentUserSelectedLiveVisibilityFriendIDs = profile.selectedLiveVisibilityFriendIDs
                        currentUserDiscoverableByFans = profile.discoverableByFans
                        currentUserAuthId = authId
                        cacheCurrentUserProfileLocally()
                    }
#if DEBUG
                    print("[ProfileDiscoverabilityDebug] loaded=\(profile.discoverableByFans)")
#endif

                    print("USER PROFILE LOADED")
                } else {
#if DEBUG
                    print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
                    print("NO USER PROFILE FOUND")
                }

            } catch {
#if DEBUG
                print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
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
#if DEBUG
                print("[ProfilePersistenceDebug] existingProfileFound=true")
#endif
                await MainActor.run {
                    currentUserDisplayName = profile.display_name ?? ""
                    currentUserUsername = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    currentUserBio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    currentUserIsBusinessAccount = profile.isBusinessIdentity
                    currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_url)
                    currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_thumbnail_url)
                    currentUserLiveVisibilityEnabled = profile.isVisibleForLiveFriendPresence
                    currentUserLiveVisibilityMode = profile.liveVisibilityMode
                    currentUserSelectedLiveVisibilityFriendIDs = profile.selectedLiveVisibilityFriendIDs
                    currentUserDiscoverableByFans = profile.discoverableByFans
                    cacheCurrentUserProfileLocally()
                }
#if DEBUG
                print("[ProfileDiscoverabilityDebug] loaded=\(profile.discoverableByFans)")
#endif

                print("USER PROFILE LOADED")
            } else {
#if DEBUG
                print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
                print("NO USER PROFILE FOUND")
            }

        } catch {
#if DEBUG
            print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
            print("ERROR LOADING USER PROFILE:", error)
        }
    }

    /// Checks whether a @handle is available for the signed-in user (`check_username_available` RPC).
    func checkUsernameAvailable(_ rawHandle: String) async -> Bool? {
        let stored = FanGeoHandleRules.normalizeForStorage(rawHandle)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")
        guard FanGeoHandleRules.validate(rawHandle) == nil else {
            print("[HandleValidationDebug] handleRejected reason=invalid")
            return false
        }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return nil
        }

        struct RpcParams: Encodable {
            let p_username: String
            let p_exclude_user_id: UUID
        }

        do {
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            let available: Bool = try await supabase
                .rpc(
                    "check_username_available",
                    params: RpcParams(p_username: stored, p_exclude_user_id: session.user.id)
                )
                .execute()
                .value
#if DEBUG
            print("[HandleAvailabilityDebug] handle=\(stored) available=\(available)")
#endif
            print("[HandleValidationDebug] handleAvailable=\(available)")
            return available
        } catch {
#if DEBUG
            print("[HandleAvailabilityDebug] rpc_failed handle=\(stored) error=\(error.localizedDescription)")
#endif
            return nil
        }
    }

    /// Upserts `user_profiles` keyed by authenticated user id. Returns `nil` on success, or a user-visible error string.
    @discardableResult
    func saveUserProfile(
        displayName: String,
        avatarURL: String,
        avatarThumbnailURL: String? = nil,
        username: String? = nil,
        bio: String? = nil
    ) async -> String? {
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
        print("[ProfilePersistenceDebug] loadingProfileForUserId=\(authId.uuidString.lowercased())")
#endif

        if let cached = currentUserAuthId, cached != authId {
#if DEBUG
            print("[ProfileSave] warning: currentUserAuthId \(cached) differs from session \(authId); using session id")
#endif
        }
        await MainActor.run { currentUserAuthId = authId }

        let existingProfile: UserProfileIdentityRow?
        do {
            let rows: [UserProfileIdentityRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileIdentitySelectColumns)
                .eq("id", value: authId.uuidString.lowercased())
                .limit(1)
                .execute()
                .value
            existingProfile = rows.first
#if DEBUG
            print("[ProfilePersistenceDebug] existingProfileFound=\(existingProfile != nil)")
#endif
        } catch {
#if DEBUG
            print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
            print("[ProfilePersistenceDebug] preventedBlankProfileOverwrite=true reason=existing_profile_unavailable")
#endif
            return "Couldn’t verify your existing profile before saving. Please try again."
        }

        let localDisplayWasBlank = await MainActor.run {
            currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let incomingDisplay = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let existingDisplay = Self.trimmedNonEmpty(existingProfile?.display_name)
        let finalDisplayName: String
        var preventedBlankProfileOverwrite = false
        if !existingDisplay.isEmpty,
           incomingDisplay.isEmpty || (localDisplayWasBlank && Self.isEmailFallbackDisplayName(incomingDisplay, email: emailForRow)) {
            finalDisplayName = existingDisplay
            preventedBlankProfileOverwrite = true
        } else {
            finalDisplayName = displayName
        }

        if let username {
            if let issue = FanGeoHandleRules.validate(username) {
                print("[HandleValidationDebug] handleRejected reason=\(issue)")
                return FanGeoHandleRules.validationMessage(for: issue)
            }
            let stored = FanGeoHandleRules.normalizeForStorage(username)
            print("[HandleValidationDebug] normalizedHandle=\(stored)")
            guard !stored.isEmpty else {
                print("[HandleValidationDebug] handleRejected reason=empty")
                return "Choose a @handle."
            }
            if let available = await checkUsernameAvailable(stored) {
                if !available {
                    print("[HandleValidationDebug] handleRejected reason=already_taken")
                    return "That handle is already taken."
                }
            } else {
                return "Could not verify whether this handle is available. Please try again."
            }
        }

        let usernameToSave: String? = {
            if let username {
                let stored = FanGeoHandleRules.normalizeForStorage(username)
                return stored.isEmpty ? nil : stored
            }
            let existing = currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
            return existing.isEmpty ? nil : FanGeoHandleRules.normalizeForStorage(existing)
        }()

        let finalBioToSave: String? = {
            let candidate: String
            if let bio {
                candidate = bio.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                let current = currentUserBio.trimmingCharacters(in: .whitespacesAndNewlines)
                candidate = current.isEmpty ? Self.trimmedNonEmpty(existingProfile?.bio) : current
            }
            return candidate.isEmpty ? nil : candidate
        }()
        if let finalBioToSave, finalBioToSave.count > 160 {
            return "Bio must be 160 characters or less."
        }

        do {
            let canonFull = ImageDisplayURL.canonicalStorageURLString(avatarURL)
            let existingAvatarURL = ImageDisplayURL.canonicalStorageURLString(existingProfile?.avatar_url)
            let finalAvatarURL: String
            if canonFull.isEmpty, !existingAvatarURL.isEmpty {
                finalAvatarURL = existingAvatarURL
                preventedBlankProfileOverwrite = true
            } else {
                finalAvatarURL = canonFull
            }

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
            let existingAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(existingProfile?.avatar_thumbnail_url)
            let finalAvatarThumbnailURL: String? = {
                let incoming = ImageDisplayURL.canonicalStorageURLString(resolvedThumb)
                if incoming.isEmpty, !existingAvatarThumbnailURL.isEmpty {
                    preventedBlankProfileOverwrite = true
                    return existingAvatarThumbnailURL
                }
                return incoming.isEmpty ? nil : incoming
            }()

            let existingUsername = Self.trimmedNonEmpty(existingProfile?.username)
            let finalUsernameToSave: String?
            if usernameToSave == nil, !existingUsername.isEmpty {
                finalUsernameToSave = FanGeoHandleRules.normalizeForStorage(existingUsername)
                preventedBlankProfileOverwrite = true
            } else {
                finalUsernameToSave = usernameToSave
            }

            let profile = UserProfileInsert(
                id: authId,
                email: emailForRow,
                display_name: finalDisplayName,
                username: finalUsernameToSave,
                bio: finalBioToSave,
                avatar_url: finalAvatarURL,
                avatar_thumbnail_url: finalAvatarThumbnailURL,
                live_visibility_enabled: currentUserLiveVisibilityEnabled,
                live_visibility_mode: currentUserLiveVisibilityMode.rawValue,
                selected_live_visibility_friend_ids: currentUserSelectedLiveVisibilityFriendIDs
                    .sorted { $0.uuidString < $1.uuidString }
                    .map { $0.uuidString.lowercased() },
                discoverable_by_fans: currentUserDiscoverableByFans
            )

#if DEBUG
            print(
                "[ProfilePersistenceDebug] profileUpsertPayload=id=\(authId.uuidString.lowercased()), email=\(emailForRow), displayNameEmpty=\(finalDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), usernameEmpty=\((finalUsernameToSave ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), bioLength=\(finalBioToSave?.count ?? 0), avatarEmpty=\(finalAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty), live_visibility_enabled=\(currentUserLiveVisibilityEnabled), live_visibility_mode=\(currentUserLiveVisibilityMode.rawValue), selectedFriendCount=\(currentUserSelectedLiveVisibilityFriendIDs.count), discoverable_by_fans=\(currentUserDiscoverableByFans)"
            )
            if preventedBlankProfileOverwrite {
                print("[ProfilePersistenceDebug] preventedBlankProfileOverwrite=true")
            }
#endif

            try await supabase
                .from("user_profiles")
                .upsert(profile, onConflict: "id")
                .execute()

            await MainActor.run {
                if currentUserEmail != emailForRow {
                    currentUserEmail = emailForRow
                }
                currentUserDisplayName = finalDisplayName
                if let finalUsernameToSave {
                    currentUserUsername = finalUsernameToSave
                }
                currentUserBio = finalBioToSave ?? ""
                currentUserAvatarURL = finalAvatarURL
                currentUserAvatarThumbnailURL = finalAvatarThumbnailURL ?? ""
                cacheCurrentUserProfileLocally()
                applyCurrentUserBioToProfileCaches(bio: finalBioToSave)
                publicProfileBioRevision &+= 1
                bumpCurrentUserAvatarDisplayRefresh()
            }

#if DEBUG
            print("[ProfileBioDebug] saveBio=\(finalBioToSave ?? "")")
            print("[ProfileBioDebug] savedUserProfilesBio=\(finalBioToSave ?? "")")
#endif
            print("[HandleValidationDebug] profileSaved handle=\(finalUsernameToSave.map { FanGeoHandleRules.displayHandle(stored: $0) } ?? "nil")")
            print("USER PROFILE SAVED")
            return nil

        } catch {
            print("ERROR SAVING USER PROFILE:", error)
            if Self.isDuplicateUsernameConstraintViolation(error) {
                return "That handle is already taken."
            }
            return "Couldn’t save your profile. Please try again."
        }
    }

    func setLiveVisibilityEnabled(_ enabled: Bool) async {
        await setLiveVisibilitySettings(
            enabled: enabled,
            mode: currentUserLiveVisibilityMode,
            selectedFriendIDs: currentUserSelectedLiveVisibilityFriendIDs
        )
    }

    func setProfileDiscoverableByFans(_ discoverable: Bool) async {
        guard canUseFanSocialFeatures else {
            await MainActor.run {
                socialActionToastText = "Profile discoverability is available for fan accounts only."
                socialActionToastIsError = true
            }
            return
        }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            await MainActor.run {
                socialActionToastText = "Sign in to update profile discoverability."
                socialActionToastIsError = true
            }
            return
        }

        let previous = await MainActor.run { currentUserDiscoverableByFans }
        guard previous != discoverable else {
#if DEBUG
            print("[ProfileDiscoverabilityDebug] saved=\(discoverable) skipped=true")
#endif
            return
        }

        await MainActor.run {
            currentUserDiscoverableByFans = discoverable
            isUpdatingProfileDiscoverabilitySetting = true
            cacheCurrentUserProfileLocally()
        }

        do {
            try await supabase
                .from("user_profiles")
                .update(UserProfileDiscoverabilityPatch(discoverable_by_fans: discoverable))
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

#if DEBUG
            print("[ProfileDiscoverabilityDebug] saved=\(discoverable)")
#endif

            await MainActor.run {
                isUpdatingProfileDiscoverabilitySetting = false
            }
        } catch {
#if DEBUG
            Self.logPostgrestError("[ProfileDiscoverabilityDebug] save failed", error)
#endif
            await MainActor.run {
                currentUserDiscoverableByFans = previous
                isUpdatingProfileDiscoverabilitySetting = false
                cacheCurrentUserProfileLocally()
                socialActionToastText = "Couldn’t update profile discoverability. Please try again."
                socialActionToastIsError = true
            }
        }
    }

    func setLiveVisibilityMode(_ mode: LiveVisibilityMode) async {
        await setLiveVisibilitySettings(
            enabled: currentUserLiveVisibilityEnabled,
            mode: mode,
            selectedFriendIDs: currentUserSelectedLiveVisibilityFriendIDs
        )
    }

    func setSelectedLiveVisibilityFriendIDs(_ selectedFriendIDs: Set<UUID>) async {
        await setLiveVisibilitySettings(
            enabled: currentUserLiveVisibilityEnabled,
            mode: currentUserLiveVisibilityMode,
            selectedFriendIDs: selectedFriendIDs
        )
    }

    func setLiveVisibilitySettings(
        enabled: Bool,
        mode: LiveVisibilityMode,
        selectedFriendIDs: Set<UUID>
    ) async {
        guard canUseFanSocialFeatures else {
            await MainActor.run {
                socialActionToastText = "Live friend presence is available for fan accounts only."
                socialActionToastIsError = true
            }
            return
        }

        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            await MainActor.run {
                socialActionToastText = "Sign in to update Live visibility."
                socialActionToastIsError = true
            }
            return
        }

        let selectedIDs = selectedFriendIDs.sorted { $0.uuidString < $1.uuidString }
        let selectedIDStrings = selectedIDs.map { $0.uuidString.lowercased() }
        let payloadDebugDescription = "enabled=\(enabled), mode=\(mode.rawValue), selected_live_visibility_friend_ids=\(selectedIDStrings)"
        let previous = await MainActor.run {
            (
                enabled: currentUserLiveVisibilityEnabled,
                mode: currentUserLiveVisibilityMode,
                selectedFriendIDs: currentUserSelectedLiveVisibilityFriendIDs
            )
        }

        if previous.enabled == enabled,
           previous.mode == mode,
           previous.selectedFriendIDs == Set(selectedIDs) {
#if DEBUG
            print("[LiveVisibilityDebug] no changes; skipping save")
            print("[LiveVisibilityDebug] selectedFriendCount=\(selectedIDs.count)")
#endif
            return
        }

#if DEBUG
        print("[LiveVisibilityDebug] payload=\(payloadDebugDescription)")
        print("[LiveVisibilityDebug] selectedFriendCount=\(selectedIDs.count)")
        print("[ProfilePersistenceDebug] liveVisibilityUpdatePayload=\(payloadDebugDescription)")
#endif

        await MainActor.run {
            currentUserLiveVisibilityEnabled = enabled
            currentUserLiveVisibilityMode = mode
            currentUserSelectedLiveVisibilityFriendIDs = Set(selectedIDs)
            isUpdatingLiveVisibilitySetting = true
            applyCurrentUserLiveVisibilityToProfileCaches(
                enabled: enabled,
                mode: mode,
                selectedFriendIDs: selectedIDs,
                userId: session.user.id
            )
            cacheCurrentUserProfileLocally()
        }

        do {
            let response = try await supabase
                .from("user_profiles")
                .update(
                    UserLiveVisibilityPatch(
                        live_visibility_enabled: enabled,
                        live_visibility_mode: mode.rawValue,
                        selected_live_visibility_friend_ids: selectedIDStrings
                    )
                )
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

#if DEBUG
            print("[LiveVisibilityDebug] response=\(response)")
#endif

            await MainActor.run {
                isUpdatingLiveVisibilitySetting = false
                refreshLiveVisibilityPresentationCaches()
            }
        } catch {
            if Self.isMissingLiveVisibilityAudienceColumnsError(error) {
#if DEBUG
                print("[LiveVisibilityDebug] error=\(error)")
                Self.logPostgrestError("[LiveVisibilityDebug] missing audience columns; trying boolean-only fallback", error)
#endif
                do {
                    let fallbackResponse = try await supabase
                        .from("user_profiles")
                        .update(UserLiveVisibilityEnabledPatch(live_visibility_enabled: enabled))
                        .eq("id", value: session.user.id.uuidString.lowercased())
                        .execute()

#if DEBUG
                    print("[LiveVisibilityDebug] response=\(fallbackResponse)")
#endif

                    await MainActor.run {
                        isUpdatingLiveVisibilitySetting = false
                        refreshLiveVisibilityPresentationCaches()
                        if mode == .selectedFriends {
                            socialActionToastText = "Live sharing was updated, but Selected Friends needs the latest Supabase migration."
                            socialActionToastIsError = true
                        }
                    }
                    return
                } catch {
#if DEBUG
                    print("[LiveVisibilityDebug] error=\(error)")
                    Self.logPostgrestError("[LiveVisibilityDebug] boolean-only fallback failed", error)
#endif
                    await MainActor.run {
                        currentUserLiveVisibilityEnabled = previous.enabled
                        currentUserLiveVisibilityMode = previous.mode
                        currentUserSelectedLiveVisibilityFriendIDs = previous.selectedFriendIDs
                        isUpdatingLiveVisibilitySetting = false
                        applyCurrentUserLiveVisibilityToProfileCaches(
                            enabled: previous.enabled,
                            mode: previous.mode,
                            selectedFriendIDs: previous.selectedFriendIDs.sorted { $0.uuidString < $1.uuidString },
                            userId: session.user.id
                        )
                        cacheCurrentUserProfileLocally()
                        socialActionToastText = Self.isMissingLiveVisibilityEnabledColumnError(error)
                            ? "Live visibility needs the latest Supabase migration before it can be saved."
                            : "Couldn’t update Live visibility. Please try again."
                        socialActionToastIsError = true
                    }
                    return
                }
            }

            await MainActor.run {
                currentUserLiveVisibilityEnabled = previous.enabled
                currentUserLiveVisibilityMode = previous.mode
                currentUserSelectedLiveVisibilityFriendIDs = previous.selectedFriendIDs
                isUpdatingLiveVisibilitySetting = false
                applyCurrentUserLiveVisibilityToProfileCaches(
                    enabled: previous.enabled,
                    mode: previous.mode,
                    selectedFriendIDs: previous.selectedFriendIDs.sorted { $0.uuidString < $1.uuidString },
                    userId: session.user.id
                )
                cacheCurrentUserProfileLocally()
                socialActionToastText = "Couldn’t update Live visibility. Please try again."
                socialActionToastIsError = true
            }
#if DEBUG
            print("[LiveVisibilityDebug] error=\(error)")
            Self.logPostgrestError("[LiveVisibility] update failed", error)
#endif
        }
    }

    @MainActor
    func applyCurrentUserBioToProfileCaches(bio: String?) {
        guard let userId = currentUserAuthId else { return }
        let trimmed = bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let normalizedBio = trimmed.isEmpty ? nil : trimmed

        func patched(_ row: UserProfileRow) -> UserProfileRow {
            UserProfileRow(
                id: row.id,
                email: row.email,
                display_name: row.display_name,
                username: row.username,
                bio: normalizedBio,
                avatar_url: row.avatar_url,
                avatar_thumbnail_url: row.avatar_thumbnail_url,
                is_business_account: row.is_business_account,
                admin_status: row.admin_status,
                live_visibility_enabled: row.live_visibility_enabled,
                live_visibility_mode: row.live_visibility_mode,
                selected_live_visibility_friend_ids: row.selected_live_visibility_friend_ids,
                discoverable_by_fans: row.discoverable_by_fans,
                created_at: row.created_at
            )
        }

        let currentEmail = OwnerBusinessEmail.normalized(currentUserEmail)
        for (key, row) in userProfilesByEmail {
            let rowEmail = OwnerBusinessEmail.normalized(row.email ?? "")
            if row.id == userId || (!currentEmail.isEmpty && rowEmail == currentEmail) {
                userProfilesByEmail[key] = patched(row)
            }
        }

        if let row = pickupJoinRequesterProfileByUserId[userId] {
            pickupJoinRequesterProfileByUserId[userId] = patched(row)
        }

        goingUserProfiles = goingUserProfiles.map { $0.id == userId ? patched($0) : $0 }
        for eventID in goingProfilesByVenueEventID.keys {
            goingProfilesByVenueEventID[eventID] = goingProfilesByVenueEventID[eventID]?.map {
                $0.id == userId ? patched($0) : $0
            }
        }
    }

    @MainActor
    private func applyCurrentUserLiveVisibilityToProfileCaches(
        enabled: Bool,
        mode: LiveVisibilityMode,
        selectedFriendIDs: [UUID],
        userId: UUID
    ) {
        func patched(_ row: UserProfileRow) -> UserProfileRow {
            UserProfileRow(
                id: row.id,
                email: row.email,
                display_name: row.display_name,
                username: row.username,
                bio: row.bio,
                avatar_url: row.avatar_url,
                avatar_thumbnail_url: row.avatar_thumbnail_url,
                is_business_account: row.is_business_account,
                admin_status: row.admin_status,
                live_visibility_enabled: enabled,
                live_visibility_mode: mode.rawValue,
                selected_live_visibility_friend_ids: selectedFriendIDs,
                discoverable_by_fans: row.discoverable_by_fans
            )
        }

        let currentEmail = OwnerBusinessEmail.normalized(currentUserEmail)
        for (key, row) in userProfilesByEmail {
            let rowEmail = OwnerBusinessEmail.normalized(row.email ?? "")
            if row.id == userId || (!currentEmail.isEmpty && rowEmail == currentEmail) {
                userProfilesByEmail[key] = patched(row)
            }
        }

        goingUserProfiles = goingUserProfiles.map { $0.id == userId ? patched($0) : $0 }
        for eventID in goingProfilesByVenueEventID.keys {
            goingProfilesByVenueEventID[eventID] = goingProfilesByVenueEventID[eventID]?.map {
                $0.id == userId ? patched($0) : $0
            }
        }
    }

    @MainActor
    private func refreshLiveVisibilityPresentationCaches() {
        fanUpdatesGoingProfilePrefetchedAt.removeAll()
        refreshFollowingInterestDerivedSnapshotsForUI()
    }

    private static func isDuplicateUsernameConstraintViolation(_ error: Error) -> Bool {
        let d = error.localizedDescription.lowercased()
        let isDup = d.contains("23505") || d.contains("duplicate key")
        guard isDup else { return false }
        return d.contains("username")
            || d.contains("uq_user_profiles_username_lower")
            || d.contains("handle")
            || d.contains("idx_user_profiles_handle_unique")
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
                    guard let raw = profile.email else { continue }
                    let key = OwnerBusinessEmail.normalized(raw)
                    guard OwnerBusinessEmail.isValidStrict(key) else { continue }
                    if let existing = userProfilesByEmail[key] {
                        if existing.isBusinessIdentity, !profile.isBusinessIdentity {
                            userProfilesByEmail[key] = profile
                        } else if !existing.isBusinessIdentity, !profile.isBusinessIdentity {
                            userProfilesByEmail[key] = mergeFanProfileRow(existing: existing, fetched: profile)
                        }
                    } else {
                        userProfilesByEmail[key] = profile
                    }
                }
            }

        } catch {
            print("ERROR LOADING USER PROFILES FOR EMAILS:", error)
        }
    }

    /// Prefer fresher `user_profiles.bio` when batch-loading social identity rows.
    private func mergeFanProfileRow(existing: UserProfileRow, fetched: UserProfileRow) -> UserProfileRow {
        let existingBio = existing.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fetchedBio = fetched.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedBio: String?
        if !fetchedBio.isEmpty {
            resolvedBio = fetchedBio
        } else if !existingBio.isEmpty {
            resolvedBio = existingBio
        } else {
            resolvedBio = nil
        }

        return UserProfileRow(
            id: fetched.id ?? existing.id,
            email: fetched.email ?? existing.email,
            display_name: {
                let f = fetched.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !f.isEmpty { return f }
                return existing.display_name
            }(),
            username: {
                let f = fetched.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !f.isEmpty { return f }
                return existing.username
            }(),
            bio: resolvedBio,
            avatar_url: {
                let f = ImageDisplayURL.canonicalStorageURLString(fetched.avatar_url)
                if !f.isEmpty { return f }
                return existing.avatar_url
            }(),
            avatar_thumbnail_url: {
                let f = ImageDisplayURL.canonicalStorageURLString(fetched.avatar_thumbnail_url)
                if !f.isEmpty { return f }
                return existing.avatar_thumbnail_url
            }(),
            is_business_account: fetched.is_business_account ?? existing.is_business_account,
            admin_status: fetched.admin_status ?? existing.admin_status,
            live_visibility_enabled: fetched.live_visibility_enabled ?? existing.live_visibility_enabled,
            live_visibility_mode: fetched.live_visibility_mode ?? existing.live_visibility_mode,
            selected_live_visibility_friend_ids: fetched.selected_live_visibility_friend_ids
                ?? existing.selected_live_visibility_friend_ids,
            discoverable_by_fans: fetched.discoverable_by_fans ?? existing.discoverable_by_fans,
            created_at: fetched.created_at ?? existing.created_at
        )
    }

    func cacheCurrentUserProfileLocally() {
        UserDefaults.standard.set(currentUserDisplayName, forKey: "cachedUserDisplayName")
        UserDefaults.standard.set(currentUserUsername, forKey: "cachedUserUsername")
        UserDefaults.standard.set(currentUserBio, forKey: "cachedUserBio")
        UserDefaults.standard.set(currentUserAvatarURL, forKey: "cachedUserAvatarURL")
        UserDefaults.standard.set(currentUserAvatarThumbnailURL, forKey: "cachedUserAvatarThumbnailURL")
        UserDefaults.standard.set(currentUserLiveVisibilityEnabled, forKey: "cachedUserLiveVisibilityEnabled")
        UserDefaults.standard.set(currentUserLiveVisibilityMode.rawValue, forKey: "cachedUserLiveVisibilityMode")
        UserDefaults.standard.set(currentUserDiscoverableByFans, forKey: "cachedUserDiscoverableByFans")
        UserDefaults.standard.set(
            currentUserSelectedLiveVisibilityFriendIDs.map { $0.uuidString.lowercased() }.sorted(),
            forKey: "cachedUserSelectedLiveVisibilityFriendIDs"
        )
    }

    private func cachedLiveVisibilityMode() -> LiveVisibilityMode {
        LiveVisibilityMode(rawValue: UserDefaults.standard.string(forKey: "cachedUserLiveVisibilityMode") ?? "") ?? .allFriends
    }

    private func cachedSelectedLiveVisibilityFriendIDs() -> Set<UUID> {
        let raw = UserDefaults.standard.stringArray(forKey: "cachedUserSelectedLiveVisibilityFriendIDs") ?? []
        return Set(raw.compactMap(UUID.init(uuidString:)))
    }

    enum PasswordResetAccountKind {
        case fan
        case venueOwner
    }

    /// Sends Supabase Auth password recovery email; routes feedback to fan vs venue-owner UI strings on ``MapViewModel``.
    func sendPasswordResetEmail(_ email: String, accountKind: PasswordResetAccountKind) async {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
#if DEBUG
        if case .fan = accountKind {
            print("[FanPasswordResetDebug] resetEmail=\(trimmed)")
        }
        if case .venueOwner = accountKind {
            print("[BusinessPasswordResetDebug] resetEmail=\(trimmed)")
        }
#endif
        guard !trimmed.isEmpty else {
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetError = "Enter your email first."
                    userPasswordResetMessage = ""
#if DEBUG
                    print("[FanPasswordResetDebug] resetError=Enter your email first.")
#endif
                case .venueOwner:
                    venuePasswordResetError = "Enter your business email first."
                    venuePasswordResetMessage = ""
#if DEBUG
                    print("[BusinessPasswordResetDebug] resetError=Enter your business email first.")
#endif
                }
            }
            return
        }

        do {
            try await supabase.auth.resetPasswordForEmail(trimmed)
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetMessage = "Password reset link sent. Check your email."
                    userPasswordResetError = ""
#if DEBUG
                    print("[FanPasswordResetDebug] resetLinkSent=true")
#endif
                case .venueOwner:
                    venuePasswordResetMessage = "Password reset link sent. Check your email."
                    venuePasswordResetError = ""
#if DEBUG
                    print("[BusinessPasswordResetDebug] resetLinkSent=true")
#endif
                }
            }
        } catch {
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetMessage = ""
                    userPasswordResetError = error.localizedDescription
#if DEBUG
                    print("[FanPasswordResetDebug] resetError=\(error.localizedDescription)")
#endif
                case .venueOwner:
                    venuePasswordResetMessage = ""
                    venuePasswordResetError = error.localizedDescription
#if DEBUG
                    print("[BusinessPasswordResetDebug] resetError=\(error.localizedDescription)")
#endif
                }
            }
        }
    }
}
