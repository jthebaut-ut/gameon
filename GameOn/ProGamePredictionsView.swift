import SwiftUI
import Combine

private enum ProGamePredictionCardMetrics {
    static let cornerRadius: CGFloat = 16
    static let optionHeight: CGFloat = 132
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

private enum ProGamePredictionEmptyConsensusCopy {
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

#if DEBUG
private enum ProPredictionPerf {
    static func log(_ event: String, gameId: String, durationMs: Int? = nil) {
        if let durationMs {
            print("[ProPredictionPerf] \(event) gameId=\(gameId) durationMs=\(durationMs)")
        } else {
            print("[ProPredictionPerf] \(event) gameId=\(gameId)")
        }
    }
}
#endif

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
    @State private var isRefreshingSummary = false
    @State private var isEditingPredictions = true
    @State private var didSavePredictions = false
    @State private var errorMessage: String?
    @State private var now = Date()
    @State private var baselineHomeScore = 0
    @State private var baselineAwayScore = 0
    @State private var isSheetContentExpanded = false
    @State private var sheetDisplayGame: SavedProGame?

    private let scoreRange = 0...20
    private let lockTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var teams: VenueEventPredictionTeams { game.proGamePredictionTeams }
    private var isSoccer: Bool { game.liveSportVisualType == .soccer }
    private var summary: ProGamePredictionSummary {
        viewModel.proGamePredictionSummaries[game.stableKey] ?? .empty(proGameID: game.stableKey)
    }
    private var displayGame: SavedProGame {
        sheetDisplayGame ?? game
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
    private var showResultsMode: Bool { displayGame.isFinal }
    private var hasPrefetchedSummary: Bool {
        viewModel.proGamePredictionSummaries[game.stableKey] != nil
    }
    private var shouldShowFullScreenLoading: Bool {
        isLoading && !hasPrefetchedSummary
    }
    private var hasSubmittedPrediction: Bool {
        didSavePredictions || summary.userPredictions?.hasAnyPrediction == true
    }
    private var showSummaryMode: Bool {
        !showResultsMode && !isLocked && hasSubmittedPrediction && !isEditingPredictions
    }
    private var displayedFanCount: Int {
        shouldUseOptimisticCrowd ? votingCrowdDisplay.displayedFanCount : summary.participantCount
    }
    private var fanVoteCountText: String {
        let count = displayedFanCount
        return count == 1 ? "1 fan has voted" : "\(count) fans have voted"
    }
    private var shouldUseOptimisticCrowd: Bool {
        canEdit && !isLocked && !showSummaryMode && !showResultsMode && !shouldShowFullScreenLoading
    }
    private var votingCrowdDisplay: ProGamePredictionOptimisticCrowd.Display {
        ProGamePredictionOptimisticCrowd.display(
            server: summary,
            draftWinner: selectedWinner,
            draftFirstScore: selectedFirstScore,
            draftHomeScore: homeScore,
            draftAwayScore: awayScore,
            baselineHomeScore: baselineHomeScore,
            baselineAwayScore: baselineAwayScore,
            teams: teams,
            isSoccer: isSoccer
        )
    }
    private var bottomInsetPadding: CGFloat {
        if isLocked || showResultsMode { return 24 }
        return canEdit ? 96 : 24
    }
    private var votingContentSpacing: CGFloat {
        if shouldShowFullScreenLoading || showResultsMode || isLocked || showSummaryMode { return FGSpacing.lg }
        return 14
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: FGSpacing.lg) {
                    if isSheetContentExpanded {
                        if shouldShowFullScreenLoading {
                            loadingMatchHeader
                        } else {
                            predictionMatchHeader
                        }
                    } else {
                        loadingMatchHeader
                    }

                    if !showResultsMode {
                        lockBanner
                    }

                    VStack(alignment: .leading, spacing: votingContentSpacing) {
                        if !isSheetContentExpanded {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else if shouldShowFullScreenLoading {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 28)
                        } else if showResultsMode {
                            resultsContent
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

                        if isSheetContentExpanded {
                            footerNote
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .padding(.bottom, bottomInsetPadding)
            }
            .fanGeoScreenBackground()
            .onAppear {
#if DEBUG
                ProPredictionPerf.log("firstBodyPaint", gameId: game.stableKey)
#endif
            }
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
                sheetDisplayGame = game
                await Task.yield()
                isSheetContentExpanded = true
#if DEBUG
                ProPredictionPerf.log("contentExpanded", gameId: game.stableKey)
#endif
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

    private var loadingMatchHeader: some View {
        VStack(spacing: 20) {
            scheduledHeaderContent
            Text(headerDateLine)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(headerSecondaryText)
                .multilineTextAlignment(.center)
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

            if isSheetContentExpanded {
                headerGoalScorerSection
                headerCardEventsSection
            }

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
        if let presentation = headerScorerPresentation {
            ProGameScoringTimelineView(
                summary: presentation.summary,
                homeTeam: displayGame.homeTeam,
                awayTeam: displayGame.awayTeam,
                gameId: displayGame.stableKey,
                headingText: presentation.summary.goalScorersHeadingText,
                maxVisibleLines: presentation.maxVisibleLines,
                supplementalLines: presentation.supplementalLines,
                headingFont: .subheadline.weight(.bold),
                lineFont: .subheadline.weight(.medium),
                headingColor: headerSecondaryText,
                lineColor: headerPrimaryText,
                flagSource: "Predictions"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            .onAppear {
                logProPredictionScorerHeaderDebug(presentation)
            }
            .onChange(of: headerScorerDebugToken) { _, _ in
                if let refreshed = headerScorerPresentation {
                    logProPredictionScorerHeaderDebug(refreshed)
                }
            }
        }
    }

    @ViewBuilder
    private var headerCardEventsSection: some View {
        if let cardSummary = headerCardTimelineSummary {
            ProGameCardEventsView(
                summary: cardSummary,
                gameId: displayGame.stableKey,
                headingText: cardSummary.matchEventsHeadingText,
                headingFont: .subheadline.weight(.bold),
                lineFont: .subheadline.weight(.medium),
                headingColor: headerSecondaryText,
                lineColor: headerPrimaryText,
                flagSource: "Predictions"
            )
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var headerCardTimelineSummary: LiveCardTimelineSummary? {
        guard showsScoreboardHeader, savedProGameHasKnownScore else { return nil }
        let mergedTimelineEvents = predictionMergedTimelineEvents()
        return LiveCardTimelineBuilder.buildSummary(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents,
            homeTeam: displayGame.homeTeam,
            awayTeam: displayGame.awayTeam,
            gameId: displayGame.stableKey,
            provider: displayGame.source
        )
    }

    private struct ProPredictionHeaderScorerPresentation: Equatable {
        let summary: LiveScoringTimelineSummary
        let supplementalLines: [String]
        let scoreTimelineMismatch: Bool
        let timelineEventsCount: Int
        let scoringSummaryEntriesCount: Int
        let renderedScorers: String

        var maxVisibleLines: Int {
            if summary.isScoreOnlyFallback {
                return max(summary.scoreOnlyLines.count, 1)
            }
            return max(summary.entries.count + supplementalLines.count, 1)
        }
    }

    private var headerScorerPresentation: ProPredictionHeaderScorerPresentation? {
        guard showsScoreboardHeader, savedProGameHasKnownScore else { return nil }

        let mergedTimelineEvents = predictionMergedTimelineEvents()
        let sportType = displayGame.liveSportVisualType
        let scoreAway = displayGame.scoreAway
        let scoreHome = displayGame.scoreHome
        let awayTeam = displayGame.awayTeam
        let homeTeam = displayGame.homeTeam
        let totalGoals = scoreAway + scoreHome

        var summary = LiveScoringTimelineBuilder.buildForGoalScorersCard(
            sportType: sportType,
            timelineEvents: mergedTimelineEvents,
            homeTeam: homeTeam,
            awayTeam: awayTeam
        )

        if summary?.hasContent != true {
            if let latestScoringEvent = predictionResolvedLatestScoringEvent(
                mergedTimelineEvents: mergedTimelineEvents
            ),
               let latestSummary = LiveScoringTimelineBuilder.summaryFromLatestScoringEvent(
                latestScoringEvent,
                sportType: sportType,
                homeTeam: homeTeam,
                awayTeam: awayTeam
               ) {
                summary = latestSummary
            }
        }

        if summary?.hasContent != true {
            if let firstScoringEvent = LiveScoringTimelineBuilder.resolveFirstScoringEvent(
                sportType: sportType,
                timelineEvents: mergedTimelineEvents,
                homeTeam: homeTeam,
                awayTeam: awayTeam,
                scoreAway: scoreAway,
                scoreHome: scoreHome
            ),
               let firstSummary = LiveScoringTimelineBuilder.summaryFromFirstScoringEvent(
                firstScoringEvent,
                sportType: sportType
               ) {
                summary = firstSummary
            }
        }

        if summary?.hasContent != true {
            summary = LiveScoringTimelineBuilder.buildScoreOnlyGoalCountSummary(
                sportType: sportType,
                scoreAway: scoreAway,
                scoreHome: scoreHome,
                awayTeam: awayTeam,
                homeTeam: homeTeam,
                flagSource: "Predictions"
            )
        }

        guard let resolvedSummary = summary, resolvedSummary.hasContent else { return nil }

        let knownGoalCount = resolvedSummary.isScoreOnlyFallback ? 0 : resolvedSummary.entries.count
        let scoreTimelineMismatch = totalGoals > 0
            && knownGoalCount > 0
            && knownGoalCount < totalGoals
        let supplementalLines = scoreTimelineMismatch ? ["Other scorers pending"] : []
        let renderedScorers = resolvedSummary.renderedTimelineSummaryText(
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            maxVisible: max(knownGoalCount, resolvedSummary.scoreOnlyLines.count, 1)
        )

        return ProPredictionHeaderScorerPresentation(
            summary: resolvedSummary,
            supplementalLines: supplementalLines,
            scoreTimelineMismatch: scoreTimelineMismatch,
            timelineEventsCount: mergedTimelineEvents.count,
            scoringSummaryEntriesCount: knownGoalCount,
            renderedScorers: supplementalLines.isEmpty
                ? renderedScorers
                : "\(renderedScorers) | Other scorers pending"
        )
    }

    private var headerScorerDebugToken: String {
        let mergedTimelineEvents = predictionMergedTimelineEvents()
        let presentation = headerScorerPresentation
        return [
            displayGame.stableKey,
            "\(displayGame.scoreAway)-\(displayGame.scoreHome)",
            "\(mergedTimelineEvents.count)",
            "\(presentation?.scoringSummaryEntriesCount ?? -1)",
            presentation?.renderedScorers ?? "none",
            "\(presentation?.scoreTimelineMismatch ?? false)"
        ].joined(separator: "|")
    }

    private func predictionMergedTimelineEvents() -> [LiveTimelineEvent] {
        var byKey: [String: LiveTimelineEvent] = [:]
        for event in displayGame.timelineEvents ?? [] {
            byKey[event.id] = event
        }
        for match in predictionHydrationLiveMatches() {
            for event in match.timelineEvents {
                byKey[event.id] = event
            }
        }
        return Array(byKey.values)
    }

    private func predictionHydrationLiveMatches() -> [LiveMatch] {
        var matches: [LiveMatch] = []
        if let exact = hydratedLiveMatch {
            matches.append(exact)
        }
        if let source = displayGame.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty,
           let externalId = displayGame.externalId?.trimmingCharacters(in: .whitespacesAndNewlines), !externalId.isEmpty,
           let external = viewModel.liveMatches.first(where: {
               $0.source?.caseInsensitiveCompare(source) == .orderedSame
                   && $0.externalId?.caseInsensitiveCompare(externalId) == .orderedSame
           }),
           !matches.contains(where: { $0.id == external.id }) {
            matches.append(external)
        }
        return matches
    }

    private func predictionResolvedLatestScoringEvent(
        mergedTimelineEvents: [LiveTimelineEvent]
    ) -> LiveLatestScoringEvent? {
        if let latest = hydratedLiveMatch?.latestScoringEvent {
            return latest
        }
        if let latest = displayGame.latestScoringEvent {
            return latest
        }
        return LiveScoringEventResolver.resolve(
            sportType: displayGame.liveSportVisualType,
            timelineEvents: mergedTimelineEvents
        ).latestEvent
    }

    private func logProPredictionScorerHeaderDebug(_ presentation: ProPredictionHeaderScorerPresentation) {
        print("[ProPredictionScorerHeaderDebug] gameId=\(displayGame.stableKey)")
        print("[ProPredictionScorerHeaderDebug] score=\(displayGame.scoreAway)-\(displayGame.scoreHome)")
        print("[ProPredictionScorerHeaderDebug] timelineEventsCount=\(presentation.timelineEventsCount)")
        print("[ProPredictionScorerHeaderDebug] scoringSummaryEntriesCount=\(presentation.scoringSummaryEntriesCount)")
        print("[ProPredictionScorerHeaderDebug] renderedScorers=\(presentation.renderedScorers)")
        print("[ProPredictionScorerHeaderDebug] scoreTimelineMismatch=\(presentation.scoreTimelineMismatch)")
    }

    private var savedProGameHasKnownScore: Bool {
        displayGame.scoreHome > 0 || displayGame.scoreAway > 0
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

    private var summaryContentSpacing: CGFloat { PredictionPremiumMetrics.sectionSpacing }

    @ViewBuilder
    private var votingContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            predictionSection(number: 1, title: "Who will win?", contentSpacing: 8, showsVoteCountInHeader: true) {
                horizontalWinnerOptions
            }

            predictionSection(number: 2, title: "Exact score", contentSpacing: 8) {
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

            predictionSection(number: 3, title: "Who will score first?", contentSpacing: 8, showsVoteCountInHeader: true) {
                horizontalFirstScoreOptions
            }
        }
    }

    private var sectionVoteHeaderLabel: some View {
        HStack(spacing: 5) {
            Image(systemName: "person.2.fill")
                .font(.caption2.weight(.semibold))
            Text(fanVoteCountText)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(FGColor.mutedText(colorScheme))
    }

    @ViewBuilder
    private var summaryContent: some View {
        VStack(alignment: .leading, spacing: summaryContentSpacing) {
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

    @ViewBuilder
    private var lockedContent: some View {
        VStack(alignment: .leading, spacing: summaryContentSpacing) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if shouldShowLivePredictionStatus {
                livePredictionStatusSection
            }

            fanConsensusSection(title: "FAN CONSENSUS", trailingCount: fanVoteCountText)

            popularScoresSection(title: "MOST POPULAR SCORES")

            if hasFirstGoalCrowdData {
                firstGoalConsensusSection(title: "FIRST GOAL CONSENSUS")
            }
        }
    }

    @ViewBuilder
    private var resultsContent: some View {
        VStack(alignment: .leading, spacing: summaryContentSpacing) {
            resultsSummaryCard

            popularScoresSection(title: "TOP FAN SCORE PREDICTIONS")
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

    private var resultsSummaryCard: some View {
        let outcomes = predictionOutcomes
        let correctCount = outcomes.filter { $0.status == .correct }.count
        let gradedCount = outcomes.filter { $0.status == .correct || $0.status == .incorrect }.count

        return PredictionPremiumCard {
            VStack(alignment: .leading, spacing: 0) {
                PredictionPremiumCardHeader(
                    title: "YOUR RESULT",
                    systemImage: "trophy.fill",
                    usesGreenTint: true,
                    colorScheme: colorScheme
                )

                VStack(spacing: 0) {
                    ForEach(outcomes) { outcome in
                        HStack(alignment: .center, spacing: 10) {
                            Text(outcome.label)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .frame(width: 78, alignment: .leading)
                            Spacer(minLength: 0)
                            Text(outcome.value)
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .multilineTextAlignment(.trailing)
                            if let status = outcome.status {
                                Text(status == .correct ? "✓" : (status == .incorrect ? "✗" : "–"))
                                    .font(.subheadline.weight(.black))
                                    .foregroundStyle(statusAccent(for: status))
                                    .frame(width: 18, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, PredictionPremiumMetrics.cardPadding)
                        .padding(.vertical, 10)

                        if outcome.id != outcomes.last?.id {
                            Divider()
                                .padding(.leading, PredictionPremiumMetrics.cardPadding)
                                .opacity(0.28)
                        }
                    }
                }

                if gradedCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                        Text("\(correctCount) OF \(gradedCount) CORRECT")
                            .font(.caption.weight(.heavy))
                            .tracking(0.4)
                    }
                    .foregroundStyle(FGColor.accentGreen)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity)
                    .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.10))
                    .clipShape(Capsule(style: .continuous))
                    .padding(.horizontal, PredictionPremiumMetrics.cardPadding)
                    .padding(.top, 8)
                    .padding(.bottom, PredictionPremiumMetrics.cardPadding)
                }
            }
        }
    }

    private struct PredictionOutcomeRow: Identifiable {
        let id: String
        let label: String
        let value: String
        let status: ProGamePredictionOutcomeStatus?
    }

    private var predictionOutcomes: [PredictionOutcomeRow] {
        guard let predictions = resolvedUserPredictions else { return [] }
        var rows: [PredictionOutcomeRow] = []

        if let winner = predictions.winner, !winner.isEmpty {
            rows.append(
                PredictionOutcomeRow(
                    id: "winner",
                    label: "Winner",
                    value: winnerPickTitle(winner),
                    status: winnerPredictionStatus(predicted: winner, game: displayGame)
                )
            )
        }
        if let home = predictions.homeScore, let away = predictions.awayScore {
            rows.append(
                PredictionOutcomeRow(
                    id: "score",
                    label: "Exact Score",
                    value: "\(away)–\(home)",
                    status: exactScorePredictionStatus(predictedAway: away, predictedHome: home, game: displayGame)
                )
            )
        }
        if let first = predictions.firstScoreTeam, !first.isEmpty {
            rows.append(
                PredictionOutcomeRow(
                    id: "firstGoal",
                    label: "First Goal",
                    value: firstGoalPickTitle(first),
                    status: firstScorerPredictionStatus(predicted: first, game: displayGame)
                )
            )
        }
        return rows
    }

    private var yourPredictionRows: [PredictionSummaryRow] {
        yourPredictionRows(from: resolvedUserPredictions)
    }

    private func yourPredictionRows(from predictions: VenueEventUserPredictions?) -> [PredictionSummaryRow] {
        var rows: [PredictionSummaryRow] = []
        if let winner = predictions?.winner, !winner.isEmpty {
            rows.append(
                PredictionSummaryRow(
                    id: "winner",
                    label: "Winner",
                    value: winnerSummaryValue(winner),
                    flag: summaryRowFlag(for: winner)
                )
            )
        }
        if let home = predictions?.homeScore, let away = predictions?.awayScore {
            rows.append(
                PredictionSummaryRow(
                    id: "score",
                    label: "Exact Score",
                    value: "\(away)–\(home)",
                    emphasizesValue: true
                )
            )
        }
        if let first = predictions?.firstScoreTeam, !first.isEmpty {
            rows.append(
                PredictionSummaryRow(
                    id: "firstGoal",
                    label: "First Goal",
                    value: firstGoalSummaryValue(first),
                    flag: summaryRowFlag(for: first)
                )
            )
        }
        return rows
    }

    private func summaryRowFlag(for team: String) -> String? {
        if team == "Draw" || team == "No goals" { return nil }
        return teamFlag(for: team)
    }

    private func winnerSummaryValue(_ winner: String) -> String {
        if winner == "Draw" { return "Draw" }
        return "\(compactTeamName(winner)) Win"
    }

    private func firstGoalSummaryValue(_ team: String) -> String {
        if team == "No goals" { return "No goals" }
        return compactTeamName(team)
    }

    private var scoreCrowdChips: [PredictionScoreCrowdChip] {
        let picks = shouldUseOptimisticCrowd ? votingCrowdDisplay.topScorePredictions : summary.topScorePredictions
        return picks
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
            if summary.participantCount == 0 {
                Text(emptyFanConsensusCopy)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            } else if hasWinnerCrowdData {
                fanConsensusBar(
                    title: compactTeamName(teams.away),
                    flag: teamFlag(for: teams.away),
                    percent: summary.winnerPercents[teams.away] ?? 0,
                    tint: Color(red: 0.95, green: 0.45, blue: 0.28)
                )
                if isSoccer {
                    fanConsensusBar(
                        title: "Draw",
                        flag: nil,
                        percent: summary.winnerPercents["Draw"] ?? 0,
                        tint: Color(red: 0.98, green: 0.78, blue: 0.18)
                    )
                }
                fanConsensusBar(
                    title: compactTeamName(teams.home),
                    flag: teamFlag(for: teams.home),
                    percent: summary.winnerPercents[teams.home] ?? 0,
                    tint: FGColor.accentBlue
                )
            }
        }
    }

    @ViewBuilder
    private func firstGoalConsensusSection(title: String) -> some View {
        PredictionConsensusSectionCard(title: title, colorScheme: colorScheme) {
            fanConsensusBar(
                title: compactTeamName(teams.away),
                flag: teamFlag(for: teams.away),
                percent: summary.firstScorePercents[teams.away] ?? 0,
                tint: Color(red: 0.95, green: 0.45, blue: 0.28)
            )
            if isSoccer {
                fanConsensusBar(
                    title: "No goals",
                    flag: nil,
                    percent: summary.firstScorePercents["No goals"] ?? 0,
                    tint: Color(red: 0.98, green: 0.78, blue: 0.18)
                )
            }
            fanConsensusBar(
                title: compactTeamName(teams.home),
                flag: teamFlag(for: teams.home),
                percent: summary.firstScorePercents[teams.home] ?? 0,
                tint: FGColor.accentBlue
            )
        }
    }

    private var hasFirstGoalCrowdData: Bool {
        !summary.firstScorePercents.isEmpty || summary.firstScoreLeader != nil
    }

    private func fanConsensusBar(title: String, flag: String?, percent: Int, tint: Color) -> some View {
        PredictionConsensusBar(
            title: title,
            flag: flag,
            percent: percent,
            tint: tint,
            colorScheme: colorScheme
        )
    }

    private func refreshSummaryManually() {
        guard !isRefreshingSummary else { return }
        isRefreshingSummary = true
        Task {
            await viewModel.refreshProGamePredictionSummary(proGameId: game.stableKey)
            await MainActor.run { isRefreshingSummary = false }
        }
    }

    private var votingWinnerPercents: [String: Int] {
        shouldUseOptimisticCrowd ? votingCrowdDisplay.winnerPercents : summary.winnerPercents
    }

    private var votingFirstScorePercents: [String: Int] {
        shouldUseOptimisticCrowd ? votingCrowdDisplay.firstScorePercents : summary.firstScorePercents
    }

    private var horizontalWinnerOptions: some View {
        HStack(spacing: 6) {
            PredictionOptionCard(
                title: compactTeamName(teams.away),
                flag: teamFlag(for: teams.away),
                percent: votingWinnerPercents[teams.away] ?? 0,
                isSelected: selectedWinner == teams.away,
                isSaving: false,
                colorScheme: colorScheme
            ) {
                guard canEdit, !isSaving else { return }
                selectedWinner = teams.away
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            if isSoccer {
                PredictionOptionCard(
                    title: "Draw",
                    flag: nil,
                    percent: votingWinnerPercents["Draw"] ?? 0,
                    isSelected: selectedWinner == "Draw",
                    isSaving: false,
                    colorScheme: colorScheme
                ) {
                    guard canEdit, !isSaving else { return }
                    selectedWinner = "Draw"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            PredictionOptionCard(
                title: compactTeamName(teams.home),
                flag: teamFlag(for: teams.home),
                percent: votingWinnerPercents[teams.home] ?? 0,
                isSelected: selectedWinner == teams.home,
                isSaving: false,
                colorScheme: colorScheme
            ) {
                guard canEdit, !isSaving else { return }
                selectedWinner = teams.home
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
        }
    }

    private var horizontalFirstScoreOptions: some View {
        HStack(spacing: 6) {
            PredictionOptionCard(
                title: compactTeamName(teams.away),
                flag: teamFlag(for: teams.away),
                percent: votingFirstScorePercents[teams.away] ?? 0,
                isSelected: selectedFirstScore == teams.away,
                isSaving: false,
                colorScheme: colorScheme
            ) {
                guard canEdit, !isSaving else { return }
                selectedFirstScore = teams.away
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }

            if isSoccer {
                PredictionOptionCard(
                    title: "No goals",
                    flag: nil,
                    percent: votingFirstScorePercents["No goals"] ?? 0,
                    isSelected: selectedFirstScore == "No goals",
                    isSaving: false,
                    colorScheme: colorScheme
                ) {
                    guard canEdit, !isSaving else { return }
                    selectedFirstScore = "No goals"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            }

            PredictionOptionCard(
                title: compactTeamName(teams.home),
                flag: teamFlag(for: teams.home),
                percent: votingFirstScorePercents[teams.home] ?? 0,
                isSelected: selectedFirstScore == teams.home,
                isSaving: false,
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
                .padding(.horizontal, 2)

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

    private var shouldShowLivePredictionStatus: Bool {
        guard isLocked else { return false }
        guard resolvedUserPredictions?.hasAnyPrediction == true else { return false }
        if displayGame.matchStatus.isHappeningNow || displayGame.isFinal { return true }
        return displayGame.firstScoringTeam != nil
    }

    private var livePredictionStatusSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            PredictionSectionHeader(
                number: nil,
                title: "PREDICTION STATUS",
                systemImage: "dot.radiowaves.left.and.right"
            )

            VStack(spacing: 10) {
                if let predictions = resolvedUserPredictions,
                   let winner = predictions.winner, !winner.isEmpty,
                   let status = winnerPredictionStatus(predicted: winner, game: displayGame) {
                    livePredictionStatusRow(
                        icon: status == .correct ? "checkmark.circle.fill" : (status == .incorrect ? "xmark.circle.fill" : "clock.fill"),
                        title: "Winner",
                        status: status
                    )
                }
                if let predictions = resolvedUserPredictions,
                   let home = predictions.homeScore,
                   let away = predictions.awayScore,
                   let status = exactScorePredictionStatus(predictedAway: away, predictedHome: home, game: displayGame) {
                    livePredictionStatusRow(
                        icon: status == .correct ? "checkmark.circle.fill" : (status == .incorrect ? "xmark.circle.fill" : "clock.fill"),
                        title: "Exact Score",
                        status: status
                    )
                }
                if let predictions = resolvedUserPredictions,
                   let first = predictions.firstScoreTeam, !first.isEmpty,
                   let status = firstScorerPredictionStatus(predicted: first, game: displayGame) {
                    livePredictionStatusRow(
                        icon: status == .correct ? "checkmark.circle.fill" : (status == .incorrect ? "xmark.circle.fill" : "clock.fill"),
                        title: "First Goal",
                        status: status
                    )
                }
            }
        }
        .padding(14)
        .background(FGColor.cardBackground(colorScheme).opacity(colorScheme == .dark ? 0.72 : 0.96))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
        }
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

    private func livePredictionStatusRow(icon: String, title: String, status: ProGamePredictionOutcomeStatus) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(statusAccent(for: status))
                .frame(width: 22)

            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
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
                .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.05))
        )
    }

    private func predictionSection<Content: View>(
        number: Int,
        title: String,
        contentSpacing: CGFloat = 8,
        showsVoteCountInHeader: Bool = false,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(number). \(title)")
                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 0)
                if showsVoteCountInHeader, displayedFanCount > 0 {
                    sectionVoteHeaderLabel
                }
            }
            content()
        }
    }

    private var emptyFanConsensusCopy: String {
        ProGamePredictionEmptyConsensusCopy.message(
            isFinal: displayGame.isFinal,
            isLocked: isLocked
        )
    }

    private var hasWinnerCrowdData: Bool {
        !(summary.winnerPercents.isEmpty && summary.winnerLeader == nil)
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
        if !showResultsMode && !showSummaryMode {
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
#if DEBUG
        let loadStartedAt = CFAbsoluteTimeGetCurrent()
        ProPredictionPerf.log("loadStarted", gameId: game.stableKey)
#endif
        applyDraftFromCachedSummaryIfAvailable()
        if !hasPrefetchedSummary {
            isLoading = true
        }

        await viewModel.loadProGamePredictionSummaries(proGameIds: [game.stableKey], forceRefresh: false)
        applyDraftFromCachedSummaryIfAvailable()

        if let summary = viewModel.proGamePredictionSummaries[game.stableKey],
           summary.userPredictionsLoaded,
           let predictions = summary.userPredictions {
            applyDraftFromUserPredictions(predictions)
        } else {
            do {
                let predictions = try await ProGamePredictionService.shared.fetchUserPrediction(proGameId: game.stableKey)
                applyDraftFromUserPredictions(predictions)
            } catch {
                if !VenueEventPredictionUserMessage.isCancellation(error) {
                    errorMessage = error.localizedDescription
                }
            }
        }

        isLoading = false
        sheetDisplayGame = viewModel.currentSavedProGameSnapshot(game)
#if DEBUG
        let durationMs = Int((CFAbsoluteTimeGetCurrent() - loadStartedAt) * 1000)
        ProPredictionPerf.log("loadFinished", gameId: game.stableKey, durationMs: durationMs)
#endif
    }

    @MainActor
    private func applyDraftFromCachedSummaryIfAvailable() {
        guard let predictions = viewModel.proGamePredictionSummaries[game.stableKey]?.userPredictions,
              predictions.hasAnyPrediction else { return }
        applyDraftFromUserPredictions(predictions)
    }

    @MainActor
    private func applyDraftFromUserPredictions(_ predictions: VenueEventUserPredictions) {
        selectedWinner = predictions.winner ?? ""
        selectedFirstScore = predictions.firstScoreTeam ?? ""
        homeScore = predictions.homeScore ?? 0
        awayScore = predictions.awayScore ?? 0
        baselineHomeScore = homeScore
        baselineAwayScore = awayScore
        if predictions.hasAnyPrediction {
            didSavePredictions = true
            isEditingPredictions = false
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
            didSavePredictions = true
            isEditingPredictions = false
            baselineHomeScore = homeScore
            baselineAwayScore = awayScore
        } catch {
            errorMessage = VenueEventPredictionUserMessage.message(for: error)
            await revertToServerPredictions()
        }
    }

    @MainActor
    private func revertToServerPredictions() async {
        await viewModel.refreshProGamePredictionSummary(proGameId: game.stableKey)
        do {
            let predictions = try await ProGamePredictionService.shared.fetchUserPrediction(proGameId: game.stableKey)
            selectedWinner = predictions.winner ?? ""
            selectedFirstScore = predictions.firstScoreTeam ?? ""
            homeScore = predictions.homeScore ?? 0
            awayScore = predictions.awayScore ?? 0
            baselineHomeScore = homeScore
            baselineAwayScore = awayScore
        } catch {
            if let saved = summary.userPredictions {
                selectedWinner = saved.winner ?? ""
                selectedFirstScore = saved.firstScoreTeam ?? ""
                homeScore = saved.homeScore ?? 0
                awayScore = saved.awayScore ?? 0
                baselineHomeScore = homeScore
                baselineAwayScore = awayScore
            }
        }
    }
}

private enum ProGamePredictionOptimisticCrowd {
    struct Display {
        let winnerPercents: [String: Int]
        let firstScorePercents: [String: Int]
        let topScorePredictions: [VenueScorePredictionCrowdPick]
        let displayedFanCount: Int
    }

    static func display(
        server: ProGamePredictionSummary,
        draftWinner: String,
        draftFirstScore: String,
        draftHomeScore: Int,
        draftAwayScore: Int,
        baselineHomeScore: Int,
        baselineAwayScore: Int,
        teams: VenueEventPredictionTeams,
        isSoccer: Bool
    ) -> Display {
        let saved = server.userPredictions
        let winnerKeys = winnerOptionKeys(teams: teams, isSoccer: isSoccer)
        let firstScoreKeys = firstScoreOptionKeys(teams: teams, isSoccer: isSoccer)

        let winnerCounts = adjustedOptionCounts(
            serverPercents: server.winnerPercents,
            optionKeys: winnerKeys,
            saved: saved?.winner,
            draft: draftWinner
        )
        let firstScoreCounts = adjustedOptionCounts(
            serverPercents: server.firstScorePercents,
            optionKeys: firstScoreKeys,
            saved: saved?.firstScoreTeam,
            draft: draftFirstScore
        )
        let scoreResult = adjustedScorePredictions(
            server: server,
            savedHomeScore: saved?.homeScore,
            savedAwayScore: saved?.awayScore,
            draftHomeScore: draftHomeScore,
            draftAwayScore: draftAwayScore,
            baselineHomeScore: baselineHomeScore,
            baselineAwayScore: baselineAwayScore
        )

        let displayedFanCount = adjustedParticipantCount(
            server: server,
            saved: saved,
            draftWinner: draftWinner,
            draftFirstScore: draftFirstScore,
            draftHomeScore: draftHomeScore,
            draftAwayScore: draftAwayScore,
            baselineHomeScore: baselineHomeScore,
            baselineAwayScore: baselineAwayScore
        )

        return Display(
            winnerPercents: percentsFromCounts(winnerCounts),
            firstScorePercents: percentsFromCounts(firstScoreCounts),
            topScorePredictions: scoreResult.topScorePredictions,
            displayedFanCount: displayedFanCount
        )
    }

    private static func adjustedParticipantCount(
        server: ProGamePredictionSummary,
        saved: VenueEventUserPredictions?,
        draftWinner: String,
        draftFirstScore: String,
        draftHomeScore: Int,
        draftAwayScore: Int,
        baselineHomeScore: Int,
        baselineAwayScore: Int
    ) -> Int {
        if saved?.hasAnyPrediction == true {
            return server.participantCount
        }
        let draftParticipates = !draftWinner.isEmpty
            || !draftFirstScore.isEmpty
            || draftScoreParticipates(
                savedHomeScore: saved?.homeScore,
                savedAwayScore: saved?.awayScore,
                draftHomeScore: draftHomeScore,
                draftAwayScore: draftAwayScore,
                baselineHomeScore: baselineHomeScore,
                baselineAwayScore: baselineAwayScore
            )
        return draftParticipates ? server.participantCount + 1 : server.participantCount
    }

    private static func draftScoreParticipates(
        savedHomeScore: Int?,
        savedAwayScore: Int?,
        draftHomeScore: Int,
        draftAwayScore: Int,
        baselineHomeScore: Int,
        baselineAwayScore: Int
    ) -> Bool {
        if let savedHomeScore, let savedAwayScore {
            return draftHomeScore != savedHomeScore || draftAwayScore != savedAwayScore
        }
        return draftHomeScore != baselineHomeScore || draftAwayScore != baselineAwayScore
    }

    private static func winnerOptionKeys(teams: VenueEventPredictionTeams, isSoccer: Bool) -> [String] {
        if isSoccer {
            return [teams.away, "Draw", teams.home]
        }
        return [teams.away, teams.home]
    }

    private static func firstScoreOptionKeys(teams: VenueEventPredictionTeams, isSoccer: Bool) -> [String] {
        if isSoccer {
            return [teams.away, "No goals", teams.home]
        }
        return [teams.away, teams.home]
    }

    private static func adjustedOptionCounts(
        serverPercents: [String: Int],
        optionKeys: [String],
        saved: String?,
        draft: String
    ) -> [String: Int] {
        let estimatedTotal = estimatedVoteTotal(from: serverPercents)
        var counts = countsFromPercents(serverPercents, total: estimatedTotal)
        applyOptionDelta(counts: &counts, optionKeys: optionKeys, saved: saved, draft: draft)
        return counts
    }

    private static func applyOptionDelta(
        counts: inout [String: Int],
        optionKeys: [String],
        saved: String?,
        draft: String
    ) {
        let savedContributes = saved.map { !$0.isEmpty } ?? false
        let draftContributes = !draft.isEmpty
        let samePick = savedContributes && draftContributes && teamNamesMatch(saved!, draft)

        if savedContributes, !samePick, let savedKey = resolveOptionKey(for: saved!, in: counts, optionKeys: optionKeys) {
            counts[savedKey] = max(0, (counts[savedKey] ?? 0) - 1)
            if counts[savedKey] == 0 {
                counts.removeValue(forKey: savedKey)
            }
        }

        if draftContributes, !samePick, let draftKey = resolveOptionKey(for: draft, in: counts, optionKeys: optionKeys) {
            counts[draftKey, default: 0] += 1
        }
    }

    private struct AdjustedScoreResult {
        let topScorePredictions: [VenueScorePredictionCrowdPick]
    }

    private static func adjustedScorePredictions(
        server: ProGamePredictionSummary,
        savedHomeScore: Int?,
        savedAwayScore: Int?,
        draftHomeScore: Int,
        draftAwayScore: Int,
        baselineHomeScore: Int,
        baselineAwayScore: Int
    ) -> AdjustedScoreResult {
        let savedScore = savedHomeScore.flatMap { home in
            savedAwayScore.map { away in (home, away) }
        }
        let draftScore = (draftHomeScore, draftAwayScore)
        let shouldAdjustScore: Bool
        if let savedScore {
            shouldAdjustScore = draftScore != savedScore
        } else {
            shouldAdjustScore = draftScore != (baselineHomeScore, baselineAwayScore)
        }

        guard shouldAdjustScore else {
            return AdjustedScoreResult(topScorePredictions: server.topScorePredictions)
        }

        var counts: [String: Int] = [:]
        var otherCount = 0
        for pick in server.topScorePredictions {
            if pick.isOther {
                otherCount = pick.count
            } else if let home = pick.homeScore, let away = pick.awayScore {
                counts[scoreKey(home: home, away: away)] = pick.count
            }
        }

        if let savedScore {
            removeScore(savedScore.0, savedScore.1, counts: &counts, otherCount: &otherCount)
        }
        addScore(draftHomeScore, draftAwayScore, counts: &counts)

        let effectiveTotal = counts.values.reduce(0, +) + otherCount
        let topScorePredictions = buildTopScorePredictions(counts: counts, total: effectiveTotal)
        return AdjustedScoreResult(topScorePredictions: topScorePredictions)
    }

    private static func removeScore(
        _ home: Int,
        _ away: Int,
        counts: inout [String: Int],
        otherCount: inout Int
    ) {
        let key = scoreKey(home: home, away: away)
        if let existing = counts[key], existing > 0 {
            counts[key] = existing - 1
            if counts[key] == 0 {
                counts.removeValue(forKey: key)
            }
        } else {
            otherCount = max(0, otherCount - 1)
        }
    }

    private static func addScore(
        _ home: Int,
        _ away: Int,
        counts: inout [String: Int]
    ) {
        let key = scoreKey(home: home, away: away)
        counts[key, default: 0] += 1
    }

    private static func buildTopScorePredictions(
        counts: [String: Int],
        total: Int
    ) -> [VenueScorePredictionCrowdPick] {
        guard total > 0 else { return [] }

        let ranked = counts.compactMap { key, count -> VenueScorePredictionCrowdPick? in
            guard let parsed = parseScoreKey(key) else { return nil }
            return VenueScorePredictionCrowdPick(
                homeScore: parsed.home,
                awayScore: parsed.away,
                count: count,
                percent: Int((Double(count) / Double(total) * 100).rounded()),
                isOther: false
            )
        }
        .sorted { lhs, rhs in
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.homeScore ?? 0) > (rhs.homeScore ?? 0)
        }

        let top = Array(ranked.prefix(3))
        let topCount = top.reduce(0) { $0 + $1.count }
        let remainingCount = max(0, total - topCount)
        guard remainingCount > 0 else { return top }
        return top + [
            VenueScorePredictionCrowdPick(
                homeScore: nil,
                awayScore: nil,
                count: remainingCount,
                percent: Int((Double(remainingCount) / Double(total) * 100).rounded()),
                isOther: true
            )
        ]
    }

    private static func estimatedVoteTotal(from percents: [String: Int]) -> Int {
        guard !percents.isEmpty else { return 0 }
        return percents.values.compactMap { percent in
            percent > 0 ? Int(ceil(100.0 / Double(percent))) : nil
        }.max() ?? 0
    }

    private static func countsFromPercents(_ percents: [String: Int], total: Int) -> [String: Int] {
        guard total > 0, !percents.isEmpty else { return [:] }
        let fractional = percents.map { (key: $0.key, raw: Double($0.value) / 100.0 * Double(total)) }
        var counts = Dictionary(uniqueKeysWithValues: fractional.map { ($0.key, Int(floor($0.raw))) })
        var remainder = total - counts.values.reduce(0, +)
        let sorted = fractional.sorted { ($0.raw - floor($0.raw)) > ($1.raw - floor($0.raw)) }
        for item in sorted where remainder > 0 {
            counts[item.key, default: 0] += 1
            remainder -= 1
        }
        return counts
    }

    private static func percentsFromCounts(_ counts: [String: Int]) -> [String: Int] {
        let denominator = counts.values.reduce(0, +)
        guard denominator > 0 else { return [:] }
        return counts.mapValues { count in
            Int((Double(count) / Double(denominator) * 100).rounded())
        }
    }

    private static func resolveOptionKey(
        for value: String,
        in counts: [String: Int],
        optionKeys: [String]
    ) -> String? {
        if let exact = optionKeys.first(where: { $0 == value }) {
            return exact
        }
        if let fromCounts = counts.keys.first(where: { teamNamesMatch($0, value) }) {
            return fromCounts
        }
        return optionKeys.first(where: { teamNamesMatch($0, value) }) ?? value
    }

    private static func teamNamesMatch(_ lhs: String, _ rhs: String) -> Bool {
        LiveMatchFilters.normalizedSearchText(lhs) == LiveMatchFilters.normalizedSearchText(rhs)
    }

    private static func scoreKey(home: Int, away: Int) -> String {
        "\(home)-\(away)"
    }

    private static func parseScoreKey(_ key: String) -> (home: Int, away: Int)? {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let home = Int(parts[0]),
              let away = Int(parts[1]) else { return nil }
        return (home, away)
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
