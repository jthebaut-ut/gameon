import SwiftUI

// MARK: - Game forms — grouped catalog matches Discover “More” + pickup / venue Manage Games

/// Inline row for `Form` — opens grouped catalog sheet (same sections as Discover Calendar More).
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
            GroupedSportPickerSheet(
                selectedSportToken: displaySelection,
                navigationTitle: "Sport",
                showsSearch: true,
                showsToolbarDone: true,
                onSelectSport: { selection = $0 }
            )
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
            GroupedSportPickerSheet(
                selectedSportToken: displaySelection,
                navigationTitle: "Sport",
                showsSearch: true,
                showsToolbarDone: true,
                onSelectSport: { selection = $0 }
            )
        }
    }
}
