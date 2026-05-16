import SwiftUI

/// Sheet to pick favorite teams from the local ``FavoriteTeamCatalog``.
struct FavoriteTeamsPickerSheet: View {
    @Binding var selectedIDs: Set<String>
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var sportFilter: FavoriteTeamSport? = nil
    @State private var searchText = ""

    private var filteredTeams: [FavoriteTeam] {
        FavoriteTeamCatalog.teams(sport: sportFilter, search: searchText)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                sportChips
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.top, FGSpacing.sm)
                    .padding(.bottom, FGSpacing.sm)

                List {
                    ForEach(filteredTeams) { team in
                        teamRow(team)
                            .listRowBackground(FGColor.cardBackground(colorScheme))
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Favorite Teams")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchText, prompt: "Search teams")
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
                    Text("\(team.sport.chipTitle) · \(team.league)")
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
}

