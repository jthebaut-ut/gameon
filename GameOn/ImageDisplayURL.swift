import Foundation

/// Picks which stored image URL to load for list vs detail surfaces (thumbnail-first with safe fallbacks).
nonisolated enum ImageDisplayURL {

    private static func nonEmpty(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// Strips query and fragment so persisted Supabase / profile URLs stay stable (no cache-busting saved to DB).
    static func canonicalStorageURLString(_ raw: String?) -> String {
        guard let raw else { return "" }
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        guard var comp = URLComponents(string: t) else { return t }
        comp.query = nil
        comp.fragment = nil
        return comp.string ?? t
    }

    /// Appends a display-only cache-bust query; use with ``MapViewModel/currentUserAvatarDisplayRefreshToken`` so `AsyncImage` refetches after replace-in-place uploads.
    static func displayVersionedURLString(_ canonical: String, refreshToken: UUID) -> String {
        let c = canonical.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !c.isEmpty else { return c }
        let sep = c.contains("?") ? "&" : "?"
        return "\(c)\(sep)v=\(refreshToken.uuidString)"
    }

    /// Maps, cards, stacks, chat rows: prefer thumbnail when present.
    static func forList(thumbnail: String?, full: String?) -> String? {
        nonEmpty(thumbnail) ?? nonEmpty(full)
    }

    /// Full-bleed / owner verification: prefer full-size when present.
    static func forDetail(thumbnail: String?, full: String?) -> String? {
        nonEmpty(full) ?? nonEmpty(thumbnail)
    }

    static func forListDisplay(thumbnail: String?, full: String?, refreshToken: UUID) -> String? {
        let ct = canonicalStorageURLString(thumbnail)
        let cf = canonicalStorageURLString(full)
        let empty = ""
        guard let base = forList(
            thumbnail: ct == empty ? nil : ct,
            full: cf == empty ? nil : cf
        ) else { return nil }
        return displayVersionedURLString(base, refreshToken: refreshToken)
    }

    static func forDetailDisplay(thumbnail: String?, full: String?, refreshToken: UUID) -> String? {
        let ct = canonicalStorageURLString(thumbnail)
        let cf = canonicalStorageURLString(full)
        let empty = ""
        guard let base = forDetail(
            thumbnail: ct == empty ? nil : ct,
            full: cf == empty ? nil : cf
        ) else { return nil }
        return displayVersionedURLString(base, refreshToken: refreshToken)
    }

    static func displayURLs(thumbnail: String?, full: String?, refreshToken: UUID) -> [URL] {
        [
            forListDisplay(thumbnail: thumbnail, full: full, refreshToken: refreshToken),
            forDetailDisplay(thumbnail: thumbnail, full: full, refreshToken: refreshToken)
        ]
        .compactMap { $0 }
        .compactMap(URL.init(string:))
    }
}
