import Foundation
import LocalAuthentication

enum PrivateChatSecuritySettings {
    static let requireFaceIDSettingKey = "requireFaceIDForPrivateChat"
}

/// Local device authentication before showing private chat (Face ID, Touch ID, or device passcode via ``LAPolicy/deviceOwnerAuthentication``).
@MainActor
enum PrivateChatAccessGate {

    enum Outcome: Equatable {
        case granted
        /// User canceled, failed match, or system error during evaluation.
        case authenticationFailed
        /// ``LAContext/canEvaluatePolicy`` is false (e.g. no passcode set) — treat as blocked for privacy.
        case deviceSecurityNotConfigured
    }

    /// User-visible when ``evaluatePolicy`` fails or user cancels.
    static let authenticationFailedMessage = "Authentication required to view private messages."

    /// User-visible when the device cannot evaluate passcode/biometric policy.
    static let noPasscodeMessage = "Set a device passcode to protect private messages."

    /// Runs local authentication on the main actor (recommended for ``LAContext``). Does not touch Supabase.
    static func authenticateForPrivateChat() async -> Outcome {
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedFallbackTitle = "Use Passcode"

        var policyError: NSError?
        let canEvaluate = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &policyError)
        guard canEvaluate else {
            return .deviceSecurityNotConfigured
        }

        let reason = "Authenticate to view your private messages."
        do {
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return success ? .granted : .authenticationFailed
        } catch {
            return .authenticationFailed
        }
    }
}
