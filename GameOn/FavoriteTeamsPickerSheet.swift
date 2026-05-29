import SwiftUI

/// Sheet to pick favorite teams from the local ``FavoriteTeamCatalog``.
struct FavoriteTeamsPickerSheet: View {
    @Binding var selectedIDs: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    @State private var sportFilter: FavoriteTeamSport = FavoriteTeamCatalog.defaultSport
    @State private var categoryFilter: String? = FavoriteTeamCatalog.defaultCategoryID(for: FavoriteTeamCatalog.defaultSport)
    @State private var searchText = ""

    struct FavoritePickerTeamShelf: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let symbol: String
        let accent: Color
        let teams: [FavoriteTeam]
    }

    private var isSearching: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var availableCategories: [FavoriteTeamCategory] {
        FavoriteTeamCatalog.categories(for: sportFilter)
    }

    private var filteredTeams: [FavoriteTeam] {
        if isSearching {
            return FavoriteTeamCatalog.searchTeams(searchText)
        }
        return FavoriteTeamCatalog.teams(sport: sportFilter, categoryID: categoryFilter)
    }

    private var filteredSections: [(title: String, teams: [FavoriteTeam])] {
        FavoriteTeamCatalog.sectionGroups(for: filteredTeams)
    }

    private var teamShelves: [FavoritePickerTeamShelf] {
        FavoriteTeamsPickerShelves.sections(
            from: filteredTeams,
            sport: sportFilter,
            categoryID: categoryFilter
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterHeader

                pickerResultsContent
            }
            .fanGeoScreenBackground()
            .onAppear {
#if DEBUG
                print("[FavoriteTeamsDebug] unlimitedFavoritesEnabled=true")
                print("[FavoriteTeamsDebug] selectedFavoriteTeamsCount=\(selectedIDs.count)")
#endif
                logFavoriteTeamCatalogDebug()
                logFavoritePickerUXDebug(searchResultsOverride: isSearching ? filteredTeams.count : nil)
            }
            .onChange(of: selectedIDs) { _, newValue in
#if DEBUG
                print("[FavoriteTeamsDebug] selectedFavoriteTeamsCount=\(newValue.count)")
#endif
                logFavoriteTeamCatalogDebug(selectedCountOverride: newValue.count)
            }
            .onChange(of: sportFilter) { _, _ in
                logFavoriteTeamCatalogDebug()
                logFavoritePickerUXDebug()
            }
            .onChange(of: categoryFilter) { _, _ in
                logFavoriteTeamCatalogDebug()
                logFavoritePickerUXDebug()
            }
            .onChange(of: searchText) { _, _ in
                logFavoriteTeamCatalogDebug()
                logFavoritePickerUXDebug(searchResultsOverride: isSearching ? filteredTeams.count : nil)
            }
            .navigationTitle("Favorites")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search favorites")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("done", languageCode: appLanguageRaw)) { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    @ViewBuilder
    private var pickerResultsContent: some View {
        if isSearching {
            searchResultsList
        } else {
            teamShelvesScroll
        }
    }

    private var searchResultsList: some View {
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

    private var teamShelvesScroll: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 22) {
                discoveryIntroRow

                if filteredTeams.isEmpty {
                    emptyStateRow
                } else {
                    ForEach(teamShelves) { shelf in
                        teamShelfSection(shelf)
                    }
                }
            }
            .padding(.horizontal, FGSpacing.md)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .scrollIndicators(.hidden)
    }

    private var filterHeader: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Choose your favorites")
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(isSearching ? "Searching every sport, category, league, and region." : "Pick a sport and category. Teams appear below right away.")
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

    private var discoveryIntroRow: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(sportFilter.accentColor)
                Text("Browse teams")
                    .font(FGTypography.metadata.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .textCase(.uppercase)
                Spacer(minLength: 0)
                Text("\(filteredTeams.count) options")
                    .font(FGTypography.metadata.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            Text("Swipe through leagues and regions. Tap a card to add or remove a favorite.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.76 : 0.92))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(sportFilter.accentColor.opacity(0.16), lineWidth: 1)
        }
    }

    private func teamShelfSection(_ shelf: FavoritePickerTeamShelf) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(shelf.symbol)
                    .font(.headline)
                VStack(alignment: .leading, spacing: 2) {
                    Text(shelf.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(shelf.subtitle)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("\(shelf.teams.count)")
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(shelf.accent)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule(style: .continuous).fill(shelf.accent.opacity(colorScheme == .dark ? 0.18 : 0.10)))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 10) {
                    ForEach(shelf.teams) { team in
                        teamShelfCard(team, accent: shelf.accent)
                    }
                }
                .padding(.horizontal, 1)
                .padding(.vertical, 2)
            }
        }
    }

    private func teamShelfCard(_ team: FavoriteTeam, accent: Color) -> some View {
        let isSelected = selectedIDs.contains(team.id)
        return Button {
            toggleTeam(team)
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    FavoriteTeamLogoBadge(team: team, diameter: 52)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Image(systemName: isSelected ? "checkmark.circle.fill" : "plus.circle")
                        .font(.system(size: 20, weight: .bold))
                        .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                        .background(Circle().fill(FGColor.cardBackground(colorScheme)))
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(team.name)
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.86)
                    Text(team.league)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(width: 138, height: 146, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(isSelected ? accent.opacity(0.52) : FGColor.divider(colorScheme).opacity(0.40), lineWidth: isSelected ? 1.35 : 1)
            }
            .shadow(color: isSelected ? accent.opacity(0.14) : .black.opacity(colorScheme == .dark ? 0.16 : 0.05), radius: isSelected ? 10 : 6, y: isSelected ? 5 : 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(team.name), \(isSelected ? "selected" : "not selected")")
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
        }
    }

    private func selectCategory(_ category: FavoriteTeamCategory) {
        withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
            categoryFilter = category.id
        }
    }

    private func teamRow(_ team: FavoriteTeam) -> some View {
        let isSelected = selectedIDs.contains(team.id)
        let sportAccent = sportAccentColor(for: team.sport.chipTitle)
        return Button {
            toggleTeam(team)
        } label: {
            HStack(spacing: 12) {
                FavoriteTeamLogoBadge(team: team, diameter: 44)

                VStack(alignment: .leading, spacing: 3) {
                    Text(team.name)
                        .font(FGTypography.body.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                    pickerTeamSportMetadata(team: team, isSelected: isSelected)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .overlay(alignment: .leading) {
                if isSelected {
                    Capsule(style: .continuous)
                        .fill(sportAccent.opacity(colorScheme == .dark ? 0.72 : 0.55))
                        .frame(width: 3)
                        .shadow(color: sportAccent.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 5, x: 1)
                        .offset(x: -8)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(team.name), \(isSelected ? "selected" : "not selected")")
    }

    private func toggleTeam(_ team: FavoriteTeam) {
        if selectedIDs.contains(team.id) {
            selectedIDs.remove(team.id)
        } else {
            selectedIDs.insert(team.id)
        }
    }

    private func pickerTeamSportMetadata(team: FavoriteTeam, isSelected: Bool) -> some View {
        HStack(spacing: 6) {
            Text(sportIcon(for: team.sport.chipTitle))
                .font(.system(size: 13))
            Text(teamMetadataLine(team))
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, isSelected ? 7 : 0)
        .padding(.vertical, isSelected ? 3 : 0)
        .background {
            if isSelected {
                Capsule(style: .continuous)
                    .fill(sportAccentColor(for: team.sport.chipTitle).opacity(colorScheme == .dark ? 0.16 : 0.10))
            }
        }
        .onAppear {
#if DEBUG
            print("[FavoriteTeamsDebug] sportIconRendered sport=\(team.sport.chipTitle)")
            print("[FavoriteTeamsDebug] favoriteTeamCardSportIconVisible=true")
            if isSelected {
                print("[FavoriteTeamsDebug] sportAccentRendered sport=\(team.sport.chipTitle)")
                print("[FavoriteTeamsDebug] sportAccentColorApplied=true")
            }
#endif
        }
    }

    private func teamMetadataLine(_ team: FavoriteTeam) -> String {
        if team.league == team.region {
            return "\(team.sport.chipTitle) · \(team.kind.displayTitle) · \(team.league)"
        }

        return "\(team.sport.chipTitle) · \(team.region) · \(team.kind.displayTitle) · \(team.league)"
    }

    private func logFavoriteTeamCatalogDebug(selectedCountOverride: Int? = nil) {
#if DEBUG
        print("[FavoriteTeamCatalogDebug] source=businessGameManagement+fanFavorites")
        print("[FavoriteTeamCatalogDebug] sport=\(sportFilter.rawValue)")
        print("[FavoriteTeamCatalogDebug] category=\(categoryFilter ?? "nil")")
        print("[FavoriteTeamCatalogDebug] region=shelf")
        print("[FavoriteTeamCatalogDebug] query=\(searchText.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("[FavoriteTeamCatalogDebug] resultsCount=\(filteredTeams.count)")
        print("[FavoriteTeamCatalogDebug] selectedCount=\(selectedCountOverride ?? selectedIDs.count)")
#endif
    }

    private func logFavoritePickerUXDebug(expandedOverride: String? = nil, searchResultsOverride: Int? = nil) {
#if DEBUG
        print("[FavoritePickerUXDebug] expandedSection=\(expandedOverride ?? "shelfMode")")
        print("[FavoritePickerUXDebug] visibleTeams=\(visibleShelfTeamCount)")
        print("[FavoritePickerUXDebug] searchResults=\(searchResultsOverride ?? (isSearching ? filteredTeams.count : 0))")
        print("[FavoritePickerUXDebug] hierarchyModeEnabled=false")
#endif
    }

    private var visibleShelfTeamCount: Int {
        guard !isSearching else { return filteredTeams.count }
        return teamShelves.reduce(0) { total, shelf in total + shelf.teams.count }
    }
}

private enum FavoriteTeamsPickerShelves {
    static func sections(
        from teams: [FavoriteTeam],
        sport: FavoriteTeamSport,
        categoryID: String?
    ) -> [FavoriteTeamsPickerSheet.FavoritePickerTeamShelf] {
        let groupedByShelf = Dictionary(grouping: teams, by: { shelfTitle(for: $0, categoryID: categoryID) })
        return groupedByShelf.map { title, shelfTeams in
            FavoriteTeamsPickerSheet.FavoritePickerTeamShelf(
                id: title.favoritePickerID,
                title: title,
                subtitle: subtitle(for: title, teamCount: shelfTeams.count),
                symbol: symbol(for: title),
                accent: accent(for: title, sport: sport),
                teams: shelfTeams.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            )
        }
        .sorted { lhs, rhs in
            let order = shelfOrder(for: sport, categoryID: categoryID)
            let left = order.firstIndex(of: lhs.title) ?? Int.max
            let right = order.firstIndex(of: rhs.title) ?? Int.max
            if left != right { return left < right }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private static func shelfTitle(for team: FavoriteTeam, categoryID: String?) -> String {
        if team.kind == .nationalTeam {
            return "National Teams"
        }
        if team.kind == .player || team.kind == .driver || team.kind == .fighter {
            return "Players"
        }
        if team.kind == .interest {
            return team.region
        }
        if team.kind == .tournament {
            return "Tournaments"
        }
        if categoryID?.contains("national") == true {
            return "National Teams"
        }
        return team.region
    }

    private static func subtitle(for title: String, teamCount: Int) -> String {
        let teamText = teamCount == 1 ? "1 favorite" : "\(teamCount) favorites"
        return teamText
    }

    private static func symbol(for region: String) -> String {
        let lowered = region.lowercased()
        if lowered.contains("premier") || lowered.contains("liga") || lowered.contains("serie") || lowered.contains("bundesliga") || lowered.contains("ligue") { return "⚽️" }
        if lowered.contains("mls") || lowered.contains("north america") { return "🌎" }
        if lowered.contains("national") { return "🌍" }
        if lowered.contains("nba") || lowered.contains("wnba") { return "🏀" }
        if lowered.contains("nfl") || lowered.contains("football") { return "🏈" }
        if lowered.contains("mlb") { return "⚾️" }
        if lowered.contains("nhl") { return "🏒" }
        if lowered.contains("performing") || lowered.contains("ballet") { return "🩰" }
        if lowered.contains("dance") { return "💃" }
        if lowered.contains("national") { return "🏆" }
        if lowered.contains("player") { return "⭐️" }
        if lowered.contains("tournament") { return "🏆" }
        return "🏟️"
    }

    private static func accent(for title: String, sport: FavoriteTeamSport) -> Color {
        let lowered = title.lowercased()
        if lowered.contains("europe") { return Color(red: 0.20, green: 0.42, blue: 0.90) }
        if lowered.contains("north america") { return Color(red: 0.18, green: 0.66, blue: 0.40) }
        if lowered.contains("south america") { return Color(red: 0.95, green: 0.56, blue: 0.16) }
        if lowered.contains("asia") { return Color(red: 0.74, green: 0.22, blue: 0.72) }
        if lowered.contains("africa") { return Color(red: 0.86, green: 0.46, blue: 0.16) }
        return sport.accentColor
    }

    private static func shelfOrder(for sport: FavoriteTeamSport, categoryID: String?) -> [String] {
        if categoryID?.contains("national") == true {
            return ["National Teams"]
        }
        switch sport {
        case .soccer:
            return ["Premier League", "La Liga", "Serie A", "Bundesliga", "Ligue 1", "MLS", "Liga MX", "National Teams", "Brazil Serie A", "Argentina Primera Division", "Libertadores-level clubs", "J1 League", "Saudi Pro League", "K League", "Players", "Tournaments"]
        case .basketball:
            return ["NBA", "WNBA", "College Basketball", "National Teams", "Players", "Tournaments"]
        case .football:
            return ["NFL", "College Football", "Players", "Tournaments"]
        case .baseball:
            return ["MLB", "National Teams", "Players", "Tournaments"]
        case .hockey:
            return ["NHL", "National Teams", "Players", "Tournaments"]
        case .dance:
            return ["Dance / Urban Sports", "Dance / Performing Arts"]
        default:
            return ["Players", "Tournaments"]
        }
    }
}

private extension String {
    var favoritePickerID: String {
        folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .joined(separator: "-")
            .lowercased()
    }
}

