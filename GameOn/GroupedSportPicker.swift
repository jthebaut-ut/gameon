import SwiftUI

/// Shared grouped sport picker (category sections + icons + search) used by Discover filters and game creation flows.
struct GroupedSportPickerSheet: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var searchText = ""

    /// Stored selection token used for checkmarks (NBA ↔ Basketball equivalence via ``DiscoverSportFilterRowLayout``).
    let selectedSportToken: String
    let navigationTitle: String
    var showsSearch: Bool = true
    /// Venue/pickup form sheets expose Done so users can dismiss without changing selection.
    var showsToolbarDone: Bool = false
    let onSelectSport: (String) -> Void

    private var visibleGroups: [DiscoverSportFilterRowLayout.SheetGroup] {
        DiscoverSportFilterRowLayout.sheetGroupsFiltered(query: searchText)
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleGroups) { group in
                    Section {
                        ForEach(group.rows, id: \.self) { row in
                            Button {
                                onSelectSport(row.selection)
                                dismiss()
                            } label: {
                                HStack(spacing: 14) {
                                    SportArtworkIconView(sport: row.selection, diameter: 40)
                                    Text(row.label)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                    Spacer(minLength: 0)
                                    if DiscoverSportFilterRowLayout.selectionTokensMatch(selectedSportToken, row.selection) {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.title3)
                                            .foregroundStyle(FGColor.accentBlue)
                                    }
                                }
                                .padding(.vertical, 2)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text(group.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(nil)
                    }
                }
            }
            .listSectionSpacing(12)
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if showsToolbarDone {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }
                    }
                }
            }
        }
        .applyGroupedSportSearch(showsSearch: showsSearch, searchText: $searchText)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private extension View {
    @ViewBuilder
    func applyGroupedSportSearch(showsSearch: Bool, searchText: Binding<String>) -> some View {
        if showsSearch {
            searchable(text: searchText, prompt: "Search sports")
        } else {
            self
        }
    }
}
