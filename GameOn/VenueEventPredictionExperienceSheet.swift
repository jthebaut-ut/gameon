import SwiftUI
import Combine

struct VenueEventPredictionExperienceContext: Identifiable, Equatable {
    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let sportType: String
    let lockTime: Date?

    var id: UUID { venueEventID }
}

/// Full-screen venue prediction experience aligned with the redesigned Pro Game flow.
struct VenueEventPredictionExperienceSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var viewModel: MapViewModel
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let sportType: String
    let lockTime: Date?

    @State private var selectedWinner = ""
    @State private var selectedFirstScore = ""
    @State private var homeScore = 0
    @State private var awayScore = 0
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var isRefreshingSummary = false
    @State private var isEditingPredictions = true
    @State private var didSavePredictions = false
    @State private var errorMessage: String?
    @State private var now = Date()

    private let scoreRange = 0...20
    private let lockTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var isSoccer: Bool {
        let key = sportType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return key == "soccer" || key == "mls" || key == "premier league"
    }

    private var summary: VenueEventPredictionSummary {
        viewModel.venueEventPredictionSummaries[venueEventID] ?? .empty(eventID: venueEventID)
    }

    private var isLocked: Bool {
        if let lockTime, now > lockTime { return true }
        return false
    }

    private var canEdit: Bool {
        !isLocked && viewModel.canUseFanSocialFeatures
    }

    private var hasSubmittedPrediction: Bool {
        didSavePredictions || summary.userPredictions?.hasAnyPrediction == true
    }

    private var showSummaryMode: Bool {
        !isLocked && hasSubmittedPrediction && !isEditingPredictions
    }

    private var fanVoteCountText: String {
        let count = max(0, summary.totalCount)
        return count == 1 ? "1 fan has voted" : "\(count) fans have voted"
    }

    private var resolvedUserPredictions: VenueEventUserPredictions? {
        if isLocked { return summary.userPredictions }
        var predictions = VenueEventUserPredictions()
        if !selectedWinner.isEmpty { predictions.winner = selectedWinner }
        if !selectedFirstScore.isEmpty { predictions.firstScoreTeam = selectedFirstScore }
        predictions.homeScore = homeScore
        predictions.awayScore = awayScore
        return predictions.hasAnyPrediction ? predictions : summary.userPredictions
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    matchHeader

                    if !isLocked {
                        PredictionLockBanner(
                            isLocked: false,
                            closesInText: closesInText
                        )
                    } else {
                        PredictionLockBanner(isLocked: true)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else if isLocked {
                            lockedContent
                        } else if showSummaryMode {
                            summaryContent
                        } else {
                            votingContent
                        }

                        if let errorMessage {
                            Text(errorMessage)
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.dangerRed)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        if !showSummaryMode {
                            footerNote
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.bottom, canEdit && !showSummaryMode && !isLocked ? 96 : 24)
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
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        refreshSummaryManually()
                    } label: {
                        if isRefreshingSummary {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(isRefreshingSummary)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                bottomBar
            }
            .task {
                await loadPredictionData()
                await viewModel.startVenueEventPredictionRealtime(for: venueEventID)
            }
            .onDisappear {
                Task { await viewModel.stopVenueEventPredictionRealtime(for: venueEventID) }
            }
            .onReceive(lockTimer) { value in
                now = value
            }
        }
    }

    private var matchHeader: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                scheduledTeamCluster(team: teams.away)
                Text("VS")
                    .font(.system(size: 14, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                scheduledTeamCluster(team: teams.home)
            }

            Text(teams.displayMatchup)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
    }

    private func scheduledTeamCluster(team: String) -> some View {
        VStack(spacing: 8) {
            if let flag = teamFlag(for: team) {
                Text(flag)
                    .font(.system(size: 40))
            } else {
                Circle()
                    .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.12))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Text(String(compactTeamName(team).prefix(2)).uppercased())
                            .font(.caption.weight(.black))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                    }
            }
            Text(compactTeamName(team))
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.72)
                .frame(maxWidth: 96)
        }
    }

    private var votingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            predictionSection(number: 1, title: "Who will win?", showsVoteCountInHeader: true) {
                horizontalWinnerOptions
            }

            predictionSection(number: 2, title: "Exact score") {
                VStack(alignment: .leading, spacing: 10) {
                    if !scoreCrowdChips.isEmpty {
                        PredictionScoreCrowdChipRow(
                            chips: scoreCrowdChips,
                            colorScheme: colorScheme,
                            showsHeader: false,
                            compact: true,
                            onSelect: { chip in
                                guard canEdit, !isSaving else { return }
                                applyScoreChip(chip)
                            }
                        )
                    }
                    scoreSteppers
                }
            }

            predictionSection(number: 3, title: "Who will score first?", showsVoteCountInHeader: true) {
                horizontalFirstScoreOptions
            }
        }
    }

    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: PredictionPremiumMetrics.sectionSpacing) {
            PredictionSummaryCard(
                title: "YOUR PREDICTION",
                rows: yourPredictionRows,
                editButtonTitle: "Edit",
                colorScheme: colorScheme,
                onEdit: { isEditingPredictions = true }
            )

            fanConsensusSection(title: "FAN CONSENSUS", trailingCount: fanVoteCountText)
            popularScoresSection(title: "MOST POPULAR SCORES")

            if hasFirstGoalCrowdData {
                firstGoalConsensusSection(title: "FIRST GOAL CONSENSUS")
            }
        }
    }

    private var lockedContent: some View {
        VStack(alignment: .leading, spacing: PredictionPremiumMetrics.sectionSpacing) {
            if let predictions = resolvedUserPredictions, predictions.hasAnyPrediction {
                PredictionSummaryCard(
                    title: "YOUR PREDICTION",
                    rows: yourPredictionRows(from: predictions),
                    showsEdit: false,
                    colorScheme: colorScheme,
                    onEdit: {}
                )
            } else {
                Text("You did not submit predictions before voting closed.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }

            fanConsensusSection(title: "FAN CONSENSUS", trailingCount: fanVoteCountText)
            popularScoresSection(title: "MOST POPULAR SCORES")

            if hasFirstGoalCrowdData {
                firstGoalConsensusSection(title: "FIRST GOAL CONSENSUS")
            }
        }
    }

    @ViewBuilder
    private func popularScoresSection(title: String, limit: Int = 5) -> some View {
        if !summary.topScorePredictions.isEmpty {
            let rows = Array(summary.topScorePredictions.prefix(limit)).map { pick in
                (
                    label: pick.isOther ? "Other" : "\(pick.awayScore ?? 0)–\(pick.homeScore ?? 0)",
                    percent: pick.percent
                )
            }
            PredictionRankedScoresCard(title: title, rows: rows, colorScheme: colorScheme)
        }
    }

    private var horizontalWinnerOptions: some View {
        HStack(spacing: 6) {
            winnerOptionCard(team: teams.away, percent: summary.winnerPercents[teams.away] ?? 0, selected: selectedWinner == teams.away) {
                guard canEdit, !isSaving else { return }
                selectedWinner = teams.away
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            if isSoccer {
                winnerOptionCard(team: "Draw", percent: summary.winnerPercents["Draw"] ?? 0, selected: selectedWinner == "Draw") {
                    guard canEdit, !isSaving else { return }
                    selectedWinner = "Draw"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            winnerOptionCard(team: teams.home, percent: summary.winnerPercents[teams.home] ?? 0, selected: selectedWinner == teams.home) {
                guard canEdit, !isSaving else { return }
                selectedWinner = teams.home
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private var horizontalFirstScoreOptions: some View {
        HStack(spacing: 6) {
            winnerOptionCard(team: teams.away, percent: summary.firstScorePercents[teams.away] ?? 0, selected: selectedFirstScore == teams.away) {
                guard canEdit, !isSaving else { return }
                selectedFirstScore = teams.away
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            if isSoccer {
                winnerOptionCard(team: "No goals", percent: summary.firstScorePercents["No goals"] ?? 0, selected: selectedFirstScore == "No goals") {
                    guard canEdit, !isSaving else { return }
                    selectedFirstScore = "No goals"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            winnerOptionCard(team: teams.home, percent: summary.firstScorePercents[teams.home] ?? 0, selected: selectedFirstScore == teams.home) {
                guard canEdit, !isSaving else { return }
                selectedFirstScore = teams.home
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private func winnerOptionCard(
        team: String,
        percent: Int,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        PredictionOptionCard(
            title: team == "Draw" || team == "No goals" ? team : compactTeamName(team),
            flag: team == "Draw" || team == "No goals" ? nil : teamFlag(for: team),
            percent: percent,
            isSelected: selected,
            isSaving: false,
            colorScheme: colorScheme,
            action: action
        )
    }

    private var scoreSteppers: some View {
        HStack(alignment: .center, spacing: 10) {
            PredictionScoreStepperCard(
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

            PredictionScoreStepperCard(
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

    private var scoreCrowdChips: [PredictionScoreCrowdChip] {
        summary.topScorePredictions
            .filter { !$0.isOther }
            .prefix(5)
            .map { pick in
                let label = "\(pick.awayScore ?? 0)–\(pick.homeScore ?? 0)"
                let selected = awayScore == pick.awayScore && homeScore == pick.homeScore
                return PredictionScoreCrowdChip(label: label, percent: pick.percent, isSelected: selected)
            }
    }

    private func applyScoreChip(_ chip: PredictionScoreCrowdChip) {
        let parts = chip.label.split(separator: "–", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let away = Int(parts[0]),
              let home = Int(parts[1]) else { return }
        awayScore = away
        homeScore = home
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    @ViewBuilder
    private func fanConsensusSection(title: String, trailingCount: String) -> some View {
        PredictionConsensusSectionCard(title: title, trailingText: trailingCount, colorScheme: colorScheme) {
            if summary.totalCount == 0 {
                Text("No fan predictions were submitted for this match.")
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            } else if hasWinnerCrowdData {
                fanConsensusBar(title: compactTeamName(teams.away), flag: teamFlag(for: teams.away), percent: summary.winnerPercents[teams.away] ?? 0, tint: Color(red: 0.95, green: 0.45, blue: 0.28))
                if isSoccer {
                    fanConsensusBar(title: "Draw", flag: nil, percent: summary.winnerPercents["Draw"] ?? 0, tint: Color(red: 0.98, green: 0.78, blue: 0.18))
                }
                fanConsensusBar(title: compactTeamName(teams.home), flag: teamFlag(for: teams.home), percent: summary.winnerPercents[teams.home] ?? 0, tint: FGColor.accentBlue)
            }
        }
    }

    @ViewBuilder
    private func firstGoalConsensusSection(title: String) -> some View {
        PredictionConsensusSectionCard(title: title, colorScheme: colorScheme) {
            fanConsensusBar(title: compactTeamName(teams.away), flag: teamFlag(for: teams.away), percent: summary.firstScorePercents[teams.away] ?? 0, tint: Color(red: 0.95, green: 0.45, blue: 0.28))
            if isSoccer {
                fanConsensusBar(title: "No goals", flag: nil, percent: summary.firstScorePercents["No goals"] ?? 0, tint: Color(red: 0.98, green: 0.78, blue: 0.18))
            }
            fanConsensusBar(title: compactTeamName(teams.home), flag: teamFlag(for: teams.home), percent: summary.firstScorePercents[teams.home] ?? 0, tint: FGColor.accentBlue)
        }
    }

    private func fanConsensusBar(title: String, flag: String?, percent: Int, tint: Color) -> some View {
        PredictionConsensusBar(title: title, flag: flag, percent: percent, tint: tint, colorScheme: colorScheme)
    }

    private var hasWinnerCrowdData: Bool {
        !(summary.winnerPercents.isEmpty && summary.winnerLeader == nil)
    }

    private var hasFirstGoalCrowdData: Bool {
        !summary.firstScorePercents.isEmpty || summary.firstScoreLeader != nil
    }

    private var yourPredictionRows: [PredictionSummaryRow] {
        yourPredictionRows(from: resolvedUserPredictions)
    }

    private func yourPredictionRows(from predictions: VenueEventUserPredictions?) -> [PredictionSummaryRow] {
        var rows: [PredictionSummaryRow] = []
        if let winner = predictions?.winner, !winner.isEmpty {
            rows.append(PredictionSummaryRow(id: "winner", label: "Winner", value: winnerSummaryValue(winner), flag: summaryRowFlag(for: winner)))
        }
        if let home = predictions?.homeScore, let away = predictions?.awayScore {
            rows.append(PredictionSummaryRow(id: "score", label: "Exact Score", value: "\(away)–\(home)", emphasizesValue: true))
        }
        if let first = predictions?.firstScoreTeam, !first.isEmpty {
            rows.append(PredictionSummaryRow(id: "firstGoal", label: "First Goal", value: firstGoalSummaryValue(first), flag: summaryRowFlag(for: first)))
        }
        return rows
    }

    private func winnerSummaryValue(_ winner: String) -> String {
        if winner == "Draw" { return "Draw" }
        return "\(compactTeamName(winner)) Win"
    }

    private func firstGoalSummaryValue(_ team: String) -> String {
        if team == "No goals" { return "No goals" }
        return compactTeamName(team)
    }

    private func summaryRowFlag(for team: String) -> String? {
        if team == "Draw" || team == "No goals" { return nil }
        return teamFlag(for: team)
    }

    private func predictionSection<Content: View>(
        number: Int,
        title: String,
        showsVoteCountInHeader: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number). \(title)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 0)
                if showsVoteCountInHeader, summary.totalCount > 0 {
                    HStack(spacing: 5) {
                        Image(systemName: "person.2.fill")
                            .font(.caption2.weight(.semibold))
                        Text(fanVoteCountText)
                    }
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            content()
        }
    }

    private var footerNote: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock")
                .font(.caption2.weight(.semibold))
            Text(isLocked ? "Predictions are closed." : "You can change your predictions until 10 minutes after kickoff.")
        }
        .font(FGTypography.caption)
        .foregroundStyle(FGColor.mutedText(colorScheme))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if isLocked {
            Text("Predictions are closed")
                .font(FGTypography.caption.weight(.bold))
                .foregroundStyle(FGColor.mutedText(colorScheme))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(.ultraThinMaterial)
        } else if showSummaryMode && canEdit {
            VStack(spacing: 0) {
                Divider()
                FGPrimaryButton(title: "Edit Prediction", systemImage: "pencil") {
                    isEditingPredictions = true
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 10)
            }
            .background(.ultraThinMaterial)
        } else if canEdit && !showSummaryMode {
            VStack(spacing: 0) {
                Divider()
                FGPrimaryButton(title: isSaving ? "Saving..." : "Save Prediction", systemImage: "checkmark") {
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

    private var closesInText: String {
        guard let lockTime else { return "Closing soon" }
        let remaining = max(0, lockTime.timeIntervalSince(now))
        if remaining <= 0 { return "Closing soon" }
        let total = Int(remaining)
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        if hours > 0 { return "Closes in \(hours)h \(minutes)m" }
        return "Closes in \(minutes)m"
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
        CountryFlagHelper.flag(for: team, source: "VenueEventPredictionExperience")
    }

    private func refreshSummaryManually() {
        guard !isRefreshingSummary else { return }
        isRefreshingSummary = true
        Task {
            await viewModel.refreshVenueEventPredictionSummary(eventID: venueEventID)
            await MainActor.run { isRefreshingSummary = false }
        }
    }

    @MainActor
    private func loadPredictionData() async {
        isLoading = true
        defer { isLoading = false }
        await viewModel.refreshVenueEventPredictionSummary(eventID: venueEventID)
        do {
            let predictions = try await VenueEventPredictionService.shared.fetchUserPrediction(venueEventId: venueEventID)
            selectedWinner = predictions.winner ?? ""
            selectedFirstScore = predictions.firstScoreTeam ?? ""
            homeScore = predictions.homeScore ?? 0
            awayScore = predictions.awayScore ?? 0
            if predictions.hasAnyPrediction {
                didSavePredictions = true
                isEditingPredictions = false
            }
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
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .winner,
                    predictedWinner: selectedWinner
                )
            }
            try await VenueEventPredictionService.shared.upsertPrediction(
                venueEventId: venueEventID,
                predictionType: .score,
                predictedHomeScore: homeScore,
                predictedAwayScore: awayScore
            )
            if !selectedFirstScore.isEmpty {
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .firstScoreTeam,
                    predictedFirstScoreTeam: selectedFirstScore
                )
            }
            await viewModel.refreshVenueEventPredictionSummary(eventID: venueEventID)
            didSavePredictions = true
            isEditingPredictions = false
        } catch {
            errorMessage = VenueEventPredictionUserMessage.message(for: error)
            await revertToServerPredictions()
        }
    }

    @MainActor
    private func revertToServerPredictions() async {
        await viewModel.refreshVenueEventPredictionSummary(eventID: venueEventID)
        if let saved = summary.userPredictions {
            selectedWinner = saved.winner ?? ""
            selectedFirstScore = saved.firstScoreTeam ?? ""
            homeScore = saved.homeScore ?? 0
            awayScore = saved.awayScore ?? 0
        }
    }
}
