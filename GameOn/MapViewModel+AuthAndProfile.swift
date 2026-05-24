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

    static let fanPasswordResetRedirectURL = URL(string: "fangeo://reset-password")!
    static let emailVerificationRedirectURL = URL(string: "fangeo://email-confirmed")!

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

    @MainActor
    func markEmailVerificationPending(email: String, kind: EmailVerificationAccountKind) {
        pendingEmailVerificationEmail = OwnerBusinessEmail.normalized(email)
        pendingEmailVerificationKind = kind
        emailVerificationError = ""
        emailVerificationMessage = kind == .business
            ? "Check your email to verify your business account."
            : "Check your email to verify your FanGeo account."
        print("[EmailVerifyDebug] signupNeedsConfirmation=true")
    }

    @MainActor
    func clearEmailVerificationPending() {
        pendingEmailVerificationEmail = ""
        pendingEmailVerificationKind = nil
        emailVerificationError = ""
        emailVerificationMessage = ""
        pendingFanEmailSignupDraft = nil
        pendingBusinessEmailSignupDraft = nil
    }

    static func isUnconfirmedEmailAuthError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("email not confirmed")
            || message.contains("email not verified")
            || message.contains("confirm your email")
            || message.contains("verify your email")
    }

    static func userEmailConfirmed(_ user: User) -> Bool {
        user.emailConfirmedAt != nil || user.confirmedAt != nil
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

    private enum BusinessOwnerActiveValidationResult {
        case active
        case inactive
        case inconclusive(Error)

        var debugValue: String {
            switch self {
            case .active:
                return "active"
            case .inactive:
                return "inactive"
            case .inconclusive(let error):
                return "inconclusive:\(error.localizedDescription)"
            }
        }
    }

    private enum BusinessAdminStatusValidationResult {
        case active(String)
        case blocked(String)
        case noBusiness
        case inconclusive(Error)

        var debugStatus: String {
            switch self {
            case .active(let status), .blocked(let status):
                return status
            case .noBusiness:
                return "noBusiness"
            case .inconclusive(let error):
                return "inconclusive:\(error.localizedDescription)"
            }
        }
    }

    private struct BusinessAdminStatusRow: Decodable {
        let id: UUID?
        let owner_email: String?
        let owner_user_id: UUID?
        let admin_status: String?
    }

    private func logBusinessSessionRestoreDebug(_ message: String) {
#if DEBUG
        print("[BusinessSessionRestoreDebug] \(message)")
#endif
    }

    private func logBusinessLogoutTrace(_ message: String) {
#if DEBUG
        print("[BusinessLogoutTrace] \(message)")
#endif
    }

    private func logDeletedAccountRestoreDebug(_ message: String) {
#if DEBUG
        print("[DeletedAccountRestoreDebug] \(message)")
#endif
    }

    @MainActor
    private func clearStaleDeletedAccountBlockIfNeeded(context: String) {
        let staleDeletedBlock = authSessionState == .deletedAccountConfirmed
            || Self.isDeletedAccountBlockMessage(authErrorMessage)
            || Self.isDeletedAccountBlockMessage(venueAuthErrorMessage)
        guard staleDeletedBlock else { return }

        if authSessionState == .deletedAccountConfirmed {
            transitionAuthSessionState(.loadingSession, reason: "\(context)_staleDeletedBlockCleared")
        }
        authErrorMessage = ""
        venueAuthErrorMessage = ""
        logDeletedAccountRestoreDebug("staleBlockCleared=true context=\(context)")
    }

    private static func isDeletedAccountBlockMessage(_ message: String) -> Bool {
        message.localizedCaseInsensitiveContains("account has been deleted")
    }

    private func hasStoredAccountModeForRestore() -> Bool {
        UserDefaults.standard.string(forKey: Self.storedAccountModeKey) != nil
    }

    private func storedAccountModeDebugValue() -> String {
        let raw = UserDefaults.standard.string(forKey: Self.storedAccountModeKey)
        return raw ?? "nil"
    }

    func shouldPreserveMissingSessionForRestore() -> Bool {
        guard !UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) else { return false }
        if hasStoredAccountModeForRestore() { return true }
        return isAuthenticatedForSocialFeatures
            || isAuthSessionRestoringForProfilePresentation
            || authSessionState == .loadingSession
            || isBusinessOwnerSessionRestorePending
    }

    func markTransientMissingSessionPreserved(reason: String, source: String) async {
        let persisted = readPersistedAccountMode()
        let hasStoredMode = hasStoredAccountModeForRestore()
        let didExplicitlyLogout = UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey)
        logBusinessLogoutTrace("transientMissingSessionPreserved=true reason=\(reason) source=\(source)")
        logBusinessLogoutTrace("didExplicitlyLogout=\(didExplicitlyLogout)")
        logBusinessLogoutTrace("storedAccountMode=\(storedAccountModeDebugValue())")

        await MainActor.run {
            if !didExplicitlyLogout, hasStoredMode, persisted.mode == .businessOwner {
                isBusinessOwnerSessionRestorePending = true
                if authSessionState != .signedIn {
                    transitionAuthSessionState(.loadingSession, reason: reason)
                }
            } else if !didExplicitlyLogout, isAuthenticatedForSocialFeatures {
                transitionAuthSessionState(.loadingSession, reason: reason)
            }
        }
    }

    private func destructiveLogoutAllowed(reason: String, source: String) -> Bool {
        let reasonKey = reason.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let sourceKey = source.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        if reasonKey.contains("explicituserlogout") { return true }
        if reasonKey.contains("explicitlogoutbootstrap") { return true }
        if sourceKey.contains("logoutuser") { return true }
        if reasonKey.contains("deletedaccountconfirmed") { return true }
        if reasonKey.contains("disabledaccountconfirmed") { return true }
        if reasonKey.contains("accountdeletion") { return true }
        if reasonKey.contains("accounttypemismatch") { return true }
        if reasonKey.contains("singlesessionmismatch") { return true }
        if reasonKey.contains("passwordreset") { return true }
        return false
    }

    private func validateActiveBusinessAccount(ownerEmail: String, ownerUserId: UUID?) async -> BusinessOwnerActiveValidationResult {
        let normalized = OwnerBusinessEmail.normalized(ownerEmail)
        guard OwnerBusinessEmail.isValidStrict(normalized) else { return .inactive }

        if ownedBusinesses.contains(where: {
            OwnerBusinessEmail.normalized($0.owner_email ?? "") == normalized && $0.admin_status == "active"
        }) {
            return .active
        }
        if let ownerUserId,
           ownedBusinesses.contains(where: { $0.owner_user_id == ownerUserId && $0.admin_status == "active" }) {
            return .active
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
            if !byEmail.isEmpty { return .active }

            if let ownerUserId {
                let byUser: [BusinessExistenceRow] = try await supabase
                    .from("businesses")
                    .select("id")
                    .eq("owner_user_id", value: ownerUserId)
                    .eq("admin_status", value: "active")
                    .limit(1)
                    .execute()
                    .value
                if !byUser.isEmpty { return .active }
            }
            return .inactive
        } catch {
#if DEBUG
            print("[BusinessSessionFlags] hasActiveBusinessAccount failed email=\(normalized):", error)
#endif
            return .inconclusive(error)
        }
    }

    private func validateBusinessAdminStatus(ownerEmail: String, ownerUserId: UUID?) async -> BusinessAdminStatusValidationResult {
        let normalized = OwnerBusinessEmail.normalized(ownerEmail)
        logDeletedAccountRestoreDebug("email=\(normalized.isEmpty ? "nil" : normalized)")

        var rowsById: [BusinessAdminStatusRow] = []
        var rowsByEmail: [BusinessAdminStatusRow] = []

        do {
            if let ownerUserId {
                rowsById = try await supabase
                    .from("businesses")
                    .select("id,owner_email,owner_user_id,admin_status")
                    .eq("owner_user_id", value: ownerUserId)
                    .limit(5)
                    .execute()
                    .value
            }

            if OwnerBusinessEmail.isValidStrict(normalized) {
                rowsByEmail = try await supabase
                    .from("businesses")
                    .select("id,owner_email,owner_user_id,admin_status")
                    .eq("owner_email", value: normalized)
                    .limit(5)
                    .execute()
                    .value
            }
        } catch {
            logDeletedAccountRestoreDebug("businessAdminStatus=inconclusive:\(error.localizedDescription)")
            logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true")
            return .inconclusive(error)
        }

        let rows = rowsById + rowsByEmail
        guard !rows.isEmpty else {
            logDeletedAccountRestoreDebug("businessAdminStatus=noBusiness")
            logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=noBusinessRow")
            return .noBusiness
        }

        let statuses = rows.map { ($0.admin_status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        let debugStatus = statuses.isEmpty ? "nil" : statuses.joined(separator: ",")
        logDeletedAccountRestoreDebug("businessAdminStatus=\(debugStatus)")

        if statuses.contains("active") {
            logDeletedAccountRestoreDebug("activeBusinessClearsBlock=true")
            return .active("active")
        }

        if let blocked = statuses.first(where: { ["archived", "deleted", "disabled"].contains($0) }) {
            logDeletedAccountRestoreDebug("dbConfirmedDeleted=true status=\(blocked)")
            return .blocked(blocked)
        }

        logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=unrecognizedBusinessStatus")
        return .noBusiness
    }

    @discardableResult
    private func restoreActiveBusinessFromAdminStatusIfNeeded(
        session: Session,
        sessionEmail: String,
        context: String
    ) async -> Bool {
        let validation = await validateBusinessAdminStatus(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        switch validation {
        case .active:
            await MainActor.run {
                clearStaleDeletedAccountBlockIfNeeded(context: context)
            }
            return true
        case .blocked(let status):
            await handleBlockedBusinessAccount(status: status, context: context)
            return false
        case .noBusiness, .inconclusive:
            return true
        }
    }

    private func handleBlockedBusinessAccount(status: String, context: String) async {
        logDeletedAccountRestoreDebug("blockedStateSetBy=\(context)")
        await forceLogout(reason: "disabledAccountConfirmed", source: "MapViewModel.\(context)")
        await MainActor.run {
            resetProfilePresentationLoadStateForNewAuth()
            transitionAuthSessionState(.deletedAccountConfirmed, reason: "\(context)_businessStatus_\(status)")
            authErrorMessage = "This business account is no longer active.\nContact support if you believe this was a mistake."
            venueAuthErrorMessage = authErrorMessage
        }
    }

    func businessAccountAccessIsAllowedForAuthenticatedSession(
        ownerEmail: String,
        userId: UUID,
        context: String
    ) async -> Bool {
        let validation = await validateBusinessAdminStatus(ownerEmail: ownerEmail, ownerUserId: userId)
        switch validation {
        case .active:
            await MainActor.run {
                clearStaleDeletedAccountBlockIfNeeded(context: context)
            }
            return true
        case .blocked(let status):
            await handleBlockedBusinessAccount(status: status, context: context)
            return false
        case .noBusiness, .inconclusive:
            return true
        }
    }

    private func shouldSuppressDeletedProfileBlockForBusinessSession(
        session: Session,
        context: String
    ) async -> Bool {
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let validation = await validateBusinessAdminStatus(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        switch validation {
        case .active:
            await MainActor.run {
                clearStaleDeletedAccountBlockIfNeeded(context: context)
            }
            logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=activeBusinessProfileDeletedIgnored context=\(context)")
            return true
        case .blocked(let status):
            await handleBlockedBusinessAccount(status: status, context: context)
            return true
        case .noBusiness, .inconclusive:
            let shouldTreatAsBusinessRestore = await MainActor.run {
                readPersistedAccountMode().mode == .businessOwner
                    || currentUserIsBusinessAccount
                    || isVenueOwnerLoggedIn
                    || isBusinessOwnerSessionRestorePending
            }
            if shouldTreatAsBusinessRestore {
                logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=businessContextProfileDeletedIgnored context=\(context)")
                return true
            }
            return false
        }
    }

    private func hasActiveBusinessAccount(ownerEmail: String, ownerUserId: UUID?) async -> Bool {
        if case .active = await validateActiveBusinessAccount(ownerEmail: ownerEmail, ownerUserId: ownerUserId) {
            return true
        }
        return false
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

        let businessAdminStatus = await validateBusinessAdminStatus(ownerEmail: normalizedOwnerEmail, ownerUserId: authId)
        switch businessAdminStatus {
        case .active:
            clearStaleDeletedAccountBlockIfNeeded(context: context)
        case .blocked(let status):
            await handleBlockedBusinessAccount(status: status, context: context)
            return false
        case .noBusiness, .inconclusive:
            break
        }

        let validation = await validateActiveBusinessAccount(ownerEmail: normalizedOwnerEmail, ownerUserId: authId)
        logBusinessSessionRestoreDebug("activeBusinessValidation=\(validation.debugValue)")
        guard case .active = validation else {
            logBusinessOwnerSessionFlags(context: "\(context)_no_business_account")
            return false
        }

        isVenueOwnerLoggedIn = true
        venueOwnerMode = true
        isLoggedIn = false
        isAdminLoggedIn = false
        currentUserAuthId = authId
        markAuthSignedIn(reason: "\(context)_businessOwner")
        venueOwnerEmail = normalizedOwnerEmail
        currentUserEmail = ""
        currentUserDisplayName = ""
        currentUserBio = ""
        currentUserIsBusinessAccount = true
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserNationalTeam = nil
        isAuthSessionRestoringForProfilePresentation = false
        isUserProfileLoadingForPresentation = false
        hasLoadedUserProfileForPresentation = false
        userProfileExistsForPresentation = false
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true
        isBusinessOwnerSessionRestorePending = false

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

        guard await restoreActiveBusinessFromAdminStatusIfNeeded(
            session: session,
            sessionEmail: sessionEmail,
            context: context
        ) else {
            return false
        }

        let validation = await validateActiveBusinessAccount(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        logBusinessSessionRestoreDebug("activeBusinessValidation=\(validation.debugValue)")
        guard case .active = validation else {
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
        currentUserNationalTeam = nil
        currentUserLiveVisibilityEnabled = true
        currentUserLiveVisibilityMode = .allFriends
        currentUserSelectedLiveVisibilityFriendIDs = []
        currentUserDiscoverableByFans = true
        isAdminLoggedIn = false
        currentUserAuthId = session.user.id
        markAuthSignedIn(reason: "\(context)_businessOwner")
        isBusinessOwnerSessionRestorePending = false

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
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryCode")
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryName")
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamFlag")
        UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamSupporterLabel")
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
        isBusinessOwnerSessionRestorePending = false
        currentUserFanXP = .rookie
        currentUserFanIdentityPreferences = .empty
        currentUserHomeCrowdVenueId = nil
        currentUserHomeCrowdVenue = nil
        discoverFocusVenueId = nil
        currentUserAvatarURL = ""
        currentUserAvatarThumbnailURL = ""
        currentUserNationalTeam = nil
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
        venueGameCardInitialGoingRefreshTask?.cancel()
        venueGameCardInitialGoingRefreshTask = nil
        venueGameCardInitialGoingRefreshLastIDs = []
        venueGameCardSnapshotStore.reset()
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
        lightweightStartupPrefetchTask?.cancel()
        lightweightStartupPrefetchTask = nil
        lastLightweightStartupPrefetchAt = nil
        favoriteVenueIDsLoadTask?.cancel()
        favoriteVenueIDsLoadTask = nil
        lastFavoriteVenueIDsLoadAt = nil
        favoriteTeamsLoadTask?.cancel()
        favoriteTeamsLoadTask = nil
        lastFavoriteTeamsLoadAt = nil
        followingTodayPlansLoadTask?.cancel()
        followingTodayPlansLoadTask = nil
        lastFollowingTodayPlansLoadAt = nil
        followingTabGlobalRefreshTask?.cancel()
        followingTabGlobalRefreshTask = nil
        myPickupGamesLightweightLoadTask?.cancel()
        myPickupGamesLightweightLoadTask = nil
        lastMyPickupGamesLightweightLoadAt = nil
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
        passwordResetUpdateMessage = ""
        passwordResetUpdateError = ""
        applePendingFanSignupEmail = ""
        appleAuthFanMessage = ""
        appleAuthFanMessageIsError = false
        appleAuthBusinessMessage = ""
        appleAuthBusinessMessageIsError = false
        appleAuthFanMessageAutoClearTask?.cancel()
        appleAuthBusinessMessageAutoClearTask?.cancel()
        appleAuthFanMessageAutoClearTask = nil
        appleAuthBusinessMessageAutoClearTask = nil
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
        ownerVenueSupporterCountry = ""
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
        switch await supabaseResolvedAuthSessionResult() {
        case .active(let session):
            uid = session.user.id.uuidString.lowercased()
        case .missingSession:
            uid = nil
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "persistAccountMode")
            }
            uid = await MainActor.run {
                currentUserAuthId?.uuidString.lowercased()
            }
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

    /// Legacy venue-owner logout entry point. Full account-tab logout uses the centralized Supabase teardown.
    func venueOwnerLocalSignOutPreservingSupabaseSession() {
        Task {
            await forceLogout(
                reason: "venueOwnerLocalSignOutPreservingSupabaseSession",
                source: "MapViewModel.venueOwnerLocalSignOutPreservingSupabaseSession"
            )
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
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_business_account,admin_status,live_visibility_enabled,live_visibility_mode,selected_live_visibility_friend_ids,discoverable_by_fans,is_deleted,national_team_country_code,national_team_country_name,national_team_flag,national_team_supporter_label,national_team_updated_at"

    private static let userProfileIdentitySelectColumns =
        "id,email,display_name,username,bio,avatar_url,avatar_thumbnail_url,is_deleted,national_team_country_code,national_team_country_name,national_team_flag,national_team_supporter_label,national_team_updated_at"

    private struct UserProfileIdentityRow: Decodable {
        let id: UUID?
        let email: String?
        let display_name: String?
        let username: String?
        let bio: String?
        let avatar_url: String?
        let avatar_thumbnail_url: String?
        let is_deleted: Bool?
        let national_team_country_code: String?
        let national_team_country_name: String?
        let national_team_flag: String?
        let national_team_supporter_label: String?
        let national_team_updated_at: String?
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

    @MainActor
    private func transitionAuthSessionState(_ newState: FanGeoAuthSessionState, reason: String) {
        let oldState = authSessionState
        guard oldState != newState else {
#if DEBUG
            print("[AuthStateDebug] authStateTransition=\(oldState.rawValue)->\(newState.rawValue) reason=\(reason) unchanged=true")
#endif
            return
        }
        authSessionState = newState
#if DEBUG
        print("[AuthStateDebug] authStateTransition=\(oldState.rawValue)->\(newState.rawValue) reason=\(reason)")
#endif
    }

    @MainActor
    private func markAuthSignedOut(reason: String) {
        transitionAuthSessionState(.signedOut, reason: reason)
    }

    @MainActor
    private func markAuthSignedIn(reason: String) {
        transitionAuthSessionState(.signedIn, reason: reason)
    }

    @MainActor
    private func markAuthRefreshFailed(_ error: Error, reason: String) {
        transitionAuthSessionState(.authRefreshFailed, reason: reason)
#if DEBUG
        print("[AuthStateDebug] tokenRefreshFailed=true reason=\(reason) error=\(error.localizedDescription)")
#endif
    }

    private func logForcedLogoutReason(_ reason: String) {
#if DEBUG
        print("[AuthStateDebug] forcedLogoutReason=\(reason)")
#endif
    }

    func forceLogout(reason: String, source: String) async {
        let destructiveAllowed = destructiveLogoutAllowed(reason: reason, source: source)
        logBusinessLogoutTrace("forceLogoutCalled reason=\(reason)")
        logBusinessLogoutTrace("destructiveLogoutAllowed=\(destructiveAllowed)")
        logBusinessLogoutTrace("didExplicitlyLogout=\(UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey))")
        logBusinessLogoutTrace("storedAccountMode=\(storedAccountModeDebugValue())")
        guard destructiveAllowed else {
            logBusinessLogoutTrace("supabaseSignOutCalled=false")
            await markTransientMissingSessionPreserved(reason: reason, source: source)
            return
        }

        let snapshot = await MainActor.run {
            (
                currentUserId: currentUserAuthId?.uuidString.lowercased() ?? "nil",
                currentEmail: currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? venueOwnerEmail.trimmingCharacters(in: .whitespacesAndNewlines)
                    : currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines),
                authState: authSessionState.rawValue
            )
        }

        print("[AuthForceLogoutDebug] reason=\(reason)")
        print("[AuthForceLogoutDebug] source=\(source)")
        print("[AuthForceLogoutDebug] currentUserId=\(snapshot.currentUserId)")
        print("[AuthForceLogoutDebug] currentEmail=\(snapshot.currentEmail.isEmpty ? "nil" : snapshot.currentEmail)")
        print("[AuthForceLogoutDebug] authState=\(snapshot.authState)")
        print("[AuthForceLogoutDebug] callStack=\(Thread.callStackSymbols.joined(separator: " | "))")

        do {
            logBusinessLogoutTrace("supabaseSignOutCalled=true")
            try await supabase.auth.signOut()
#if DEBUG
            print("[AuthForceLogoutDebug] signOutSuccess=true")
#endif
        } catch {
            print("[AuthForceLogoutDebug] signOutSuccess=false error=\(error.localizedDescription)")
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
            markAuthSignedOut(reason: reason)
        }

        clearPersistedAccountMode()
        UserDefaults.standard.set(true, forKey: Self.didExplicitlyLogoutKey)
    }

    private func logSessionRestored(_ restored: Bool, reason: String, userId: UUID? = nil) {
#if DEBUG
        let userText = userId?.uuidString.lowercased() ?? "nil"
        print("[AuthStateDebug] sessionRestored=\(restored) reason=\(reason) userId=\(userText)")
#endif
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

    @MainActor
    func resetProfilePresentationLoadStateForNewAuth() {
        isUserProfileLoadingForPresentation = false
        hasLoadedUserProfileForPresentation = false
        userProfileExistsForPresentation = false
    }

    @MainActor
    func beginProfilePresentationLoad() {
        isUserProfileLoadingForPresentation = true
        hasLoadedUserProfileForPresentation = false
        userProfileExistsForPresentation = false
    }

    @MainActor
    func finishProfilePresentationLoad(profileExists: Bool) {
        userProfileExistsForPresentation = profileExists
        hasLoadedUserProfileForPresentation = true
        isUserProfileLoadingForPresentation = false
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

            if let profile = existing.first {
#if DEBUG
                print("[ProfileBootstrap] profile found")
                print("[ProfilePersistenceDebug] existingProfileFound=true")
#endif
                if profile.isDeletedAccount {
                    if await shouldSuppressDeletedProfileBlockForBusinessSession(
                        session: session,
                        context: "ensureUserProfileExists"
                    ) {
                        return
                    }
                    await handleDeletedCurrentUser()
                    return
                }
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
            let signUpResponse = try await supabase.auth.signUp(
                email: fanEmail,
                password: password,
                redirectTo: Self.emailVerificationRedirectURL
            )

            let signUpSession = signUpResponse.session
            let restoredSession = try? await supabase.auth.session
            guard let activeSession = signUpSession ?? restoredSession,
                  Self.userEmailConfirmed(activeSession.user) else {
                await forceLogout(reason: "registerUserNeedsEmailConfirmation", source: "MapViewModel.registerUser")
                await MainActor.run {
                    markEmailVerificationPending(email: fanEmail, kind: .fan)
                }
                return
            }

            if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: activeSession.user.id) {
#if DEBUG
                print("[AuthAccountTypeGate] fan registration blocked businessEmail=\(fanEmail)")
#endif
                await undoPartialSupabaseSessionAfterAccountTypeMismatch()
                await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
                return
            }

            await MainActor.run {
                clearAuthenticatedSessionCaches()
                resetProfilePresentationLoadStateForNewAuth()
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
                markAuthSignedIn(reason: "registerUser")
                bumpCurrentUserAvatarDisplayRefresh()
            }
            await MainActor.run { currentUserAuthId = activeSession.user.id }

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
                await forceLogout(reason: "loginUserSessionMissingAfterSignIn", source: "MapViewModel.loginUser")
                await MainActor.run { authErrorMessage = "Unable to login." }
                return
            }

            guard Self.userEmailConfirmed(session.user) else {
                await forceLogout(reason: "loginUserEmailUnconfirmed", source: "MapViewModel.loginUser")
                await MainActor.run {
                    authErrorMessage = "Please verify your email before signing in."
                    markEmailVerificationPending(email: fanEmail, kind: .fan)
                    print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
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
                resetProfilePresentationLoadStateForNewAuth()
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
                markAuthSignedIn(reason: "loginUser")

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
                markAuthSignedOut(reason: "loginUserError")

                let message = error.localizedDescription.lowercased()

                if Self.isUnconfirmedEmailAuthError(error) {
                    authErrorMessage = "Please verify your email before signing in."
                    markEmailVerificationPending(email: fanEmail, kind: .fan)
                    print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
                } else if message.contains("invalid login credentials") {
                    authErrorMessage = "No account found or incorrect password."
                } else {
                    authErrorMessage = "Unable to login."
                }
            }

            print("LOGIN ERROR:", error)
        }
    }

    func resendEmailVerification(email: String? = nil, kind: EmailVerificationAccountKind? = nil) async {
        let targetEmail = OwnerBusinessEmail.normalized(email ?? pendingEmailVerificationEmail)
        let targetKind = kind ?? pendingEmailVerificationKind ?? .fan
        guard OwnerBusinessEmail.isValidStrict(targetEmail) else {
            await MainActor.run {
                emailVerificationError = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            }
            return
        }

        print("[EmailVerifyDebug] resendStarted=true")
        do {
            try await supabase.auth.resend(
                email: targetEmail,
                type: .signup,
                emailRedirectTo: Self.emailVerificationRedirectURL
            )
            await MainActor.run {
                pendingEmailVerificationEmail = targetEmail
                pendingEmailVerificationKind = targetKind
                emailVerificationError = ""
                emailVerificationMessage = targetKind == .business
                    ? "Verification email sent. Check your business email to continue."
                    : "Verification email sent. Check your email to continue."
            }
            print("[EmailVerifyDebug] resendSuccess=true")
        } catch {
            await MainActor.run {
                emailVerificationError = "Could not resend verification email. Please try again."
            }
            print("[EmailVerifyDebug] resendSuccess=false error=\(error.localizedDescription)")
        }
    }

    func handleEmailVerificationDeepLink(_ url: URL) async {
        guard Self.isEmailVerificationDeepLink(url) else { return }
        print("[EmailVerifyDebug] confirmationDeepLinkReceived=true")

        if let session = try? await supabase.auth.session(from: url) {
            guard await passwordResetRecoverySessionIsAllowed(session: session) else {
                return
            }
            let confirmedAt = session.user.emailConfirmedAt ?? session.user.confirmedAt
            print("[EmailConfirmDebug] emailConfirmedAt=\(confirmedAt?.description ?? "nil")")
            if await completePendingEmailSignupAfterConfirmationIfPossible(session: session) {
                return
            }
            await forceLogout(reason: "emailVerificationCompleted", source: "MapViewModel.handleEmailVerificationDeepLink")
        }

        await MainActor.run {
            clearEmailVerificationPending()
            authErrorMessage = "Email verified. You can now sign in."
            venueAuthErrorMessage = "Email verified. You can now sign in."
            emailVerificationMessage = "Email verified. You can now sign in."
            emailVerificationError = ""
        }
    }

    private func completePendingEmailSignupAfterConfirmationIfPossible(session: Session) async -> Bool {
        guard Self.userEmailConfirmed(session.user) else { return false }
        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")

        if pendingEmailVerificationKind == .fan,
           let draft = pendingFanEmailSignupDraft,
           OwnerBusinessEmail.normalized(draft.email) == sessionEmail {
            print("[EmailConfirmDebug] creatingProfileAfterConfirmation=true")
            return await completePendingEmailFanSignupAfterConfirmation(session: session, draft: draft)
        }

        if pendingEmailVerificationKind == .business,
           let draft = pendingBusinessEmailSignupDraft,
           OwnerBusinessEmail.normalized(draft.email) == sessionEmail {
            print("[EmailConfirmDebug] creatingProfileAfterConfirmation=true")
            return await completePendingBusinessSignupAfterConfirmation(session: session, draft: draft)
        }

        return false
    }

    /// Verifies the signed-in profile has not been disabled or deleted.
    /// Returns `false` after signing out and clearing local state when access must be blocked.
    @discardableResult
    func checkCurrentUserAdminStatus() async -> Bool {
        let sessionResolution = await supabaseResolvedAuthSessionResult()
        let session: Session
        switch sessionResolution {
        case .active(let activeSession):
            session = activeSession
        case .missingSession:
#if DEBUG
            print("[AuthStateDebug] deletedAccountConfirmed=false reason=adminStatusNoSession")
#endif
            return true
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "adminStatusCheck")
            }
#if DEBUG
            print("[AuthStateDebug] deletedAccountConfirmed=false reason=adminStatusRefreshFailed")
#endif
            return true
        }

        let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        let businessValidation = await validateBusinessAdminStatus(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        switch businessValidation {
        case .active:
            await MainActor.run {
                clearStaleDeletedAccountBlockIfNeeded(context: "checkCurrentUserAdminStatus")
            }
            return true
        case .blocked(let status):
            await handleBlockedBusinessAccount(status: status, context: "checkCurrentUserAdminStatus")
            return false
        case .noBusiness, .inconclusive:
            break
        }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: session.user.id)
                .limit(1)
                .execute()
                .value

            guard let profile = rows.first else {
                return true
            }

            if profile.isDeletedAccount {
                let shouldTreatAsBusinessRestore = await MainActor.run {
                    readPersistedAccountMode().mode == .businessOwner
                        || currentUserIsBusinessAccount
                        || isVenueOwnerLoggedIn
                        || isBusinessOwnerSessionRestorePending
                }
                if shouldTreatAsBusinessRestore {
                    logDeletedAccountRestoreDebug("inconclusiveNotDeleted=true reason=businessRestoreProfileDeletedWithoutBusinessConfirmation")
                    await markTransientMissingSessionPreserved(
                        reason: "profileDeletedBusinessRestoreInconclusive",
                        source: "MapViewModel.checkCurrentUserAdminStatus"
                    )
                    return true
                }
#if DEBUG
                print("[AuthStateDebug] deletedAccountConfirmed=true reason=adminStatusProfile userId=\(session.user.id.uuidString.lowercased())")
#endif
                await handleDeletedCurrentUser()
                return false
            }

            if profile.admin_status == "disabled" {
                await handleDisabledCurrentUser()
                return false
            }

            return true
        } catch {
            print("ERROR CHECKING USER ADMIN STATUS:", error)
            return true
        }
    }

    private func handleDeletedCurrentUser() async {
        logDeletedAccountRestoreDebug("blockedStateSetBy=handleDeletedCurrentUser")
        logDeletedAccountRestoreDebug("dbConfirmedDeleted=true source=user_profiles")
        await forceLogout(reason: "deletedAccountConfirmed", source: "MapViewModel.handleDeletedCurrentUser")
        await MainActor.run {
            resetProfilePresentationLoadStateForNewAuth()
            transitionAuthSessionState(.deletedAccountConfirmed, reason: "profileVerifiedDeleted")
            authErrorMessage = "This account has been deleted.\nContact support if you believe this was a mistake."
        }
#if DEBUG
        print("[AuthStateDebug] deletedAccountConfirmed=true")
#endif

    }

    private func handleDisabledCurrentUser() async {
        logDeletedAccountRestoreDebug("blockedStateSetBy=handleDisabledCurrentUser")
        logDeletedAccountRestoreDebug("dbConfirmedDeleted=true source=user_profiles_disabled")
        await forceLogout(reason: "disabledAccountConfirmed", source: "MapViewModel.handleDisabledCurrentUser")
        await MainActor.run {
            authErrorMessage = "This account has been disabled by FanGeo support."
        }
    }

    func logoutUser(reason: String = "explicitUserLogout", preserveAuthErrorMessage: Bool = false) async {
#if DEBUG
        print("[Auth] logout requested")
#endif
        let preservedAuthErrorMessage = preserveAuthErrorMessage ? await MainActor.run { authErrorMessage } : ""

        await forceLogout(reason: reason, source: "MapViewModel.logoutUser")

        if preserveAuthErrorMessage, !preservedAuthErrorMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await MainActor.run {
                authErrorMessage = preservedAuthErrorMessage
            }
        }

#if DEBUG
        print("[Auth] local auth state cleared")
        print("[Auth] explicit logout marker set")
#endif
    }

    func hasValidSession() async -> Bool {
        if UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) {
            return false
        }

        switch await supabaseResolvedAuthSessionResult() {
        case .active:
            return true
        case .missingSession:
            let restoreInProgress = await MainActor.run {
                isAuthSessionRestoringForProfilePresentation || authSessionState == .loadingSession
            }
            if restoreInProgress {
                logBusinessSessionRestoreDebug("forceLogoutSuppressedDuringRestore=true reason=hasValidSessionMissing")
                await markTransientMissingSessionPreserved(
                    reason: "hasValidSessionMissingRestoreInProgress",
                    source: "MapViewModel.hasValidSession"
                )
                return true
            }
            if await MainActor.run(body: { shouldPreserveMissingSessionForRestore() }) {
                await markTransientMissingSessionPreserved(
                    reason: "hasValidSessionMissingPersistedRestore",
                    source: "MapViewModel.hasValidSession"
                )
                Task { [weak self] in
                    await self?.bootstrapAuthSessionOnly()
                }
                return true
            }
            let wasAuthenticated = await MainActor.run { isAuthenticatedForSocialFeatures }
#if DEBUG
            if wasAuthenticated {
                print("[AuthStateDebug] sessionRestored=false reason=hasValidSessionMissingPreserved")
            }
#endif
            return wasAuthenticated
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "hasValidSession")
            }
            return true
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
            currentUserNationalTeam = cachedNationalTeamIdentity()
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
            isBusinessOwnerSessionRestorePending = false
            currentUserAuthId = session.user.id
            markAuthSignedIn(reason: "fanSessionRestore")
            if clearVenueOwnerCaches {
                clearVenueOwnerOwnedBusinessCaches()
                ownerVenueDatabaseId = nil
            }
        }
#if DEBUG
        print("[AuthRestore] restoredFanUser email=\(sessionEmail)")
#endif
    }

    private func bootstrapAuthSessionResultWithRetry() async -> SupabaseAuthSessionResolution {
        let first = await supabaseResolvedAuthSessionResult()
        switch first {
        case .active:
            logBusinessSessionRestoreDebug("supabaseSessionExists=true")
            return first
        case .refreshFailed:
            logBusinessSessionRestoreDebug("supabaseSessionExists=false")
            return first
        case .missingSession:
            logBusinessSessionRestoreDebug("supabaseSessionExists=false")
            logBusinessSessionRestoreDebug("restorePending=missingSessionRetry")
            logBusinessSessionRestoreDebug("forceLogoutSuppressedDuringRestore=true reason=bootstrapMissingSession")
            try? await Task.sleep(nanoseconds: 450_000_000)
            let retry = await supabaseResolvedAuthSessionResult()
            if case .active = retry {
                logBusinessSessionRestoreDebug("supabaseSessionExists=true")
            } else {
                logBusinessSessionRestoreDebug("supabaseSessionExists=false")
            }
            return retry
        }
    }

    private func preserveBusinessOwnerAuthIdentity(
        session: Session,
        sessionEmail: String,
        reason: String
    ) async {
        await MainActor.run {
            currentUserAuthId = session.user.id
            currentUserEmail = sessionEmail
            venueOwnerEmail = sessionEmail
            currentUserIsBusinessAccount = true
            isVenueOwnerLoggedIn = true
            venueOwnerMode = true
            isLoggedIn = false
            isAdminLoggedIn = false
            isBusinessOwnerSessionRestorePending = true
            markAuthSignedIn(reason: reason)
            restorePersistedSelectedVenueForBusinessLaunch()
        }
        await persistAccountModeForActiveAuthSession(.businessOwner)
        logBusinessSessionRestoreDebug("preservedAuthIdentity=true userId=\(session.user.id.uuidString.lowercased()) email=\(sessionEmail)")
    }

    private func sessionUserIsDefinitelyFanProfile(userId: UUID) async -> Bool {
        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: userId)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value
            guard let profile = rows.first else { return false }
            return profile.isRegularFanProfile()
        } catch {
#if DEBUG
            print("[BusinessSessionRestoreDebug] fanProfileValidation=inconclusive:\(error.localizedDescription)")
#endif
            return false
        }
    }

    private func handleFailedBusinessOwnerBootstrapRestore(
        session: Session,
        sessionEmail: String
    ) async {
        logBusinessSessionRestoreDebug("fallbackBusinessRestoreStarted=true")
        await preserveBusinessOwnerAuthIdentity(
            session: session,
            sessionEmail: sessionEmail,
            reason: "bootstrapBusinessOwnerFallbackPreserveIdentity"
        )

        let validation = await validateActiveBusinessAccount(ownerEmail: sessionEmail, ownerUserId: session.user.id)
        logBusinessSessionRestoreDebug("activeBusinessValidation=\(validation.debugValue)")

        switch validation {
        case .active:
            let restored = await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                session: session,
                sessionEmail: sessionEmail,
                context: "bootstrap_restore_business_owner_fallback_retry"
            )
            logBusinessSessionRestoreDebug("restoreBusinessReturned=\(restored)")
            if restored {
                await MainActor.run { isBusinessOwnerSessionRestorePending = false }
                logBusinessSessionRestoreDebug("restoreCompleted=business")
            } else {
                logBusinessSessionRestoreDebug("restorePending=true reason=businessRestoreRetryReturnedFalse")
            }

        case .inactive:
            if await sessionUserIsDefinitelyFanProfile(userId: session.user.id) {
                await MainActor.run { isBusinessOwnerSessionRestorePending = false }
                await persistAccountModeForActiveAuthSession(.fanUser)
                await applyFanUserSessionRestoreAfterBootstrap(
                    session: session,
                    sessionEmail: sessionEmail,
                    clearVenueOwnerCaches: true
                )
                logBusinessSessionRestoreDebug("restoreCompleted=fan")
            } else {
                logBusinessSessionRestoreDebug("restorePending=true reason=inactiveBusinessWithoutFanProfile")
            }

        case .inconclusive(_):
            logBusinessSessionRestoreDebug("restorePending=true reason=activeBusinessValidationInconclusive")
        }
    }

    /// Reads Supabase session and applies cached profile URLs from `UserDefaults` only. Does **not** load profile, favorites, or following (see ``refreshUserPersonalizationInBackground()``).
    func bootstrapAuthSessionOnly() async {
        let restoreID = UUID()
        await MainActor.run {
            authSessionRestoreID = restoreID
            isAuthSessionRestoringForProfilePresentation = true
            transitionAuthSessionState(.loadingSession, reason: "bootstrapStart")
        }
        logBusinessSessionRestoreDebug("bootstrapStart=true")
        defer {
            Task { @MainActor [weak self, restoreID] in
                guard let self, self.authSessionRestoreID == restoreID else { return }
                self.authSessionRestoreID = nil
                self.isAuthSessionRestoringForProfilePresentation = false
            }
        }

        if UserDefaults.standard.bool(forKey: Self.didExplicitlyLogoutKey) {
#if DEBUG
            print("[Auth] startup session restore skipped due to explicit logout")
#endif
            await forceLogout(reason: "explicitLogoutBootstrap", source: "MapViewModel.bootstrapAuthSessionOnly")
            logSessionRestored(false, reason: "explicitLogout")
            return
        }

        switch await bootstrapAuthSessionResultWithRetry() {
        case .missingSession:
            await markTransientMissingSessionPreserved(
                reason: "bootstrapMissingSessionAfterRetry",
                source: "MapViewModel.bootstrapAuthSessionOnly"
            )
            logSessionRestored(false, reason: "missingSession")
            logBusinessSessionRestoreDebug("restorePending=true reason=missingSessionAfterRetry")
            print("NO ACTIVE SESSION")
            return

        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "bootstrap")
            }
            logSessionRestored(false, reason: "tokenRefreshFailed")
            return

        case .active(let session):
                let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
                let sessionUid = session.user.id.uuidString.lowercased()
                logBusinessOwnerSessionFlags(context: "bootstrap_session_loaded")
                logSessionRestored(true, reason: "bootstrap", userId: session.user.id)

                guard Self.userEmailConfirmed(session.user) else {
                    await forceLogout(reason: "bootstrapEmailUnconfirmed", source: "MapViewModel.bootstrapAuthSessionOnly")
                    await MainActor.run {
                        markEmailVerificationPending(email: sessionEmail, kind: .fan)
                        authErrorMessage = "Please verify your email before signing in."
                        print("[EmailVerifyDebug] signInBlockedUnconfirmed=true")
                    }
                    return
                }

                if !(await checkCurrentUserAdminStatus()) {
                    print("SESSION RESTORE BLOCKED: account unavailable")
                    return
                }

                let persisted = readPersistedAccountMode()
#if DEBUG
                print("[AuthRestore] storedAccountMode=\(persisted.mode.rawValue)")
#endif
                logBusinessSessionRestoreDebug("persistedMode=\(persisted.mode.rawValue)")
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
                        currentUserNationalTeam = cachedNationalTeamIdentity()
                        currentUserLiveVisibilityEnabled = UserDefaults.standard.object(forKey: "cachedUserLiveVisibilityEnabled") as? Bool ?? true
                        currentUserLiveVisibilityMode = cachedLiveVisibilityMode()
                        currentUserSelectedLiveVisibilityFriendIDs = cachedSelectedLiveVisibilityFriendIDs()
                        currentUserDiscoverableByFans = UserDefaults.standard.object(forKey: "cachedUserDiscoverableByFans") as? Bool ?? true
                        currentUserAuthId = session.user.id
                        markAuthSignedIn(reason: "adminSessionRestore")
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
                    let restored = await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                        session: session,
                        sessionEmail: sessionEmail,
                        context: "bootstrap_restore_business_owner"
                    )
                    logBusinessSessionRestoreDebug("restoreBusinessReturned=\(restored)")
                    if !restored {
                        await handleFailedBusinessOwnerBootstrapRestore(
                            session: session,
                            sessionEmail: sessionEmail
                        )
                    } else {
                        logBusinessSessionRestoreDebug("restoreCompleted=business")
                    }
                    print("SESSION RESTORED:", sessionEmail)
                    return

                case .fanUser:
                    let restoredBusiness = await restoreBusinessOwnerSessionFromSupabaseSessionIfNeeded(
                        session: session,
                        sessionEmail: sessionEmail,
                        context: "bootstrap_restore_business_owner_fallback"
                    )
                    logBusinessSessionRestoreDebug("restoreBusinessReturned=\(restoredBusiness)")
                    if restoredBusiness {
                        logBusinessSessionRestoreDebug("restoreCompleted=business")
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
        }
    }

    /// Profile bootstrap, fan profile row, favorites, and Following-tab caches. Runs after Discover core so map/calendar are not blocked.
    func refreshUserPersonalizationInBackground() async {
        let t0 = Date()
        switch await supabaseResolvedAuthSessionResult() {
        case .active:
            break
        case .missingSession:
            await markTransientMissingSessionPreserved(
                reason: "personalizationMissingSession",
                source: "MapViewModel.refreshUserPersonalizationInBackground"
            )
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization loaded ms=\(ms) (no session)")
            #endif
            return
        case .refreshFailed(let error):
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "personalization")
            }
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization skipped ms=\(ms) (auth refresh failed)")
            #endif
            return
        }

        guard await checkCurrentUserAdminStatus() else {
            #if DEBUG
            let ms = Int(Date().timeIntervalSince(t0) * 1000)
            print("[Background] personalization blocked ms=\(ms) (account unavailable)")
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

        await prefetchLightweightUserDataForStartup()

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
        let sessionResolution = await supabaseResolvedAuthSessionResult()
        if case .refreshFailed(let error) = sessionResolution {
            await MainActor.run {
                markAuthRefreshFailed(error, reason: "loadUserProfile")
                finishProfilePresentationLoad(profileExists: false)
            }
#if DEBUG
            print("[ProfilePersistenceDebug] profileLoadSkipped reason=authRefreshFailed")
#endif
            return
        }

        if case .active(let session) = sessionResolution {
            guard await checkCurrentUserAdminStatus() else {
                await MainActor.run {
                    finishProfilePresentationLoad(profileExists: false)
                }
                return
            }

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
                    if profile.isDeletedAccount {
                        if await shouldSuppressDeletedProfileBlockForBusinessSession(
                            session: session,
                            context: "loadUserProfile"
                        ) {
                            await MainActor.run {
                                finishProfilePresentationLoad(profileExists: false)
                            }
                            return
                        }
                        await handleDeletedCurrentUser()
                        await MainActor.run {
                            finishProfilePresentationLoad(profileExists: false)
                        }
                        return
                    }
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
                        currentUserNationalTeam = profile.nationalTeamIdentity
                        currentUserLiveVisibilityEnabled = profile.isVisibleForLiveFriendPresence
                        currentUserLiveVisibilityMode = profile.liveVisibilityMode
                        currentUserSelectedLiveVisibilityFriendIDs = profile.selectedLiveVisibilityFriendIDs
                        currentUserDiscoverableByFans = profile.discoverableByFans
                        currentUserAuthId = authId
                        cacheCurrentUserProfileLocally()
                        finishProfilePresentationLoad(profileExists: true)
                    }
#if DEBUG
                    print("[ProfileDiscoverabilityDebug] loaded=\(profile.discoverableByFans)")
#endif

                    print("USER PROFILE LOADED")
                } else {
#if DEBUG
                    print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
                    await MainActor.run {
                        finishProfilePresentationLoad(profileExists: false)
                    }
                    print("NO USER PROFILE FOUND")
                }

            } catch {
#if DEBUG
                print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
                await MainActor.run {
                    finishProfilePresentationLoad(profileExists: false)
                }
                print("ERROR LOADING USER PROFILE:", error)
            }
            return
        }

        let email = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail

        guard !email.isEmpty else {
            await MainActor.run {
                finishProfilePresentationLoad(profileExists: false)
            }
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
                if profile.isDeletedAccount {
#if DEBUG
                    print("[AuthStateDebug] deletedAccountConfirmed=false reason=noSessionProfileFallbackDeletedRow")
#endif
                    await MainActor.run {
                        finishProfilePresentationLoad(profileExists: false)
                    }
                    return
                }
                await MainActor.run {
                    currentUserDisplayName = profile.display_name ?? ""
                    currentUserUsername = profile.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    currentUserBio = profile.bio?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    currentUserIsBusinessAccount = profile.isBusinessIdentity
                    currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_url)
                    currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(profile.avatar_thumbnail_url)
                        currentUserNationalTeam = profile.nationalTeamIdentity
                    currentUserLiveVisibilityEnabled = profile.isVisibleForLiveFriendPresence
                    currentUserLiveVisibilityMode = profile.liveVisibilityMode
                    currentUserSelectedLiveVisibilityFriendIDs = profile.selectedLiveVisibilityFriendIDs
                    currentUserDiscoverableByFans = profile.discoverableByFans
                    cacheCurrentUserProfileLocally()
                    finishProfilePresentationLoad(profileExists: true)
                }
#if DEBUG
                print("[ProfileDiscoverabilityDebug] loaded=\(profile.discoverableByFans)")
#endif

                print("USER PROFILE LOADED")
            } else {
#if DEBUG
                print("[ProfilePersistenceDebug] existingProfileFound=false")
#endif
                await MainActor.run {
                    finishProfilePresentationLoad(profileExists: false)
                }
                print("NO USER PROFILE FOUND")
            }

        } catch {
#if DEBUG
            print("[ProfilePersistenceDebug] profileDecodeFailed=\(error.localizedDescription)")
#endif
            await MainActor.run {
                finishProfilePresentationLoad(profileExists: false)
            }
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

        if existingProfile?.is_deleted == true {
            if let session = try? await supabase.auth.session,
               await shouldSuppressDeletedProfileBlockForBusinessSession(
                    session: session,
                    context: "saveUserProfile"
               ) {
                return "Business profile restore is still finishing. Please try again in a moment."
            }
            await handleDeletedCurrentUser()
            return "This account has been deleted.\nContact support if you believe this was a mistake."
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

    @discardableResult
    func saveNationalTeamIdentity(_ identity: NationalTeamIdentity) async -> String? {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            return "Sign in to update your national team."
        }

        let storedSupporterLabel = NationalTeamCopy.storageSupporterLabelKey(from: identity.supporterLabel)
        let storedIdentity = NationalTeamIdentity(
            countryCode: identity.countryCode,
            countryName: identity.countryName,
            flag: identity.flag,
            supporterLabel: storedSupporterLabel
        )
        let patch = UserProfileNationalTeamPatch(
            national_team_country_code: storedIdentity.countryCode,
            national_team_country_name: storedIdentity.countryName,
            national_team_flag: storedIdentity.flag,
            national_team_supporter_label: storedIdentity.supporterLabel,
            national_team_updated_at: ISO8601DateFormatter().string(from: Date())
        )

        do {
            try await supabase
                .from("user_profiles")
                .update(patch)
                .eq("id", value: session.user.id.uuidString.lowercased())
                .execute()

            await MainActor.run {
                currentUserNationalTeam = storedIdentity
                cacheCurrentUserProfileLocally()
                publicProfileBioRevision &+= 1
#if DEBUG
                print("[NationalTeamDebug] profileSavedNationalTeam=\(storedIdentity.countryCode)")
#endif
            }
            return nil
        } catch {
#if DEBUG
            Self.logPostgrestError("[NationalTeamDebug] save failed", error)
#endif
            return "Couldn’t save your national team. Please try again."
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
                is_deleted: row.is_deleted,
                created_at: row.created_at,
                national_team_country_code: row.national_team_country_code,
                national_team_country_name: row.national_team_country_name,
                national_team_flag: row.national_team_flag,
                national_team_supporter_label: row.national_team_supporter_label,
                national_team_updated_at: row.national_team_updated_at
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
                discoverable_by_fans: row.discoverable_by_fans,
                is_deleted: row.is_deleted,
                national_team_country_code: row.national_team_country_code,
                national_team_country_name: row.national_team_country_name,
                national_team_flag: row.national_team_flag,
                national_team_supporter_label: row.national_team_supporter_label,
                national_team_updated_at: row.national_team_updated_at
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
        let uniqueEmails = Array(
            Set(
                emails
                    .map(OwnerBusinessEmail.normalized)
                    .filter(OwnerBusinessEmail.isValidStrict)
            )
        )

        guard !uniqueEmails.isEmpty else { return }

        do {
            let rows = try await SocialIdentityService().fetchUserProfileRows(forEmails: uniqueEmails)
            let fetchedKeys = Set(
                rows.compactMap { profile -> String? in
                    let key = OwnerBusinessEmail.normalized(profile.email ?? "")
                    return OwnerBusinessEmail.isValidStrict(key) ? key : nil
                }
            )

            await MainActor.run {
                let unresolvedKeys = Set(uniqueEmails).subtracting(fetchedKeys)
                for key in unresolvedKeys {
                    removeStaleFanProfileCacheEntry(forNormalizedEmail: key)
                }

                for profile in rows {
                    guard let raw = profile.email else { continue }
                    let key = OwnerBusinessEmail.normalized(raw)
                    guard OwnerBusinessEmail.isValidStrict(key) else { continue }
                    if profile.isDeletedAccount, let id = profile.id {
                        removeStaleFanProfileCacheEntries(forDeletedUserId: id, keepingNormalizedEmail: key)
                    }
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

    private func removeStaleFanProfileCacheEntry(forNormalizedEmail normalizedEmail: String) {
        let keysToRemove = userProfilesByEmail.keys.filter { key in
            OwnerBusinessEmail.normalized(key) == normalizedEmail
        }
        for key in keysToRemove {
            if userProfilesByEmail[key]?.isBusinessIdentity != true {
                userProfilesByEmail.removeValue(forKey: key)
            }
        }
    }

    private func removeStaleFanProfileCacheEntries(forDeletedUserId userId: UUID, keepingNormalizedEmail keepEmail: String) {
        let keysToRemove = userProfilesByEmail.compactMap { key, profile -> String? in
            guard profile.id == userId else { return nil }
            guard profile.isBusinessIdentity != true else { return nil }
            return OwnerBusinessEmail.normalized(key) == keepEmail ? nil : key
        }
        for key in keysToRemove {
            userProfilesByEmail.removeValue(forKey: key)
        }
    }

    @MainActor
    func invalidateFanChatAuthorProfileCache(for emails: [String]) {
        let normalizedEmails = Set(
            emails
                .map(OwnerBusinessEmail.normalized)
                .filter(OwnerBusinessEmail.isValidStrict)
        )
        for email in normalizedEmails {
            removeStaleFanProfileCacheEntry(forNormalizedEmail: email)
        }
    }

    /// Prefer fresher `user_profiles.bio` when batch-loading social identity rows.
    private func mergeFanProfileRow(existing: UserProfileRow, fetched: UserProfileRow) -> UserProfileRow {
        if fetched.isDeletedAccount {
            return UserProfileRow(
                id: fetched.id ?? existing.id,
                email: fetched.email ?? existing.email,
                display_name: "Deleted User",
                username: nil,
                bio: nil,
                avatar_url: nil,
                avatar_thumbnail_url: nil,
                is_business_account: false,
                admin_status: fetched.admin_status ?? existing.admin_status,
                live_visibility_enabled: false,
                live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
                selected_live_visibility_friend_ids: [],
                discoverable_by_fans: false,
                is_deleted: true,
                created_at: fetched.created_at ?? existing.created_at
            )
        }
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
            is_deleted: fetched.is_deleted ?? existing.is_deleted,
            created_at: fetched.created_at ?? existing.created_at
        )
    }

    func cacheCurrentUserProfileLocally() {
        UserDefaults.standard.set(currentUserDisplayName, forKey: "cachedUserDisplayName")
        UserDefaults.standard.set(currentUserUsername, forKey: "cachedUserUsername")
        UserDefaults.standard.set(currentUserBio, forKey: "cachedUserBio")
        UserDefaults.standard.set(currentUserAvatarURL, forKey: "cachedUserAvatarURL")
        UserDefaults.standard.set(currentUserAvatarThumbnailURL, forKey: "cachedUserAvatarThumbnailURL")
        if let currentUserNationalTeam {
            UserDefaults.standard.set(currentUserNationalTeam.countryCode, forKey: "cachedUserNationalTeamCountryCode")
            UserDefaults.standard.set(currentUserNationalTeam.countryName, forKey: "cachedUserNationalTeamCountryName")
            UserDefaults.standard.set(currentUserNationalTeam.flag, forKey: "cachedUserNationalTeamFlag")
            UserDefaults.standard.set(currentUserNationalTeam.supporterLabel, forKey: "cachedUserNationalTeamSupporterLabel")
        } else {
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryCode")
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamCountryName")
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamFlag")
            UserDefaults.standard.removeObject(forKey: "cachedUserNationalTeamSupporterLabel")
        }
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

    private func cachedNationalTeamIdentity() -> NationalTeamIdentity? {
        NationalTeamIdentity.fromProfile(
            countryCode: UserDefaults.standard.string(forKey: "cachedUserNationalTeamCountryCode"),
            countryName: UserDefaults.standard.string(forKey: "cachedUserNationalTeamCountryName"),
            flag: UserDefaults.standard.string(forKey: "cachedUserNationalTeamFlag"),
            supporterLabel: UserDefaults.standard.string(forKey: "cachedUserNationalTeamSupporterLabel")
        )
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
            print("[PasswordResetDebug] success=false step=send_reset_link error=missing_email")
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
            print("[PasswordResetDebug] step=send_reset_link")
            try await supabase.auth.resetPasswordForEmail(
                trimmed,
                redirectTo: Self.fanPasswordResetRedirectURL
            )
            await MainActor.run {
                switch accountKind {
                case .fan:
                    userPasswordResetMessage = "If an account exists for this email, we sent a password reset link."
                    userPasswordResetError = ""
                    print("[PasswordResetDebug] success=true step=send_reset_link")
#if DEBUG
                    print("[FanPasswordResetDebug] resetLinkSent=true")
#endif
                case .venueOwner:
                    venuePasswordResetMessage = "If an account exists for this email, we sent a password reset link."
                    venuePasswordResetError = ""
                    print("[PasswordResetDebug] success=true step=send_reset_link")
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
                    print("[PasswordResetDebug] success=false step=send_reset_link error=\(error.localizedDescription)")
#if DEBUG
                    print("[FanPasswordResetDebug] resetError=\(error.localizedDescription)")
#endif
                case .venueOwner:
                    venuePasswordResetMessage = ""
                    venuePasswordResetError = error.localizedDescription
                    print("[PasswordResetDebug] success=false step=send_reset_link error=\(error.localizedDescription)")
#if DEBUG
                    print("[BusinessPasswordResetDebug] resetError=\(error.localizedDescription)")
#endif
                }
            }
        }
    }

    func handlePasswordResetDeepLink(_ url: URL) async {
        guard Self.isPasswordResetDeepLink(url) else { return }
        let params = Self.passwordResetDeepLinkParams(from: url)
        print("[PasswordResetDebug] deepLinkReceived=\(Self.redactedPasswordResetDeepLinkDescription(url, params: params))")
        await MainActor.run {
            passwordResetUpdateMessage = ""
            passwordResetUpdateError = ""
        }

        do {
            UserDefaults.standard.set(false, forKey: Self.didExplicitlyLogoutKey)
            let session = try await passwordResetRecoverySession(from: url, params: params)
            print("[PasswordResetDebug] recoverySessionDetected=true")

            guard await passwordResetRecoverySessionIsAllowed(session: session) else {
                print("[PasswordResetDebug] recoveryError=deleted_or_disabled_account")
                return
            }

            await MainActor.run {
                currentUserAuthId = session.user.id
                isPasswordResetRecoverySessionActive = true
                queuePasswordResetCreateSheetForRecovery()
            }
        } catch {
            await MainActor.run {
                passwordResetUpdateError = "This reset link is invalid or expired. Please request a new password reset link."
                isPasswordResetRecoverySessionActive = false
                queuePasswordResetCreateSheetForRecovery()
            }
            print("[PasswordResetDebug] recoverySessionDetected=false")
            print("[PasswordResetDebug] recoveryError=\(error.localizedDescription)")
        }
    }

    @MainActor
    func passwordResetRequestSheetDidAppear() {
        isPasswordResetRequestSheetPresented = true
        print("[PasswordResetDebug] sheetMode=\(passwordResetSheetMode.rawValue)")
    }

    @MainActor
    func passwordResetRequestSheetDidDisappear() {
        isPasswordResetRequestSheetPresented = false
    }

    @MainActor
    private func queuePasswordResetCreateSheetForRecovery() {
        passwordResetSheetMode = .createPassword
        isShowingPasswordResetCreateSheet = true
        print("[PasswordResetDebug] sheetMode=createPassword")
        print("[PasswordResetDebug] rootRecoveryPresentation=true")
        print("[PasswordResetDebug] blockingAllOtherAuthSheets=true")
        if isPasswordResetRequestSheetPresented {
            print("[PasswordResetDebug] reusedExistingSheetForRecovery=true")
        }
        print("[PasswordResetDebug] showingCreatePassword=true")
    }

    var passwordResetRequestSheetPresentationBlocked: Bool {
        isPasswordResetRecoverySessionActive || isShowingPasswordResetCreateSheet
    }

    @MainActor
    func canPresentPasswordResetRequestSheet() -> Bool {
        guard !passwordResetRequestSheetPresentationBlocked else {
            print("[PasswordResetDebug] blockedRequestSheetDuringRecovery=true")
            return false
        }
        passwordResetSheetMode = .requestLink
        print("[PasswordResetDebug] sheetMode=requestLink")
        return true
    }

    private func passwordResetRecoverySession(from url: URL, params: [String: String]) async throws -> Session {
        if let accessToken = params["access_token"], let refreshToken = params["refresh_token"] {
            return try await supabase.auth.setSession(accessToken: accessToken, refreshToken: refreshToken)
        }

        if let tokenHash = params["token_hash"] ?? params["token_hashes"] {
            let response = try await supabase.auth.verifyOTP(tokenHash: tokenHash, type: .recovery)
            if let session = response.session {
                return session
            }
        }

        return try await supabase.auth.session(from: url)
    }

    func updateRecoveredPassword(_ newPassword: String) async {
        print("[PasswordResetDebug] step=update_password")
        await MainActor.run {
            passwordResetUpdateMessage = ""
            passwordResetUpdateError = ""
        }

        do {
            let session = try await supabase.auth.session
            guard await passwordResetRecoverySessionIsAllowed(session: session) else {
                print("[PasswordResetDebug] success=false step=update_password error=deleted_or_disabled_account")
                return
            }

            try await supabase.auth.update(user: UserAttributes(password: newPassword))
            print("[PasswordResetDebug] success=true step=update_password")

            await forceLogout(reason: "passwordResetCompleted", source: "MapViewModel.updateRecoveredPassword")

            await MainActor.run {
                isPasswordResetRecoverySessionActive = false
                isShowingPasswordResetCreateSheet = false
                passwordResetSheetMode = .requestLink
                passwordResetUpdateMessage = "Your password has been updated. Please sign in again."
            }
        } catch {
            await MainActor.run {
                passwordResetUpdateError = error.localizedDescription
            }
            print("[PasswordResetDebug] success=false step=update_password error=\(error.localizedDescription)")
        }
    }

    func cancelPasswordResetRecovery() async {
        print("[PasswordResetDebug] step=cancel_recovery")
        if isPasswordResetRecoverySessionActive {
            await forceLogout(reason: "passwordResetCancelled", source: "MapViewModel.cancelPasswordResetRecovery")
            print("[PasswordResetDebug] success=true step=cancel_recovery")
        } else {
            print("[PasswordResetDebug] signOutSkipped=true reason=no_recovery_session")
        }

        await MainActor.run {
            isPasswordResetRecoverySessionActive = false
            isShowingPasswordResetCreateSheet = false
            passwordResetSheetMode = .requestLink
            passwordResetUpdateError = ""
        }
    }

    private static func isPasswordResetDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "fangeo" else { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "reset-password" || path == "/reset-password"
    }

    private static func isEmailVerificationDeepLink(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "fangeo" else { return false }
        let host = url.host?.lowercased() ?? ""
        let path = url.path.lowercased()
        return host == "email-confirmed"
            || path == "/email-confirmed"
            || host == "auth-callback"
            || path == "/auth-callback"
    }

    private static func passwordResetDeepLinkParams(from url: URL) -> [String: String] {
        var result: [String: String] = [:]
        if let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems {
            for item in queryItems {
                result[item.name] = item.value ?? ""
            }
        }
        if let fragment = URLComponents(url: url, resolvingAgainstBaseURL: false)?.fragment,
           let fragmentItems = URLComponents(string: "https://fangeo.local?\(fragment)")?.queryItems {
            for item in fragmentItems {
                result[item.name] = item.value ?? ""
            }
        }
        return result
    }

    private static func redactedPasswordResetDeepLinkDescription(_ url: URL, params: [String: String]) -> String {
        let host = url.host ?? ""
        let path = url.path.isEmpty ? "/" : url.path
        let paramKeys = params.keys.sorted().joined(separator: ",")
        return "\(url.scheme ?? "unknown")://\(host)\(path) params=[\(paramKeys)]"
    }

    private func passwordResetRecoverySessionIsAllowed(session: Session) async -> Bool {
        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select(Self.userProfileSelectColumns)
                .eq("id", value: session.user.id.uuidString.lowercased())
                .limit(1)
                .execute()
                .value

            if let profile = rows.first, profile.isDeletedAccount {
                if await shouldSuppressDeletedProfileBlockForBusinessSession(
                    session: session,
                    context: "passwordResetRecovery"
                ) {
                    return false
                }
                await handleDeletedCurrentUser()
                return false
            }

            if let profile = rows.first,
               let status = profile.admin_status,
               status != "active" {
                await handleDisabledCurrentUser()
                return false
            }

            return true
        } catch {
            print("[PasswordResetDebug] success=false step=profile_check error=\(error.localizedDescription)")
            return true
        }
    }
}
