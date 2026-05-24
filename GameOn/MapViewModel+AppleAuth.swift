import Foundation
import CryptoKit
import Supabase

private struct AppleExistingFanProfileRow: Decodable {
    let id: UUID?
    let is_deleted: Bool?
    let admin_status: String?
}

extension MapViewModel {
    func clearAppleAuthMessage(accountMode: AppleAuthAccountMode, reason: String) {
        switch accountMode {
        case .fan:
            appleAuthFanMessageAutoClearTask?.cancel()
            appleAuthFanMessageAutoClearTask = nil
            guard !appleAuthFanMessage.isEmpty else { return }
            appleAuthFanMessage = ""
            appleAuthFanMessageIsError = false
        case .business:
            appleAuthBusinessMessageAutoClearTask?.cancel()
            appleAuthBusinessMessageAutoClearTask = nil
            guard !appleAuthBusinessMessage.isEmpty else { return }
            appleAuthBusinessMessage = ""
            appleAuthBusinessMessageIsError = false
        }
        print("[AppleAuthDebug] errorClearedReason=\(reason)")
    }

    func handleAppleAuthFailure(message: String, accountMode: AppleAuthAccountMode) async {
        print("[AppleAuthDebug] authError=\(message) accountMode=\(accountMode.rawValue)")
        print("[AppleAuthDebug] authFailureReason=\(message)")
        presentAppleAuthMessage(
            "Could not sign in with Apple. Please try again.",
            accountMode: accountMode,
            isError: true,
            autoClearAfterSeconds: 8
        )
    }

    func signInWithAppleIdentityToken(
        _ identityToken: String,
        rawNonce: String,
        email: String?,
        fullName: PersonNameComponents?,
        accountMode: AppleAuthAccountMode,
        entryPoint: AppleAuthEntryPoint = .signIn
    ) async {
        do {
            print("[AppleAuthDebug] supabaseSignInRequestStart=true accountMode=\(accountMode.rawValue) entryPoint=\(entryPoint.rawValue) identityTokenLength=\(identityToken.count) rawNonceLength=\(rawNonce.count) appleEmailProvided=\(email != nil)")
            Self.logAppleIdentityTokenClaims(identityToken, rawNonce: rawNonce)
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleSupabaseSignInStart=true")
            }
            await MainActor.run {
                clearEmailVerificationPending()
                clearAppleAuthMessage(accountMode: accountMode, reason: "authorizationStarted")
            }

            let session = try await supabase.auth.signInWithIdToken(
                credentials: OpenIDConnectCredentials(
                    provider: .apple,
                    idToken: identityToken,
                    nonce: rawNonce
                )
            )

            print("[AppleAuthDebug] supabaseSignInSucceeded=true")
            print("[AppleAuthDebug] currentAuthUserId=\(session.user.id.uuidString.lowercased())")
            print("[AppleAuthDebug] currentAuthUserEmail=\(session.user.email ?? "nil")")
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleSupabaseSignInSucceeded=true userId=\(session.user.id.uuidString.lowercased()) email=\(session.user.email ?? "nil")")
            }

            let sessionEmail = OwnerBusinessEmail.normalized(session.user.email ?? email ?? "")
            if sessionEmail.lowercased().contains("privaterelay.appleid.com") {
                print("[AppleAuthDebug] relayEmailUsed=true")
            }

            if await refreshActiveBanGate(reason: "appleLogin") {
                clearExplicitLogoutMarkerAfterManualAuthSucceeded()
                return
            }

            switch accountMode {
            case .fan:
                await finishAppleFanSignIn(
                    session: session,
                    sessionEmail: sessionEmail,
                    fullName: fullName,
                    entryPoint: entryPoint
                )
            case .business:
                await finishAppleBusinessSignIn(session: session, sessionEmail: sessionEmail, fullName: fullName)
            }
        } catch {
            let nsError = error as NSError
            print("[AppleAuthDebug] supabaseSignInFailed=true domain=\(nsError.domain) code=\(nsError.code) localized=\(error.localizedDescription) raw=\(String(reflecting: error)) userInfo=\(nsError.userInfo)")
            print("[AppleAuthDebug] authError=\(error.localizedDescription)")
            print("[AppleAuthDebug] authFailureReason=\(String(reflecting: error))")
            if entryPoint == .fanSignup {
                print("[FanSignupDebug] appleSupabaseSignInFailed=true localized=\(error.localizedDescription) raw=\(String(reflecting: error))")
            }
            presentAppleAuthMessage(
                "Could not sign in with Apple. Please try again.",
                accountMode: accountMode,
                isError: true,
                autoClearAfterSeconds: 8
            )
        }
    }

    private func finishAppleFanSignIn(
        session: Session,
        sessionEmail: String,
        fullName: PersonNameComponents?,
        entryPoint: AppleAuthEntryPoint
    ) async {
        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
            await forceLogout(reason: "appleFanMissingEmail", source: "MapViewModel.finishAppleFanSignIn")
            presentAppleAuthMessage(
                "Apple did not return a usable email address.",
                accountMode: .fan,
                isError: true,
                autoClearAfterSeconds: 8
            )
            return
        }

        if await businessAccountExistsForOwnerEmailOrUserId(email: sessionEmail, userId: session.user.id) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { authErrorMessage = Self.fanLoginBlockedBecauseBusinessMessage }
            return
        }

        if await appleFanProfileConflictExists(email: sessionEmail, currentUserId: session.user.id) {
            return
        }

        if entryPoint == .fanSignup,
           !(await appleCurrentFanProfileExists(session: session)) {
            await MainActor.run {
                applePendingFanSignupEmail = sessionEmail
                currentUserAuthId = session.user.id
                currentUserEmail = sessionEmail
                authErrorMessage = ""
            }
            print("[AppleAuthDebug] profileMissing=true")
            print("[AppleAuthDebug] enteringPendingProfileCreation=true email=\(sessionEmail) userId=\(session.user.id.uuidString.lowercased())")
            print("[AppleAuthDebug] routedToOnboarding=true")
            print("[FanSignupDebug] applePendingProfileCreation=true email=\(sessionEmail) userId=\(session.user.id.uuidString.lowercased())")
            presentAppleAuthMessage(
                "We found your Apple account. Finish setting up your FanGeo profile.",
                accountMode: .fan,
                isError: false,
                autoClearAfterSeconds: nil
            )
            return
        }

        guard await appleEnsureFanProfileExists(session: session, email: sessionEmail, fullName: fullName) else {
            return
        }

        guard await checkCurrentUserAdminStatus() else {
            await logAppleDeletedAccountBlockIfNeeded()
            return
        }

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            resetProfilePresentationLoadStateForNewAuth()
            currentUserEmail = sessionEmail
            currentUserDisplayName = Self.appleDisplayName(from: fullName)
            currentUserUsername = ""
            currentUserBio = ""
            currentUserIsBusinessAccount = false
            currentUserAvatarURL = ""
            currentUserAvatarThumbnailURL = ""
            isLoggedIn = true
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            currentUserAuthId = session.user.id
            authSessionState = .signedIn
            authErrorMessage = ""
            bumpCurrentUserAvatarDisplayRefresh()
        }

        guard await checkCurrentUserAdminStatus() else {
            await logAppleDeletedAccountBlockIfNeeded()
            return
        }

        await persistAccountModeForActiveAuthSession(.fanUser)
        clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        await registerFanActiveSessionOnLogin()
        Task { await refreshUserPersonalizationInBackground() }
    }

    private func finishAppleBusinessSignIn(
        session: Session,
        sessionEmail: String,
        fullName: PersonNameComponents?
    ) async {
        guard OwnerBusinessEmail.isValidStrict(sessionEmail) else {
            await forceLogout(reason: "appleBusinessMissingEmail", source: "MapViewModel.finishAppleBusinessSignIn")
            presentAppleAuthMessage(
                "Apple did not return a usable email address.",
                accountMode: .business,
                isError: true,
                autoClearAfterSeconds: 8
            )
            return
        }

        if await activeFanUserProfileExistsForEmail(sessionEmail) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
            return
        }

        if await shouldBlockBusinessOwnerLogin(sessionEmail: sessionEmail, userId: session.user.id) {
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run { venueAuthErrorMessage = Self.businessLoginBlockedBecauseFanMessage }
            return
        }

        guard await appleEnsureBusinessProfileExists(session: session, email: sessionEmail, fullName: fullName) else {
            return
        }

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            isVenueOwnerLoggedIn = true
            venueOwnerMode = true
            venueOwnerEmail = sessionEmail
            isLoggedIn = false
            currentUserEmail = ""
            venueAuthErrorMessage = ""
            venueOwnerJustCompletedRegistration = false
            currentUserAuthId = session.user.id
            authSessionState = .signedIn
        }

        await persistAccountModeForActiveAuthSession(.businessOwner)
        clearExplicitLogoutMarkerAfterManualAuthSucceeded()
        await refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        _ = await ensureBusinessOwnerSessionFlagsIfPossible(context: "after_apple_business_login")

        Task {
            await loadFavoriteVenuesFromSupabase()
            await refreshFollowingTabDataGlobally()
        }
    }

    private func presentAppleAuthMessage(
        _ message: String,
        accountMode: AppleAuthAccountMode,
        isError: Bool,
        autoClearAfterSeconds: UInt64?
    ) {
        switch accountMode {
        case .fan:
            appleAuthFanMessageAutoClearTask?.cancel()
            appleAuthFanMessage = message
            appleAuthFanMessageIsError = isError
        case .business:
            appleAuthBusinessMessageAutoClearTask?.cancel()
            appleAuthBusinessMessage = message
            appleAuthBusinessMessageIsError = isError
        }

        print("[AppleAuthDebug] errorPresented=\(isError)")

        guard let seconds = autoClearAfterSeconds else { return }
        print("[AppleAuthDebug] errorAutoClearScheduled=\(seconds)")
        let nanos = seconds * 1_000_000_000

        switch accountMode {
        case .fan:
            appleAuthFanMessageAutoClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    guard let self, self.appleAuthFanMessage == message else { return }
                    self.clearAppleAuthMessage(accountMode: .fan, reason: "autoClear")
                }
            }
        case .business:
            appleAuthBusinessMessageAutoClearTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: nanos)
                await MainActor.run {
                    guard let self, self.appleAuthBusinessMessage == message else { return }
                    self.clearAppleAuthMessage(accountMode: .business, reason: "autoClear")
                }
            }
        }
    }

    private func appleEnsureFanProfileExists(
        session: Session,
        email: String,
        fullName: PersonNameComponents?
    ) async -> Bool {
        do {
            let rows: [AppleExistingFanProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,is_deleted,admin_status")
                .eq("id", value: session.user.id)
                .limit(1)
                .execute()
                .value

            if rows.first != nil {
                print("[AppleAuthDebug] existingProfileFound=true")
                return true
            }

            print("[AppleAuthDebug] existingProfileFound=false")
            print("[AppleAuthDebug] profileMissing=true")
            print("[AppleAuthDebug] creatingNewProfile=true")

            let row = UserProfileBootstrapInsert(
                id: session.user.id,
                email: email,
                display_name: Self.appleDisplayName(from: fullName),
                bio: nil,
                avatar_url: "",
                avatar_thumbnail_url: nil,
                live_visibility_enabled: true,
                live_visibility_mode: LiveVisibilityMode.allFriends.rawValue,
                selected_live_visibility_friend_ids: [],
                discoverable_by_fans: true
            )

            try await supabase
                .from("user_profiles")
                .insert(row)
                .execute()

            print("[AppleAuthDebug] newAppleProfileCreated=true")
            print("[AppleAuthDebug] profileCreationSucceeded=true")
            return true
        } catch {
            print("[AppleAuthDebug] profileCreationFailed=\(error.localizedDescription)")
            print("[AppleAuthDebug] onboardingRequired=true")
            print("[AppleAuthDebug] routedToOnboarding=true")
            await forceLogout(reason: "appleFanProfileCreationFailed", source: "MapViewModel.appleEnsureFanProfileExists")
            presentAppleAuthMessage(
                "We found your Apple account. Finish setting up your FanGeo profile.",
                accountMode: .fan,
                isError: false,
                autoClearAfterSeconds: nil
            )
            return false
        }
    }

    private func appleCurrentFanProfileExists(session: Session) async -> Bool {
        do {
            let rows: [AppleExistingFanProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,is_deleted,admin_status")
                .eq("id", value: session.user.id)
                .limit(1)
                .execute()
                .value

            guard let row = rows.first else {
                print("[AppleAuthDebug] existingProfileFound=false")
                return false
            }

            print("[AppleAuthDebug] existingProfileFound=true")
            if row.is_deleted == true {
                await forceLogout(reason: "appleFanSignupDeletedProfile", source: "MapViewModel.appleCurrentFanProfileExists")
                await MainActor.run {
                    authErrorMessage = "This account has been deleted.\nContact support if you believe this was a mistake."
                }
                print("[AppleAuthDebug] accountBlockedDeleted=true")
                return true
            }
            return true
        } catch {
            print("[AppleAuthDebug] authError=\(error.localizedDescription)")
            return false
        }
    }

    private func appleEnsureBusinessProfileExists(
        session: Session,
        email: String,
        fullName: PersonNameComponents?
    ) async -> Bool {
        do {
            let rowsByUser: [BusinessRow] = try await supabase
                .from("businesses")
                .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
                .eq("owner_user_id", value: session.user.id)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value

            if rowsByUser.first != nil {
                print("[AppleAuthDebug] existingProfileFound=true")
                return true
            }

            let rowsByEmail: [BusinessRow] = try await supabase
                .from("businesses")
                .select("id,display_name,owner_email,owner_user_id,admin_status,created_at")
                .eq("owner_email", value: email)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value

            if rowsByEmail.first != nil {
                print("[AppleAuthDebug] existingProfileFound=true")
                return true
            }

            print("[AppleAuthDebug] existingProfileFound=false")
            print("[AppleAuthDebug] profileMissing=true")
            print("[AppleAuthDebug] creatingNewProfile=true")

            let payload = BusinessInsertPayload(
                display_name: Self.appleBusinessDisplayName(email: email, fullName: fullName),
                owner_email: email,
                owner_user_id: session.user.id,
                admin_status: "active"
            )

            try await supabase
                .from("businesses")
                .insert(payload)
                .execute()

            print("[AppleAuthDebug] newAppleProfileCreated=true")
            print("[AppleAuthDebug] profileCreationSucceeded=true")
            return true
        } catch {
            print("[AppleAuthDebug] profileCreationFailed=\(error.localizedDescription)")
            print("[AppleAuthDebug] onboardingRequired=true")
            print("[AppleAuthDebug] routedToOnboarding=true")
            await forceLogout(reason: "appleBusinessProfileCreationFailed", source: "MapViewModel.appleEnsureBusinessProfileExists")
            presentAppleAuthMessage(
                "Finish creating your account.",
                accountMode: .business,
                isError: false,
                autoClearAfterSeconds: nil
            )
            return false
        }
    }

    private func logAppleDeletedAccountBlockIfNeeded() async {
        let message = await MainActor.run { authErrorMessage }
        if message.localizedCaseInsensitiveContains("account has been deleted") {
            print("[AppleAuthDebug] accountBlockedDeleted=true")
        }
    }

    func appleFanProfileConflictExists(email: String, currentUserId: UUID) async -> Bool {
        do {
            let rows: [AppleExistingFanProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,is_deleted,admin_status")
                .eq("email", value: email)
                .limit(5)
                .execute()
                .value

            for row in rows {
                guard row.id != currentUserId else { continue }

                if row.is_deleted == true {
                    await forceLogout(reason: "appleFanEmailMatchesDeletedProfile", source: "MapViewModel.appleFanProfileConflictExists")
                    await MainActor.run {
                        authErrorMessage = "This account has been deleted.\nContact support if you believe this was a mistake."
                    }
                    print("[AppleAuthDebug] accountBlockedDeleted=true")
                    return true
                }

                let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if status == nil || status == "active" {
                    await forceLogout(reason: "appleFanDuplicateProfileEmail", source: "MapViewModel.appleFanProfileConflictExists")
                    await MainActor.run {
                        authErrorMessage = "A FanGeo account already exists for this email. Please sign in with that account first."
                    }
                    return true
                }
            }
        } catch {
            print("[AppleAuthDebug] authError=\(error.localizedDescription)")
        }

        return false
    }

    private static func appleDisplayName(from fullName: PersonNameComponents?) -> String {
        guard let fullName else { return "" }
        let formatter = PersonNameComponentsFormatter()
        let value = formatter.string(from: fullName).trimmingCharacters(in: .whitespacesAndNewlines)
        return value
    }

    private static func appleBusinessDisplayName(email: String, fullName: PersonNameComponents?) -> String {
        let name = appleDisplayName(from: fullName)
        if !name.isEmpty { return name }

        let prefix = email.split(separator: "@").first.map(String.init) ?? ""
        let cleaned = prefix
            .replacingOccurrences(of: ".", with: " ")
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Apple Business Account" : cleaned.capitalized
    }

    private static func logAppleIdentityTokenClaims(_ identityToken: String, rawNonce: String) {
        let parts = identityToken.split(separator: ".")
        guard parts.count >= 2,
              let payloadData = base64URLDecodedData(String(parts[1])),
              let json = try? JSONSerialization.jsonObject(with: payloadData) as? [String: Any] else {
            print("[AppleAuthDebug] identityTokenClaimsDecoded=false")
            return
        }

        let issuer = json["iss"] as? String ?? "nil"
        let audience: String = {
            if let value = json["aud"] as? String { return value }
            if let values = json["aud"] as? [String] { return values.joined(separator: ",") }
            return "nil"
        }()
        let subjectPresent = ((json["sub"] as? String)?.isEmpty == false)
        let expiresAt = json["exp"].map { "\($0)" } ?? "nil"
        let nonce = json["nonce"] as? String
        let hashedNonce = sha256(rawNonce)
        let email = json["email"] as? String
        let isRelay = email?.localizedCaseInsensitiveContains("privaterelay.appleid.com") == true
        let emailVerified = json["email_verified"].map { "\($0)" } ?? "nil"
        let isPrivateEmail = json["is_private_email"].map { "\($0)" } ?? "nil"

        print("[AppleAuthDebug] identityTokenClaimsDecoded=true")
        print("[AppleAuthDebug] identityTokenIssuer=\(issuer)")
        print("[AppleAuthDebug] identityTokenAudience=\(audience)")
        print("[AppleAuthDebug] identityTokenSubjectPresent=\(subjectPresent)")
        print("[AppleAuthDebug] identityTokenExpiresAt=\(expiresAt)")
        print("[AppleAuthDebug] identityTokenNonceExists=\(nonce != nil)")
        print("[AppleAuthDebug] identityTokenNonceMatchesRequest=\(nonce == hashedNonce)")
        print("[AppleAuthDebug] identityTokenEmailExists=\(email != nil)")
        print("[AppleAuthDebug] identityTokenRelayEmail=\(isRelay)")
        print("[AppleAuthDebug] identityTokenEmailVerified=\(emailVerified)")
        print("[AppleAuthDebug] identityTokenIsPrivateEmail=\(isPrivateEmail)")
    }

    private static func base64URLDecodedData(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: base64)
    }

    private static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.map { String(format: "%02x", $0) }.joined()
    }
}
