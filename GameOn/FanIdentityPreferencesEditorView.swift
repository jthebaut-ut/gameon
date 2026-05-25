import SwiftUI

/// Self-service editor for public fan identity preferences (Account tab).
struct FanIdentityPreferencesEditorView: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var draft: FanIdentityPreferences = .empty
    @State private var isSaving = false
    @State private var message = ""

    private var selectedOpenToSet: Set<String> {
        Set(draft.openToItems)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Choose what you're open to with other fans.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))

                    openToCard

                    if !message.isEmpty {
                        Text(message)
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(message == "Saved." ? FGColor.accentGreen : .red.opacity(0.85))
                    }
                }
                .padding(14)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Edit Open To")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isSaving ? "Saving…" : "Save") {
                        Task { await save() }
                    }
                    .disabled(isSaving)
                }
            }
            .onAppear {
                draft = viewModel.currentUserFanIdentityPreferences
            }
        }
    }

    private var openToCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open To")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .textCase(.uppercase)
                .tracking(0.6)

            Text("Your selections")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            FanOpenToSelectedGrid(
                selectedIDs: draft.openToItems,
                onRemove: { id in removeOpenTo(id) }
            )

            Text("Social")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.top, 2)

            FanOpenToPickerGrid(
                activities: FanOpenToCatalog.socialActivities,
                selectedIDs: selectedOpenToSet,
                onSelect: { addOpenTo($0) }
            )

            Text("Pickup sports")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.top, 4)

            Text("Same sports as Community Games")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))

            FanOpenToPickerGrid(
                activities: FanOpenToCatalog.sportActivities,
                selectedIDs: selectedOpenToSet,
                onSelect: { addOpenTo($0) }
            )
        }
        .padding(12)
        .fanGeoGlassCard(cornerRadius: 18)
    }

    private func addOpenTo(_ activity: FanOpenToActivityDefinition) {
        guard !draft.openToItems.contains(activity.id) else { return }
        draft.openToItems.append(activity.id)
        print("[FanIdentityEditor] selectedOpenTo=\(activity.id)")
    }

    private func removeOpenTo(_ id: String) {
        draft.openToItems.removeAll { $0 == id }
        print("[FanIdentityEditor] removedOpenTo=\(id)")
    }

    @MainActor
    private func save() async {
        isSaving = true
        defer { isSaving = false }

        var normalized = draft
        normalized.openToItems = FanOpenToCatalog.canonicalizeItemIDs(normalized.openToItems).sorted()
        normalized.markOpenToSaved()

        if let err = await viewModel.saveFanIdentityPreferences(normalized) {
            message = err
        } else {
            print("[FanIdentityEditor] saveSuccess")
            message = "Saved."
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        }
    }
}
