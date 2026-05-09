import Foundation
import Supabase

// End-user Supabase Auth (sign up / sign in / session) and `user_profiles` load/save, avatar upload, and profile caching.

extension MapViewModel {

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

        let emailFromSession = session.user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let emailForRow: String
        if !emailFromSession.isEmpty {
            emailForRow = emailFromSession
        } else {
            let fallback = await MainActor.run {
                currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func registerUser(email: String, password: String) async {
        do {
            _ = try await supabase.auth.signUp(
                email: email,
                password: password
            )

            await MainActor.run {
                currentUserEmail = email
                currentUserDisplayName = ""
                currentUserAvatarURL = ""
                currentUserAvatarThumbnailURL = ""
                goingUserProfiles = []
                goingProfilesByVenueEventID = [:]

                isLoggedIn = true
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                venueOwnerEmail = ""
                bumpCurrentUserAvatarDisplayRefresh()
                clearFollowingTabCaches()
            }
            if let session = try? await supabase.auth.session {
                await MainActor.run { currentUserAuthId = session.user.id }
            }

            await ensureUserProfileExists()
            await loadUserProfile()
        } catch {
            print("User registration failed:", error)
        }
    }

    func loginUser(email: String, password: String) async {
        do {
            _ = try await supabase.auth.signIn(
                email: email,
                password: password
            )

            await MainActor.run {
                currentUserEmail = email
                currentUserDisplayName = ""
                currentUserAvatarURL = ""
                currentUserAvatarThumbnailURL = ""
                goingUserProfiles = []
                goingProfilesByVenueEventID = [:]

                isLoggedIn = true
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                venueOwnerEmail = ""

                authErrorMessage = ""
                bumpCurrentUserAvatarDisplayRefresh()
                clearFollowingTabCaches()
            }

            if let session = try? await supabase.auth.session {
                await MainActor.run { currentUserAuthId = session.user.id }
            }

            await ensureUserProfileExists()
            await loadUserProfile()
            await loadFavoriteVenuesFromSupabase()
            await refreshFollowingTabDataGlobally()
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

    func logoutUser() async {
        do {
            try await supabase.auth.signOut()

            await MainActor.run {
                currentUserEmail = ""
                currentUserDisplayName = ""
                currentUserAvatarURL = ""
                currentUserAvatarThumbnailURL = ""
                goingUserProfiles = []
                goingProfilesByVenueEventID = [:]

                isLoggedIn = false
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                venueOwnerEmail = ""
                bumpCurrentUserAvatarDisplayRefresh()
                clearFollowingTabCaches()
                currentUserAuthId = nil
            }
        } catch {
            print("Logout failed:", error)
        }
    }

    func hasValidSession() async -> Bool {

        do {
            _ = try await supabase.auth.session
            return true
        } catch {
            return false
        }
    }

    // Called on app launch (`MainTabView`): restores cached display fields, reads Supabase session, then loads profile and favorites when logged in.
    func restoreSession() async {
        await MainActor.run {
            currentUserDisplayName = UserDefaults.standard.string(forKey: "cachedUserDisplayName") ?? ""
            currentUserAvatarURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarURL"))
            currentUserAvatarThumbnailURL = ImageDisplayURL.canonicalStorageURLString(UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL"))
        }
        do {
            let session = try await supabase.auth.session
            let email = session.user.email ?? ""

            await MainActor.run {
                currentUserEmail = email
                isLoggedIn = !email.isEmpty
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
                currentUserAuthId = session.user.id
            }

            await ensureUserProfileExists()
            await loadUserProfile()
            await loadFavoriteVenuesFromSupabase()
            await refreshFollowingTabDataGlobally()

            print("SESSION RESTORED:", email)

        } catch {
            await MainActor.run { currentUserAuthId = nil }
            print("NO ACTIVE SESSION")
        }
    }

    // Fetches the row for the current user by `auth.uid` when a session exists; otherwise falls back to email (e.g. venue-owner context without fan session).
    func loadUserProfile() async {
        if let session = try? await supabase.auth.session {
            let authId = session.user.id
            do {
                let rows: [UserProfileRow] = try await supabase
                    .from("user_profiles")
                    .select("id,email,display_name,avatar_url,avatar_thumbnail_url")
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
                .select("id,email,display_name,avatar_url,avatar_thumbnail_url")
                .eq("email", value: email)
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
        let emailFromSession = session.user.email?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let emailForRow: String
        if !emailFromSession.isEmpty {
            emailForRow = emailFromSession
        } else {
            let fallback = currentUserEmail.trimmingCharacters(in: .whitespacesAndNewlines)
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
            return "Couldn’t save your profile. Please try again."
        }
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
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,display_name,avatar_url,avatar_thumbnail_url")
                .in("email", values: uniqueEmails)
                .execute()
                .value

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
