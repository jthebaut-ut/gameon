import SwiftUI

// MARK: - Formatting

func predictionLocalizedWholePercent(_ percent: Int) -> String {
    (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
}

// MARK: - Premium metrics

enum PredictionPremiumMetrics {
    static let cornerRadius: CGFloat = 18
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 12
    static let rowSpacing: CGFloat = 8
    static let votingOptionHeight: CGFloat = 132
}

// MARK: - Premium card shell

struct PredictionPremiumCard<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.82 : 0.98))
            .clipShape(RoundedRectangle(cornerRadius: PredictionPremiumMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: PredictionPremiumMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.38 : 0.28), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.06), radius: 10, y: 4)
    }
}

struct PredictionPremiumCardHeader: View {
    let title: String
    var systemImage: String? = nil
    var trailingText: String? = nil
    var showsEdit: Bool = false
    var editButtonTitle: String = "Edit"
    var usesGreenTint: Bool = false
    let colorScheme: ColorScheme
    var onEdit: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
            }

            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(0.45)
                .foregroundStyle(usesGreenTint ? FGColor.accentGreen : FGColor.primaryText(colorScheme))

            Spacer(minLength: 0)

            if let trailingText {
                Text(trailingText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .lineLimit(1)
            }

            if showsEdit, let onEdit {
                Button(action: onEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                            .font(.caption2.weight(.bold))
                        Text(editButtonTitle)
                            .font(.caption.weight(.bold))
                    }
                    .foregroundStyle(FGColor.accentGreen)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, PredictionPremiumMetrics.cardPadding)
        .padding(.vertical, 12)
        .background {
            if usesGreenTint {
                LinearGradient(
                    colors: [
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.12),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.08 : 0.04)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
    }
}

// MARK: - Section header

struct PredictionSectionHeader: View {
    @Environment(\.colorScheme) private var colorScheme

    let number: Int?
    let title: String
    var systemImage: String? = nil
    var trailingText: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
            }

            if let number {
                Text("\(number). \(title)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            } else {
                Text(title)
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(0.4)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .textCase(number == nil ? .uppercase : nil)
            }

            Spacer(minLength: 0)

            if let trailingText {
                Text(trailingText)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Lock banner

struct PredictionLockBanner: View {
    @Environment(\.colorScheme) private var colorScheme

    let isLocked: Bool
    var closesInText: String? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(isLocked ? FGColor.dangerRed : FGColor.accentGreen)

            VStack(alignment: .leading, spacing: 4) {
                Text(isLocked ? "Voting closed" : "Voting closes 10 minutes after kickoff")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                if !isLocked, let closesInText {
                    Text(closesInText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    (isLocked ? FGColor.dangerRed : FGColor.accentGreen)
                        .opacity(colorScheme == .dark ? 0.14 : 0.08)
                )
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    (isLocked ? FGColor.dangerRed : FGColor.accentGreen).opacity(0.22),
                    lineWidth: 1
                )
        }
    }
}

// MARK: - Option card

struct PredictionOptionCard: View {
    let title: String
    let flag: String?
    let percent: Int
    let isSelected: Bool
    let isSaving: Bool
    let colorScheme: ColorScheme
    var compact: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: compact ? 6 : 6) {
                if let flag, !flag.isEmpty {
                    Text(TeamTheme.safeFlag(flag) ?? "")
                        .font(.system(size: compact ? 26 : 26))
                        .frame(height: compact ? 28 : 28)
                } else if title == "Draw" || title == "No goals" {
                    Text(title == "Draw" ? "=" : "∅")
                        .font(.system(size: compact ? 20 : 22, weight: .black, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .frame(height: compact ? 28 : 28)
                }

                Text(title)
                    .font(.system(size: compact ? 13 : 13, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, minHeight: compact ? 30 : 32, maxHeight: compact ? 30 : 32)

                Text(predictionLocalizedWholePercent(percent))
                    .font(.system(size: compact ? 20 : 20, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.primaryText(colorScheme))
                    .monospacedDigit()

                ZStack {
                    if isSaving {
                        ProgressView().controlSize(.mini)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: compact ? 15 : 14, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    } else {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.7), lineWidth: 1.5)
                            .frame(width: compact ? 17 : 16, height: compact ? 17 : 16)
                    }
                }
                .frame(height: compact ? 18 : 18)
            }
            .padding(.horizontal, compact ? 8 : 8)
            .padding(.vertical, compact ? 12 : 10)
            .frame(maxWidth: .infinity, minHeight: compact ? PredictionPremiumMetrics.votingOptionHeight : 118, maxHeight: compact ? PredictionPremiumMetrics.votingOptionHeight : 118)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: compact ? 16 : 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: compact ? 16 : 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? FGColor.accentGreen.opacity(0.88) : FGColor.divider(colorScheme).opacity(0.45),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardBackground: LinearGradient {
        if isSelected {
            return LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.11),
                    FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.94 : 0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        return LinearGradient(
            colors: [
                FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.92 : 0.98),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

// MARK: - Consensus bar

struct PredictionConsensusBar: View {
    let title: String
    let flag: String?
    let percent: Int
    let tint: Color
    let colorScheme: ColorScheme
    var compact: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 8) {
                if let flag, !flag.isEmpty {
                    Text(TeamTheme.safeFlag(flag) ?? "")
                        .font(compact ? .subheadline : .body)
                }
                Text(title)
                    .font(.system(size: compact ? 13 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(predictionLocalizedWholePercent(percent))
                    .font(.system(size: compact ? 15 : 18, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.32 : 0.20))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.65)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, proxy.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: compact ? 7 : 10)
        }
    }
}

// MARK: - Score crowd chips

struct PredictionScoreCrowdChip: Identifiable, Equatable {
    let id: String
    let label: String
    let percent: Int
    let isSelected: Bool

    init(label: String, percent: Int, isSelected: Bool = false) {
        self.label = label
        self.percent = percent
        self.isSelected = isSelected
        self.id = "\(label)|\(percent)"
    }
}

struct PredictionScoreCrowdChipRow: View {
    let chips: [PredictionScoreCrowdChip]
    let colorScheme: ColorScheme
    var showsHeader: Bool = true
    var compact: Bool = false
    var onSelect: ((PredictionScoreCrowdChip) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 0 : 8) {
            if showsHeader {
                Text("Most popular scores")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: compact ? 6 : 8) {
                    ForEach(chips) { chip in
                        Button {
                            onSelect?(chip)
                        } label: {
                            HStack(spacing: compact ? 4 : 6) {
                                Text(chip.label)
                                    .font(compact ? .caption2.weight(.bold) : .caption.weight(.bold))
                                Text(predictionLocalizedWholePercent(chip.percent))
                                    .font(.system(size: compact ? 10 : 11, weight: .black, design: .rounded))
                                    .foregroundStyle(chip.isSelected ? .white : FGColor.accentGreen)
                            }
                            .padding(.horizontal, compact ? 10 : 12)
                            .padding(.vertical, compact ? 6 : 8)
                            .background(
                                chip.isSelected
                                    ? FGColor.accentGreen
                                    : FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.09)
                            )
                            .foregroundStyle(chip.isSelected ? .white : FGColor.primaryText(colorScheme))
                            .clipShape(Capsule(style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .disabled(onSelect == nil)
                    }
                }
            }
        }
    }
}

// MARK: - Summary card

struct PredictionSummaryRow: Identifiable, Equatable {
    let id: String
    let label: String
    let value: String
    var flag: String?
    var emphasizesValue: Bool = false
}

struct PredictionSummaryCard: View {
    let title: String
    let rows: [PredictionSummaryRow]
    var showsEdit: Bool = true
    var editButtonTitle: String = "Edit"
    let colorScheme: ColorScheme
    let onEdit: () -> Void

    var body: some View {
        PredictionPremiumCard {
            VStack(alignment: .leading, spacing: 0) {
                PredictionPremiumCardHeader(
                    title: title,
                    systemImage: "checkmark.seal.fill",
                    showsEdit: showsEdit,
                    editButtonTitle: editButtonTitle,
                    usesGreenTint: true,
                    colorScheme: colorScheme,
                    onEdit: showsEdit ? onEdit : nil
                )

                VStack(spacing: 0) {
                    ForEach(rows) { row in
                        HStack(alignment: .center, spacing: 10) {
                            Text(row.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .frame(width: 78, alignment: .leading)

                            Spacer(minLength: 0)

                            HStack(spacing: 6) {
                                if let flag = row.flag, !flag.isEmpty {
                                    Text(TeamTheme.safeFlag(flag) ?? "")
                                        .font(row.emphasizesValue ? .title3 : .body)
                                }
                                Text(row.value)
                                    .font(
                                        row.emphasizesValue
                                            ? .system(size: 22, weight: .black, design: .rounded).monospacedDigit()
                                            : .subheadline.weight(.bold)
                                    )
                                    .foregroundStyle(
                                        row.emphasizesValue ? FGColor.accentGreen : FGColor.primaryText(colorScheme)
                                    )
                                    .multilineTextAlignment(.trailing)
                            }
                        }
                        .padding(.horizontal, PredictionPremiumMetrics.cardPadding)
                        .padding(.vertical, row.emphasizesValue ? 12 : 10)

                        if row.id != rows.last?.id {
                            Divider()
                                .padding(.leading, PredictionPremiumMetrics.cardPadding)
                                .opacity(0.28)
                        }
                    }
                }
                .padding(.bottom, 4)
            }
        }
    }
}

struct PredictionConsensusSectionCard<Content: View>: View {
    let title: String
    var trailingText: String? = nil
    let colorScheme: ColorScheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        PredictionPremiumCard {
            VStack(alignment: .leading, spacing: PredictionPremiumMetrics.rowSpacing) {
                PredictionPremiumCardHeader(
                    title: title,
                    systemImage: "person.3.fill",
                    trailingText: trailingText,
                    colorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: PredictionPremiumMetrics.rowSpacing) {
                    content()
                }
                .padding(.horizontal, PredictionPremiumMetrics.cardPadding)
                .padding(.bottom, PredictionPremiumMetrics.cardPadding)
            }
        }
    }
}

// MARK: - Score stepper card

struct PredictionScoreStepperCard: View {
    let teamName: String
    let flag: String?
    let score: Int
    let colorScheme: ColorScheme
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        VStack(spacing: 6) {
            Text(TeamTheme.safeFlag(flag) ?? " ")
                .font(.system(size: 24))
                .frame(height: 26)

            Text(teamName)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30)

            Text("\(score)")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(FGColor.accentGreen)
                .monospacedDigit()

            HStack(spacing: 10) {
                scoreButton(symbol: "minus", enabled: canDecrement, action: onDecrement)
                scoreButton(symbol: "plus", enabled: canIncrement, action: onIncrement)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(0.28), lineWidth: 1)
        }
    }

    private func scoreButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(enabled ? FGColor.primaryText(colorScheme) : FGColor.mutedText(colorScheme))
                .frame(width: 36, height: 36)
                .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

// MARK: - Ranked score list

struct PredictionRankedScoreRow: View {
    let label: String
    let percent: Int
    let colorScheme: ColorScheme
    var highlight: Bool = false
    var compact: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            HStack(spacing: 10) {
                Text(label)
                    .font(.system(size: compact ? 14 : 14, weight: .bold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .monospacedDigit()
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(predictionLocalizedWholePercent(percent))
                    .font(.system(size: compact ? 13 : 14, weight: .black, design: .rounded))
                    .foregroundStyle(highlight ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                    .monospacedDigit()
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.32 : 0.20))
                    Capsule()
                        .fill(
                            (highlight ? FGColor.accentGreen : FGColor.accentBlue)
                                .opacity(highlight ? 0.95 : 0.72)
                        )
                        .frame(width: max(6, proxy.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: compact ? 7 : 9)
        }
    }
}

struct PredictionRankedScoresCard: View {
    let title: String
    let rows: [(label: String, percent: Int)]
    let colorScheme: ColorScheme

    var body: some View {
        PredictionPremiumCard {
            VStack(alignment: .leading, spacing: PredictionPremiumMetrics.rowSpacing) {
                PredictionPremiumCardHeader(
                    title: title,
                    systemImage: "target",
                    colorScheme: colorScheme
                )

                VStack(alignment: .leading, spacing: PredictionPremiumMetrics.rowSpacing) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        PredictionRankedScoreRow(
                            label: row.label,
                            percent: row.percent,
                            colorScheme: colorScheme,
                            highlight: index == 0
                        )
                    }
                }
                .padding(.horizontal, PredictionPremiumMetrics.cardPadding)
                .padding(.bottom, PredictionPremiumMetrics.cardPadding)
            }
        }
    }
}
