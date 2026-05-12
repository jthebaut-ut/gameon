import Foundation

// MARK: - Client-side text + spam (UX hints; server must still enforce)

extension ModerationService {

    /// Number of distinct reports after which a venue-event comment is hidden from public threads (client + DB column `is_moderation_hidden`).
    static let hiddenAfterReportsThreshold = 3

    /// Shown when ``containsProfanity(_:)`` is true.
    static func profanityRejectionUserMessage() -> String {
        "That wording isn’t allowed on FanGeo. Please remove profanity or slurs and try again."
    }

    /// Lowercase, strip diacritics, map common leet substitutions, keep only a–z and 0–9 for substring scans.
    static func normalizeModerationText(_ text: String) -> String {
        var s = text.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()

        let leet: [(String, String)] = [
            ("0", "o"), ("1", "i"), ("3", "e"), ("4", "a"), ("5", "s"),
            ("7", "t"), ("8", "b"), ("$", "s"), ("@", "a"), ("!", "i"),
            ("+", "t")
        ]
        for (a, b) in leet {
            s = s.replacingOccurrences(of: a, with: b)
        }

        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0) }
        return String(String.UnicodeScalarView(letters))
    }

    /// Tokenizes on non-alphanumeric then normalizes each token (leet + letters only per token).
    static func moderationTokens(from text: String) -> [String] {
        let parts = text.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        return parts.map { normalizeModerationText($0) }.filter { !$0.isEmpty }
    }

    /// Lightweight profanity / slur scan (no ML). Tuned to reduce obvious bypasses; not exhaustive.
    static func containsProfanity(_ text: String) -> Bool {
        let collapsed = normalizeModerationText(text)
        guard !collapsed.isEmpty else { return false }

        for w in Self.longProfanitySubstrings where w.count >= 4 {
            if collapsed.contains(w) { return true }
        }

        let tokens = Set(moderationTokens(from: text))
        for w in Self.shortProfanityTokens where tokens.contains(w) || collapsed == w {
            return true
        }

        return false
    }

    // Curated English offensive terms (lowercase, post-normalization where noted).
    private static let longProfanitySubstrings: [String] = [
        "fuck", "shit", "bitch", "bastard", "asshole", "motherfucker", "bullshit",
        "dickhead", "dickbag", "cocksuck", "pisshead", "douchebag", "jackass",
        "dumbass", "hardon", "jerkoff", "cumshot", "blowjob", "handjob",
        "faggot", "nigger", "nigga", "spic", "chink", "kike", "wetback", "retard"
    ]

    private static let shortProfanityTokens: Set<String> = [
        "fuk", "fck", "sht", "cnt", "dik", "twat", "slut", "whore", "piss", "crap"
    ]
}
