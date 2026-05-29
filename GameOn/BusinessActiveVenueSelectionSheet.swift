import SwiftUI

struct BusinessActiveVenueSelectionSheet: View {
    @ObservedObject var viewModel: MapViewModel
    let businessId: UUID
    let venueLimit: Int
    let venues: [VenueProfileRow]
    let approvedDateText: (VenueProfileRow) -> String
    let onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedVenueIds: Set<UUID>
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        viewModel: MapViewModel,
        businessId: UUID,
        venueLimit: Int,
        venues: [VenueProfileRow],
        approvedDateText: @escaping (VenueProfileRow) -> String,
        onSaved: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.businessId = businessId
        self.venueLimit = venueLimit
        self.venues = venues
        self.approvedDateText = approvedDateText
        self.onSaved = onSaved
        _selectedVenueIds = State(initialValue: Self.initialSelectedVenueIds(venues: venues, venueLimit: venueLimit))
    }

    private var selectedCount: Int {
        orderedSelectedVenueIds.count
    }

    private var canSave: Bool {
        !isSaving && selectedCount > 0 && selectedCount <= venueLimit
    }

    private var uniqueVenueRows: [VenueSelectionRow] {
        var seen = Set<UUID>()
        return venues.compactMap { row -> VenueSelectionRow? in
            guard let id = row.id, seen.insert(id).inserted else { return nil }
            return VenueSelectionRow(id: id, row: row)
        }
    }

    private var visibleVenueIds: Set<UUID> {
        Set(uniqueVenueRows.map(\.id))
    }

    private var normalizedSelectedVenueIds: Set<UUID> {
        selectedVenueIds.intersection(visibleVenueIds)
    }

    private var orderedSelectedVenueIds: [UUID] {
        uniqueVenueRows.compactMap { normalizedSelectedVenueIds.contains($0.id) ? $0.id : nil }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Choose active venues")
                            .font(.headline.weight(.bold))
                        Text("Your Regular plan keeps up to \(venueLimit) approved venues active. Active venues stay visible on Discover and can host games.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Text("\(selectedCount) of \(venueLimit) selected")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(selectedCount > venueLimit ? FGColor.dangerRed : FGColor.accentGreen)
                    }
                    .padding(.vertical, 4)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.dangerRed)
                    }
                }

                Section {
                    ForEach(uniqueVenueRows) { item in
                        venueRow(item.row, id: item.id)
                    }
                } footer: {
                    Text("This one-time choice is saved to your business account. You can upgrade to Business Pro to reactivate every approved venue.")
                }
            }
            .navigationTitle("Active Venues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving..." : "Save") {
                        Task { await save() }
                    }
                    .disabled(!canSave)
                }
            }
            .overlay {
                if isSaving {
                    ZStack {
                        Color.black.opacity(0.12).ignoresSafeArea()
                        ProgressView()
                            .padding(20)
                            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
            .onAppear {
#if DEBUG
                print("[BusinessActiveVenueSelectionDebug] sheetLoaded businessId=\(businessId.uuidString.lowercased()) venueLimit=\(venueLimit) venueCount=\(uniqueVenueRows.count) initiallySelectedIds=\(Self.debugIdList(orderedSelectedVenueIds))")
#endif
                selectedVenueIds = normalizedSelectedVenueIds
            }
        }
    }

    private func venueRow(_ row: VenueProfileRow, id: UUID) -> some View {
        let isSelected = selectedVenueIds.contains(id)
        let isLocked = MapViewModel.venueIsPlanLocked(row)
        return Button {
            toggle(id)
        } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.mutedText(colorScheme))

                VStack(alignment: .leading, spacing: 4) {
                    Text(row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? row.venue_name! : "Approved venue")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(isLocked && !isSelected ? .secondary : .primary)
                        .lineLimit(1)
                    Text(venueSubtitle(row))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if isLocked && !isSelected {
                        Text(BusinessLimitCopy.planLockedVenueBadge)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func toggle(_ id: UUID) {
        errorMessage = nil
        let venueName = venueName(for: id)
        if selectedVenueIds.contains(id) {
            selectedVenueIds.remove(id)
#if DEBUG
            print("[BusinessActiveVenueSelectionDebug] toggle venueId=\(id.uuidString.lowercased()) venueName=\(venueName) selectedCount=\(orderedSelectedVenueIds.count) selectedIds=\(Self.debugIdList(orderedSelectedVenueIds))")
#endif
            return
        }
        guard orderedSelectedVenueIds.count < venueLimit else {
            errorMessage = "Select up to \(venueLimit) active venues."
            return
        }
        selectedVenueIds.insert(id)
#if DEBUG
        print("[BusinessActiveVenueSelectionDebug] toggle venueId=\(id.uuidString.lowercased()) venueName=\(venueName) selectedCount=\(orderedSelectedVenueIds.count) selectedIds=\(Self.debugIdList(orderedSelectedVenueIds))")
#endif
    }

    @MainActor
    private func save() async {
        guard canSave else { return }
        let payloadVenueIds = orderedSelectedVenueIds
        guard payloadVenueIds.count == selectedCount, payloadVenueIds.count <= venueLimit else {
            errorMessage = "Selection changed. Please review your active venues and try again."
            return
        }
        isSaving = true
        defer { isSaving = false }
        let saved = await viewModel.saveFreeActiveVenueSelection(
            businessId: businessId,
            selectedVenueIds: payloadVenueIds,
            venueLimit: venueLimit
        )
        if saved {
            onSaved()
            dismiss()
        } else {
            errorMessage = "Could not save active venues. Please try again."
        }
    }

    private func venueSubtitle(_ row: VenueProfileRow) -> String {
        let city = row.city?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = row.state?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let location = [city, state].filter { !$0.isEmpty }.joined(separator: ", ")
        let approved = approvedDateText(row)
        return location.isEmpty ? approved : "\(location) • \(approved)"
    }

    private func venueName(for id: UUID) -> String {
        guard let row = uniqueVenueRows.first(where: { $0.id == id })?.row else {
            return "Venue"
        }
        let value = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? "Venue" : value
    }

    private static func initialSelectedVenueIds(venues: [VenueProfileRow], venueLimit: Int) -> Set<UUID> {
        var seen = Set<UUID>()
        let uniqueRows = venues.filter { row in
            guard let id = row.id else { return false }
            return seen.insert(id).inserted
        }
        var selected = uniqueRows.filter { MapViewModel.venueIsActiveForBusinessLimit($0) }.compactMap(\.id)
        if selected.count < venueLimit {
            let existing = Set(selected)
            selected.append(contentsOf: uniqueRows.compactMap(\.id).filter { !existing.contains($0) }.prefix(venueLimit - selected.count))
        }
        return Set(selected.prefix(venueLimit))
    }

    private static func debugIdList(_ ids: [UUID]) -> String {
        ids.map { $0.uuidString.lowercased() }.joined(separator: ",")
    }

    private struct VenueSelectionRow: Identifiable {
        let id: UUID
        let row: VenueProfileRow
    }
}
