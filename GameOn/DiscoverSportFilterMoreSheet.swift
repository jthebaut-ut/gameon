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

    private static func sheetRows(from rows: [(label: String, selection: String)]) -> [SheetRow] {
        rows.map { SheetRow(label: $0.label, selection: $0.selection) }
    }

    static var sheetGroups: [SheetGroup] {
        AppSportCatalog.SportCatalog.groupedCategories.map { category in
            SheetGroup(id: category.id, title: category.title, rows: sheetRows(from: category.rows))
        }
    }

    static func sheetGroupsFiltered(query raw: String) -> [SheetGroup] {
        AppSportCatalog.SportCatalog.filteredCategories(query: raw).map { category in
            SheetGroup(id: category.id, title: category.title, rows: sheetRows(from: category.rows))
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
    let selectedSport: String
    let onSelectSport: (String) -> Void

    var body: some View {
        GroupedSportPickerSheet(
            selectedSportToken: selectedSport,
            navigationTitle: "Sports",
            showsSearch: true,
            showsToolbarDone: false,
            onSelectSport: onSelectSport
        )
    }
}
