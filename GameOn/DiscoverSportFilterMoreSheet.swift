import SwiftUI

// MARK: - Discover map compact row (toolbar)

enum DiscoverSportFilterRowLayout {

    struct CompactItem: Identifiable, Hashable {
        enum Kind: Hashable {
            case all
            case sport(selection: String, display: String?)
            case more
        }

        let id: String
        let kind: Kind
    }

    /// Discover map filter chips use these storage tokens (e.g. `NBA`) so Supabase + sample events stay aligned; popular chips may show a friendlier label.
    private static let popularPairs: [(selection: String, display: String)] = AppSportCatalog.discoverMapDefaultPopularPairs

    private static let popularSelections: Set<String> = Set(popularPairs.map(\.selection))

    /// True when the current filter matches one of the six default Discover chips (including friendly labels used elsewhere, e.g. Calendar).
    private static func isDefaultPopularSport(_ selectedSport: String) -> Bool {
        let t = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        if popularSelections.contains(t) { return true }
        switch t {
        case "Basketball", "Football", "Hockey":
            return true
        default:
            return false
        }
    }

    static func compactRowItems(selectedSport: String) -> [CompactItem] {
        var items: [CompactItem] = [CompactItem(id: "all", kind: .all)]
        if selectedSport != "All", !isDefaultPopularSport(selectedSport) {
            items.append(CompactItem(id: "pin-\(selectedSport)", kind: .sport(selection: selectedSport, display: nil)))
        }
        for pair in popularPairs {
            items.append(
                CompactItem(id: "pop-\(pair.selection)", kind: .sport(selection: pair.selection, display: pair.display))
            )
        }
        items.append(CompactItem(id: "more", kind: .more))
        return items
    }

    // MARK: - More sheet (grouped catalog)

    struct SheetRow: Hashable {
        let label: String
        let selection: String
    }

    struct SheetGroup: Identifiable, Hashable {
        let id: String
        let title: String
        let rows: [SheetRow]
    }

    private static func sheetRows(_ pairs: [(label: String, value: String)]) -> [SheetRow] {
        pairs.map { SheetRow(label: $0.label, selection: $0.value) }
    }

    static let sheetGroups: [SheetGroup] = [
        SheetGroup(id: "motorsports", title: "Motorsports", rows: sheetRows(AppSportCatalog.DiscoverMore.motorsports)),
        SheetGroup(id: "action", title: "Action", rows: sheetRows(AppSportCatalog.DiscoverMore.action)),
        SheetGroup(id: "indoor", title: "Indoor", rows: sheetRows(AppSportCatalog.DiscoverMore.indoor)),
        SheetGroup(id: "water_winter", title: "Water/Winter", rows: sheetRows(AppSportCatalog.DiscoverMore.waterWinter)),
        SheetGroup(id: "team", title: "Team Sports", rows: sheetRows(AppSportCatalog.DiscoverMore.teamSports))
    ]

    static func sheetGroupsFiltered(query raw: String) -> [SheetGroup] {
        let q = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return sheetGroups }
        return sheetGroups.compactMap { group in
            if group.title.localizedCaseInsensitiveContains(q) {
                return group
            }
            let rows = group.rows.filter { row in
                row.label.localizedCaseInsensitiveContains(q) || row.selection.localizedCaseInsensitiveContains(q)
            }
            if rows.isEmpty { return nil }
            return SheetGroup(id: group.id, title: group.title, rows: rows)
        }
    }

    /// True when two filter tokens refer to the same sport (e.g. Calendar ``"Basketball"`` vs Discover chip ``"NBA"``).
    static func selectionTokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines)
        if a == b { return true }
        let leagueToFriendly: [String: String] = [
            "NBA": "Basketball",
            "NFL": "Football",
            "NHL": "Hockey"
        ]
        if leagueToFriendly[a] == b || leagueToFriendly[b] == a { return true }
        return false
    }
}

// MARK: - Shared sport chips HStack (wrap in your own horizontal ScrollView)

struct ScalableSportFilterChipsHStack: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showMoreSheet: Bool
    var spacing: CGFloat = 10
    var isCompact: Bool = true

    var body: some View {
        HStack(spacing: spacing) {
            ForEach(DiscoverSportFilterRowLayout.compactRowItems(selectedSport: viewModel.selectedSport)) { item in
                switch item.kind {
                case .all:
                    sportChip(selection: "All")
                case .sport(let selection, let displayTitle):
                    sportChip(selection: selection, displayTitle: displayTitle)
                case .more:
                    SportFilterChip(sport: "More", isSelected: false, isCompact: isCompact) {
                        showMoreSheet = true
                    }
                }
            }
        }
    }

    private func sportChip(selection: String, displayTitle: String? = nil) -> some View {
        SportFilterChip(
            sport: selection,
            displayTitle: displayTitle,
            isSelected: DiscoverSportFilterRowLayout.selectionTokensMatch(viewModel.selectedSport, selection),
            isCompact: isCompact
        ) {
            withAnimation(.spring()) {
                viewModel.sportChanged(to: selection)
            }
        }
    }
}

/// Calendar tab: horizontal scroll + default outer padding.
struct ScalableSportFilterChipRow: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showMoreSheet: Bool
    var rowSpacing: CGFloat = 10
    var isCompact: Bool = true

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            ScalableSportFilterChipsHStack(
                viewModel: viewModel,
                showMoreSheet: $showMoreSheet,
                spacing: rowSpacing,
                isCompact: isCompact
            )
            .padding(.horizontal, 4)
        }
    }
}

// MARK: - Sheet

struct DiscoverSportFilterMoreSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var searchText = ""

    let selectedSport: String
    let onSelectSport: (String) -> Void

    private var visibleGroups: [DiscoverSportFilterRowLayout.SheetGroup] {
        DiscoverSportFilterRowLayout.sheetGroupsFiltered(query: searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleGroups) { group in
                    Section(group.title) {
                        ForEach(group.rows, id: \.self) { row in
                            Button {
                                onSelectSport(row.selection)
                            } label: {
                                HStack(spacing: 12) {
                                    SportArtworkIconView(sport: row.selection, diameter: 40)
                                    Text(row.label)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                    Spacer(minLength: 0)
                                    if DiscoverSportFilterRowLayout.selectionTokensMatch(selectedSport, row.selection) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(FGColor.accentBlue)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }
            }
            .navigationTitle("Sports")
            .navigationBarTitleDisplayMode(.inline)
        }
        .searchable(text: $searchText, prompt: "Search sports")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
