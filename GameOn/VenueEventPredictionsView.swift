import SwiftUI
import UIKit

private enum InlineScoreSaveState: Equatable {
    case idle
    case saving
    case saved
    case failed
}

private enum PredictionTeamDisplayName {
    static func compact(_ teamName: String, languageCode: String) -> String {
        let original = CountryFlagHelper.displayName(for: teamName, languageCode: languageCode)
        let normalized = original.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let shortened: String
        switch normalized {
        case "united states", "united states of america":
            shortened = "USA"
        case "united kingdom", "great britain":
            shortened = "UK"
        case "united arab emirates":
            shortened = "UAE"
        case "netherlands":
            shortened = "NED"
        default:
            shortened = original
        }
#if DEBUG
        if VenueGameCardDiagnostics.enabled {
            print("[PredictionCardLayoutDebug] displayNameOriginal=\(original)")
            print("[PredictionCardLayoutDebug] displayNameShortened=\(shortened)")
        }
#endif
        return shortened
    }
}

private enum PredictionCardMetrics {
    static let matchupHeight: CGFloat = 136
    static let scoreHeight: CGFloat = 164
    static let sheetOptionMinHeight: CGFloat = 78
    static let flagHeight: CGFloat = 28
    static let nameHeight: CGFloat = 32
    static let horizontalPadding: CGFloat = 9
    static let scoreFlagHeight: CGFloat = 24
    static let scoreNameHeight: CGFloat = 28
    static let scoreNumberHeight: CGFloat = 31
    static let scoreControlTouchSize: CGFloat = 44
    static let scoreControlVisualHeight: CGFloat = 32
    static let scoreTopPadding: CGFloat = 10
    static let scoreBottomPadding: CGFloat = 13
    static let scoreVerticalSpacing: CGFloat = 4
    static let matchupFlagHeight: CGFloat = 26
    static let matchupNameHeight: CGFloat = 30
    static let matchupPercentHeight: CGFloat = 24
    static let matchupStatusHeight: CGFloat = 17
    static let matchupVerticalPadding: CGFloat = 10
    static let matchupVerticalSpacing: CGFloat = 5
}

struct VenueEventPredictionModule: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    var sportType: String = ""
    let summary: VenueEventPredictionSummary?
    var isLocked = false
    let onOpen: (VenueEventPredictionType) -> Void
    var onQuickVote: ((VenueEventPredictionType, String) async -> Bool)? = nil
    var onQuickScoreSave: ((Int, Int) async -> Bool)? = nil
    var onQuickScoreClear: (() async -> Bool)? = nil
    var onRefreshSummary: (() async -> Void)? = nil
    var onStartRealtime: (() async -> Void)? = nil
    var onStopRealtime: (() async -> Void)? = nil
    var onLockedTap: (() -> Void)? = nil
    @State private var selectedWinner = ""
    @State private var selectedFirstScore = ""
    @State private var selectedHomeScore: Int?
    @State private var selectedAwayScore: Int?
    @State private var savingSelectionKey: String?
    @State private var isRefreshingSummary = false
    @State private var scoreSaveState: InlineScoreSaveState = .idle
    @State private var scoreSaveTask: Task<Void, Never>?

    private var resolvedSummary: VenueEventPredictionSummary {
        summary ?? .empty(eventID: venueEventID)
    }

    private var userScoreSummaryText: String? {
        guard let selectedHomeScore, let selectedAwayScore else { return nil }
        return "Your score: \(homeDisplayName) \(selectedHomeScore)–\(selectedAwayScore) \(awayDisplayName)"
    }

    private var aggregateScoreSummaryText: String? {
        guard let scoreMode = resolvedSummary.scoreMode?.trimmingCharacters(in: .whitespacesAndNewlines),
              !scoreMode.isEmpty else {
            return nil
        }
        return "Predicted score: \(scoreMode.replacingOccurrences(of: " - ", with: "–"))"
    }

    private var homeDisplayName: String {
        PredictionTeamDisplayName.compact(teams.home, languageCode: appLanguageRaw)
    }

    private var awayDisplayName: String {
        PredictionTeamDisplayName.compact(teams.away, languageCode: appLanguageRaw)
    }

    private var inlineHomeScore: Int {
        selectedHomeScore ?? 0
    }

    private var inlineAwayScore: Int {
        selectedAwayScore ?? 0
    }

    private var hasInlineScorePrediction: Bool {
        selectedHomeScore != nil && selectedAwayScore != nil
    }

    var body: some View {
        predictionVotingCard
        .task(id: userPredictionLoadToken) {
            await loadUserPrediction()
        }
        .task(id: venueEventID) {
            await onStartRealtime?()
        }
        .onReceive(NotificationCenter.default.publisher(for: .venueEventUserPredictionDidChange)) { notification in
            guard let changedEventID = notification.userInfo?[VenueEventPredictionUserChangeKey.eventID] as? UUID,
                  changedEventID == venueEventID else {
                return
            }
            Task { await loadUserPrediction() }
        }
        .onAppear {
#if DEBUG
            if VenueGameCardDiagnostics.enabled {
                print("[PredictionUIDebug] homeTeam=\(teams.home)")
                print("[PredictionUIDebug] awayTeam=\(teams.away)")
                print("[PredictionUIDebug] homeFlag=\(CountryFlagHelper.flag(for: teams.home) ?? "none")")
                print("[PredictionUIDebug] awayFlag=\(CountryFlagHelper.flag(for: teams.away) ?? "none")")
                print("[PredictionUIDebug] teamType=home:\(teamDebugType(teams.home)),away:\(teamDebugType(teams.away))")
                print("[PredictionUIDebug] countryFlagApplied=home:\(CountryFlagHelper.flag(for: teams.home) != nil),away:\(CountryFlagHelper.flag(for: teams.away) != nil)")
                print("[PredictionUILayoutDebug] sport=\(sportType)")
                print("[PredictionUILayoutDebug] percentages=\(winnerPercentagesDebugDescription)")
                print("[PredictionUILayoutDebug] firstScoreRowLayout=true")
                print("[PredictionUILayoutDebug] firstScorePercentages=\(firstScorePercentagesDebugDescription)")
                print("[PredictionHeaderLayoutDebug] compactHeaderEnabled=true")
                print("[PredictionHeaderLayoutDebug] inlineMatchupApplied=true")
                print("[PredictionUIDebug] inlineScorePredictionRowRemoved=true")
                print("[ScorePredictionDebug] inlineModeEnabled=true")
                print("[PredictionCardLayoutDebug] equalCardSizeApplied=true")
                print("[PredictionCardLayoutDebug] compactCardSizingApplied=true")
                print("[PredictionCardLayoutDebug] cardWidth=flexEqual")
                print("[PredictionCardLayoutDebug] cardHeight=winner:\(PredictionCardMetrics.matchupHeight),score:\(PredictionCardMetrics.scoreHeight)")
                print("[PredictionCardLayoutDebug] controlsRecentered=true")
                print("[PredictionCardLayoutDebug] bottomPaddingAdjusted=true")
                print("[PredictionCardLayoutDebug] touchTargetsValidated=true")
                print("[PredictionCardLayoutDebug] restoredVerticalBreathingRoom=true")
                print("[PredictionCardLayoutDebug] checkmarkClippingResolved=true")
                print("[PredictionCardLayoutDebug] finalCardHeight=winner:\(PredictionCardMetrics.matchupHeight),score:\(PredictionCardMetrics.scoreHeight)")
                print("[ScorePredictionDebug] aggregateLoaded=\(!resolvedSummary.topScorePredictions.isEmpty)")
                print("[ScorePredictionDebug] aggregateTotal=\(resolvedSummary.scorePredictionTotal)")
                if let topScore = resolvedSummary.topScorePredictions.first, !topScore.isOther {
                    print("[ScorePredictionDebug] topScore=\(topScore.homeScore ?? 0)-\(topScore.awayScore ?? 0):\(topScore.percent)")
                }
            }
#endif
        }
        .onChange(of: resolvedSummary.totalCount) { oldValue, newValue in
#if DEBUG
            print("[RealtimeChainDebug] uiStateUpdated table=venue_event_predictions key=\(venueEventID.uuidString.lowercased()).predictionModuleTotal oldValue=\(oldValue) newValue=\(newValue)")
#endif
        }
        .onChange(of: resolvedSummary.winnerPercent) { oldValue, newValue in
#if DEBUG
            print("[RealtimeChainDebug] uiStateUpdated table=venue_event_predictions key=\(venueEventID.uuidString.lowercased()).predictionModuleWinnerPercent oldValue=\(oldValue ?? -1) newValue=\(newValue ?? -1)")
#endif
        }
        .onDisappear {
            scoreSaveTask?.cancel()
            Task { await onStopRealtime?() }
        }
    }

    private var userPredictionLoadToken: String {
        "\(venueEventID.uuidString)|score=\(resolvedSummary.scoreMode ?? "nil")|total=\(resolvedSummary.totalCount)"
    }

    private var predictionVotingCard: some View {
        VStack(alignment: .leading, spacing: FGSpacing.md) {
            compactPredictionHeader

            winnerMatchupSection(
                title: "Who wins?",
                icon: "trophy.fill",
                type: .winner
            )

            inlineScorePredictionSection

            firstScoreMatchupSection(
                title: "Which team scores first?",
                icon: "bolt.fill",
                type: .firstScoreTeam
            )
        }
        .padding(FGSpacing.md)
        .background {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(.ultraThinMaterial)
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.10),
                            FGColor.accentGreen.opacity(colorScheme == .dark ? 0.10 : 0.06)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.24 : 0.18), lineWidth: 1)
        }
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.06), radius: 12, y: 5)
    }

    private var compactPredictionHeader: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(compactHeaderTitle)
                    .font(FGTypography.caption.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                    .allowsTightening(true)

                Spacer(minLength: FGSpacing.xs)

                participantAvatars

                Text(predictionCountText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                predictionHeaderRefreshButton

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
            }

            Text(isLocked ? "Predictions closed" : "Make your pre-game picks")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(FGColor.secondaryText(colorScheme).opacity(0.82))
                .lineLimit(1)
        }
    }

    private var compactHeaderTitle: String {
        "\(L10n.t("before_the_game", languageCode: appLanguageRaw)) • \(teams.displayMatchup)"
    }

    private var predictionCountText: String {
        let count = resolvedSummary.totalCount
        return count == 1 ? "1 prediction" : "\(count) predictions"
    }

    private var predictionHeaderRefreshButton: some View {
        Button {
            refreshPredictionSummaryManually()
        } label: {
            ZStack {
                Circle()
                    .fill(.ultraThinMaterial)
                    .background {
                        Circle()
                            .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.12 : 0.07))
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.62), lineWidth: 0.8)
                    }

                if isRefreshingSummary {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(FGColor.secondaryText(colorScheme))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            .frame(width: 24, height: 24)
            .contentShape(Circle())
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.9, hapticOnPress: false))
        .disabled(isRefreshingSummary || onRefreshSummary == nil)
        .opacity(onRefreshSummary == nil ? 0.55 : 1)
        .accessibilityLabel("Refresh predictions")
    }

    private func refreshPredictionSummaryManually() {
        guard !isRefreshingSummary, let onRefreshSummary else { return }
#if DEBUG
        print("[PredictionRealtimeDebug] manualRefreshTapped eventId=\(venueEventID.uuidString.lowercased())")
#endif
        isRefreshingSummary = true
        Task {
            await onRefreshSummary()
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.18)) {
                    isRefreshingSummary = false
                }
            }
        }
    }

    private func teamDebugType(_ team: String) -> String {
        if CountryFlagHelper.isCountry(team) { return "country" }
        return FavoriteTeamCatalog.searchTeams(team).contains { candidate in
            candidate.kind == .team && candidate.name.caseInsensitiveCompare(team) == .orderedSame
        } ? "club" : "custom"
    }

    private var winnerOptions: [PredictionVotingOption] {
        let matchupOptions = [
            option(for: teams.home, type: .winner),
            option(for: teams.away, type: .winner)
        ]
        guard isSoccerPrediction else { return matchupOptions }
        return [
            matchupOptions[0],
            PredictionVotingOption(
                value: "Draw",
                title: "Draw",
                subtitle: nil,
                flag: nil,
                percent: resolvedSummary.winnerPercents["Draw"] ?? 0,
                avatars: resolvedSummary.winnerAvatarsByOption["Draw"] ?? []
            ),
            matchupOptions[1]
        ]
    }

    private var winnerMatchupOptions: (home: PredictionVotingOption, away: PredictionVotingOption) {
        (option(for: teams.home, type: .winner), option(for: teams.away, type: .winner))
    }

    private var drawOption: PredictionVotingOption {
        PredictionVotingOption(
            value: "Draw",
            title: "Draw",
            subtitle: nil,
            flag: nil,
            percent: resolvedSummary.winnerPercents["Draw"] ?? 0,
            avatars: resolvedSummary.winnerAvatarsByOption["Draw"] ?? []
        )
    }

    private var isSoccerPrediction: Bool {
        let normalized = sportType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized.contains("soccer") || normalized.contains("football") && normalized.contains("association")
    }

    private var winnerPercentagesDebugDescription: String {
        "home=\(winnerMatchupOptions.home.percent),away=\(winnerMatchupOptions.away.percent),draw=\(drawOption.percent)"
    }

    private var firstScoreMatchupOptions: (home: PredictionVotingOption, away: PredictionVotingOption) {
        (option(for: teams.home, type: .firstScoreTeam), option(for: teams.away, type: .firstScoreTeam))
    }

    private var firstScorePercentagesDebugDescription: String {
        "home=\(firstScoreMatchupOptions.home.percent),away=\(firstScoreMatchupOptions.away.percent)"
    }

    private var inlineScorePredictionSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Label("Predict exact score", systemImage: "target")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Spacer(minLength: 8)

                inlineScoreStatus

                if hasInlineScorePrediction {
                    Button {
                        clearInlineScorePrediction()
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(width: 24, height: 24)
                            .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.13 : 0.08))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear score")
                }
            }

            HStack(alignment: .center, spacing: 8) {
                ScorePredictionTeamCard(
                    teamName: homeDisplayName,
                    score: inlineHomeScore,
                    flag: CountryFlagHelper.flag(for: teams.home),
                    colorScheme: colorScheme,
                    canDecrement: inlineHomeScore > 0,
                    canIncrement: inlineHomeScore < 20,
                    onDecrement: { adjustInlineScore(isHome: true, delta: -1) },
                    onIncrement: { adjustInlineScore(isHome: true, delta: 1) }
                )

                Text("VS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 2)

                ScorePredictionTeamCard(
                    teamName: awayDisplayName,
                    score: inlineAwayScore,
                    flag: CountryFlagHelper.flag(for: teams.away),
                    colorScheme: colorScheme,
                    canDecrement: inlineAwayScore > 0,
                    canIncrement: inlineAwayScore < 20,
                    onDecrement: { adjustInlineScore(isHome: false, delta: -1) },
                    onIncrement: { adjustInlineScore(isHome: false, delta: 1) }
                )
            }

            inlineScoreCrowdSummary
        }
    }

    @ViewBuilder
    private var inlineScoreStatus: some View {
        switch scoreSaveState {
        case .saving:
            HStack(spacing: 5) {
                ProgressView()
                    .controlSize(.mini)
                Text("Saving")
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
        case .saved:
            Label("Saved", systemImage: "checkmark.circle.fill")
                .font(.caption2.weight(.bold))
                .foregroundStyle(FGColor.accentGreen)
        case .failed:
            Text("Try again")
                .font(.caption2.weight(.bold))
                .foregroundStyle(FGColor.dangerRed)
        case .idle:
            if let summary = userScoreSummaryText {
                Text(summary)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
    }

    private var inlineScoreCrowdSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let userScoreSummaryText {
                Text(userScoreSummaryText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            if resolvedSummary.topScorePredictions.isEmpty {
                Text("Be the first to predict the score.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            } else {
                Text("Top crowd picks")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .textCase(.uppercase)

                VStack(spacing: 5) {
                    ForEach(resolvedSummary.topScorePredictions) { pick in
                        HStack(spacing: 6) {
                            Text(scoreCrowdPickLabel(pick))
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)

                            Spacer(minLength: 4)

                            Text("\(pick.percent)%")
                                .font(.caption2.weight(.black))
                                .foregroundStyle(FGColor.accentGreen)
                                .monospacedDigit()
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.09 : 0.055))
                        .clipShape(Capsule(style: .continuous))
                    }
                }
            }
        }
    }

    private func scoreCrowdPickLabel(_ pick: VenueScorePredictionCrowdPick) -> String {
        if pick.isOther {
            return "Other"
        }
        let home = pick.homeScore ?? 0
        let away = pick.awayScore ?? 0
        if home == away {
            return "\(home)–\(away) Draw"
        }
        return "\(homeDisplayName) \(home)–\(away) \(awayDisplayName)"
    }

    private func option(for team: String, type: VenueEventPredictionType) -> PredictionVotingOption {
        let displayName = PredictionTeamDisplayName.compact(team, languageCode: appLanguageRaw)
        let percent: Int
        let avatars: [VenuePredictionParticipantAvatar]
        switch type {
        case .winner:
            percent = resolvedSummary.winnerPercents[team] ?? 0
            avatars = resolvedSummary.winnerAvatarsByOption[team] ?? []
        case .firstScoreTeam:
            percent = resolvedSummary.firstScorePercents[team] ?? 0
            avatars = resolvedSummary.firstScoreAvatarsByOption[team] ?? []
        case .score:
            percent = 0
            avatars = []
        }
        return PredictionVotingOption(
            value: team,
            title: displayName,
            subtitle: nil,
            flag: CountryFlagHelper.flag(for: team),
            percent: percent,
            avatars: avatars
        )
    }

    private func predictionVotingSection(
        title: String,
        icon: String,
        options: [PredictionVotingOption],
        type: VenueEventPredictionType
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            VStack(spacing: 8) {
                ForEach(options) { option in
                    PredictionOptionVotingCard(
                        option: option,
                        isSelected: selectedValue(for: type) == option.value,
                        isSaving: savingSelectionKey == selectionKey(type: type, value: option.value),
                        colorScheme: colorScheme
                    ) {
                        vote(type: type, value: option.value)
                    }
                }
            }
        }
    }

    private func winnerMatchupSection(
        title: String,
        icon: String,
        type: VenueEventPredictionType
    ) -> some View {
        let options = winnerMatchupOptions
        return VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(alignment: .center, spacing: 8) {
                PredictionMatchupTeamCard(
                    option: options.home,
                    isSelected: selectedValue(for: type) == options.home.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.home.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.home.value)
                }

                Text("VS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 2)

                PredictionMatchupTeamCard(
                    option: options.away,
                    isSelected: selectedValue(for: type) == options.away.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.away.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.away.value)
                }
            }

            if isSoccerPrediction {
                PredictionDrawChip(
                    option: drawOption,
                    isSelected: selectedValue(for: type) == drawOption.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: drawOption.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: drawOption.value)
                }
            }
        }
    }

    private func firstScoreMatchupSection(
        title: String,
        icon: String,
        type: VenueEventPredictionType
    ) -> some View {
        let options = firstScoreMatchupOptions
        return VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.caption.weight(.heavy))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(alignment: .center, spacing: 8) {
                PredictionMatchupTeamCard(
                    option: options.home,
                    isSelected: selectedValue(for: type) == options.home.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.home.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.home.value)
                }

                Text("VS")
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 2)

                PredictionMatchupTeamCard(
                    option: options.away,
                    isSelected: selectedValue(for: type) == options.away.value,
                    isSaving: savingSelectionKey == selectionKey(type: type, value: options.away.value),
                    colorScheme: colorScheme
                ) {
                    vote(type: type, value: options.away.value)
                }
            }
        }
    }

    private func selectedValue(for type: VenueEventPredictionType) -> String {
        switch type {
        case .winner:
            return selectedWinner
        case .firstScoreTeam:
            return selectedFirstScore
        case .score:
            return ""
        }
    }

    private func vote(type: VenueEventPredictionType, value: String) {
        guard !isLocked else {
            onLockedTap?()
            return
        }
        guard let onQuickVote else {
            onOpen(type)
            return
        }

        let previousWinner = selectedWinner
        let previousFirstScore = selectedFirstScore
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            if type == .winner {
                selectedWinner = value
            } else if type == .firstScoreTeam {
                selectedFirstScore = value
            }
            savingSelectionKey = selectionKey(type: type, value: value)
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#if DEBUG
        if type == .winner {
            print("[PredictionUIDebug] selectedWinner=\(value)")
        } else if type == .firstScoreTeam {
            print("[PredictionUIDebug] selectedFirstScore=\(value)")
            if VenueGameCardDiagnostics.enabled {
                print("[PredictionUILayoutDebug] selectedFirstScore=\(value)")
                print("[PredictionUILayoutDebug] firstScorePercentages=\(firstScorePercentagesDebugDescription)")
            }
        }
        if VenueGameCardDiagnostics.enabled {
            print("[PredictionUILayoutDebug] selectedOption=\(value)")
            print("[PredictionUILayoutDebug] percentages=\(winnerPercentagesDebugDescription)")
        }
#endif

        Task {
            let didSave = await onQuickVote(type, value)
            await MainActor.run {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                    savingSelectionKey = nil
                    if !didSave {
                        selectedWinner = previousWinner
                        selectedFirstScore = previousFirstScore
                    }
                }
            }
        }
    }

    private func adjustInlineScore(isHome: Bool, delta: Int) {
        guard !isLocked else {
            onLockedTap?()
            return
        }

        let previousHome = selectedHomeScore
        let previousAway = selectedAwayScore
        let currentHome = selectedHomeScore ?? 0
        let currentAway = selectedAwayScore ?? 0
        let nextHome = isHome ? min(20, max(0, currentHome + delta)) : currentHome
        let nextAway = isHome ? currentAway : min(20, max(0, currentAway + delta))
        guard nextHome != currentHome || nextAway != currentAway || !hasInlineScorePrediction else { return }

        withAnimation(.spring(response: 0.24, dampingFraction: 0.82)) {
            selectedHomeScore = nextHome
            selectedAwayScore = nextAway
            scoreSaveState = .saving
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#if DEBUG
        if delta > 0 {
            print("[ScorePredictionDebug] scoreIncremented=\(isHome ? "home" : "away")")
        } else {
            print("[ScorePredictionDebug] scoreDecremented=\(isHome ? "home" : "away")")
        }
        print("[ScorePredictionDebug] homeScore=\(nextHome)")
        print("[ScorePredictionDebug] awayScore=\(nextAway)")
#endif
        queueInlineScoreSave(home: nextHome, away: nextAway, previousHome: previousHome, previousAway: previousAway)
    }

    private func queueInlineScoreSave(home: Int, away: Int, previousHome: Int?, previousAway: Int?) {
        scoreSaveTask?.cancel()
#if DEBUG
        print("[ScorePredictionDebug] inlineSaveQueued=true")
#endif
        scoreSaveTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let didSave = await (onQuickScoreSave?(home, away) ?? false)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    if didSave {
                        scoreSaveState = .saved
                        notifyUserPredictionChanged()
#if DEBUG
                        print("[ScorePredictionDebug] inlineSaveSucceeded=true")
                        print("[ScorePredictionDebug] aggregateUpdatedAfterSave=true")
#endif
                    } else {
                        selectedHomeScore = previousHome
                        selectedAwayScore = previousAway
                        scoreSaveState = .failed
                    }
                }
            }
            guard didSave else { return }
            try? await Task.sleep(for: .milliseconds(1200))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                if scoreSaveState == .saved {
                    scoreSaveState = .idle
                }
            }
        }
    }

    private func clearInlineScorePrediction() {
        guard hasInlineScorePrediction else { return }
        guard !isLocked else {
            onLockedTap?()
            return
        }
        let previousHome = selectedHomeScore
        let previousAway = selectedAwayScore
        scoreSaveTask?.cancel()
        withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
            selectedHomeScore = nil
            selectedAwayScore = nil
            scoreSaveState = .saving
        }
#if DEBUG
        print("[ScorePredictionDebug] inlineClearTapped=true")
#endif
        Task {
            let didClear = await (onQuickScoreClear?() ?? false)
            await MainActor.run {
                withAnimation(.spring(response: 0.24, dampingFraction: 0.84)) {
                    if didClear {
                        scoreSaveState = .saved
                        notifyUserPredictionChanged()
                    } else {
                        selectedHomeScore = previousHome
                        selectedAwayScore = previousAway
                        scoreSaveState = .failed
                    }
                }
            }
            guard didClear else { return }
            try? await Task.sleep(for: .milliseconds(900))
            await MainActor.run {
                if scoreSaveState == .saved {
                    scoreSaveState = .idle
                }
            }
        }
    }

    private func selectionKey(type: VenueEventPredictionType, value: String) -> String {
        "\(type.rawValue)|\(value)"
    }

    @MainActor
    private func loadUserPrediction() async {
        do {
            let prediction = try await VenueEventPredictionService.shared.fetchUserPrediction(venueEventId: venueEventID)
            selectedWinner = prediction.winner ?? ""
            selectedFirstScore = prediction.firstScoreTeam ?? ""
            selectedHomeScore = prediction.homeScore
            selectedAwayScore = prediction.awayScore
#if DEBUG
            if !selectedWinner.isEmpty {
                print("[PredictionUIDebug] selectedWinner=\(selectedWinner)")
            }
            if !selectedFirstScore.isEmpty {
                print("[PredictionUIDebug] selectedFirstScore=\(selectedFirstScore)")
                if VenueGameCardDiagnostics.enabled {
                    print("[PredictionUILayoutDebug] selectedFirstScore=\(selectedFirstScore)")
                }
            }
            if let selectedHomeScore, let selectedAwayScore {
                print("[ScorePredictionDebug] loadedExistingScore=\(selectedHomeScore)-\(selectedAwayScore)")
            }
#endif
        } catch {
#if DEBUG
            print("[PredictionUIDebug] userPredictionLoadSkipped=\(error.localizedDescription)")
#endif
        }
    }

    private var participantAvatars: some View {
        HStack(spacing: -7) {
            ForEach(resolvedSummary.participantAvatars.prefix(3)) { avatar in
                VenuePredictionAvatarView(avatar: avatar)
            }
        }
        .frame(minWidth: resolvedSummary.participantAvatars.isEmpty ? 0 : 38, alignment: .trailing)
    }

    private func notifyUserPredictionChanged() {
        NotificationCenter.default.post(
            name: .venueEventUserPredictionDidChange,
            object: nil,
            userInfo: [
                VenueEventPredictionUserChangeKey.eventID: venueEventID,
                VenueEventPredictionUserChangeKey.predictionType: VenueEventPredictionType.score.rawValue
            ]
        )
    }

}

struct VenueEventPredictionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode

    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let predictionType: VenueEventPredictionType
    let onSaved: () async -> Void

    @State private var userPrediction = VenueEventUserPredictions()
    @State private var selectedTeam = ""
    @State private var awayScore = 0
    @State private var homeScore = 0
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let scoreRange = 0...20

    private var title: String {
        switch predictionType {
        case .winner:
            return "Who wins?"
        case .score:
            return "Score prediction"
        case .firstScoreTeam:
            return "Which team scores first?"
        }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: FGSpacing.lg) {
                Text(teams.displayMatchup)
                    .font(FGTypography.body.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))

                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                } else {
                    predictionEditor
                }

                if let errorMessage {
                    Text(errorMessage)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.dangerRed)
                }

                Spacer(minLength: 0)

                if predictionType == .score {
                    HStack(spacing: FGSpacing.sm) {
                        FGSecondaryButton(title: "Remove", systemImage: "trash") {
                            Task { await deletePrediction() }
                        }
                        .disabled(isSaving || isLoading)

                        FGPrimaryButton(title: isSaving ? "Saving..." : "Save", systemImage: "checkmark") {
                            Task { await savePrediction() }
                        }
                        .disabled(isSaving || isLoading || !scoreIsValid)
                    }
                } else {
                    FGSecondaryButton(title: "Remove", systemImage: "trash") {
                        Task { await deletePrediction() }
                    }
                    .disabled(isSaving || isLoading)
                }
            }
            .padding(22)
            .fanGeoScreenBackground()
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
#if DEBUG
                print("[ScorePredictionDebug] sheetOpened=\(predictionType == .score)")
#endif
                await loadUserPrediction()
            }
        }
    }

    private var scoreIsValid: Bool {
        scoreRange.contains(homeScore) && scoreRange.contains(awayScore)
    }

    @ViewBuilder
    private var predictionEditor: some View {
        switch predictionType {
        case .winner, .firstScoreTeam:
            VStack(spacing: FGSpacing.sm) {
                ForEach(sheetVotingOptions) { option in
                    PredictionOptionVotingCard(
                        option: option,
                        isSelected: selectedTeam == option.value,
                        isSaving: isSaving && selectedTeam == option.value,
                        colorScheme: colorScheme
                    ) {
                        selectedTeam = option.value
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#if DEBUG
                        if predictionType == .winner {
                            print("[PredictionUIDebug] selectedWinner=\(option.value)")
                        } else {
                            print("[PredictionUIDebug] selectedFirstScore=\(option.value)")
                        }
#endif
                        Task { await savePrediction() }
                    }
                }
            }
        case .score:
            VStack(alignment: .leading, spacing: FGSpacing.md) {
                HStack(alignment: .center, spacing: 8) {
                    ScorePredictionTeamCard(
                        teamName: PredictionTeamDisplayName.compact(teams.home, languageCode: appLanguageRaw),
                        score: homeScore,
                        flag: CountryFlagHelper.flag(for: teams.home),
                        colorScheme: colorScheme,
                        canDecrement: homeScore > scoreRange.lowerBound,
                        canIncrement: homeScore < scoreRange.upperBound,
                        onDecrement: { adjustScore(isHome: true, delta: -1) },
                        onIncrement: { adjustScore(isHome: true, delta: 1) }
                    )

                    Text("VS")
                        .font(.system(size: 11, weight: .black, design: .rounded))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .padding(.horizontal, 2)

                    ScorePredictionTeamCard(
                        teamName: PredictionTeamDisplayName.compact(teams.away, languageCode: appLanguageRaw),
                        score: awayScore,
                        flag: CountryFlagHelper.flag(for: teams.away),
                        colorScheme: colorScheme,
                        canDecrement: awayScore > scoreRange.lowerBound,
                        canIncrement: awayScore < scoreRange.upperBound,
                        onDecrement: { adjustScore(isHome: false, delta: -1) },
                        onIncrement: { adjustScore(isHome: false, delta: 1) }
                    )
                }

                Text("Pick the final score. 0–0 is valid.")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    private var sheetVotingOptions: [PredictionVotingOption] {
        let teamOptions = teams.options.map { team in
            let displayName = PredictionTeamDisplayName.compact(team, languageCode: appLanguageRaw)
            return PredictionVotingOption(
                value: team,
                title: displayName,
                subtitle: nil,
                flag: CountryFlagHelper.flag(for: team),
                percent: 0,
                avatars: []
            )
        }
        guard predictionType == .winner else { return teamOptions }
        return [
            teamOptions[0],
            PredictionVotingOption(value: "Draw", title: "Draw", subtitle: nil, flag: nil, percent: 0, avatars: []),
            teamOptions[1]
        ]
    }

    private func adjustScore(isHome: Bool, delta: Int) {
        if isHome {
            homeScore = min(scoreRange.upperBound, max(scoreRange.lowerBound, homeScore + delta))
        } else {
            awayScore = min(scoreRange.upperBound, max(scoreRange.lowerBound, awayScore + delta))
        }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
#if DEBUG
        print("[ScorePredictionDebug] homeScore=\(homeScore)")
        print("[ScorePredictionDebug] awayScore=\(awayScore)")
#endif
    }

    @MainActor
    private func loadUserPrediction() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let prediction = try await VenueEventPredictionService.shared.fetchUserPrediction(venueEventId: venueEventID)
            userPrediction = prediction
            switch predictionType {
            case .winner:
                selectedTeam = prediction.winner ?? ""
            case .score:
                homeScore = prediction.homeScore ?? 0
                awayScore = prediction.awayScore ?? 0
#if DEBUG
                if prediction.homeScore != nil || prediction.awayScore != nil {
                    print("[ScorePredictionDebug] loadedExistingScore=\(homeScore)-\(awayScore)")
                }
                print("[ScorePredictionDebug] homeScore=\(homeScore)")
                print("[ScorePredictionDebug] awayScore=\(awayScore)")
#endif
            case .firstScoreTeam:
                selectedTeam = prediction.firstScoreTeam ?? ""
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func savePrediction() async {
        guard predictionType != .score || scoreIsValid else {
            errorMessage = "Choose a valid score."
            return
        }
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
            switch predictionType {
            case .winner:
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .winner,
                    predictedWinner: selectedTeam
                )
            case .score:
#if DEBUG
                print("[ScorePredictionDebug] saveTapped=true")
                print("[ScorePredictionDebug] homeScore=\(homeScore)")
                print("[ScorePredictionDebug] awayScore=\(awayScore)")
#endif
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .score,
                    predictedHomeScore: homeScore,
                    predictedAwayScore: awayScore
                )
            case .firstScoreTeam:
                try await VenueEventPredictionService.shared.upsertPrediction(
                    venueEventId: venueEventID,
                    predictionType: .firstScoreTeam,
                    predictedFirstScoreTeam: selectedTeam
                )
            }
            await onSaved()
            notifyUserPredictionChanged()
#if DEBUG
            if predictionType == .score {
                print("[ScorePredictionDebug] saveSucceeded=true")
            }
#endif
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func deletePrediction() async {
        isSaving = true
        errorMessage = nil
        defer { isSaving = false }
        do {
#if DEBUG
            if predictionType == .score {
                print("[ScorePredictionDebug] removeTapped=true")
            }
#endif
            try await VenueEventPredictionService.shared.deletePrediction(
                venueEventId: venueEventID,
                predictionType: predictionType
            )
            await onSaved()
            notifyUserPredictionChanged()
#if DEBUG
            if predictionType == .score {
                print("[ScorePredictionDebug] removeSucceeded=true")
            }
#endif
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func notifyUserPredictionChanged() {
        NotificationCenter.default.post(
            name: .venueEventUserPredictionDidChange,
            object: nil,
            userInfo: [
                VenueEventPredictionUserChangeKey.eventID: venueEventID,
                VenueEventPredictionUserChangeKey.predictionType: predictionType.rawValue
            ]
        )
    }
}

private enum VenueEventPredictionUserChangeKey {
    static let eventID = "venueEventID"
    static let predictionType = "predictionType"
}

private extension Notification.Name {
    static let venueEventUserPredictionDidChange = Notification.Name("VenueEventUserPredictionDidChange")
}

private struct PredictionVotingOption: Identifiable, Equatable {
    let value: String
    let title: String
    let subtitle: String?
    let flag: String?
    let percent: Int
    let avatars: [VenuePredictionParticipantAvatar]

    var id: String { value }
}

private struct ScorePredictionTeamCard: View {
    let teamName: String
    let score: Int
    let flag: String?
    let colorScheme: ColorScheme
    let canDecrement: Bool
    let canIncrement: Bool
    let onDecrement: () -> Void
    let onIncrement: () -> Void

    var body: some View {
        VStack(spacing: PredictionCardMetrics.scoreVerticalSpacing) {
            Text(flag ?? " ")
                .font(.system(size: 25))
                .frame(height: PredictionCardMetrics.scoreFlagHeight)

            Text(teamName)
                .font(.system(size: 14, weight: .heavy, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.76)
                .frame(maxWidth: .infinity, minHeight: PredictionCardMetrics.scoreNameHeight, maxHeight: PredictionCardMetrics.scoreNameHeight)

            Text("\(score)")
                .font(.system(size: 30, weight: .black, design: .rounded))
                .foregroundStyle(FGColor.accentGreen)
                .monospacedDigit()
                .frame(height: PredictionCardMetrics.scoreNumberHeight)

            HStack(spacing: 10) {
                scoreControlButton(symbol: "minus", isEnabled: canDecrement, action: onDecrement)
                scoreControlButton(symbol: "plus", isEnabled: canIncrement, action: onIncrement)
            }
            .frame(height: PredictionCardMetrics.scoreControlTouchSize)
        }
        .padding(.horizontal, PredictionCardMetrics.horizontalPadding)
        .padding(.top, PredictionCardMetrics.scoreTopPadding)
        .padding(.bottom, PredictionCardMetrics.scoreBottomPadding)
        .frame(maxWidth: .infinity, minHeight: PredictionCardMetrics.scoreHeight, maxHeight: PredictionCardMetrics.scoreHeight)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.34 : 0.24), lineWidth: 1.2)
        }
        .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 12, y: 5)
        .accessibilityElement(children: .combine)
    }

    private func scoreControlButton(symbol: String, isEnabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .black))
                .foregroundStyle(isEnabled ? FGColor.primaryText(colorScheme) : FGColor.mutedText(colorScheme))
                .frame(width: PredictionCardMetrics.scoreControlTouchSize, height: PredictionCardMetrics.scoreControlTouchSize)
                .background {
                    Capsule(style: .continuous)
                        .fill(.ultraThinMaterial)
                        .frame(width: PredictionCardMetrics.scoreControlTouchSize, height: PredictionCardMetrics.scoreControlVisualHeight)
                        .background {
                            Capsule(style: .continuous)
                                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.13 : 0.08))
                                .frame(width: PredictionCardMetrics.scoreControlTouchSize, height: PredictionCardMetrics.scoreControlVisualHeight)
                        }
                }
                .overlay {
                    Capsule(style: .continuous)
                        .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.16), lineWidth: 0.8)
                        .frame(width: PredictionCardMetrics.scoreControlTouchSize, height: PredictionCardMetrics.scoreControlVisualHeight)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.09 : 0.94),
                FGColor.accentGreen.opacity(colorScheme == .dark ? 0.17 : 0.09),
                FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.05)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct PredictionMatchupTeamCard: View {
    let option: PredictionVotingOption
    let isSelected: Bool
    let isSaving: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: PredictionCardMetrics.matchupVerticalSpacing) {
                Text(option.flag ?? " ")
                    .font(.system(size: 26))
                    .frame(height: PredictionCardMetrics.matchupFlagHeight)

                Text(option.title)
                    .font(.system(size: 14.5, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.78)
                    .frame(maxWidth: .infinity, minHeight: PredictionCardMetrics.matchupNameHeight, maxHeight: PredictionCardMetrics.matchupNameHeight)

                Text("\(option.percent)%")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                    .monospacedDigit()
                    .frame(height: PredictionCardMetrics.matchupPercentHeight)

                ZStack {
                    if isSaving {
                        ProgressView()
                            .controlSize(.mini)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    } else {
                        Color.clear
                    }
                }
                .frame(height: PredictionCardMetrics.matchupStatusHeight)
            }
            .padding(.horizontal, PredictionCardMetrics.horizontalPadding)
            .padding(.vertical, PredictionCardMetrics.matchupVerticalPadding)
            .frame(maxWidth: .infinity, minHeight: PredictionCardMetrics.matchupHeight, maxHeight: PredictionCardMetrics.matchupHeight)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(
                        isSelected ? FGColor.accentGreen.opacity(0.76) : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.13),
                        lineWidth: isSelected ? 1.5 : 1
                    )
            }
            .shadow(
                color: (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.16 : 0.08),
                radius: isSelected ? 16 : 8,
                y: isSelected ? 7 : 3
            )
            .scaleEffect(isSelected ? 1.025 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.76), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.09 : 0.94),
                (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.18 : 0.09)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct PredictionDrawChip: View {
    let option: PredictionVotingOption
    let isSelected: Bool
    let isSaving: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(option.title)
                    .font(.caption.weight(.heavy))
                Text("\(option.percent)%")
                    .font(.caption.weight(.black))
                    .monospacedDigit()
                if isSaving {
                    ProgressView()
                        .controlSize(.mini)
                } else if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.caption.weight(.bold))
                }
            }
            .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background((isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.14 : 0.08))
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder((isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(0.28), lineWidth: 1)
            }
            .scaleEffect(isSelected ? 1.012 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct PredictionOptionVotingCard: View {
    let option: PredictionVotingOption
    let isSelected: Bool
    let isSaving: Bool
    let colorScheme: ColorScheme
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Text(option.flag ?? " ")
                    .font(.system(size: 26))
                    .frame(width: 34)

                VStack(alignment: .leading, spacing: 5) {
                    Text(option.title)
                        .font(.system(size: 15.5, weight: .heavy, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.82)
                        .frame(minHeight: 36, alignment: .leading)

                    if let subtitle = option.subtitle {
                        Text(subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    if !option.avatars.isEmpty {
                        HStack(spacing: -7) {
                            ForEach(option.avatars.prefix(3)) { avatar in
                                VenuePredictionAvatarView(avatar: avatar)
                            }
                        }
                        .padding(.top, 1)
                    }
                }

                Spacer(minLength: 8)

                VStack(alignment: .trailing, spacing: 5) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.mini)
                    } else if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(FGColor.accentGreen)
                    }

                    Text("\(option.percent)%")
                        .font(.system(size: 22, weight: .black, design: .rounded))
                        .foregroundStyle(isSelected ? FGColor.accentGreen : FGColor.primaryText(colorScheme))
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: PredictionCardMetrics.sheetOptionMinHeight, alignment: .leading)
            .background(cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        isSelected ? FGColor.accentGreen.opacity(0.72) : FGColor.accentBlue.opacity(colorScheme == .dark ? 0.16 : 0.12),
                        lineWidth: isSelected ? 1.4 : 1
                    )
            }
            .shadow(
                color: (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.16 : 0.08),
                radius: isSelected ? 14 : 8,
                y: isSelected ? 6 : 3
            )
            .scaleEffect(isSelected ? 1.015 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var cardBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.08 : 0.92),
                (isSelected ? FGColor.accentGreen : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.16 : 0.08)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}

private struct VenuePredictionAvatarView: View {
    @Environment(\.colorScheme) private var colorScheme

    let avatar: VenuePredictionParticipantAvatar

    private var imageURL: URL? {
        let raw = avatar.avatarThumbnailURL ?? avatar.avatarURL
        return raw.flatMap(URL.init(string:))
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(FGColor.cardBackground(colorScheme))
            if let imageURL {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .scaledToFill()
                    default:
                        fallback
                    }
                }
            } else {
                fallback
            }
        }
        .frame(width: 22, height: 22)
        .clipShape(Circle())
        .overlay(Circle().stroke(FGColor.cardBackground(colorScheme), lineWidth: 2))
    }

    private var fallback: some View {
        Text(String(avatar.displayName.prefix(1)).uppercased())
            .font(.caption2.weight(.bold))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(FGColor.accentBlue.opacity(0.18))
    }
}
