import SwiftUI
import Combine

private enum ProGamePredictionCardMetrics {
    static let cornerRadius: CGFloat = 18
    static let optionHeight: CGFloat = 118
    static let scoreHeight: CGFloat = 156
    static let horizontalPadding: CGFloat = 10
}

private enum ProGamePredictionFooterCopy {
    static func fanVoteLabel(count: Int) -> String {
        let formatted = fanVoteCountFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
        return count == 1 ? "\(formatted) fan voted" : "\(formatted) fans voted"
    }

    private static let fanVoteCountFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()
}

private enum ProGamePredictionEmptySentimentCopy {
    static func message(isFinal: Bool, isLocked: Bool) -> String {
        if isFinal {
            return "No fan predictions were submitted for this match."
        }
        if isLocked {
            return "No fan predictions were submitted before voting closed."
        }
        return "No predictions yet. Be the first to vote."
    }
}

private enum ProGamePredictionFooterPresentation {
    case open
    case locked
    case results

    init(game: SavedProGame) {
        if game.isFinal {
            self = .results
        } else if game.proGamePredictionsAreLocked {
            self = .locked
        } else {
            self = .open
        }
    }

    var emoji: String {
        switch self {
        case .open: return "🎯"
        case .locked: return "🔒"
        case .results: return "🏆"
        }
    }

    var title: String {
        switch self {
        case .open: return "Predictions Open"
        case .locked: return "Predictions Closed"
        case .results: return "Prediction Results"
        }
    }
}

struct ProGamePredictionFooterRow: View {
    @Environment(\.colorScheme) private var colorScheme

    let game: SavedProGame
    let summary: ProGamePredictionSummary?
    let action: () -> Void

    private var presentation: ProGamePredictionFooterPresentation {
        ProGamePredictionFooterPresentation(game: game)
    }

    private var participantCount: Int { summary?.participantCount ?? 0 }

    private var fanVoteText: String {
        ProGamePredictionFooterCopy.fanVoteLabel(count: participantCount)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(presentation.emoji)
                    .font(.system(size: 13))

                Text(presentation.title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)

                Text("•")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))

                Text(fanVoteText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.mutedText(colorScheme).opacity(0.85))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(footerBackground)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(presentation.title), \(fanVoteText)")
        .accessibilityHint("Opens predictions")
    }

    private var footerBackground: Color {
        switch presentation {
        case .open:
            return FGColor.accentGreen.opacity(colorScheme == .dark ? 0.12 : 0.07)
        case .locked:
            return Self.closedFooterTint.opacity(colorScheme == .dark ? 0.16 : 0.10)
        case .results:
            return FGColor.mutedText(colorScheme).opacity(colorScheme == .dark ? 0.14 : 0.08)
        }
    }

    private static let closedFooterTint = Color(red: 0.95, green: 0.62, blue: 0.14)
}

private enum ProGamePredictionOutcomeStatus: String {
    case correct = "Correct"
    case incorrect = "Incorrect"
    case stillInPlay = "Still in play"
}

private enum ProGamePredictionSheetMetrics {
    static let premiumCornerRadius: CGFloat = 18
    static let sentimentBarHeight: CGFloat = 10
    static let closedBannerTint = Color(red: 0.95, green: 0.62, blue: 0.14)
    static let headerVerticalPadding: CGFloat = 28
    static let headerHorizontalPadding: CGFloat = 20
    static let headerEmblemSize: CGFloat = 40
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
    private var displayGame: SavedProGame {
        viewModel.currentSavedProGameSnapshot(game)
    }
    private var resolvedUserPredictions: VenueEventUserPredictions? {
        if isLocked {
            return summary.userPredictions
        }
        var predictions = VenueEventUserPredictions()
        if !selectedWinner.isEmpty { predictions.winner = selectedWinner }
        if !selectedFirstScore.isEmpty { predictions.firstScoreTeam = selectedFirstScore }
        predictions.homeScore = homeScore
        predictions.awayScore = awayScore
        return predictions.hasAnyPrediction ? predictions : summary.userPredictions
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
                    predictionMatchHeader

                    VStack(alignment: .leading, spacing: FGSpacing.lg) {
                        if isLocked, shouldShowLivePredictionStatus {
                            livePredictionStatusSection
                        }

                        lockBanner

                        if isLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else if isLocked {
                            myPicksSection
                        } else {
                            editableSections
                        }

                        fanSentimentSection

                        if let errorMessage {
                            Text(errorMessage)
                                .font(FGTypography.caption)
                                .foregroundStyle(FGColor.dangerRed)
                                .frame(maxWidth: .infinity, alignment: .center)
                        }

                        footerNote
                    }
                    .padding(.horizontal, 18)
                }
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

    private var predictionMatchHeader: some View {
        VStack(spacing: 20) {
            if showsScoreboardHeader {
                scoreboardHeaderContent
            } else {
                scheduledHeaderContent
            }

            if showsScoreboardHeader {
                matchStatusBadge
            } else {
                Text(headerDateLine)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(headerSecondaryText)
                    .multilineTextAlignment(.center)
            }

            headerGoalScorerSection

            headerCompetitionRow
        }
        .padding(.horizontal, ProGamePredictionSheetMetrics.headerHorizontalPadding)
        .padding(.vertical, ProGamePredictionSheetMetrics.headerVerticalPadding)
        .frame(maxWidth: .infinity)
        .background(predictionHeaderBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.35 : 0.18))
                .frame(height: 1)
        }
    }

    private var showsScoreboardHeader: Bool {
        if displayGame.isFinal { return true }
        if displayGame.matchStatus.isHappeningNow { return true }
        if let match = hydratedLiveMatch, match.scoresAreAvailable { return true }
        return displayGame.scoreHome > 0 || displayGame.scoreAway > 0
    }

    private var hydratedLiveMatch: LiveMatch? {
        viewModel.liveMatches.first { SavedProGame.stableKey(for: $0) == displayGame.stableKey }
    }

    private var headerFeaturedEvent: FeaturedEvent? {
        guard let slug = displayGame.featuredEventSlug?.trimmingCharacters(in: .whitespacesAndNewlines),
              !slug.isEmpty else {
            return nil
        }
        let normalizedSlug = LiveMatchFilters.normalizedSearchText(slug)
        return viewModel.activeFeaturedEvents.first {
            LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug
        } ?? FeaturedEvent.fallbackEvents.first {
            LiveMatchFilters.normalizedSearchText($0.slug) == normalizedSlug
        }
    }

    private var predictionHeaderScoreboardStyle: ProGameScoreboardStyle {
        ProGameScoreboardStyle(
            scoreFont: .system(size: 42, weight: .black, design: .rounded).monospacedDigit(),
            separatorFont: .system(size: 30, weight: .bold, design: .rounded),
            teamNameFont: .title3.weight(.bold),
            emblemSize: ProGamePredictionSheetMetrics.headerEmblemSize,
            scoreRowSpacing: 10,
            teamNameSpacing: 6,
            teamScoreGap: 14,
            sectionSpacing: 8
        )
    }

    private var scoreboardHeaderContent: some View {
        ProGameScoreboardView(
            awayIdentity: teamIdentity(for: displayGame.awayTeam),
            homeIdentity: teamIdentity(for: displayGame.homeTeam),
            awayScore: displayGame.scoreAway,
            homeScore: displayGame.scoreHome,
            style: predictionHeaderScoreboardStyle,
            scoreColor: displayGame.matchStatus.isHappeningNow && !displayGame.isFinal ? FGColor.dangerRed : headerPrimaryText,
            teamNameColor: headerPrimaryText,
            metadataColor: headerSecondaryText
        )
    }

    private var scheduledHeaderContent: some View {
        HStack(alignment: .center, spacing: 14) {
            scheduledTeamCluster(team: displayGame.awayTeam)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("VS")
                .font(.system(size: 14, weight: .black, design: .rounded))
                .foregroundStyle(headerSecondaryText)
                .layoutPriority(1)
                .fixedSize()

            scheduledTeamCluster(team: displayGame.homeTeam)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private func scheduledTeamCluster(team: String) -> some View {
        let identity = teamIdentity(for: team)
        return HStack(spacing: 8) {
            scheduledTeamEmblem(identity)
            Text(identity.displayName)
                .font(.title3.weight(.bold))
                .foregroundStyle(headerPrimaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .multilineTextAlignment(.leading)
        }
    }

    @ViewBuilder
    private func scheduledTeamEmblem(_ identity: ProGameTeamScoreIdentity) -> some View {
        switch identity.leading {
        case let .flag(flag):
            Text(flag)
                .font(.system(size: ProGamePredictionSheetMetrics.headerEmblemSize))
                .accessibilityHidden(true)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                Color.clear
            }
            .frame(width: ProGamePredictionSheetMetrics.headerEmblemSize, height: ProGamePredictionSheetMetrics.headerEmblemSize)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }

    private var matchStatusBadge: some View {
        Text(matchStatusLabel)
            .font(.caption.weight(.heavy))
            .tracking(0.8)
            .foregroundStyle(matchStatusColor)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(matchStatusColor.opacity(colorScheme == .dark ? 0.14 : 0.10))
            )
    }

    @ViewBuilder
    private var headerGoalScorerSection: some View {
        if let summary = headerGoalTimelineSummary {
            ProGameScoringTimelineView(
                summary: summary,
                homeTeam: displayGame.homeTeam,
                awayTeam: displayGame.awayTeam,
                headingText: summary.goalScorersHeadingText,
                maxVisibleLines: headerGoalTimelineMaxVisibleLines,
                headingFont: .subheadline.weight(.bold),
                lineFont: .subheadline.weight(.medium),
                headingColor: headerSecondaryText,
                lineColor: headerPrimaryText,
                flagSource: "Predictions"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerGoalTimelineSummary: LiveScoringTimelineSummary? {
        guard showsScoreboardHeader else { return nil }
        guard savedProGameHasKnownScore else { return nil }

        let mergedTimelineEvents = displayGame.timelineEvents ?? []
        let summary = LiveScoringTimelineBuilder.resolvedGoalDisplaySummary(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents,
            scoreAway: displayGame.scoreAway,
            scoreHome: displayGame.scoreHome,
            awayTeam: displayGame.awayTeam,
            homeTeam: displayGame.homeTeam,
            flagSource: "Predictions"
        )
        guard let summary, summary.hasContent else { return nil }

        if displayGame.isFinal || summary.isScoreOnlyFallback {
            return summary
        }
        guard let firstEntry = summary.entries.first else { return nil }
        return LiveScoringTimelineSummary(sportIcon: summary.sportIcon, entries: [firstEntry])
    }

    private var savedProGameHasKnownScore: Bool {
        displayGame.scoreHome > 0 || displayGame.scoreAway > 0
    }

    private var headerGoalTimelineMaxVisibleLines: Int {
        displayGame.isFinal ? LiveScoringTimelineSummary.defaultMaxVisibleTimelineLines : 1
    }

    private var headerCompetitionRow: some View {
        ProGameLeagueChip(
            sportType: displayGame.liveSportVisualType,
            featuredEvent: headerFeaturedEvent,
            league: displayGame.league
        )
    }

    private var headerDateLine: String {
        let date = displayGame.startTime.formatted(.dateTime.month(.abbreviated).day().year())
        let time = CompactGameTimeFormatter.timeWithZone(
            for: displayGame.startTime,
            timeZoneOption: viewModel.selectedTimeZone
        )
        return "\(date) · \(time)"
    }

    private var matchStatusLabel: String {
        switch displayGame.matchStatus {
        case .live:
            if displayGame.liveSportVisualType == .soccer,
               let minute = displayGame.minute,
               minute > 0 {
                return "LIVE \(minute)'"
            }
            if let clock = displayGame.liveClockText?.trimmingCharacters(in: .whitespacesAndNewlines),
               !clock.isEmpty {
                return clock
            }
            return "LIVE"
        case .halfTime:
            return "HT"
        case .fullTime:
            return "FINAL"
        case .scheduled:
            return "Scheduled"
        }
    }

    private var matchStatusColor: Color {
        switch displayGame.matchStatus {
        case .live, .halfTime:
            return FGColor.dangerRed
        case .fullTime:
            return FGColor.mutedText(colorScheme)
        case .scheduled:
            return FGColor.secondaryText(colorScheme)
        }
    }

    private func teamIdentity(for team: String) -> ProGameTeamScoreIdentity {
        ProGameTeamScoreIdentity.resolve(
            teamName: team,
            badgeURL: teamBadgeURL(for: team),
            source: "Predictions"
        )
    }

    private func teamBadgeURL(for team: String) -> String? {
        hydratedLiveMatch?.badgeURL(forTeamName: team)
    }

    private var predictionHeaderBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.98, green: 0.98, blue: 0.99)
            : Color.white
    }

    private var headerPrimaryText: Color {
        Color(red: 0.08, green: 0.09, blue: 0.11)
    }

    private var headerSecondaryText: Color {
        Color(red: 0.36, green: 0.39, blue: 0.44)
    }

    private var lockBanner: some View {
        let bannerTint = isLocked ? ProGamePredictionSheetMetrics.closedBannerTint : FGColor.accentGreen
        return HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(bannerTint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    .frame(width: 34, height: 34)
                Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isLocked ? ProGamePredictionSheetMetrics.closedBannerTint : FGColor.accentGreen)
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
                            bannerTint.opacity(colorScheme == .dark ? 0.20 : 0.10),
                            premiumCardFill.opacity(colorScheme == .dark ? 0.92 : 0.88)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(
                    bannerTint.opacity(colorScheme == .dark ? 0.28 : 0.18),
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

    private var shouldShowLivePredictionStatus: Bool {
        guard isLocked else { return false }
        guard resolvedUserPredictions?.hasAnyPrediction == true else { return false }
        if displayGame.matchStatus.isHappeningNow || displayGame.isFinal { return true }
        return displayGame.firstScoringTeam != nil
    }

    private var myPicksSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            premiumSectionHeader(title: "MY PICKS", systemImage: "checkmark.seal.fill")

            if let predictions = resolvedUserPredictions, predictions.hasAnyPrediction {
                VStack(spacing: 10) {
                    if let winner = predictions.winner, !winner.isEmpty {
                        myPickRow(
                            icon: "✅",
                            title: winnerPickTitle(winner),
                            crowdPercent: crowdPercentForWinnerPick(winner)
                        )
                    }
                    if let home = predictions.homeScore, let away = predictions.awayScore {
                        myPickRow(
                            icon: "🎯",
                            title: "Correct Score \(away)–\(home)",
                            crowdPercent: crowdPercentForScorePick(away: away, home: home)
                        )
                    }
                    if let first = predictions.firstScoreTeam, !first.isEmpty {
                        myPickRow(
                            icon: "⚽",
                            title: firstGoalPickTitle(first),
                            crowdPercent: crowdPercentForFirstGoalPick(first)
                        )
                    }
                }
            } else {
                Text("You did not submit predictions before voting closed.")
                    .font(FGTypography.caption)
                    .foregroundStyle(premiumSecondaryText)
            }
        }
        .premiumCardStyle(colorScheme: colorScheme)
    }

    private var livePredictionStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            premiumSectionHeader(title: "LIVE PREDICTION STATUS", systemImage: "dot.radiowaves.left.and.right")

            VStack(spacing: 10) {
                if let predictions = resolvedUserPredictions,
                   let winner = predictions.winner, !winner.isEmpty,
                   let status = winnerPredictionStatus(predicted: winner, game: displayGame) {
                    livePredictionStatusRow(
                        icon: status == .correct ? "checkmark.circle.fill" : (status == .incorrect ? "xmark.circle.fill" : "clock.fill"),
                        title: "Winner prediction",
                        status: status
                    )
                }
                if let predictions = resolvedUserPredictions,
                   let first = predictions.firstScoreTeam, !first.isEmpty,
                   let status = firstScorerPredictionStatus(predicted: first, game: displayGame) {
                    livePredictionStatusRow(
                        icon: status == .correct ? "checkmark.circle.fill" : (status == .incorrect ? "xmark.circle.fill" : "clock.fill"),
                        title: "First scorer prediction",
                        status: status
                    )
                }
                if let predictions = resolvedUserPredictions,
                   let home = predictions.homeScore,
                   let away = predictions.awayScore,
                   let status = exactScorePredictionStatus(predictedAway: away, predictedHome: home, game: displayGame) {
                    livePredictionStatusRow(
                        icon: status == .correct ? "checkmark.circle.fill" : (status == .incorrect ? "xmark.circle.fill" : "clock.fill"),
                        title: "Exact score prediction",
                        status: status
                    )
                }
            }
        }
        .premiumCardStyle(colorScheme: colorScheme, accent: FGColor.accentGreen)
    }

    private func premiumSectionHeader(title: String, systemImage: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.accentGreen)
            Text(title)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .tracking(0.6)
                .foregroundStyle(premiumPrimaryText)
            Spacer(minLength: 0)
        }
    }

    private func myPickRow(icon: String, title: String, crowdPercent: Int?) -> some View {
        HStack(spacing: 12) {
            Text(icon)
                .font(.system(size: 18))
                .frame(width: 24)

            Text(title)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundStyle(premiumPrimaryText)
                .lineLimit(2)
                .minimumScaleFactor(0.85)

            Spacer(minLength: 0)

            if let crowdPercent {
                Text("\(crowdPercent)% of fans")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(premiumRowFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.06), lineWidth: 1)
        )
    }

    private func livePredictionStatusRow(icon: String, title: String, status: ProGamePredictionOutcomeStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(statusAccent(for: status))
                .frame(width: 22)

            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(premiumPrimaryText)
                .lineLimit(2)

            Spacer(minLength: 0)

            Text(status.rawValue)
                .font(.caption2.weight(.heavy))
                .foregroundStyle(statusAccent(for: status))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule(style: .continuous)
                        .fill(statusAccent(for: status).opacity(colorScheme == .dark ? 0.18 : 0.12))
                )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(premiumRowFill)
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

    private var emptyFanSentimentCopy: String {
        ProGamePredictionEmptySentimentCopy.message(
            isFinal: displayGame.isFinal,
            isLocked: isLocked
        )
    }

    private var fanSentimentSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "person.3.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.accentGreen)
                Text("FAN SENTIMENT")
                    .font(.system(size: 12, weight: .heavy, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(premiumPrimaryText)
                Spacer(minLength: 0)
                HStack(spacing: 4) {
                    Image(systemName: "person.2.fill")
                        .font(.caption2.weight(.bold))
                    Text(summary.totalCount == 1 ? "1 prediction" : "\(summary.totalCount) predictions")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(FGColor.accentGreen)
            }

            if summary.totalCount == 0 {
                Text(emptyFanSentimentCopy)
                    .font(FGTypography.caption)
                    .foregroundStyle(premiumSecondaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if hasWinnerCrowdData {
                    VStack(spacing: 14) {
                        fanSentimentBar(
                            title: compactTeamName(teams.away),
                            flag: teamFlag(for: teams.away),
                            percent: summary.winnerPercents[teams.away] ?? 0,
                            tint: Color(red: 0.95, green: 0.45, blue: 0.28)
                        )
                        if isSoccer {
                            fanSentimentBar(
                                title: "Draw",
                                flag: nil,
                                percent: summary.winnerPercents["Draw"] ?? 0,
                                tint: Color(red: 0.98, green: 0.78, blue: 0.18)
                            )
                        }
                        fanSentimentBar(
                            title: compactTeamName(teams.home),
                            flag: teamFlag(for: teams.home),
                            percent: summary.winnerPercents[teams.home] ?? 0,
                            tint: FGColor.accentBlue
                        )
                    }
                }

                if !summary.topScorePredictions.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Top score picks")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(premiumSecondaryText)
                            .padding(.top, 4)

                        ForEach(summary.topScorePredictions) { pick in
                            HStack(spacing: 10) {
                                Text(pick.isOther ? "Other" : "\(pick.awayScore ?? 0)–\(pick.homeScore ?? 0)")
                                    .font(.system(size: 14, weight: .heavy, design: .rounded))
                                    .foregroundStyle(premiumPrimaryText)
                                Spacer(minLength: 0)
                                Text("\(pick.percent)%")
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }
                    }
                }
            }
        }
        .premiumCardStyle(colorScheme: colorScheme)
    }

    private var hasWinnerCrowdData: Bool {
        !(summary.winnerPercents.isEmpty && summary.winnerLeader == nil)
    }

    private func fanSentimentBar(title: String, flag: String?, percent: Int, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if let flag {
                    Text(TeamTheme.safeFlag(flag) ?? "")
                        .font(.body)
                }
                Text(title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(premiumPrimaryText)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(percent)%")
                    .font(.system(size: 22, weight: .black, design: .rounded))
                    .foregroundStyle(tint)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.08))
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [tint.opacity(0.95), tint.opacity(0.65)],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(8, proxy.size.width * CGFloat(percent) / 100))
                }
            }
            .frame(height: ProGamePredictionSheetMetrics.sentimentBarHeight)
        }
    }

    private var premiumCardFill: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.12, blue: 0.15)
            : Color(red: 0.10, green: 0.11, blue: 0.14)
    }

    private var premiumRowFill: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.05)
            : Color.white.opacity(0.06)
    }

    private var premiumPrimaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.94) : Color.white.opacity(0.96)
    }

    private var premiumSecondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : Color.white.opacity(0.68)
    }

    private func statusAccent(for status: ProGamePredictionOutcomeStatus) -> Color {
        switch status {
        case .correct:
            return FGColor.accentGreen
        case .incorrect:
            return FGColor.dangerRed
        case .stillInPlay:
            return ProGamePredictionSheetMetrics.closedBannerTint
        }
    }

    private func winnerPickTitle(_ winner: String) -> String {
        if winner == "Draw" { return "Draw" }
        return "\(compactTeamName(winner)) Win"
    }

    private func firstGoalPickTitle(_ team: String) -> String {
        if team == "No goals" { return "First Goal: No goals" }
        return "First Goal \(compactTeamName(team))"
    }

    private func crowdPercentForWinnerPick(_ winner: String) -> Int? {
        let percent = summary.winnerPercents[winner]
            ?? (winner == "Draw" ? summary.winnerPercents["Draw"] : nil)
        guard let percent, percent > 0 else { return nil }
        return percent
    }

    private func crowdPercentForScorePick(away: Int, home: Int) -> Int? {
        let match = summary.topScorePredictions.first {
            !$0.isOther && $0.awayScore == away && $0.homeScore == home
        }
        return match?.percent
    }

    private func crowdPercentForFirstGoalPick(_ team: String) -> Int? {
        let percent = summary.firstScorePercents[team]
        guard let percent, percent > 0 else { return nil }
        return percent
    }

    private func teamsMatch(_ lhs: String, _ rhs: String) -> Bool {
        LiveMatchFilters.normalizedSearchText(lhs) == LiveMatchFilters.normalizedSearchText(rhs)
    }

    private func actualWinner(for game: SavedProGame) -> String {
        if game.scoreAway > game.scoreHome { return game.awayTeam }
        if game.scoreHome > game.scoreAway { return game.homeTeam }
        return "Draw"
    }

    private func winnerPredictionStatus(predicted: String, game: SavedProGame) -> ProGamePredictionOutcomeStatus? {
        if game.isFinal {
            let actual = actualWinner(for: game)
            if predicted == "Draw" && actual == "Draw" { return .correct }
            return teamsMatch(predicted, actual) ? .correct : .incorrect
        }
        guard game.matchStatus.isHappeningNow else { return .stillInPlay }

        if predicted == "Draw" {
            return game.scoreAway == game.scoreHome ? .correct : .incorrect
        }
        if teamsMatch(predicted, game.awayTeam) {
            if game.scoreAway > game.scoreHome { return .correct }
            if game.scoreAway < game.scoreHome { return .incorrect }
            return .stillInPlay
        }
        if teamsMatch(predicted, game.homeTeam) {
            if game.scoreHome > game.scoreAway { return .correct }
            if game.scoreHome < game.scoreAway { return .incorrect }
            return .stillInPlay
        }
        return .stillInPlay
    }

    private func firstScorerPredictionStatus(predicted: String, game: SavedProGame) -> ProGamePredictionOutcomeStatus? {
        if let firstGoalTeam = game.firstScoringTeam {
            if predicted == "No goals" { return .incorrect }
            return teamsMatch(predicted, firstGoalTeam) ? .correct : .incorrect
        }
        if game.scoreAway + game.scoreHome > 0, predicted == "No goals" {
            return .incorrect
        }
        if game.isFinal {
            if predicted == "No goals", game.scoreAway == 0, game.scoreHome == 0 { return .correct }
            return predicted == "No goals" ? .incorrect : .incorrect
        }
        return .stillInPlay
    }

    private func exactScorePredictionStatus(
        predictedAway: Int,
        predictedHome: Int,
        game: SavedProGame
    ) -> ProGamePredictionOutcomeStatus? {
        let matches = predictedAway == game.scoreAway && predictedHome == game.scoreHome
        if game.isFinal {
            return matches ? .correct : .incorrect
        }
        guard game.matchStatus.isHappeningNow else { return .stillInPlay }
        if game.scoreAway > predictedAway || game.scoreHome > predictedHome {
            return .incorrect
        }
        return .stillInPlay
    }

    @ViewBuilder
    private var footerNote: some View {
        Text(isLocked ? "Predictions are closed." : "You can change your predictions until 10 minutes after kickoff.")
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

private struct ProGamePredictionPremiumCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var accent: Color?

    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: ProGamePredictionSheetMetrics.premiumCornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                premiumFill,
                                premiumFill.opacity(0.92)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            )
            .overlay {
                RoundedRectangle(cornerRadius: ProGamePredictionSheetMetrics.premiumCornerRadius, style: .continuous)
                    .strokeBorder(
                        (accent ?? Color.white).opacity(colorScheme == .dark ? 0.10 : 0.08),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.28 : 0.16), radius: 14, y: 6)
    }

    private var premiumFill: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.12, blue: 0.15)
            : Color(red: 0.10, green: 0.11, blue: 0.14)
    }
}

private extension View {
    func premiumCardStyle(colorScheme: ColorScheme, accent: Color? = nil) -> some View {
        modifier(ProGamePredictionPremiumCardModifier(accent: accent))
    }
}
