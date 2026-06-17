import SwiftUI

nonisolated struct ProGameTeamScoreIdentity: Equatable {
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

struct ProGameScoreboardStyle: Equatable {
    var scoreFont: Font = .system(size: 28, weight: .black, design: .rounded).monospacedDigit()
    var separatorFont: Font = .system(size: 22, weight: .bold, design: .rounded)
    var teamNameFont: Font = .caption.weight(.semibold)
    var emblemSize: CGFloat = 28
    var scoreRowSpacing: CGFloat = 8
    var teamNameSpacing: CGFloat = 4
    var teamScoreGap: CGFloat = 10
    var sectionSpacing: CGFloat = 6
}

enum ProGameScoreboardStatusHeader: Equatable {
    case finalScore
}

struct ProGameScoreboardView: View {
    let awayIdentity: ProGameTeamScoreIdentity
    let homeIdentity: ProGameTeamScoreIdentity
    let awayScore: Int
    let homeScore: Int

    var style: ProGameScoreboardStyle = ProGameScoreboardStyle()
    var statusHeader: ProGameScoreboardStatusHeader?
    var accentColor: Color?
    var scoreColor: Color?
    var teamNameColor: Color?
    var metadataColor: Color?

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: style.sectionSpacing) {
            statusHeaderView

            unifiedScoreRow
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
        case nil:
            EmptyView()
        }
    }

    private var unifiedScoreRow: some View {
        HStack(alignment: .center, spacing: style.teamScoreGap) {
            teamSideCluster(identity: awayIdentity)
                .frame(maxWidth: .infinity, alignment: .leading)

            scoreCluster
                .layoutPriority(1)
                .fixedSize(horizontal: true, vertical: false)

            teamSideCluster(identity: homeIdentity)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: .infinity)
    }

    private var scoreCluster: some View {
        HStack(spacing: style.scoreRowSpacing) {
            Text("\(awayScore)")
                .font(style.scoreFont)
                .foregroundStyle(resolvedScoreColor)
                .frame(minWidth: 20)

            Text("-")
                .font(style.separatorFont)
                .foregroundStyle(resolvedMetadataColor.opacity(0.85))

            Text("\(homeScore)")
                .font(style.scoreFont)
                .foregroundStyle(resolvedScoreColor)
                .frame(minWidth: 20)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(awayScore) to \(homeScore)")
    }

    private func teamSideCluster(identity: ProGameTeamScoreIdentity) -> some View {
        HStack(spacing: style.teamNameSpacing) {
            inlineTeamEmblem(identity, size: style.emblemSize)

            Text(identity.displayName)
                .font(style.teamNameFont)
                .foregroundStyle(resolvedTeamNameColor)
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.85)
                .layoutPriority(-1)
        }
    }

    @ViewBuilder
    private func inlineTeamEmblem(_ identity: ProGameTeamScoreIdentity, size: CGFloat) -> some View {
        switch identity.leading {
        case let .flag(flag):
            Text(flag)
                .font(.system(size: size * 0.78))
                .frame(width: size, height: size, alignment: .center)
                .accessibilityHidden(true)
        case let .logoURL(url):
            DiscoverCachedRemoteImage(url: url, contentMode: .fit) {
                Color.clear
            }
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .accessibilityHidden(true)
        case .none:
            EmptyView()
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
    var headingText: String?
    var maxVisibleLines: Int = LiveScoringTimelineSummary.defaultMaxVisibleTimelineLines
    var headingFont: Font = .caption2.weight(.bold)
    var lineFont: Font = .caption2.weight(.medium)
    var headingColor: Color?
    var lineColor: Color?
    var flagSource: String = "GoingPro"

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let display = summary.timelineDisplay(
            homeTeam: homeTeam,
            awayTeam: awayTeam,
            maxVisible: maxVisibleLines,
            flagSource: flagSource
        )
        if display.lines.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 3) {
                Text(headingText ?? summary.goalScorersHeadingText)
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
    var accentColor: Color?
    var style: ProGameScoreboardStyle = ProGameScoreboardStyle()
    var timelineSummary: LiveScoringTimelineSummary?
    var showsFramedFinalBackground: Bool = true
    var flagSource: String = "GoingPro"

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let scoreboard = ProGameScoreboardView(
            awayIdentity: ProGameTeamScoreIdentity.resolve(teamName: awayTeam, badgeURL: awayBadgeURL, source: source),
            homeIdentity: ProGameTeamScoreIdentity.resolve(teamName: homeTeam, badgeURL: homeBadgeURL, source: source),
            awayScore: awayScore,
            homeScore: homeScore,
            style: style,
            statusHeader: isFinal ? .finalScore : nil,
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
                    headingColor: resolvedGoalScorerHeadingColor,
                    lineColor: resolvedGoalScorerLineColor,
                    flagSource: flagSource
                )
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

    private var resolvedGoalScorerHeadingColor: Color {
        FGColor.secondaryText(colorScheme)
    }

    private var resolvedGoalScorerLineColor: Color {
        FGColor.primaryText(colorScheme)
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
