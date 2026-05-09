import Foundation

/// Picks which stored image URL to load for list vs detail surfaces (thumbnail-first with safe fallbacks).
enum ImageDisplayURL {

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Maps, cards, stacks, chat rows: prefer thumbnail when present.
    static func forList(thumbnail: String?, full: String?) -> String? {
        nonEmpty(thumbnail) ?? nonEmpty(full)
    }

    /// Full-bleed / owner verification: prefer full-size when present.
    static func forDetail(thumbnail: String?, full: String?) -> String? {
        nonEmpty(full) ?? nonEmpty(thumbnail)
    }
}
