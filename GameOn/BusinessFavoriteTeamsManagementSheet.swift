import SwiftUI

struct BusinessFavoriteTeamsManagementSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let businessId: UUID?

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedIDs: Set<String> = []
    @State private var showTeamPicker = false
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var banner: String?

    private var resolvedBusinessId: UUID? {
        businessId ?? viewModel.currentBusinessIdForAddLocation()
    }

    private var selectedTeams: [FavoriteTeam] {
        FavoriteTeamsStore.resolvedTeams(fromIDs: Array(selectedIDs).sorted())
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerCard

                    if let banner, !banner.isEmpty {
                        noticeCard(banner, isError: banner.lowercased().contains("could not"))
                    }

                    selectedTeamsSection
                }
                .padding(.horizontal, FGSpacing.md)
                .padding(.top, FGSpacing.md)
                .padding(.bottom, 32)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Favorite Teams")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        showTeamPicker = true
                    } label: {
                        Label("Add Team", systemImage: "plus")
                    }
                    .disabled(resolvedBusinessId == nil || isLoading || isSaving)
                }
            }
            .task(id: resolvedBusinessId) {
                await loadTeams()
            }
            .sheet(isPresented: $showTeamPicker, onDismiss: {
                Task { await saveSelection(selectedIDs) }
            }) {
                FavoriteTeamsPickerSheet(selectedIDs: $selectedIDs)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationBackground(FGAdaptiveSurface.sheetRoot)
            }
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "star.circle.fill")
                    .font(.system(size: 34, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentBlue)

                VStack(alignment: .leading, spacing: 3) {
                    Text("Favorite Teams")
                        .font(FGTypography.cardTitle.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(teamCountText(selectedIDs.count))
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer(minLength: 0)
            }

            Button {
                showTeamPicker = true
            } label: {
                Label("Manage Teams", systemImage: "slider.horizontal.3")
                    .font(FGTypography.caption.weight(.bold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentBlue)
            .disabled(resolvedBusinessId == nil || isLoading || isSaving)
        }
        .padding()
        .background(FGColor.cardBackground(colorScheme), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.72), lineWidth: 1)
        }
    }

    private var selectedTeamsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Selected Teams")
                    .font(FGTypography.cardTitle.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer()
                if isLoading || isSaving {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            if selectedTeams.isEmpty {
                emptySelectedTeamsCard
            } else {
                VStack(spacing: 10) {
                    ForEach(selectedTeams) { team in
                        selectedTeamRow(team)
                    }
                }
            }
        }
    }

    private var emptySelectedTeamsCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "star")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("No teams followed yet.")
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text("Add teams to power the business Pro Games My Teams filter.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 16)
        .background(FGColor.cardBackground(colorScheme), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func selectedTeamRow(_ team: FavoriteTeam) -> some View {
        HStack(spacing: 12) {
            FavoriteTeamLogoBadge(team: team, diameter: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(team.name)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Text("\(team.league) · \(team.sport.chipTitle)")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Button {
                removeTeam(team)
            } label: {
                Label("Remove Team", systemImage: "minus.circle.fill")
                    .labelStyle(.iconOnly)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.red.opacity(0.92))
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
        }
        .padding(12)
        .background(FGColor.cardBackground(colorScheme), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.62), lineWidth: 1)
        }
    }

    private func noticeCard(_ message: String, isError: Bool) -> some View {
        Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(isError ? Color.red : FGColor.accentGreen)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background((isError ? Color.red : FGColor.accentGreen).opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func loadTeams() async {
        guard let resolvedBusinessId else {
            selectedIDs = []
            banner = "Could not find a business account for favorite teams."
            return
        }
        isLoading = true
        await viewModel.loadBusinessFavoriteTeams(businessId: resolvedBusinessId, force: true)
        selectedIDs = viewModel.businessFavoriteTeamIDs
        isLoading = false
    }

    private func removeTeam(_ team: FavoriteTeam) {
        selectedIDs.remove(team.id)
        Task { await saveSelection(selectedIDs) }
    }

    private func saveSelection(_ ids: Set<String>) async {
        guard let resolvedBusinessId else { return }
        isSaving = true
        let saved = await viewModel.replaceBusinessFavoriteTeams(businessId: resolvedBusinessId, teamIDs: ids)
        selectedIDs = viewModel.businessFavoriteTeamIDs
        banner = saved ? "Favorite teams updated." : "Could not update favorite teams. Please try again."
        isSaving = false
    }

    private func teamCountText(_ count: Int) -> String {
        "\(count) \(count == 1 ? "Team" : "Teams") Followed"
    }
}
