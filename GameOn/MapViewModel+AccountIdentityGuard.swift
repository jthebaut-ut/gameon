import Foundation
import Supabase

enum AccountIdentityType: String {
    case fan
    case business
}

private struct AccountIdentityClaimParams: Encodable {
    let p_account_type: String
}

private struct AccountIdentityClaimRow: Decodable {
    let account_type: String
    let email: String
    let account_id: UUID
}

extension MapViewModel {
    @discardableResult
    func claimAccountIdentity(
        _ accountType: AccountIdentityType,
        context: String
    ) async -> Bool {
        do {
            let rows: [AccountIdentityClaimRow] = try await supabase
                .rpc(
                    "claim_account_type",
                    params: AccountIdentityClaimParams(p_account_type: accountType.rawValue)
                )
                .execute()
                .value
#if DEBUG
            if let row = rows.first {
                print("[AuthAccountTypeGuard] claimed type=\(row.account_type) email=\(row.email) accountId=\(row.account_id.uuidString.lowercased()) context=\(context)")
            } else {
                print("[AuthAccountTypeGuard] claimedEmptyResult type=\(accountType.rawValue) context=\(context)")
            }
#endif
            return true
        } catch {
            let message = Self.accountIdentityUserMessage(for: error, attemptedType: accountType)
#if DEBUG
            print("[AuthAccountTypeGuard] claimFailed type=\(accountType.rawValue) context=\(context) error=\(error.localizedDescription)")
#endif
            await undoPartialSupabaseSessionAfterAccountTypeMismatch()
            await MainActor.run {
                switch accountType {
                case .fan:
                    authErrorMessage = message
                case .business:
                    venueAuthErrorMessage = message
                }
            }
            return false
        }
    }

    static func accountIdentityUserMessage(
        for error: Error,
        attemptedType: AccountIdentityType
    ) -> String {
        let text = Self.accountIdentityErrorText(error)

        if text.contains("please verify your email") {
            return "Please verify your email before continuing."
        }
        if text.contains("email already used for a fan account")
            || text.contains("already claimed as a fan account") {
            return attemptedType == .business
                ? "Email already used for a Fan account. Please use a different email for Business access."
                : "Email already used for a Fan account."
        }
        if text.contains("email already used for a business account")
            || text.contains("already claimed as a business account") {
            return attemptedType == .fan
                ? "Email already used for a Business account. Please sign in with that account type or use a different email for Fan access."
                : "Email already used for a Business account."
        }

        switch attemptedType {
        case .fan:
            return "Could not verify this email for Fan access. Please try again."
        case .business:
            return "Could not verify this email for Business access. Please try again."
        }
    }

    private static func accountIdentityErrorText(_ error: Error) -> String {
        let ns = error as NSError
        var parts = [
            error.localizedDescription,
            ns.domain,
            "\(ns.code)"
        ]
        if let postgrest = error as? PostgrestError {
            parts.append(postgrest.code ?? "")
            parts.append(postgrest.message)
            parts.append(postgrest.detail ?? "")
            parts.append(postgrest.hint ?? "")
        }
        return parts.joined(separator: " ").lowercased()
    }
}
