import Foundation

/// Validation and display helpers for public FanGeo @handles (stored without `@`, lowercase).
enum FanGeoHandleRules {
    static let minLength = 3
    static let maxLength = 20

    enum ValidationIssue: Equatable {
        case tooShortOrLong
        case invalidCharacters
        case edgePeriod
        case consecutiveSpecialCharacters
    }

    /// Strips leading `@`, lowercases, trims — value persisted in `user_profiles.username`.
    static func normalizeForStorage(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("@") {
            s.removeFirst()
        }
        return s.lowercased()
    }

    static func validate(_ raw: String) -> ValidationIssue? {
        let stored = normalizeForStorage(raw)
        guard stored.count >= minLength, stored.count <= maxLength else {
            return .tooShortOrLong
        }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_.")
        guard stored.unicodeScalars.allSatisfy({ allowed.contains($0) }) else {
            return .invalidCharacters
        }
        if stored.hasPrefix(".") || stored.hasSuffix(".") {
            return .edgePeriod
        }
        if stored.contains("..") || stored.contains("__") || stored.contains("._") || stored.contains("_.") {
            return .consecutiveSpecialCharacters
        }
        return nil
    }

    static func validationMessage(for issue: ValidationIssue) -> String {
        switch issue {
        case .tooShortOrLong:
            return "Handle must be 3–20 characters."
        case .invalidCharacters:
            return "Use only letters, numbers, underscores, or periods."
        case .edgePeriod:
            return "Handle cannot start or end with a period."
        case .consecutiveSpecialCharacters:
            return "Avoid consecutive periods or underscores."
        }
    }

    /// Public UI line with `@` prefix from stored handle.
    static func displayHandle(stored: String) -> String {
        let n = normalizeForStorage(stored)
        guard !n.isEmpty else { return "" }
        return "@\(n)"
    }

    /// Temporary UI-only fallback when `username` is unset — never persist from this helper.
    static func temporaryFallbackHandle(email: String) -> String {
        let local = OwnerBusinessEmail.normalized(email)
            .split(separator: "@")
            .first
            .map(String.init) ?? ""
        guard !local.isEmpty else { return "@fan" }
        return "@\(local.lowercased())"
    }

    static func publicHandleLine(storedUsername: String?, email: String) -> String {
        let stored = storedUsername?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !stored.isEmpty {
            return displayHandle(stored: stored)
        }
        // Fallback only — not saved as username.
        return temporaryFallbackHandle(email: email)
    }
}
