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

    private var accessibilitySelection: String {
        displaySelection.isEmpty ? "Choose" : AppSportCatalog.displayLabel(forSportToken: displaySelection)
    }

    var body: some View {
        Button {
            showSheet = true
        } label: {
            HStack {
                Text(label)
                Spacer()
                SportSelectionValueView(sport: displaySelection)
            }
        }
        .accessibilityLabel("\(label): \(accessibilitySelection)")
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

struct SportSelectionValueView: View {
    let sport: String

    private var displaySport: String {
        AppSportCatalog.displayLabel(forSportToken: sport)
    }

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(sport)
    }

    var body: some View {
        let trimmedSport = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedSport.isEmpty {
            Text("Choose")
                .foregroundStyle(.secondary)
        } else {
            HStack(alignment: .center, spacing: 6) {
                if !visual.emoji.isEmpty {
                    Text(visual.emoji)
                        .font(.system(size: 16))
                        .baselineOffset(-0.5)
                } else {
                    Image(systemName: visual.systemImage)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(visual.accent)
                }
                Text(displaySport)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displaySport)
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
