import Foundation

/// Single source of truth for sport **strings** used in Calendar filters, pickup/venue pickers, analytics, and Supabase payloads.
/// Chip colors, SF Symbols, and search aliases live in ``SportFilterCatalog`` (SwiftUI).
public enum AppSportCatalog {

    // MARK: - Grouped catalog (Discover “More”, pickup game form, venue Manage Games)

    /// Shared grouped sport model: fixed category order and row order inside each section.
    /// Row ``selection`` is the stored DB / filter token; ``label`` is novice-facing display text.
    public enum SportCatalog {
        public struct Category: Identifiable, Hashable {
            public let id: String
            public let title: String
            public let rows: [(label: String, selection: String)]

            public func hash(into hasher: inout Hasher) {
                hasher.combine(id)
            }

            public static func == (lhs: Category, rhs: Category) -> Bool {
                lhs.id == rhs.id
            }
        }

        /// Same sections as historical Discover “More”, expanded with additional sports (novice-friendly).
        public static let groupedCategories: [Category] = [
            Category(id: "motorsports", title: "Motorsports", rows: [
                ("Formula 1", "Formula 1"),
                ("NASCAR", "NASCAR"),
                ("MotoGP", "MotoGP"),
                ("Motocross", "Motocross"),
            ]),
            Category(id: "action", title: "Action", rows: [
                ("Climbing", "Climbing"),
                ("Skateboarding", "Skateboarding"),
                ("Boxing", "Boxing"),
                ("MMA / UFC", "UFC"),
                ("Wrestling", "Wrestling"),
            ]),
            Category(id: "indoor", title: "Indoor", rows: [
                ("Bowling", "Bowling"),
                ("Handball", "Handball"),
                ("Esports", "Esports"),
                ("Ping Pong", "Ping Pong"),
                ("Pickleball", "Pickleball"),
            ]),
            Category(id: "water_winter", title: "Water/Winter", rows: [
                ("Swimming", "Swimming"),
                ("Skiing", "Skiing"),
            ]),
            Category(id: "endurance", title: "Running & cycling", rows: [
                ("Running", "Running"),
                ("Cycling", "Cycling"),
                ("Track & Field", "Track & Field"),
            ]),
            Category(id: "team", title: "Team Sports", rows: [
                ("Soccer", "Soccer"),
                ("Basketball", "NBA"),
                ("Football", "NFL"),
                ("Baseball", "Baseball"),
                ("Hockey", "NHL"),
                ("Golf", "Golf"),
                ("Tennis", "Tennis"),
                ("Volleyball", "Volleyball"),
                ("Cricket", "Cricket"),
                ("Rugby", "Rugby"),
                ("Softball", "Softball"),
                ("Lacrosse", "Lacrosse"),
            ]),
        ]

        /// Deduped selection tokens in category order (no `All`).
        public static var groupedSelectionTokensOrdered: [String] {
            var seen = Set<String>()
            var out: [String] = []
            out.reserveCapacity(48)
            for category in groupedCategories {
                for row in category.rows where seen.insert(row.selection).inserted {
                    out.append(row.selection)
                }
            }
            return out
        }

        /// Search filter for grouped sheets (category title + row label/selection).
        public static func filteredCategories(query raw: String) -> [Category] {
            let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !q.isEmpty else { return groupedCategories }
            return groupedCategories.compactMap { category in
                if category.title.localizedCaseInsensitiveContains(q) {
                    return category
                }
                let rows = category.rows.filter { row in
                    row.label.localizedCaseInsensitiveContains(q)
                        || row.selection.localizedCaseInsensitiveContains(q)
                }
                if rows.isEmpty { return nil }
                return Category(id: category.id, title: category.title, rows: rows)
            }
        }
    }

    /// Alias for grouped picker sections (`SportCatalog.Category`).
    public typealias SportCategory = SportCatalog.Category

    /// Tokens that appear in filters/history as friendly names but map to league chips elsewhere.
    private static let legacyFriendlySportTokens: [String] = ["Basketball", "Football", "Hockey"]

    /// Distinct ordered list including `All`, league tokens (NBA/NFL/NHL), friendly aliases, and grouped catalog sports.
    public static let calendarAndPickerSportsOrdered: [String] = {
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(64)

        func append(_ s: String) {
            guard seen.insert(s).inserted else { return }
            out.append(s)
        }

        append("All")

        let toolbarPriority: [String] = [
            "Soccer", "Basketball", "Football", "Baseball", "Hockey", "Golf",
            "NBA", "NFL", "NHL",
            "Tennis", "Volleyball", "Ping Pong", "UFC", "Formula 1",
        ]
        for s in toolbarPriority { append(s) }

        for s in SportCatalog.groupedSelectionTokensOrdered { append(s) }

        for s in legacyFriendlySportTokens { append(s) }

        return out
    }()

    public static var sportsExcludingAll: [String] {
        calendarAndPickerSportsOrdered.filter { $0 != "All" }
    }

    /// Stored sport strings for pickup + venue owner game forms (same tokens Discover filters on).
    public static var formPickerSportsOrdered: [String] { sportsExcludingAll }

    /// Compact Discover toolbar: stored selection token + chip label (see ``DiscoverSportFilterRowLayout``).
    public static let discoverMapDefaultPopularPairs: [(selection: String, display: String)] = [
        ("Soccer", "Soccer"),
        ("NBA", "Basketball"),
        ("NFL", "Football"),
        ("Baseball", "Baseball"),
        ("NHL", "Hockey"),
        ("Golf", "Golf"),
    ]
}
