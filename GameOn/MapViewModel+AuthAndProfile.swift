import Foundation
import Supabase

// End-user Supabase Auth (sign up / sign in / session) and `user_profiles` load/save, avatar upload, and profile caching.

extension MapViewModel {

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
            }
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
            }

            await loadUserProfile()
            await loadFavoriteVenuesFromSupabase()
        } catch {
            await MainActor.run {
                isLoggedIn = false

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
            currentUserAvatarURL = UserDefaults.standard.string(forKey: "cachedUserAvatarURL") ?? ""
            currentUserAvatarThumbnailURL = UserDefaults.standard.string(forKey: "cachedUserAvatarThumbnailURL") ?? ""
        }
        do {
            let session = try await supabase.auth.session
            let email = session.user.email ?? ""

            await MainActor.run {
                currentUserEmail = email
                isLoggedIn = !email.isEmpty
                isVenueOwnerLoggedIn = false
                venueOwnerMode = false
            }

            await loadUserProfile()
            await loadFavoriteVenuesFromSupabase()

            print("SESSION RESTORED:", email)

        } catch {
            print("NO ACTIVE SESSION")
        }
    }

    // Fetches the row for the current user or venue-owner email into `currentUserDisplayName` / `currentUserAvatarURL`.
    func loadUserProfile() async {
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
                    currentUserAvatarURL = profile.avatar_url ?? ""
                    currentUserAvatarThumbnailURL = profile.avatar_thumbnail_url ?? ""
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

    // Upserts `user_profiles` and mirrors the result into published fields and `UserDefaults` cache.
    func saveUserProfile(displayName: String, avatarURL: String, avatarThumbnailURL: String? = nil) async {
        let email = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail

        guard !email.isEmpty else {
            print("NO USER EMAIL FOR PROFILE SAVE")
            return
        }

        do {
            let resolvedThumb: String? = {
                if let t = avatarThumbnailURL {
                    let x = t.trimmingCharacters(in: .whitespacesAndNewlines)
                    return x.isEmpty ? nil : x
                }
                let x = currentUserAvatarThumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
                return x.isEmpty ? nil : x
            }()

            let profile = UserProfileInsert(
                email: email,
                display_name: displayName,
                avatar_url: avatarURL,
                avatar_thumbnail_url: resolvedThumb
            )

            try await supabase
                .from("user_profiles")
                .upsert(profile, onConflict: "email")
                .execute()

            await MainActor.run {
                currentUserDisplayName = displayName
                currentUserAvatarURL = avatarURL
                currentUserAvatarThumbnailURL = resolvedThumb ?? ""
                cacheCurrentUserProfileLocally()
            }

            print("USER PROFILE SAVED")

        } catch {
            print("ERROR SAVING USER PROFILE:", error)
        }
    }

    /// Uploads full + thumbnail JPEGs to `user-avatars` (stable paths per email folder).
    func uploadUserAvatar(data: Data, fileName: String) async -> UploadedAvatarURLs? {
        let email = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail

        guard !email.isEmpty else {
            print("NO USER EMAIL FOR AVATAR UPLOAD")
            return nil
        }

        do {
            let safeEmail = email
                .lowercased()
                .replacingOccurrences(of: "@", with: "_")
                .replacingOccurrences(of: ".", with: "_")

            let pathFull = "\(safeEmail)/\(fileName)"
            let thumbName = Self.companionAvatarThumbnailFileName(for: fileName)
            let pathThumb = "\(safeEmail)/\(thumbName)"

            let oldFull = currentUserAvatarURL
            let oldThumb = currentUserAvatarThumbnailURL

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

            let fullStr = publicFull.absoluteString
            let thumbStr = publicThumb.absoluteString

            await deleteReplacedStorageObjectIfNeeded(oldPublicURL: oldFull, newPublicURL: fullStr, bucket: "user-avatars")
            await deleteReplacedStorageObjectIfNeeded(oldPublicURL: oldThumb, newPublicURL: thumbStr, bucket: "user-avatars")

            return UploadedAvatarURLs(fullURL: fullStr, thumbnailURL: thumbStr)

        } catch {
            print("ERROR UPLOADING USER AVATAR:", error)
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
