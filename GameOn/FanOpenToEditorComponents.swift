import SwiftUI

// MARK: - Open To activity card

struct FanOpenToActivityCard: View {
    let activity: FanOpenToActivityDefinition
    let isSelected: Bool
    var showsRemoveButton: Bool = false
    var onTap: () -> Void = {}
    var onRemove: (() -> Void)?

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color {
        activity.tint(colorScheme: colorScheme)
    }

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 6) {
                    Image(systemName: activity.systemImage)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(tint)
                        .frame(height: 26)

                    Text(activity.title)
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .background(cardBackground)
                .overlay(cardBorder)

                if showsRemoveButton, let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 18, height: 18)
                            .background(Circle().fill(Color.black.opacity(0.55)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        tint.opacity(colorScheme == .dark ? 0.22 : 0.14),
                        Color.white.opacity(colorScheme == .dark ? 0.05 : 0.88)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(
                isSelected ? tint.opacity(0.65) : FGColor.divider(colorScheme).opacity(0.9),
                lineWidth: isSelected ? 1.5 : 0.75
            )
            .shadow(color: isSelected ? tint.opacity(0.28) : .clear, radius: 6, y: 2)
    }
}

// MARK: - Personality chip

struct FanPersonalityChip: View {
    let label: String
    let isSelected: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: onTap) {
            Text(label)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(isSelected ? .white : FGColor.primaryText(colorScheme))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background {
                    Capsule(style: .continuous)
                        .fill(
                            isSelected
                                ? LinearGradient(
                                    colors: [FGColor.accentBlue, FGColor.accentBlue.opacity(0.82)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                : LinearGradient(
                                    colors: [
                                        Color.white.opacity(colorScheme == .dark ? 0.07 : 0.82),
                                        Color.white.opacity(colorScheme == .dark ? 0.04 : 0.72)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                        )
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    isSelected ? FGColor.accentBlue.opacity(0.5) : FGColor.divider(colorScheme),
                                    lineWidth: isSelected ? 1 : 0.75
                                )
                        }
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Wrapping layout for personality chips

struct FanPersonalityChipFlow: View {
    let selectedIDs: Set<String>
    let onToggle: (FanPersonalityTag) -> Void

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 8)]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach(FanPersonalityTag.allCases) { tag in
                FanPersonalityChip(
                    label: tag.label,
                    isSelected: selectedIDs.contains(tag.rawValue),
                    onTap: { onToggle(tag) }
                )
            }
        }
    }
}

// MARK: - Open To picker grid (editor)

struct FanOpenToPickerGrid: View {
    let selectedIDs: Set<String>
    let onSelect: (FanOpenToActivityDefinition) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(FanOpenToCatalog.all) { activity in
                if !selectedIDs.contains(activity.id) {
                    FanOpenToActivityCard(
                        activity: activity,
                        isSelected: false,
                        onTap: { onSelect(activity) }
                    )
                }
            }
        }
    }
}

struct FanOpenToSelectedGrid: View {
    let selectedIDs: [String]
    let onRemove: (String) -> Void

    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]

    var body: some View {
        if selectedIDs.isEmpty {
            Text("Tap a sport or activity below to add it.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.mutedText(colorScheme))
        } else {
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(selectedIDs, id: \.self) { id in
                    if let activity = FanOpenToCatalog.definition(id: id) {
                        FanOpenToActivityCard(
                            activity: activity,
                            isSelected: true,
                            showsRemoveButton: true,
                            onTap: {},
                            onRemove: { onRemove(id) }
                        )
                    }
                }
            }
        }
    }

    @Environment(\.colorScheme) private var colorScheme
}
