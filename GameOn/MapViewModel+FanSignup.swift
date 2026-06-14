import Foundation
import Supabase

struct FanSignupProfileInput: Sendable {
    let displayName: String
    let handle: String
    let bio: String
    let avatarData: Data?
    let favoriteTeamIDs: [String]
    let nationalTeamIdentity: NationalTeamIdentity?
}

enum FanSignupFailureStep: String, Sendable {
    case validation
    case auth
    case profile
    case favoriteTeams
}

struct FanSignupSubmitOutcome: Sendable {
    let succeeded: Bool
    let failureStep: FanSignupFailureStep?
    let errorMessage: String?
    /// True when Supabase auth account was created and session is active.
    let authSucceeded: Bool
}

extension MapViewModel {
    static let defaultFanSignupBio = "I am a FanGeo Fan."

    /// Pre-auth @handle availability (signup form). Uses `check_username_available_for_registration` when not signed in.
    func checkUsernameAvailableForSignup(_ rawHandle: String) async -> Bool? {
        let stored = FanGeoHandleRules.normalizeForStorage(rawHandle)
        print("[HandleValidationDebug] normalizedHandle=\(stored)")
        guard FanGeoHandleRules.validate(rawHandle) == nil else {
            print("[HandleValidationDebug] handleRejected reason=invalid")
            return false
        }

        if (try? await supabase.auth.session) != nil {
            return await checkUsernameAvailable(rawHandle)
        }

        struct RpcParams: Encodable {
            let p_username: String
        }

        do {
            print("[HandleValidationDebug] availabilityCheck=\(stored)")
            let available: Bool = try await supabase
                .rpc(
                    "check_username_available_for_registration",
                    params: RpcParams(p_username: stored)
                )
                .execute()
                .value
            print("[HandleValidationDebug] handleAvailable=\(available)")
            return available
        } catch {
            print("[SignupUX] submitFailed step=handleCheck error=\(error.localizedDescription)")
            return nil
        }
    }

    /// Creates fan auth + profile in one flow. Returns partial success when auth succeeds but profile save fails.
    func registerFanAccountWithProfile(
        email: String,
        password: String,
        profile: FanSignupProfileInput,
        recordFanGuidelinesAcceptance: Bool
    ) async -> FanSignupSubmitOutcome {
        let fanEmail = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(fanEmail) else {
            let message = OwnerBusinessEmail.invalidOwnerEmailUserMessage
            await MainActor.run { authErrorMessage = message }
            print("[EmailConfirmDebug] formValidationFailed reason=invalid_email")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .validation,
                errorMessage: message,
                authSucceeded: false
            )
        }

        let trimmedPassword = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPassword.isEmpty else {
            let message = "Password is required."
            await MainActor.run { authErrorMessage = message }
            print("[EmailConfirmDebug] formValidationFailed reason=password_required")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .validation,
                errorMessage: message,
                authSucceeded: false
            )
        }

        let displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !displayName.isEmpty else {
            print("[EmailConfirmDebug] formValidationFailed reason=display_name_required")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .validation,
                errorMessage: "Display name is required.",
                authSucceeded: false
            )
        }

        if ModerationService.containsProfanity(displayName) {
            let message = ModerationService.profanityRejectionUserMessage()
            print("[EmailConfirmDebug] formValidationFailed reason=display_name_profanity")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .validation,
                errorMessage: message,
                authSucceeded: false
            )
        }

        if let issue = FanGeoHandleRules.validate(profile.handle) {
            print("[HandleValidationDebug] handleRejected reason=\(issue)")
            print("[EmailConfirmDebug] formValidationFailed reason=invalid_handle")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .validation,
                errorMessage: FanGeoHandleRules.validationMessage(for: issue),
                authSucceeded: false
            )
        }

        await MainActor.run { authErrorMessage = "" }

        if await businessAccountExistsForOwnerEmailOnly(fanEmail) {
            let message = Self.fanLoginBlockedBecauseBusinessMessage
            await MainActor.run { authErrorMessage = message }
            print("[SignupUX] submitFailed step=auth error=\(message)")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: false
            )
        }

        print("[EmailConfirmDebug] formValidationPassed=true")

        let signUpResponse: AuthResponse
        do {
            print("[EmailConfirmDebug] callingAuthSignUp=true")
            signUpResponse = try await supabase.auth.signUp(
                email: fanEmail,
                password: trimmedPassword,
                redirectTo: Self.emailVerificationRedirectURL
            )
            print("[EmailConfirmDebug] authSignUpSucceeded=true")
            print("[EmailConfirmDebug] authSignUpUserId=\(signUpResponse.user.id.uuidString.lowercased())")
            print("[EmailConfirmDebug] authSignUpSessionNil=\(signUpResponse.session == nil)")
        } catch {
            let message = Self.userFacingAuthSignupErrorMessage(error)
            await MainActor.run { authErrorMessage = message }
            print("[SignupUX] submitFailed step=auth error=\(message)")
            print("[EmailConfirmDebug] authSignUpFailed error=\(String(reflecting: error)) localized=\(error.localizedDescription)")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: false
            )
        }

        print("[SignupUX] authCreated")

        let signUpSession = signUpResponse.session
        let restoredSession = try? await supabase.auth.session
        let activeSession = signUpSession ?? restoredSession
        guard let session = activeSession,
              Self.userEmailConfirmed(session.user) else {
            await forceLogout(reason: "fanSignupNeedsEmailConfirmation", source: "MapViewModel.registerFanAccountWithProfile")
            await MainActor.run {
                pendingFanEmailSignupDraft = PendingFanEmailSignupDraft(
                    email: fanEmail,
                    profile: profile,
                    recordFanGuidelinesAcceptance: recordFanGuidelinesAcceptance
                )
                markEmailVerificationPending(
                    email: fanEmail,
                    kind: .fan,
                    includeEmailDeliveryGuidance: true
                )
            }
            print("[EmailConfirmDebug] authUserCreatedPending=true")
            print("[EmailConfirmDebug] profileCreationDeferred=true")
            return FanSignupSubmitOutcome(
                succeeded: true,
                failureStep: nil,
                errorMessage: nil,
                authSucceeded: false
            )
        }

        if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: session.user.id) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            let message = Self.fanLoginBlockedBecauseBusinessMessage
            await MainActor.run { authErrorMessage = message }
            print("[SignupUX] submitFailed step=auth error=\(message)")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: false
            )
        }

        guard await claimAccountIdentity(.fan, context: "registerFanAccountWithProfile") else {
            let message = await MainActor.run { authErrorMessage }
            print("[SignupUX] submitFailed step=auth error=\(message)")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: false
            )
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
            authSessionState = .signedIn
#if DEBUG
            print("[AuthStateDebug] authStateTransition=fanSignup->signedIn")
#endif
            bumpCurrentUserAvatarDisplayRefresh()
        }

        await MainActor.run { currentUserAuthId = session.user.id }

        await persistAccountModeForActiveAuthSession(.fanUser)

        if (try? await supabase.auth.session) != nil {
            clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        }

        await registerFanActiveSessionOnLogin()

        if recordFanGuidelinesAcceptance {
            UserDefaults.standard.set(true, forKey: "fanGuidelinesAccepted")
        }

        await ensureUserProfileExists()

        let profileSaveError = await finishFanSignupProfile(profile: profile)
        if let profileSaveError {
            print("[SignupUX] submitFailed step=profile error=\(profileSaveError)")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .profile,
                errorMessage: profileSaveError,
                authSucceeded: true
            )
        }

        print("[SignupUX] profileCreated")

        Task { await refreshUserPersonalizationInBackground() }

        return FanSignupSubmitOutcome(
            succeeded: true,
            failureStep: nil,
            errorMessage: nil,
            authSucceeded: true
        )
    }

    /// Retry profile save after auth succeeded (signup profile step failed).
    func retryFanSignupProfileSave(profile: FanSignupProfileInput) async -> FanSignupSubmitOutcome {
        if let message = await finishFanSignupProfile(profile: profile) {
            print("[SignupUX] submitFailed step=profile error=\(message)")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .profile,
                errorMessage: message,
                authSucceeded: true
            )
        }
        print("[SignupUX] profileCreated")
        Task { await refreshUserPersonalizationInBackground() }
        return FanSignupSubmitOutcome(
            succeeded: true,
            failureStep: nil,
            errorMessage: nil,
            authSucceeded: true
        )
    }

    /// Completes fan profile onboarding after native Apple auth has already established a Supabase session.
    func completeAppleFanSignupProfile(
        profile: FanSignupProfileInput,
        recordFanGuidelinesAcceptance: Bool
    ) async -> FanSignupSubmitOutcome {
        let session: Session
        do {
            session = try await supabase.auth.session
        } catch {
            let message = "Continue with Apple again to finish creating your account."
            await MainActor.run { authErrorMessage = message }
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: false
            )
        }

        let fanEmail = OwnerBusinessEmail.normalized(session.user.email ?? "")
        guard OwnerBusinessEmail.isValidStrict(fanEmail) else {
            let message = "Apple did not return a usable email address."
            await MainActor.run { authErrorMessage = message }
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: true
            )
        }

        if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: session.user.id) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            let message = Self.fanLoginBlockedBecauseBusinessMessage
            await MainActor.run { authErrorMessage = message }
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: false
            )
        }

        if await appleFanProfileConflictExists(email: fanEmail, currentUserId: session.user.id) {
            let message = await MainActor.run { authErrorMessage }
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message.isEmpty ? "Could not create your FanGeo profile." : message,
                authSucceeded: false
            )
        }

        guard await claimAccountIdentity(.fan, context: "completeApplePendingFanSignup") else {
            let message = await MainActor.run { authErrorMessage }
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .auth,
                errorMessage: message,
                authSucceeded: false
            )
        }

        await MainActor.run {
            currentUserAuthId = session.user.id
            currentUserEmail = fanEmail
            currentUserIsBusinessAccount = false
        }

        if let profileSaveError = await finishFanSignupProfile(profile: profile) {
            print("[SignupUX] submitFailed step=profile error=\(profileSaveError)")
            return FanSignupSubmitOutcome(
                succeeded: false,
                failureStep: .profile,
                errorMessage: profileSaveError,
                authSucceeded: true
            )
        }

        await MainActor.run {
            isLoggedIn = true
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            authSessionState = .signedIn
            applePendingFanSignupEmail = ""
            authErrorMessage = ""
            clearAppleAuthMessage(accountMode: .fan, reason: "profileCreated")
            bumpCurrentUserAvatarDisplayRefresh()
        }

        await persistAccountModeForActiveAuthSession(.fanUser)
        clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        await registerFanActiveSessionOnLogin()

        if recordFanGuidelinesAcceptance {
            UserDefaults.standard.set(true, forKey: "fanGuidelinesAccepted")
        }

        print("[SignupUX] profileCreated")
        print("[AppleAuthDebug] profileCreationSucceeded=true")
        Task { await refreshUserPersonalizationInBackground() }

        return FanSignupSubmitOutcome(
            succeeded: true,
            failureStep: nil,
            errorMessage: nil,
            authSucceeded: true
        )
    }

    func completePendingEmailFanSignupAfterConfirmation(
        session: Session,
        draft: PendingFanEmailSignupDraft
    ) async -> Bool {
        let fanEmail = OwnerBusinessEmail.normalized(session.user.email ?? draft.email)
        guard OwnerBusinessEmail.isValidStrict(fanEmail),
              Self.userEmailConfirmed(session.user) else {
            return false
        }

        if await businessAccountExistsForOwnerEmailOrUserId(email: fanEmail, userId: session.user.id) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            let message = Self.fanLoginBlockedBecauseBusinessMessage
            await MainActor.run { authErrorMessage = message }
            return true
        }

        guard await claimAccountIdentity(.fan, context: "completePendingEmailFanSignupAfterConfirmation") else {
            await MainActor.run { emailVerificationError = authErrorMessage }
            return true
        }

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            resetProfilePresentationLoadStateForNewAuth()
            currentUserAuthId = session.user.id
            currentUserEmail = fanEmail
            currentUserDisplayName = ""
            currentUserUsername = ""
            currentUserBio = ""
            currentUserIsBusinessAccount = false
            currentUserAvatarURL = ""
            currentUserAvatarThumbnailURL = ""
            isLoggedIn = false
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            bumpCurrentUserAvatarDisplayRefresh()
        }

        if let profileSaveError = await finishFanSignupProfile(profile: draft.profile) {
            await forceLogout(reason: "emailConfirmedFanProfileSaveFailed", source: "MapViewModel.completePendingEmailFanSignupAfterConfirmation")
            await MainActor.run {
                authErrorMessage = profileSaveError
                emailVerificationError = profileSaveError
            }
            print("[SignupUX] submitFailed step=profile error=\(profileSaveError)")
            return true
        }

        await MainActor.run {
            isLoggedIn = true
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            authSessionState = .signedIn
            pendingFanEmailSignupDraft = nil
            pendingEmailVerificationEmail = ""
            pendingEmailVerificationKind = nil
            emailVerificationError = ""
            emailVerificationMessage = "Email verified. Your FanGeo profile is ready."
        }
        await persistAccountModeForActiveAuthSession(.fanUser)
        clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        await registerFanActiveSessionOnLogin()

        if draft.recordFanGuidelinesAcceptance {
            UserDefaults.standard.set(true, forKey: "fanGuidelinesAccepted")
        }

        print("[SignupUX] profileCreated")
        Task { await refreshUserPersonalizationInBackground() }
        return true
    }

    private func finishFanSignupProfile(profile: FanSignupProfileInput) async -> String? {
        let displayName = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let bioTrimmed = profile.bio.trimmingCharacters(in: .whitespacesAndNewlines)
        let bioToSave = bioTrimmed.isEmpty ? Self.defaultFanSignupBio : bioTrimmed

        if let available = await checkUsernameAvailable(profile.handle) {
            let stored = FanGeoHandleRules.normalizeForStorage(profile.handle)
            print("[SignupUX] handleCheck username=\(stored) available=\(available)")
            print("[HandleValidationDebug] handleAvailable=\(available)")
            guard available else {
                print("[HandleValidationDebug] handleRejected reason=already_taken")
                return "That handle is already taken."
            }
        } else {
            return "Could not verify whether this handle is available. Please try again."
        }

        var avatarURL = ""
        var avatarThumbnailURL: String?
        if let data = profile.avatarData {
            let fileName = "avatar-\(Int(Date().timeIntervalSince1970)).jpg"
            if let urls = await uploadUserAvatar(data: data, fileName: fileName) {
                avatarURL = urls.fullURL
                avatarThumbnailURL = urls.thumbnailURL
            }
        }

        if let err = await saveUserProfile(
            displayName: displayName,
            avatarURL: avatarURL,
            avatarThumbnailURL: avatarThumbnailURL,
            username: profile.handle,
            bio: bioToSave
        ) {
            return err
        }

        if !profile.favoriteTeamIDs.isEmpty {
            let sorted = profile.favoriteTeamIDs.sorted()
            await MainActor.run {
                FavoriteTeamsStore.writeToAppStorage(sorted)
                FavoriteTeamsStore.writePrimaryTeamIDToAppStorage(sorted.first)
            }
            let synced = await syncFavoriteTeamsToSupabase(teamIDs: sorted, primaryTeamID: sorted.first)
            print("[SignupUX] favoriteTeamsSaved count=\(sorted.count) synced=\(synced)")
        } else {
            print("[SignupUX] favoriteTeamsSaved count=0")
        }

        if let nationalTeamIdentity = profile.nationalTeamIdentity {
            if let err = await saveNationalTeamIdentity(nationalTeamIdentity) {
                return err
            }
            print("[SignupUX] nationalTeamSaved country=\(nationalTeamIdentity.countryCode)")
        } else {
            print("[SignupUX] nationalTeamSaved skipped=true")
        }

        return nil
    }

    private static func userFacingAuthSignupErrorMessage(_ error: Error) -> String {
        let text = error.localizedDescription.lowercased()
        if text.contains("already registered") || text.contains("already exists") {
            return "An account with this email already exists. Sign in instead."
        }
        if text.contains("password") && (text.contains("short") || text.contains("least")) {
            return "Choose a stronger password and try again."
        }
        return "Could not create your account. Please try again."
    }
}
