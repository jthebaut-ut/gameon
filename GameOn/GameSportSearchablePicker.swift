import SwiftUI

// MARK: - Game forms (searchable; same stored strings as AppSportCatalog / Discover filters)

private struct GameSportPickerSelectionSheet: View {
    @Binding var selection: String
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var query: String = ""

    private var baseSports: [String] {
        AppSportCatalog.formPickerSportsOrdered
    }

    private var visibleSports: [String] {
        let trimmedSel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = baseSports
        if !trimmedSel.isEmpty, !list.contains(trimmedSel) {
            list = [trimmedSel] + list
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return list }
        return list.filter { $0.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if visibleSports.isEmpty {
                    ContentUnavailableView.search(text: query)
                } else {
                    List(visibleSports, id: \.self) { sport in
                        Button {
                            selection = sport
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                SportArtworkIconView(sport: sport, diameter: 40)
                                Text(sport)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer(minLength: 0)
                                if sport == selection.trimmingCharacters(in: .whitespacesAndNewlines) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(FGColor.accentBlue)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                    }
                }
            }
            .navigationTitle("Sport")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .searchable(text: $query, prompt: "Search sports")
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Inline row for `Form` — opens a searchable catalog sheet (not a horizontal chip row).
struct GameSportSearchablePickerFormRow: View {
    @Binding var selection: String
    var label: String = "Sport"

    @State private var showSheet = false

    private var displaySelection: String {
        selection.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack {
                Text(label)
                Spacer()
                Text(displaySelection.isEmpty ? "Choose" : displaySelection)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
            }
        }
        .accessibilityLabel("\(label): \(displaySelection.isEmpty ? "Choose" : displaySelection)")
        .sheet(isPresented: $showSheet) {
            GameSportPickerSelectionSheet(selection: $selection)
        }
    }
}

/// Styled control matching other padded controls on the venue owner “Add game” stack.
struct GameSportSearchablePickerDashboardCard: View {
    @Binding var selection: String
    var title: String = "Sport"

    @State private var showSheet = false

    private var displaySelection: String {
        selection.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack {
                Text(title)
                    .fontWeight(.semibold)
                Spacer()
                Text(displaySelection.isEmpty ? "Choose" : displaySelection)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showSheet) {
            GameSportPickerSelectionSheet(selection: $selection)
        }
    }
}
