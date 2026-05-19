import SwiftUI

/// Sheet to pick favorite teams from the local ``FavoriteTeamCatalog``.
struct FavoriteTeamsPickerSheet: View {
    @Binding var selectedIDs: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var sportFilter: FavoriteTeamSport? = nil
    @State private var regionFilter: String? = nil
    @State private var kindFilter: FavoriteTeamKind? = nil
    @State private var searchText = ""

    private var filteredTeams: [FavoriteTeam] {
        FavoriteTeamCatalog.teams(sport: sportFilter, search: searchText, region: regionFilter, kind: kindFilter)
    }

    private var filteredSections: [(title: String, teams: [FavoriteTeam])] {
        FavoriteTeamCatalog.sectionGroups(for: filteredTeams)
    }

    private var availableRegions: [String] {
        FavoriteTeamCatalog.regions(for: sportFilter)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                VStack(spacing: 8) {
                    sportChips
                    regionChips
                    kindChips
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.sm)
                .padding(.bottom, FGSpacing.sm)

                List {
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

    private var sportChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sportChip(title: "All", sport: nil)
                ForEach(FavoriteTeamSport.allCases) { sport in
                    sportChip(title: sport.chipTitle, sport: sport)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sportChip(title: String, sport: FavoriteTeamSport?) -> some View {
        let selected = sportFilter == sport
        return Button {
            sportFilter = sport
            if let regionFilter, !FavoriteTeamCatalog.regions(for: sport).contains(regionFilter) {
                self.regionFilter = nil
            }
        } label: {
            Text(title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(selected ? Color.white : FGColor.primaryText(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            selected
                                ? (sport?.accentColor ?? FGColor.accentGreen)
                                : FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.9 : 1)
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: selected ? 0 : 1)
                }
        }
        .buttonStyle(.plain)
    }

    private var regionChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All Regions", isSelected: regionFilter == nil, accent: FGColor.accentGreen) {
                    regionFilter = nil
                }

                ForEach(availableRegions, id: \.self) { region in
                    filterChip(title: region, isSelected: regionFilter == region, accent: FGColor.accentBlue) {
                        regionFilter = region
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                filterChip(title: "All Types", isSelected: kindFilter == nil, accent: FGColor.accentGreen) {
                    kindFilter = nil
                }

                ForEach(FavoriteTeamKind.allCases) { kind in
                    filterChip(title: kind.displayTitle, isSelected: kindFilter == kind, accent: FGColor.accentBlue) {
                        kindFilter = kind
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func filterChip(title: String, isSelected: Bool, accent: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(FGTypography.metadata.weight(.semibold))
                .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            isSelected
                                ? accent
                                : FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.9 : 1)
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.divider(colorScheme), lineWidth: isSelected ? 0 : 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func teamRow(_ team: FavoriteTeam) -> some View {
        let isSelected = selectedIDs.contains(team.id)
        return Button {
            if isSelected {
                selectedIDs.remove(team.id)
            } else {
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
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(team.name), \(isSelected ? "selected" : "not selected")")
    }

    private func teamMetadataLine(_ team: FavoriteTeam) -> String {
        if team.league == team.region {
            return "\(team.sport.chipTitle) · \(team.kind.displayTitle) · \(team.league)"
        }

        return "\(team.sport.chipTitle) · \(team.region) · \(team.kind.displayTitle) · \(team.league)"
    }
}

