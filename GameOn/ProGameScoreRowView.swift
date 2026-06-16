import SwiftUI

struct ProGameTeamScoreIdentity: Equatable {
    enum LeadingContent: Equatable {
        case flag(String)
        case logoURL(URL)
        case none
    }

    let leading: LeadingContent
    let displayName: String

    static func resolve(teamName: String, badgeURL: String?, source: String) -> ProGameTeamScoreIdentity {
        let cleanedName = cleanTeamName(teamName)
        guard !cleanedName.isEmpty else {
            return ProGameTeamScoreIdentity(leading: .none, displayName: cleanedName)
        }

        if let flag = CountryFlagHelper.flag(for: cleanedName, source: source)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !flag.isEmpty {
            return ProGameTeamScoreIdentity(leading: .flag(flag), displayName: cleanedName)
        }

        let cleanedBadge = badgeURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !cleanedBadge.isEmpty, let url = URL(string: cleanedBadge) {
            return ProGameTeamScoreIdentity(leading: .logoURL(url), displayName: cleanedName)
        }

        return ProGameTeamScoreIdentity(leading: .none, displayName: cleanedName)
    }

    static func cleanTeamName(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return text }

        while let first = text.unicodeScalars.first,
              first.properties.isEmojiPresentation || first.properties.generalCategory == .otherSymbol {
            text = String(text.unicodeScalars.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("•") || text.hasPrefix("-") {
                text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}

enum ProGameCompetitionStageFormatter {
    static func lines(league: String, featuredEventTitle: String?) -> (competition: String?, stage: String?) {
        let trimmedLeague = league.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFeatured = featuredEventTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        let competition: String?
        if !trimmedFeatured.isEmpty {
            competition = trimmedFeatured
        } else if !trimmedLeague.isEmpty {
            competition = trimmedLeague
        } else {
            competition = nil
        }

        let stage = stageLine(from: trimmedLeague, competition: competition)
        return (competition, stage)
    }

    private static func stageLine(from league: String, competition: String?) -> String? {
        guard !league.isEmpty else { return nil }

        let normalizedLeague = LiveMatchFilters.normalizedSearchText(league)
        let normalizedCompetition = competition.map(LiveMatchFilters.normalizedSearchText(_:)) ?? ""

        if normalizedLeague.contains("group stage") || normalizedLeague.contains("group ") {
            if !normalizedCompetition.isEmpty,
               normalizedLeague == normalizedCompetition {
                return nil
            }
            return league
        }

        if league.contains(" · "), !normalizedCompetition.isEmpty,
           normalizedLeague != normalizedCompetition {
            return league
        }

        if !normalizedCompetition.isEmpty,
           normalizedLeague != normalizedCompetition,
           (normalizedLeague.contains("round") || normalizedLeague.contains("knockout") || normalizedLeague.contains("quarter") || normalizedLeague.contains("semi") || normalizedLeague.contains("final")) {
            return league
        }

        return nil
    }
}

struct ProGameScoreboardStyle: Equatable {
    var scoreFont: Font = .system(size: 28, weight: .black, design: .rounded).monospacedDigit()
    var separatorFont: Font = .system(size: 22, weight: .bold, design: .rounded)
    var teamNameFont: Font = .caption.weight(.semibold)
    var competitionFont: Font = .caption2.weight(.semibold)
    var stageFont: Font = .caption2.weight(.medium)
    var emblemSize: CGFloat = 28
    var scoreRowSpacing: CGFloat = 10
    var sectionSpacing: CGFloat = 6
}

enum ProGameScoreboardStatusHeader: Equatable {
    case live(String)
    case finalScore
}

struct ProGameScoreboardView: View {
    let awayIdentity: ProGameTeamScoreIdentity
    let homeIdentity: ProGameTeamScoreIdentity
    let awayScore: Int
    let homeScore: Int

    var style: ProGameScoreboardStyle = ProGameScoreboardStyle()
    var statusHeader: ProGameScoreboardStatusHeader?
    var competitionTitle: String?
    var stageLine: String?
    var accentColor: Color?
    var scoreColor: Color?
    var teamNameColor: Color?
    var metadataColor: Color?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: style.sectionSpacing) {
            statusHeaderView

            scoreRow

            teamNameRow

            competitionMetadata
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var statusHeaderView: some View {
        switch statusHeader {
        case .finalScore:
            Label("FINAL SCORE", systemImage: "checkmark.seal.fill")
                .font(.caption.weight(.heavy))
                .tracking(0.6)
                .foregroundStyle(resolvedAccent)
                .frame(maxWidth: .infinity, alignment: .leading)
        case let .live(text):
            Text(text)
                .font(.caption2.weight(.bold))
                .foregroundStyle(FGColor.dangerRed)
                .frame(maxWidth: .infinity, alignment: .leading)
        case nil:
            EmptyView()
        }
    }

    private var scoreRow: some View {
        HStack(spacing: style.scoreRowSpacing) {
            teamEmblem(awayIdentity, size: style.emblemSize)

            Text("\(awayScore)")
                .font(style.scoreFont)
                .foregroundStyle(resolvedScoreColor)
                .frame(minWidth: 24)

            Text("-")
                .font(style.separatorFont)
                .foregroundStyle(resolvedMetadataColor.opacity(0.85))

            Text("\(homeScore)")
                .font(style.scoreFont)
                .foregroundStyle(resolvedScoreColor)
                .frame(minWidth: 24)

            teamEmblem(homeIdentity, size: style.emblemSize)
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var teamNameRow: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(awayIdentity.displayName)
                .font(style.teamNameFont)
                .foregroundStyle(resolvedTeamNameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(homeIdentity.displayName)
                .font(style.teamNameFont)
                .foregroundStyle(resolvedTeamNameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var competitionMetadata: some View {
        if competitionTitle != nil || stageLine != nil {
            VStack(spacing: 2) {
                if let competitionTitle {
                    Text(competitionTitle)
                        .font(style.competitionFont)
                        .foregroundStyle(resolvedMetadataColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
                if let stageLine {
                    Text(stageLine)
                        .font(style.stageFont)
                        .foregroundStyle(resolvedMetadataColor.opacity(0.92))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
            .padding(.top, 2)
        }
    }

    @ViewBuilder
    private func teamEmblem(_ identity: ProGameTeamScoreIdentity, size: CGFloat) -> some View {
        switch identity.leading {
        case let .flag(flag):
            Text(flag)
                .font(.system(size: size * 0.72))
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(.secondarySystemGroupedBackground).opacity(colorScheme == .dark ? 0.55 : 0.85))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.10 : 0.06), lineWidth: 0.5)
                )
                .accessibilityHidden(true)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                Color.clear
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityHidden(true)
        case .none:
            Color.clear
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private var resolvedAccent: Color {
        accentColor ?? FGColor.primaryText(colorScheme)
    }

    private var resolvedScoreColor: Color {
        scoreColor ?? FGColor.primaryText(colorScheme)
    }

    private var resolvedTeamNameColor: Color {
        teamNameColor ?? FGColor.primaryText(colorScheme)
    }

    private var resolvedMetadataColor: Color {
        metadataColor ?? FGColor.secondaryText(colorScheme)
    }
}

struct ProGameScoringTimelineView: View {
    let summary: LiveScoringTimelineSummary
    let homeTeam: String
    let awayTeam: String
    var headingFont: Font = .caption2.weight(.bold)
    var lineFont: Font = .caption2.weight(.medium)
    var headingColor: Color?
    var lineColor: Color?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let display = summary.timelineDisplay(homeTeam: homeTeam, awayTeam: awayTeam)
        if display.lines.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(summary.goalScorersHeadingText)
                    .font(headingFont)
                    .foregroundStyle(resolvedHeadingColor)

                ForEach(Array(display.lines.enumerated()), id: \.offset) { _, line in
                    Text(line.text)
                        .font(lineFont)
                        .foregroundStyle(resolvedLineColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                if display.overflowCount > 0 {
                    Text("+\(display.overflowCount) more goals")
                        .font(lineFont.weight(.semibold))
                        .foregroundStyle(resolvedLineColor.opacity(0.85))
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var resolvedHeadingColor: Color {
        headingColor ?? FGColor.secondaryText(colorScheme)
    }

    private var resolvedLineColor: Color {
        lineColor ?? FGColor.secondaryText(colorScheme)
    }
}

struct ProGameScoreBlock: View {
    let awayTeam: String
    let homeTeam: String
    let awayScore: Int
    let homeScore: Int
    let awayBadgeURL: String?
    let homeBadgeURL: String?
    let source: String

    var isFinal: Bool = false
    var isLive: Bool = false
    var liveStatusText: String?
    var league: String = ""
    var featuredEventTitle: String?
    var accentColor: Color?
    var style: ProGameScoreboardStyle = ProGameScoreboardStyle()
    var timelineSummary: LiveScoringTimelineSummary?
    var latestScoringEvent: LiveLatestScoringEvent?
    var showsFramedFinalBackground: Bool = true

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let competition = ProGameCompetitionStageFormatter.lines(
            league: league,
            featuredEventTitle: featuredEventTitle
        )
        let scoreboard = ProGameScoreboardView(
            awayIdentity: ProGameTeamScoreIdentity.resolve(teamName: awayTeam, badgeURL: awayBadgeURL, source: source),
            homeIdentity: ProGameTeamScoreIdentity.resolve(teamName: homeTeam, badgeURL: homeBadgeURL, source: source),
            awayScore: awayScore,
            homeScore: homeScore,
            style: style,
            statusHeader: statusHeader,
            competitionTitle: competition.competition,
            stageLine: competition.stage,
            accentColor: accentColor,
            scoreColor: isLive && !isFinal ? FGColor.dangerRed : nil,
            metadataColor: FGColor.secondaryText(colorScheme)
        )

        VStack(alignment: .leading, spacing: 8) {
            scoreboard

            if let timelineSummary {
                ProGameScoringTimelineView(
                    summary: timelineSummary,
                    homeTeam: homeTeam,
                    awayTeam: awayTeam,
                    headingColor: FGColor.secondaryText(colorScheme),
                    lineColor: isFinal ? FGColor.secondaryText(colorScheme) : (accentColor ?? FGColor.secondaryText(colorScheme))
                )
            } else if isLive, let latestScoringEvent {
                latestScoringEventLine(latestScoringEvent)
            }
        }
        .padding(.horizontal, isFinal && showsFramedFinalBackground ? 12 : 0)
        .padding(.vertical, isFinal && showsFramedFinalBackground ? 10 : 2)
        .background {
            if isFinal && showsFramedFinalBackground {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.gray.opacity(colorScheme == .dark ? 0.20 : 0.10))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusHeader: ProGameScoreboardStatusHeader? {
        if isFinal {
            return .finalScore
        }
        if isLive, let liveStatusText, !liveStatusText.isEmpty {
            return .live(liveStatusText)
        }
        return nil
    }

    private func latestScoringEventLine(_ event: LiveLatestScoringEvent) -> some View {
        Text(event.displayText)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(FGColor.dangerRed)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.18 : 0.10))
            )
    }
}

struct ProGameScoreRowView: View {
    let identity: ProGameTeamScoreIdentity
    let score: Int
    var scoreFont: Font = .system(size: 24, weight: .black, design: .rounded).monospacedDigit()
    var nameFont: Font = FGTypography.caption.weight(.bold)
    var nameColor: Color?
    var scoreColor: Color?
    var leadingSpacing: CGFloat = 8
    var scoreMinWidth: CGFloat = 36

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: leadingSpacing) {
            leadingContent

            Text(identity.displayName)
                .font(nameFont)
                .foregroundStyle(resolvedNameColor)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 10)

            Text("\(score)")
                .font(scoreFont)
                .foregroundStyle(resolvedScoreColor)
                .frame(minWidth: scoreMinWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private var leadingContent: some View {
        switch identity.leading {
        case let .flag(flag):
            Text(flag)
                .font(.system(size: 15))
                .accessibilityHidden(true)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                Color.clear
            }
            .frame(width: 18, height: 18)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .accessibilityHidden(true)
        case .none:
            EmptyView()
        }
    }

    private var resolvedNameColor: Color {
        nameColor ?? FGColor.primaryText(colorScheme)
    }

    private var resolvedScoreColor: Color {
        scoreColor ?? FGColor.primaryText(colorScheme)
    }
}

extension LiveMatch {
    func badgeURL(forTeamName team: String) -> String? {
        let cleanedTeam = ProGameTeamScoreIdentity.cleanTeamName(team)
        let normalized = LiveMatchFilters.normalizedSearchText(cleanedTeam)
        if LiveMatchFilters.normalizedSearchText(awayTeam) == normalized {
            return awayTeamBadgeURL
        }
        if LiveMatchFilters.normalizedSearchText(homeTeam) == normalized {
            return homeTeamBadgeURL
        }
        return nil
    }
}
