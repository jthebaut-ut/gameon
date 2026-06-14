import Foundation
import Supabase

// MARK: - Fan vs business owner email exclusivity (auth-time only; no UI changes)

extension MapViewModel {

    static let fanLoginBlockedBecauseBusinessMessage =
        "This email is linked to a business account. Please sign in using Business owner access."

    static let businessLoginBlockedBecauseFanMessage =
        "This email is linked to a regular FanGeo account. Please sign in using Fan account access."

    static let businessSignupBlockedBecauseFanMessage =
        "This email is already used by a Fan account. Please sign in and add a Business Profile, or use a different business email."

    static let businessSignupBlockedBecauseAppleAuthMessage =
        "This email is already connected with Apple Sign-In. Continue with Apple or use a different business email."

    /// `businesses` rows that reserve an email / auth uid for the business-owner surface (not fan login).
    private static let businessLifecycleAdminStatusesForGate: [String] = ["active", "archived", "disabled"]

    /// Signs out and clears local session flags after a successful Supabase password sign-in that must be rejected for account-type mismatch.
    func undoPartialSupabaseSessionAfterAccountTypeMismatch() async {
        await forceLogout(reason: "accountTypeMismatch", source: "MapViewModel.undoPartialSupabaseSessionAfterAccountTypeMismatch")
    }

    private struct BusinessSignupEmailConflictParams: Encodable {
        let p_email: String
    }

    private struct BusinessSignupEmailConflictRow: Decodable {
        let conflict_type: String
        let account_type: String?
        let auth_provider: String?
    }

    private enum BusinessSignupEmailConflict {
        case none
        case fan
        case business
        case appleAuth
        case existingAuth
        case invalidEmail

        var reason: String {
            switch self {
            case .none: return "none"
            case .fan: return "fan_account"
            case .business: return "business_account"
            case .appleAuth: return "apple_auth"
            case .existingAuth: return "existing_auth"
            case .invalidEmail: return "invalid_email"
            }
        }

        var message: String? {
            switch self {
            case .none:
                return nil
            case .fan:
                return MapViewModel.businessSignupBlockedBecauseFanMessage
            case .business:
                return "A business account already exists for this email. Please sign in."
            case .appleAuth:
                return MapViewModel.businessSignupBlockedBecauseAppleAuthMessage
            case .existingAuth:
                return "This email is already in use. Please sign in or use a different email."
            case .invalidEmail:
                return OwnerBusinessEmail.invalidOwnerEmailUserMessage
            }
        }
    }

    private func businessSignupEmailConflict(for email: String) async -> BusinessSignupEmailConflict? {
        let e = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(e) else { return .invalidEmail }

        do {
            let rows: [BusinessSignupEmailConflictRow] = try await supabase
                .rpc(
                    "business_signup_email_conflict",
                    params: BusinessSignupEmailConflictParams(p_email: e)
                )
                .execute()
                .value

            guard let row = rows.first else {
                print("[BusinessAccountConflict] email=\(e) conflict=none_empty_result")
                return BusinessSignupEmailConflict.none
            }

            let conflict: BusinessSignupEmailConflict
            switch row.conflict_type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "none":
                conflict = BusinessSignupEmailConflict.none
            case "fan_account":
                conflict = .fan
            case "business_account":
                conflict = .business
            case "apple_auth":
                conflict = .appleAuth
            case "existing_auth":
                conflict = .existingAuth
            case "invalid_email":
                conflict = .invalidEmail
            default:
                conflict = .existingAuth
            }

            print("[BusinessAccountConflict] email=\(e) conflict=\(conflict.reason) account_type=\(row.account_type ?? "nil") auth_provider=\(row.auth_provider ?? "nil")")
            return conflict
        } catch {
            print("[BusinessAccountConflict] email=\(e) conflict_check_failed error=\(error.localizedDescription)")
            return nil
        }
    }

    func blockBusinessSignupIfEmailAlreadyReserved(_ email: String) async -> Bool {
        let e = OwnerBusinessEmail.normalized(email)

        if let conflict = await businessSignupEmailConflict(for: e) {
            guard let message = conflict.message else { return false }
            await MainActor.run { venueAuthErrorMessage = message }
            return true
        }

        if await activeFanUserProfileExistsForEmail(e) {
            print("[BusinessAccountConflict] email=\(e) conflict=fan_account source=user_profiles_fallback")
            await MainActor.run { venueAuthErrorMessage = Self.businessSignupBlockedBecauseFanMessage }
            return true
        }

        return false
    }

    func businessSignupStep1EmailConflictMessage(for email: String) async -> String? {
        let e = OwnerBusinessEmail.normalized(email)
        guard OwnerBusinessEmail.isValidStrict(e) else {
            print("[BusinessSignupStep1EmailCheck] email=\(e) conflict=invalid_email")
            return OwnerBusinessEmail.invalidOwnerEmailUserMessage
        }

        if let conflict = await businessSignupEmailConflict(for: e) {
            print("[BusinessSignupStep1EmailCheck] email=\(e) conflict=\(conflict.reason)")
            return conflict.message
        }

        if await activeFanUserProfileExistsForEmail(e) {
            print("[BusinessSignupStep1EmailCheck] email=\(e) conflict=fan_account source=user_profiles_fallback")
            return Self.businessSignupBlockedBecauseFanMessage
        }

        print("[BusinessSignupStep1EmailCheck] email=\(e) conflict=none")
        return nil
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
                .in("business_origin", values: BusinessOrigin.loginOwnedValues)
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
                .in("business_origin", values: BusinessOrigin.loginOwnedValues)
                .limit(1)
                .execute()
                .value
            if !byEmail.isEmpty { return true }

            let byUser: [BusinessGateRow] = try await supabase
                .from("businesses")
                .select("id")
                .eq("owner_user_id", value: userId)
                .in("admin_status", values: Self.businessLifecycleAdminStatusesForGate)
                .in("business_origin", values: BusinessOrigin.loginOwnedValues)
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
