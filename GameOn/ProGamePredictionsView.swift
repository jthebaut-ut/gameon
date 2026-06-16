import SwiftUI
import Combine

private enum ProGamePredictionCardMetrics {
    static let cornerRadius: CGFloat = 18
    static let optionHeight: CGFloat = 118
    static let scoreHeight: CGFloat = 156
    static let horizontalPadding: CGFloat = 10
}

private enum ProGamePredictionSummaryCardCopy {
    static func compactTeamName(_ team: String, languageCode: String) -> String {
        let original = CountryFlagHelper.displayName(for: team, languageCode: languageCode)
        let normalized = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "Team" }
        switch normalized {
        case "united states", "united states of america": return "USA"
        case "united kingdom", "great britain": return "UK"
        case "united arab emirates": return "UAE"
        case "netherlands": return "NED"
        default: return original
        }
    }

    static func fanVoteLabel(count: Int) -> String {
        let formatted = fanVoteCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return count == 1 ? "\(formatted) fan voted" : "\(formatted) fans voted"
    }

    static func summaryLines(
        predictions: VenueEventUserPredictions?,
        teams: VenueEventPredictionTeams,
        languageCode: String,
        isLocked: Bool
    ) -> (primary: String?, secondary: String?) {
        guard let predictions, predictions.hasAnyPrediction else {
            return (nil, isLocked ? "Voting closed" : "Tap to make your prediction")
        }

        var primary: String?
        var secondary: String?

        if let awayScore = predictions.awayScore, let homeScore = predictions.homeScore {
            let awayName = compactTeamName(teams.away, languageCode: languageCode)
            let homeName = compactTeamName(teams.home, languageCode: languageCode)
            primary = "Your pick: \(awayName) \(awayScore)–\(homeScore) \(homeName)"
        } else if let winner = predictions.winner, !winner.isEmpty {
            let winnerTitle = winner == "Draw"
                ? "Draw"
                : compactTeamName(winner, languageCode: languageCode)
            primary = "Your pick: \(winnerTitle)"
        }

        if let firstScoreTeam = predictions.firstScoreTeam, !firstScoreTeam.isEmpty {
            let firstTitle = firstScoreTeam == "No goals"
                ? "No goals"
                : compactTeamName(firstScoreTeam, languageCode: languageCode)
            secondary = "First scorer: \(firstTitle)"
        }

        return (primary, secondary)
    }

    private static let fanVoteCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

struct ProGamePredictionSummaryCard: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let game: SavedProGame
    let summary: ProGamePredictionSummary?
    let action: () -> Void

    private var isLocked: Bool { game.proGamePredictionsAreLocked }
    private var participantCount: Int { summary?.participantCount ?? 0 }
    private var fanVoteText: String {
        ProGamePredictionSummaryCardCopy.fanVoteLabel(count: participantCount)
    }

    private var summaryLines: (primary: String?, secondary: String?) {
        ProGamePredictionSummaryCardCopy.summaryLines(
            predictions: summary?.userPredictions,
            teams: game.proGamePredictionTeams,
            languageCode: appLanguageRaw,
            isLocked: isLocked
        )
    }

    var body: some View {
        Button(action: action) {
            cardContent
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("Opens predictions")
    }

    private var cardContent: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                statusHeader
                fanVoteRow
                summaryPrimaryLine
                summarySecondaryLine
            }

            Spacer(minLength: 0)

            Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(cardBackground)
        .overlay(cardBorder)
    }

    private var statusHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: isLocked ? "lock.fill" : "trophy.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(FGColor.accentGreen)
            Text(isLocked ? "Predictions Locked" : "Predictions Open")
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
    }

    private var fanVoteRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 10, weight: .semibold))
            Text(fanVoteText)
                .font(.caption2.weight(.semibold))
        }
        .foregroundStyle(FGColor.mutedText(colorScheme))
    }

    @ViewBuilder
    private var summaryPrimaryLine: some View {
        if let primary = summaryLines.primary {
            Text(primary)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var summarySecondaryLine: some View {
        if let secondary = summaryLines.secondary {
            let isPromptLine = summaryLines.primary == nil
            Text(secondary)
                .font(.caption2.weight(isPromptLine ? .semibold : .regular))
                .foregroundStyle(isPromptLine ? FGColor.secondaryText(colorScheme) : FGColor.mutedText(colorScheme))
                .lineLimit(isPromptLine ? 2 : 1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08))
    }

    private var cardBorder: some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.28 : 0.18), lineWidth: 1)
    }

    private var accessibilityLabel: String {
        var parts = [isLocked ? "Predictions locked" : "Predictions open", fanVoteText]
        if let primary = summaryLines.primary {
            parts.append(primary)
        }
        if let secondary = summaryLines.secondary {
            parts.append(secondary)
        }
        return parts.joined(separator: ", ")
    }
}

struct ProGamePredictionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: MapViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let game: SavedProGame

    @State private var selectedWinner = ""
    @State private var selectedFirstScore = ""
    @State private var homeScore = 0
    @State private var awayScore = 0
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?
    @State private var now = Date()

    private let scoreRange = 0...20
    private let lockTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var teams: VenueEventPredictionTeams { game.proGamePredictionTeams }
    private var isSoccer: Bool { game.liveSportVisualType == .soccer }
    private var summary: ProGamePredictionSummary {
        viewModel.proGamePredictionSummaries[game.stableKey] ?? .empty(proGameID: game.stableKey)
    }
    private var isLocked: Bool { now > game.proGamePredictionLockTime }
    private var canEdit: Bool { !isLocked && viewModel.canUseFanSocialFeatures }
    private var bottomInsetPadding: CGFloat {
        if isLocked { return 24 }
        return canEdit ? 96 : 24
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    matchupHeader
                    lockBanner

                    if isLoading {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 28)
                    } else if isLocked {
                        lockedUserSummary
                    } else {
                        editableSections
                    }

                    overallPredictionsSection

                    if let errorMessage {
                        Text(errorMessage)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.dangerRed)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }

                    footerNote
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, bottomInsetPadding)
            }
            .fanGeoScreenBackground()
            .navigationTitle("Predictions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.body.weight(.semibold))
                    }
                    .disabled(isSaving)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            .task {
                await loadPredictionData()
                await viewModel.startProGamePredictionRealtime(for: game.stableKey)
            }
            .onDisappear {
                Task { await viewModel.stopProGamePredictionRealtime(for: game.stableKey) }
            }
            .onReceive(lockTimer) { value in
                now = value
            }
        }
    }

    private var matchupHeader: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                matchupTeamColumn(
                    team: teams.away,
                    flag: teamFlag(for: teams.away)
                )
                Text("VS")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(.horizontal, 4)
                matchupTeamColumn(
                    team: teams.home,
                    flag: teamFlag(for: teams.home)
                )
            }
            .frame(maxWidth: .infinity)

            Text(Self.matchDateLine(for: game))
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            Text(game.league)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }

    private func matchupTeamColumn(team: String, flag: String?) -> some View {
        VStack(spacing: 8) {
            Text(TeamTheme.safeFlag(flag) ?? " ")
                .font(.system(size: 34))
                .frame(height: 40)
            Text(compactTeamName(team))
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
    }

    private var lockBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill((isLocked ? Color.gray : FGColor.accentGreen).opacity(colorScheme == .dark ? 0.22 : 0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isLocked ? FGColor.mutedText(colorScheme) : FGColor.accentGreen)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(isLocked ? "Voting closed" : "Voting closes 10 minutes after kickoff")
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(isLocked ? "10 minutes have passed since kickoff." : closesInText)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            (isLocked ? Color.gray : FGColor.accentGreen).opacity(colorScheme == .dark ? 0.20 : 0.10),
                            Color.white.opacity(colorScheme == .dark ? 0.04 : 0.55)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    (isLocked ? Color.gray : FGColor.accentGreen).opacity(colorScheme == .dark ? 0.28 : 0.18),
                    lineWidth: 1
                )
        )
    }

    private var closesInText: String {
        let remaining = max(0, game.proGamePredictionLockTime.timeIntervalSince(now))
        if remaining <= 0 { return "Closing soon" }
        let total = Int(remaining)
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        if days > 0 {
            return "Closes in \(days)d \(hours)h \(minutes)m"
        }
        if hours > 0 {
            return "Closes in \(hours)h \(minutes)m"
        }
        return "Closes in \(minutes)m"
    }

    @ViewBuilder
    private var editableSections: some View {
        predictionSection(number: 1, title: "Who will win?") {
            horizontalWinnerOptions
        }

        predictionSection(number: 2, title: "Exact score") {
            scoreSteppers
        }

        predictionSection(number: 3, title: "Which team will score first?") {
            horizontalFirstScoreOptions
        }
    }

    private var horizontalWinnerOptions: some View {
        HStack(spacing: 8) {
            ProGamePredictionOptionCard(
                title: compactTeamName(teams.away),
                flag: teamFlag(for: teams.away),
                isSelected: selectedWinner == teams.away,
                colorScheme: colorScheme
            ) {
                guard canEdit, !isSaving else { return }
                selectedWinner = teams.away
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            if isSoccer {
                ProGamePredictionOptionCard(
                    title: "Draw",
                    flag: nil,
                    isSelected: selectedWinner == "Draw",
                    colorScheme: colorScheme
                ) {
                    guard canEdit, !isSaving else { return }
                    selectedWinner = "Draw"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            ProGamePredictionOptionCard(
                title: compactTeamName(teams.home),
                flag: teamFlag(for: teams.home),
                isSelected: selectedWinner == teams.home,
                colorScheme: colorScheme
            ) {
                guard canEdit, !isSaving else { return }
                selectedWinner = teams.home
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private var horizontalFirstScoreOptions: some View {
        HStack(spacing: 8) {
            ProGamePredictionOptionCard(
                title: compactTeamName(teams.away),
                flag: teamFlag(for: teams.away),
                isSelected: selectedFirstScore == teams.away,
                colorScheme: colorScheme
            ) {
                guard canEdit, !isSaving else { return }
                selectedFirstScore = teams.away
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            if isSoccer {
                ProGamePredictionOptionCard(
                    title: "No goals",
                    flag: nil,
                    isSelected: selectedFirstScore == "No goals",
                    colorScheme: colorScheme
                ) {
                    guard canEdit, !isSaving else { return }
                    selectedFirstScore = "No goals"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            ProGamePredictionOptionCard(
                title: compactTeamName(teams.home),
                flag: teamFlag(for: teams.home),
                isSelected: selectedFirstScore == teams.home,
                colorScheme: colorScheme
            ) {
                guard canEdit, !isSaving else { return }
                selectedFirstScore = teams.home
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private var scoreSteppers: some View {
        HStack(alignment: .center, spacing: 10) {
            ProGamePredictionScoreCard(
                teamName: compactTeamName(teams.away),
                flag: teamFlag(for: teams.away),
                score: awayScore,
                colorScheme: colorScheme,
                canDecrement: canEdit && !isSaving && awayScore > scoreRange.lowerBound,
                canIncrement: canEdit && !isSaving && awayScore < scoreRange.upperBound,
                onDecrement: { awayScore = max(scoreRange.lowerBound, awayScore - 1) },
                onIncrement: { awayScore = min(scoreRange.upperBound, awayScore + 1) }
            )

            Text(":")
                .font(.system(size: 28, weight: .black, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .padding(.horizontal, 2)

            ProGamePredictionScoreCard(
                teamName: compactTeamName(teams.home),
                flag: teamFlag(for: teams.home),
                score: homeScore,
                colorScheme: colorScheme,
                canDecrement: canEdit && !isSaving && homeScore > scoreRange.lowerBound,
                canIncrement: canEdit && !isSaving && homeScore < scoreRange.upperBound,
                onDecrement: { homeScore = max(scoreRange.lowerBound, homeScore - 1) },
                onIncrement: { homeScore = min(scoreRange.upperBound, homeScore + 1) }
            )
        }
    }

    private var lockedUserSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Your predictions")
                .font(FGTypography.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            if summary.userPredictions?.hasAnyPrediction == true {
                if let winner = summary.userPredictions?.winner, !winner.isEmpty {
                    lockedPredictionChip(
                        title: winner == "Draw" ? "Draw" : compactTeamName(winner),
                        subtitle: "Winner",
                        flag: winner == "Draw" ? nil : teamFlag(for: winner)
                    )
                }
                if let home = summary.userPredictions?.homeScore,
                   let away = summary.userPredictions?.awayScore {
                    lockedPredictionChip(
                        title: "\(away) - \(home)",
                        subtitle: "Exact score",
                        flag: nil
                    )
                }
                if let first = summary.userPredictions?.firstScoreTeam, !first.isEmpty {
                    lockedPredictionChip(
                        title: first == "No goals" ? "No goals" : compactTeamName(first),
                        subtitle: "First to score",
                        flag: first == "No goals" ? nil : teamFlag(for: first)
                    )
                }
            } else {
                Text("You did not submit predictions before voting closed.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(glassCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
    }

    private func lockedPredictionChip(title: String, subtitle: String, flag: String?) -> some View {
        HStack(spacing: 10) {
            if let flag {
                Text(TeamTheme.safeFlag(flag) ?? " ")
                    .font(.title3)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                Text(title)
                    .font(FGTypography.body.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.12 : 0.07))
        )
    }

    private func predictionSection<Content: View>(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("\(number). \(title)")
                .font(.system(size: 15, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            content()
        }
    }

    private var overallPredictionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overall predictions")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 8)
                Text(summary.totalCount == 1 ? "1 prediction" : "\(summary.totalCount) predictions")
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
            }

            if summary.totalCount == 0 {
                Text("No predictions yet. Be the first to vote.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if hasWinnerCrowdData {
                    crowdBar(
                        title: compactTeamName(teams.away),
                        flag: teamFlag(for: teams.away),
                        percent: summary.winnerPercents[teams.away] ?? 0,
                        tint: FGColor.accentBlue
                    )
                    if isSoccer {
                        crowdBar(title: "Draw", flag: nil, percent: summary.winnerPercents["Draw"] ?? 0, tint: Color.gray)
                    }
                    crowdBar(
                        title: compactTeamName(teams.home),
                        flag: teamFlag(for: teams.home),
                        percent: summary.winnerPercents[teams.home] ?? 0,
                        tint: FGColor.accentGreen
                    )
                }

                if !summary.topScorePredictions.isEmpty {
                    Text("Top score picks")
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.top, 2)

                    VStack(spacing: 8) {
                        ForEach(summary.topScorePredictions) { pick in
                            HStack(spacing: 10) {
                                Text(pick.isOther ? "Other" : "\(pick.awayScore ?? 0) - \(pick.homeScore ?? 0)")
                                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Spacer(minLength: 0)
                                Text("\(pick.percent)%")
                                    .font(FGTypography.caption.weight(.black))
                                    .foregroundStyle(FGColor.accentGreen)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous)
                                            .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.10))
                                    )
                            }
                        }
                    }
                }

                if hasFirstScoreCrowdData {
                    Text("First to score")
                        .font(FGTypography.caption.weight(.bold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .padding(.top, 2)

                    crowdBar(
                        title: compactTeamName(teams.away),
                        flag: teamFlag(for: teams.away),
                        percent: summary.firstScorePercents[teams.away] ?? 0,
                        tint: FGColor.accentBlue
                    )
                    if isSoccer {
                        crowdBar(
                            title: "No goals",
                            flag: nil,
                            percent: summary.firstScorePercents["No goals"] ?? 0,
                            tint: Color.gray
                        )
                    }
                    crowdBar(
                        title: compactTeamName(teams.home),
                        flag: teamFlag(for: teams.home),
                        percent: summary.firstScorePercents[teams.home] ?? 0,
                        tint: FGColor.accentGreen
                    )
                }
            }
        }
        .padding(16)
        .background(glassCardBackground)
        .clipShape(RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.05), radius: 10, y: 4)
    }

    private var hasWinnerCrowdData: Bool {
        !(summary.winnerPercents.isEmpty && summary.winnerLeader == nil)
    }

    private var hasFirstScoreCrowdData: Bool {
        !summary.firstScorePercents.isEmpty
    }

    private func crowdBar(title: String, flag: String?, percent: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let flag {
                    Text(TeamTheme.safeFlag(flag) ?? "")
                        .font(.caption)
                }
                Text(title)
                    .font(FGTypography.caption.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(percent)%")
                    .font(FGTypography.caption.weight(.black))
                    .foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(FGColor.divider(colorScheme))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.85), tint.opacity(0.55)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(6, proxy.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: 7)
        }
    }

    private var glassCardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.92),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.06 : 0.04)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    @ViewBuilder
    private var footerNote: some View {
        Text(isLocked ? "Predictions are now locked." : "You can change your predictions until 10 minutes after kickoff.")
            .font(FGTypography.caption)
            .foregroundStyle(FGColor.mutedText(colorScheme))
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isLocked {
            Text("Predictions are now locked")
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial)
        } else if canEdit {
            VStack(spacing: 0) {
                Divider()
                FGPrimaryButton(title: isSaving ? "Saving..." : "Save Predictions", systemImage: "checkmark") {
                    Task { await savePredictions() }
                }
                .disabled(isSaving || !hasValidSelections)
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .background(.ultraThinMaterial)
        }
    }

    private var hasValidSelections: Bool {
        !selectedWinner.isEmpty || !selectedFirstScore.isEmpty || (homeScore >= 0 && awayScore >= 0)
    }

    private func compactTeamName(_ team: String) -> String {
        let original = CountryFlagHelper.displayName(for: team, languageCode: appLanguageRaw)
        let normalized = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return "Team" }
        switch normalized {
        case "united states", "united states of america": return "USA"
        case "united kingdom", "great britain": return "UK"
        case "united arab emirates": return "UAE"
        case "netherlands": return "NED"
        default: return original
        }
    }

    private func teamFlag(for team: String) -> String? {
        CountryFlagHelper.flag(for: team, source: "ProGamePredictions")
    }

    @MainActor
    private func loadPredictionData() async {
        isLoading = true
        defer { isLoading = false }
        await viewModel.refreshProGamePredictionSummary(proGameId: game.stableKey)
        do {
            let predictions = try await ProGamePredictionService.shared.fetchUserPrediction(proGameId: game.stableKey)
            selectedWinner = predictions.winner ?? ""
            selectedFirstScore = predictions.firstScoreTeam ?? ""
            homeScore = predictions.homeScore ?? 0
            awayScore = predictions.awayScore ?? 0
        } catch {
            if !VenueEventPredictionUserMessage.isCancellation(error) {
                errorMessage = error.localizedDescription
            }
        }
    }

    @MainActor
    private func savePredictions() async {
        guard canEdit, !isSaving else { return }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        do {
            if !selectedWinner.isEmpty {
                try await ProGamePredictionService.shared.upsertPrediction(
                    proGameId: game.stableKey,
                    predictionType: .winner,
                    predictedWinner: selectedWinner
                )
            }
            try await ProGamePredictionService.shared.upsertPrediction(
                proGameId: game.stableKey,
                predictionType: .score,
                predictedHomeScore: homeScore,
                predictedAwayScore: awayScore
            )
            if !selectedFirstScore.isEmpty {
                try await ProGamePredictionService.shared.upsertPrediction(
                    proGameId: game.stableKey,
                    predictionType: .firstScoreTeam,
                    predictedFirstScoreTeam: selectedFirstScore
                )
            }
            await viewModel.refreshProGamePredictionSummary(proGameId: game.stableKey)
        } catch {
            errorMessage = VenueEventPredictionUserMessage.message(for: error)
        }
    }

    private static func matchDateLine(for game: SavedProGame) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: game.startTime)
    }
}

private struct ProGamePredictionOptionCard: View {
    let title: String
    let flag: String?
    let isSelected: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                if let flag {
                    Text(TeamTheme.safeFlag(flag) ?? " ")
                        .font(.system(size: 24))
                        .frame(height: 28)
                } else {
                    Image(systemName: title == "Draw" ? "equal.circle.fill" : "minus.circle")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                        .frame(height: 28)
                }

                Text(title)
                    .font(.system(size: 12.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.75)
                    .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)

                ZStack {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    } else {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
                            .frame(width: 16, height: 16)
                    }
                }
                .frame(height: 18)
            }
            .padding(.horizontal, ProGamePredictionCardMetrics.horizontalPadding)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: ProGamePredictionCardMetrics.optionHeight)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected ? FGColor.accentGreen.opacity(0.82) : FGColor.divider(colorScheme),
                        lineWidth: isSelected ? 2 : 1
                    )
            }
            .shadow(
                color: FGColor.accentGreen.opacity(isSelected ? (colorScheme == .dark ? 0.18 : 0.12) : 0),
                radius: isSelected ? 10 : 0,
                y: isSelected ? 4 : 0
            )
            .scaleEffect(isSelected ? 1.02 : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.94),
                (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.14 : 0.07)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct ProGamePredictionScoreCard: View {
    let teamName: String
    let flag: String?
    let score: Int
    let colorScheme: ColorScheme
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Text(TeamTheme.safeFlag(flag) ?? " ")
                .font(.system(size: 24))
                .frame(height: 28)

            Text(teamName)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)

            Text("\(score)")
                .font(.system(size: 34, weight: .black, design: .rounded))
                .foregroundStyle(FGColor.accentGreen)
                .monospacedDigit()
                .frame(height: 38)

            HStack(spacing: 10) {
                scoreButton(symbol: "minus", enabled: canDecrement, action: onDecrement)
                scoreButton(symbol: "plus", enabled: canIncrement, action: onIncrement)
            }
        }
        .padding(.horizontal, ProGamePredictionCardMetrics.horizontalPadding)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, minHeight: ProGamePredictionCardMetrics.scoreHeight)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.94),
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: ProGamePredictionCardMetrics.cornerRadius, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1.2)
        }
        .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.12 : 0.08), radius: 10, y: 4)
    }

    private func scoreButton(symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(enabled ? FGColor.primaryText(colorScheme) : FGColor.mutedText(colorScheme))
                .frame(width: 38, height: 32)
                .background {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 0.8)
                        }
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

struct ProGamePredictionSheetContext: Identifiable {
    let game: SavedProGame
    var id: String { game.stableKey }
}
