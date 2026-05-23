import Foundation
import Supabase

// MARK: - Fan vs business owner email exclusivity (auth-time only; no UI changes)

extension MapViewModel {

    static let fanLoginBlockedBecauseBusinessMessage =
        "This email is linked to a business account. Please sign in using Business owner access."

    static let businessLoginBlockedBecauseFanMessage =
        "This email is linked to a regular FanGeo account. Please sign in using Fan account access."

    /// `businesses` rows that reserve an email / auth uid for the business-owner surface (not fan login).
    private static let businessLifecycleAdminStatusesForGate: [String] = ["active", "archived", "disabled"]

    /// Signs out and clears local session flags after a successful Supabase password sign-in that must be rejected for account-type mismatch.
    func undoPartialSupabaseSessionAfterAccountTypeMismatch() async {
#if DEBUG
        print("[AuthStateDebug] forcedLogoutReason=accountTypeMismatch")
#endif
        do {
            try await supabase.auth.signOut()
        } catch {
#if DEBUG
            print("[AuthAccountTypeGate] signOut after mismatch failed: \(error.localizedDescription)")
#endif
        }

        await MainActor.run {
            clearAuthenticatedSessionCaches()
            clearVenueOwnerDraftState()
            isLoggedIn = false
            isVenueOwnerLoggedIn = false
            venueOwnerMode = false
            isAdminLoggedIn = false
            authSessionState = .signedOut
#if DEBUG
            print("[AuthStateDebug] authStateTransition=accountTypeMismatch->signedOut")
#endif
        }
        clearPersistedAccountMode()
    }

    /// Any `businesses` row for this email with a reserved lifecycle status (no auth uid required).
    func businessAccountExistsForOwnerEmailOnly(_ email: String) async -> Bool {
        let e = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(e) else { return false }

        struct BusinessGateRow: Decodable {
            let id: UUID
        }

        do {
            let byEmail: [BusinessGateRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_email", value: e)
                .in("admin_status", values: Self.businessLifecycleAdminStatusesForGate)
                .limit(1)
                .execute()
                .value
            return !byEmail.isEmpty
        } catch {
#if DEBUG
            print("[AuthAccountTypeGate] businessAccountExistsForOwnerEmailOnly query failed email=\(e):", error)
#endif
            return false
        }
    }

    /// Any `businesses` row tied to this email or auth user with a reserved lifecycle status.
    func businessAccountExistsForOwnerEmailOrUserId(email: String, userId: UUID) async -> Bool {
        let e = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(e) else { return false }

        struct BusinessGateRow: Decodable {
            let id: UUID
        }

        do {
            let byEmail: [BusinessGateRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_email", value: e)
                .in("admin_status", values: Self.businessLifecycleAdminStatusesForGate)
                .limit(1)
                .execute()
                .value
            if !byEmail.isEmpty { return true }

            let byUser: [BusinessGateRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_user_id", value: userId)
                .in("admin_status", values: Self.businessLifecycleAdminStatusesForGate)
                .limit(1)
                .execute()
                .value
            return !byUser.isEmpty
        } catch {
#if DEBUG
            print("[AuthAccountTypeGate] businessAccountExistsForOwnerEmailOrUserId query failed email=\(e):", error)
#endif
            return false
        }
    }

    /// True when a fan-style `user_profiles` row exists for this normalized email (active, not marked business-only identity).
    func activeFanUserProfileExistsForEmail(_ email: String) async -> Bool {
        let e = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(e) else { return false }

        if await businessAccountExistsForOwnerEmailOnly(e) {
            return false
        }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,admin_status")
                .eq("email", value: e)
                .eq("admin_status", value: "active")
                .limit(5)
                .execute()
                .value
            return !rows.isEmpty
        } catch {
#if DEBUG
            print("[AuthAccountTypeGate] activeFanUserProfileExistsForEmail query failed email=\(e):", error)
#endif
            return false
        }
    }

    /// True when the signed-in user has an active `user_profiles` row and no qualifying `businesses` row (fan-only session).
    func shouldBlockBusinessOwnerLogin(sessionEmail: String, userId: UUID) async -> Bool {
        let e = OwnerBusinessEmail.normalized(sessionEmail)
        guard OwnerBusinessEmail.isValidStrict(e) else { return false }

        if await businessAccountExistsForOwnerEmailOrUserId(email: e, userId: userId) {
            return false
        }

        do {
            let rows: [UserProfileRow] = try await supabase
                .from("user_profiles")
                .select("id,email,admin_status")
                .eq("id", value: userId)
                .eq("admin_status", value: "active")
                .limit(1)
                .execute()
                .value
            guard rows.first != nil else { return false }
            return true
        } catch {
#if DEBUG
            print("[AuthAccountTypeGate] shouldBlockBusinessOwnerLogin profile query failed uid=\(userId):", error)
#endif
            return false
        }
    }
}
