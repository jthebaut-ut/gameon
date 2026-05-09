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
    func uploadUserAvatar(data: Data, fileName: String) async -> String? {
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

            let path = "\(safeEmail)/\(fileName)"

            let uploadData = ImageCompression.jpegDataForUpload(from: data, preset: .avatar)

            try await supabase.storage
                .from("user-avatars")
                .upload(
                    path,
                    data: uploadData,
                    options: FileOptions(
                        contentType: "image/jpeg",
                        upsert: true
                    )
                )

            let publicURL = try supabase.storage
                .from("user-avatars")
                .getPublicURL(path: path)

            return publicURL.absoluteString

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
}
