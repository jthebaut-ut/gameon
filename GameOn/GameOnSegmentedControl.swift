import SwiftUI

struct GameOnSegmentedTab<Selection: Hashable>: Identifiable {
    let id: Selection
    let title: String
    var systemImage: String?
    var badge: String?
    var tint: Color?
    var showsActivityDot: Bool
    var accessibilityLabel: String?
    var activityAccessibilityLabel: String?

    init(
        id: Selection,
        title: String,
        systemImage: String? = nil,
        badge: String? = nil,
        tint: Color? = nil,
        showsActivityDot: Bool = false,
        accessibilityLabel: String? = nil,
        activityAccessibilityLabel: String? = nil
    ) {
        self.id = id
        self.title = title
        self.systemImage = systemImage
        self.badge = badge
        self.tint = tint
        self.showsActivityDot = showsActivityDot
        self.accessibilityLabel = accessibilityLabel
        self.activityAccessibilityLabel = activityAccessibilityLabel
    }
}

struct GameOnSegmentedControl<Selection: Hashable>: View {
    let tabs: [GameOnSegmentedTab<Selection>]
    @Binding var selection: Selection
    var accent: Color = FGColor.accentGreen
    var fillsWidth = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 8) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .background {
            Capsule(style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.32 : 0.64))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.58), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.045), radius: 9, y: 3)
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ tab: GameOnSegmentedTab<Selection>) -> some View {
        let isSelected = selection == tab.id
        let tint = tab.tint ?? accent

        return Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                selection = tab.id
            }
        } label: {
            VStack(spacing: 6) {
                HStack(spacing: 7) {
                    HStack(spacing: tab.systemImage == nil ? 0 : 4) {
                        if let systemImage = tab.systemImage {
                            Image(systemName: systemImage)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(isSelected ? tint : FGColor.secondaryText(colorScheme))
                        }

                        Text(tab.title)
                            .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                            .lineLimit(1)
                            .minimumScaleFactor(0.82)
                    }

                    if let badge = tab.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .foregroundStyle(isSelected ? tint : Color.orange.opacity(0.95))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule())
                            .accessibilityLabel(badge)
                    }

                    if tab.showsActivityDot {
                        Circle()
                            .fill(Color.orange.opacity(0.9))
                            .frame(width: 6, height: 6)
                            .accessibilityLabel(tab.activityAccessibilityLabel ?? "New activity")
                    }
                }
                .foregroundStyle(isSelected ? FGColor.primaryText(colorScheme) : FGColor.secondaryText(colorScheme))

                Capsule(style: .continuous)
                    .fill(isSelected ? tint.opacity(0.92) : Color.clear)
                    .frame(width: isSelected ? 24 : 12, height: 2)
                    .opacity(isSelected ? 1 : 0)
            }
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(isSelected ? tint.opacity(colorScheme == .dark ? 0.11 : 0.08) : Color.clear)
            }
            .shadow(color: tint.opacity(isSelected ? 0.16 : 0), radius: 10, y: 0)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985))
        .accessibilityLabel(tab.accessibilityLabel ?? tab.title)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
