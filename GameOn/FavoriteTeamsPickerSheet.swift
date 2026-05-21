import SwiftUI

/// Sheet to pick favorite teams from the local ``FavoriteTeamCatalog``.
struct FavoriteTeamsPickerSheet: View {
    @Binding var selectedIDs: Set<String>
    var maximumSelectionCount: Int = 2
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var sportFilter: FavoriteTeamSport = FavoriteTeamCatalog.defaultSport
    @State private var categoryFilter: String? = FavoriteTeamCatalog.defaultCategoryID(for: FavoriteTeamCatalog.defaultSport)
    @State private var regionFilter: String? = nil
    @State private var searchText = ""

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var availableCategories: [FavoriteTeamCategory] {
        FavoriteTeamCatalog.categories(for: sportFilter)
    }

    private var availableRegions: [String] {
        FavoriteTeamCatalog.regions(for: sportFilter, categoryID: categoryFilter)
    }

    private var filteredTeams: [FavoriteTeam] {
        if isSearching {
            return FavoriteTeamCatalog.searchTeams(searchText)
        }
        return FavoriteTeamCatalog.teams(sport: sportFilter, categoryID: categoryFilter, region: regionFilter)
    }

    private var filteredSections: [(title: String, teams: [FavoriteTeam])] {
        FavoriteTeamCatalog.sectionGroups(for: filteredTeams)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterHeader

                List {
                    if filteredTeams.isEmpty {
                        emptyStateRow
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(filteredSections.indices, id: \.self) { index in
                            let section = filteredSections[index]
                            Section(section.title) {
                                ForEach(section.teams) { team in
                                    teamRow(team)
                                        .listRowBackground(FGColor.cardBackground(colorScheme))
                                }
                            }
                        }
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search favorites")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose your favorites")
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(isSearching ? "Searching every sport, category, and region." : "Start with a sport, then narrow the list. Pick up to \(maximumSelectionCount).")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            filterStep(title: "1. Sport") {
                sportSelector
            }

            if !isSearching, !availableCategories.isEmpty {
                filterStep(title: "2. Category") {
                    categorySelector
                }
            }

            if !isSearching, availableRegions.count > 1 {
                filterStep(title: "3. Region", subtitle: "Optional") {
                    regionSelector
                }
            }
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.top, FGSpacing.md)
        .padding(.bottom, FGSpacing.sm)
        .background {
            Rectangle()
                .fill(FGColor.background(colorScheme).opacity(0.96))
        }
    }

    private func filterStep<Content: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .textCase(.uppercase)
                if let subtitle {
                    Text(subtitle)
                        .font(FGTypography.metadata.weight(.semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }

            content()
        }
    }

    private var sportSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(FavoriteTeamCatalog.selectorSports) { sport in
                    SportFilterChip(
                        sport: sport.discoverSportToken,
                        displayTitle: sport.chipTitle,
                        isSelected: sportFilter == sport,
                        isCompact: true
                    ) {
                        selectSport(sport)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var categorySelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableCategories) { category in
                    filterChip(
                        title: category.title,
                        isSelected: categoryFilter == category.id,
                        accent: sportFilter.accentColor
                    ) {
                        selectCategory(category)
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var regionSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(availableRegions, id: \.self) { region in
                    filterChip(title: region, isSelected: regionFilter == region, accent: FGColor.accentBlue) {
                        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                            regionFilter = regionFilter == region ? nil : region
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var emptyStateRow: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("No favorites found")
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(isSearching ? "Try a sport, player, league, category, or region." : "Try another category or clear the region.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func filterChip(title: String, isSelected: Bool, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FGTypography.metadata.weight(.bold))
                .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            isSelected
                                ? LinearGradient(
                                    colors: [accent.opacity(0.96), accent.opacity(0.76)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                                : LinearGradient(
                                    colors: [
                                        FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.94 : 1),
                                        FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.86 : 0.96)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(isSelected ? Color.white.opacity(0.18) : FGColor.divider(colorScheme), lineWidth: 1)
                }
                .shadow(color: isSelected ? accent.opacity(0.16) : .black.opacity(colorScheme == .dark ? 0.12 : 0.04), radius: isSelected ? 8 : 4, y: isSelected ? 3 : 1)
        }
        .buttonStyle(.plain)
    }

    private func selectSport(_ sport: FavoriteTeamSport) {
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            sportFilter = sport
            categoryFilter = FavoriteTeamCatalog.defaultCategoryID(for: sport)
            regionFilter = nil
        }
    }

    private func selectCategory(_ category: FavoriteTeamCategory) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            categoryFilter = category.id
            if let regionFilter, !FavoriteTeamCatalog.regions(for: sportFilter, categoryID: category.id).contains(regionFilter) {
                self.regionFilter = nil
            }
        }
    }

    private func teamRow(_ team: FavoriteTeam) -> some View {
        let isSelected = selectedIDs.contains(team.id)
        let selectionLimitReached = selectedIDs.count >= maximumSelectionCount && !isSelected
        return Button {
            if isSelected {
                selectedIDs.remove(team.id)
            } else if !selectionLimitReached {
                selectedIDs.insert(team.id)
            }
        } label: {
            HStack(spacing: 12) {
                FavoriteTeamLogoBadge(team: team, diameter: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(team.name)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                    Text(teamMetadataLine(team))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme).opacity(selectionLimitReached ? 0.45 : 1))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(selectionLimitReached ? 0.52 : 1)
        }
        .buttonStyle(.plain)
        .disabled(selectionLimitReached)
        .accessibilityLabel("\(team.name), \(isSelected ? "selected" : "not selected")")
    }

    private func teamMetadataLine(_ team: FavoriteTeam) -> String {
        if team.league == team.region {
            return "\(team.sport.chipTitle) · \(team.kind.displayTitle) · \(team.league)"
        }

        return "\(team.sport.chipTitle) · \(team.region) · \(team.kind.displayTitle) · \(team.league)"
    }
}

