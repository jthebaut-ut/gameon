import Foundation

/// Canonical formatting and strict validation for business-owner / `owner_email` paths (Supabase auth, `businesses`, `venue_claims`, `venues`).
nonisolated enum OwnerBusinessEmail {
    /// Trim whitespace and lowercase (use for all saves and `.eq("owner_email", …)` queries).
    static func normalized(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static let invalidOwnerEmailUserMessage = "Enter a valid email address (example: name@domain.com)."

    /// Requires `@`, a dot in the domain segment (TLD), and no whitespace anywhere in the string after trim.
    static func isValidStrict(_ normalized: String) -> Bool {
        guard !normalized.isEmpty else { return false }
        if normalized.contains(where: { $0.isWhitespace }) { return false }
        guard let atIdx = normalized.firstIndex(of: "@") else { return false }
        let local = normalized[..<atIdx]
        guard !local.isEmpty else { return false }
        let domain = normalized[normalized.index(after: atIdx)...]
        guard !domain.isEmpty else { return false }
        if domain.contains("@") { return false }
        guard let dotIdx = domain.firstIndex(of: ".") else { return false }
        let tld = domain[domain.index(after: dotIdx)...]
        return !tld.isEmpty
    }
}
