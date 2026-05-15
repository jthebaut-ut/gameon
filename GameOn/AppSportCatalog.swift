import Foundation

/// Single source of truth for sport **strings** used in Calendar filters, pickup/venue pickers, analytics, and Supabase payloads.
/// Chip colors, SF Symbols, and search aliases live in ``SportFilterCatalog`` (SwiftUI).
public enum AppSportCatalog {

    public static let newlyExpandedSports: [String] = [
        "MotoGP",
        "Motocross",
        "Climbing",
        "Skateboarding",
        "Bowling",
        "Swimming",
        "Skiing",
        "Esports",
        "Handball"
    ]

    /// Distinct ordered list including `All`, friendly labels, league tokens (NBA/NFL/NHL), and expanded sports.
    public static let calendarAndPickerSportsOrdered: [String] = {
        let ordered: [String] = [
            "All",
            "Soccer",
            "Basketball",
            "Football",
            "Baseball",
            "Hockey",
            "Golf",
            "NBA",
            "NFL",
            "NHL",
            "Tennis",
            "Volleyball",
            "Ping Pong",
            "UFC",
            "Formula 1"
        ] + newlyExpandedSports + [
            "Cricket",
            "Rugby",
            "Softball",
            "Cycling"
        ]
        var seen = Set<String>()
        var out: [String] = []
        out.reserveCapacity(ordered.count)
        for s in ordered where seen.insert(s).inserted {
            out.append(s)
        }
        return out
    }()

    public static var sportsExcludingAll: [String] {
        calendarAndPickerSportsOrdered.filter { $0 != "All" }
    }

    /// Stored sport strings for pickup + venue owner game forms (same tokens Discover filters on, e.g. `NBA`, `Soccer`, `MotoGP`).
    public static var formPickerSportsOrdered: [String] { sportsExcludingAll }

    /// Compact Discover toolbar: stored selection token + chip label (see ``DiscoverSportFilterRowLayout``).
    public static let discoverMapDefaultPopularPairs: [(selection: String, display: String)] = [
        ("Soccer", "Soccer"),
        ("NBA", "Basketball"),
        ("NFL", "Football"),
        ("Baseball", "Baseball"),
        ("NHL", "Hockey"),
        ("Golf", "Golf")
    ]

    // MARK: - Discover “More” sheet (group → label + stored selection token)

    public enum DiscoverMore {
        public static let motorsports: [(label: String, value: String)] = [
            ("Formula 1", "Formula 1"),
            ("MotoGP", "MotoGP"),
            ("Motocross", "Motocross")
        ]
        public static let action: [(label: String, value: String)] = [
            ("Climbing", "Climbing"),
            ("Skateboarding", "Skateboarding")
        ]
        public static let indoor: [(label: String, value: String)] = [
            ("Bowling", "Bowling"),
            ("Handball", "Handball"),
            ("Esports", "Esports")
        ]
        public static let waterWinter: [(label: String, value: String)] = [
            ("Swimming", "Swimming"),
            ("Skiing", "Skiing")
        ]
        public static let teamSports: [(label: String, value: String)] = [
            ("Soccer", "Soccer"),
            ("Basketball", "NBA"),
            ("Football", "NFL"),
            ("Baseball", "Baseball"),
            ("Hockey", "NHL"),
            ("Golf", "Golf"),
            ("Tennis", "Tennis"),
            ("Volleyball", "Volleyball")
        ]
    }
}
