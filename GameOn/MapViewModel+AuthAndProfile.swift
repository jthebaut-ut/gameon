import Foundation
import Supabase

// End-user Supabase Auth (sign up / sign in / session) and `user_profiles` load/save, avatar upload, and profile caching.

extension MapViewModel {

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
                goingUserProfiles = []

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
                goingUserProfiles = []

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
                goingUserProfiles = []

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
                .select()
                .eq("email", value: email)
                .limit(1)
                .execute()
                .value

            if let profile = rows.first {
                await MainActor.run {
                    currentUserDisplayName = profile.display_name ?? ""
                    currentUserAvatarURL = profile.avatar_url ?? ""
                    cacheCurrentUserProfileLocally()
                }

                print("USER PROFILE LOADED")
            } else {
                await MainActor.run {
                    currentUserDisplayName = ""
                    currentUserAvatarURL = ""
                }

                print("NO USER PROFILE FOUND")
            }

        } catch {
            print("ERROR LOADING USER PROFILE:", error)
        }
    }

    // Upserts `user_profiles` and mirrors the result into published fields and `UserDefaults` cache.
    func saveUserProfile(displayName: String, avatarURL: String) async {
        let email = !currentUserEmail.isEmpty ? currentUserEmail : venueOwnerEmail

        guard !email.isEmpty else {
            print("NO USER EMAIL FOR PROFILE SAVE")
            return
        }

        do {
            let profile = UserProfileInsert(
                email: email,
                display_name: displayName,
                avatar_url: avatarURL
            )

            try await supabase
                .from("user_profiles")
                .upsert(profile, onConflict: "email")
                .execute()

            await MainActor.run {
                currentUserDisplayName = displayName
                currentUserAvatarURL = avatarURL
                cacheCurrentUserProfileLocally()
            }

            print("USER PROFILE SAVED")

        } catch {
            print("ERROR SAVING USER PROFILE:", error)
        }
    }

    // Uploads a compressed JPEG to the `user-avatars` bucket; returns the public URL for storing on the profile.
    // - Important: Path is unique per user id (App Store-friendly). Old avatar is deleted after replacement when possible.
    func uploadUserAvatar(data: Data, fileName: String) async -> String? {
        do {
            let session = try await supabase.auth.session
            let userId = session.user.id.uuidString.lowercased()

            let uploadData = ImageCompression.jpegDataForUpload(from: data, preset: .avatar)

            // Unique per upload so we can safely delete old objects later.
            let objectPath = "\(userId)/avatar-\(UUID().uuidString.lowercased()).jpg"

            try await supabase.storage
                .from("user-avatars")
                .upload(
                    objectPath,
                    data: uploadData,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: false
                    )
                )

            let publicURL = try supabase.storage
                .from("user-avatars")
                .getPublicURL(path: objectPath)

            return publicURL.absoluteString
        } catch {
            print("ERROR UPLOADING USER AVATAR:", error)
            return nil
        }
    }

    /// Attempts to delete a previously uploaded user avatar object from Storage.
    /// TODO: Consider storing the exact storage path in `user_profiles` to avoid URL parsing.
    func deleteUserAvatarIfPossible(previousAvatarURL: String) async {
        let trimmed = previousAvatarURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let objectPath = Self.storageObjectPathFromPublicURL(trimmed, bucket: "user-avatars") else { return }
        do {
            _ = try await supabase.storage
                .from("user-avatars")
                .remove(paths: [objectPath])
        } catch {
#if DEBUG
            print("AvatarDelete: failed (non-fatal):", error)
#endif
        }
    }

    private static func storageObjectPathFromPublicURL(_ urlString: String, bucket: String) -> String? {
        // Expected format:
        // .../storage/v1/object/public/<bucket>/<path>
        guard let url = URL(string: urlString) else { return nil }
        let path = url.path
        let needle = "/object/public/\(bucket)/"
        guard let range = path.range(of: needle) else { return nil }
        let object = String(path[range.upperBound...])
        return object.isEmpty ? nil : object
    }

    // Batch-loads display names/avatars for a set of emails (e.g. “who’s going”) into `userProfilesByEmail`.
    func loadUserProfilesForEmails(_ emails: [String]) async {
        let uniqueEmails = Array(Set(emails)).filter { !$0.isEmpty }

        guard !uniqueEmails.isEmpty else { return }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select()
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
