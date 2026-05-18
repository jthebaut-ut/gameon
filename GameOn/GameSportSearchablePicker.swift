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
    var style: Style = .compact

    enum Style {
        case compact
        case businessRow

        var iconSize: CGFloat {
            switch self {
            case .compact: 16
            case .businessRow: 34
            }
        }

        var symbolSize: CGFloat {
            switch self {
            case .compact: 14
            case .businessRow: 30
            }
        }

        var textFont: Font {
            switch self {
            case .compact: .body
            case .businessRow: .system(size: 16, weight: .semibold, design: .rounded)
            }
        }

        var spacing: CGFloat {
            switch self {
            case .compact: 6
            case .businessRow: 8
            }
        }

        var foregroundStyle: AnyShapeStyle {
            switch self {
            case .compact: AnyShapeStyle(.secondary)
            case .businessRow: AnyShapeStyle(.primary)
            }
        }

        var iconFrame: CGFloat {
            switch self {
            case .compact: 18
            case .businessRow: 38
            }
        }

        var expandsToFillWidth: Bool {
            switch self {
            case .compact: true
            case .businessRow: false
            }
        }
    }

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
            HStack(alignment: .center, spacing: style.spacing) {
                if !visual.emoji.isEmpty {
                    Text(visual.emoji)
                        .font(.system(size: style.iconSize))
                        .baselineOffset(style == .businessRow ? -1 : -0.5)
                        .frame(width: style.iconFrame, height: style.iconFrame, alignment: .center)
                } else {
                    Image(systemName: visual.systemImage)
                        .font(.system(size: style.symbolSize, weight: .semibold, design: .rounded))
                        .foregroundStyle(visual.accent)
                        .frame(width: style.iconFrame, height: style.iconFrame, alignment: .center)
                }
                Text(displaySport)
                    .font(style.textFont)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
            }
            .foregroundStyle(style.foregroundStyle)
            .multilineTextAlignment(.trailing)
            .frame(maxWidth: style.expandsToFillWidth ? .infinity : nil, alignment: .trailing)
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
            HStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .layoutPriority(1)
                Spacer(minLength: 10)
                SportSelectionValueView(sport: displaySelection, style: .businessRow)
                    .layoutPriority(0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 54)
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
