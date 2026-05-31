import CoreLocation
import Photos
import SwiftUI
import Charts
import PhotosUI

private func localizedWholePercent(_ percent: Int) -> String {
    (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)))
}

private func localizedSignedWholePercent(_ percent: Int) -> String {
    (Double(percent) / 100).formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))
}

// MARK: - Venue analytics locally hidden events
//
// TODO: Persist hides in Supabase with `venue_hidden_analytics_events` (venue_owner_id, venue_event_id,
// created_at) and RLS so owners can manage their own rows. Until then, hides survive relaunch via UserDefaults.

private enum VenueOwnerAnalyticsHiddenEventsLocalStore {
    private static let defaultsKeyPrefix = "VenueOwnerAnalyticsHiddenEventIDs."

    /// Per-owner; when ``venueDatabaseId`` is set, hides are scoped to that location (Phase B3.1).
    private static func storageKey(ownerEmail: String, venueDatabaseId: UUID?) -> String {
        let email = ownerEmail.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let vid = venueDatabaseId {
            let vidKey = vid.uuidString.lowercased()
            if !email.isEmpty {
                return defaultsKeyPrefix + email + "." + vidKey
            }
            return defaultsKeyPrefix + "venue_id." + vidKey
        }
        return defaultsKeyPrefix + email
    }

    static func load(ownerEmail: String, venueDatabaseId: UUID?) -> Set<UUID> {
        let key = storageKey(ownerEmail: ownerEmail, venueDatabaseId: venueDatabaseId)
        guard let arr = UserDefaults.standard.array(forKey: key) as? [String] else { return [] }
        return Set(arr.compactMap(UUID.init))
    }

    static func save(ownerEmail: String, venueDatabaseId: UUID?, ids: Set<UUID>) {
        let key = storageKey(ownerEmail: ownerEmail, venueDatabaseId: venueDatabaseId)
        UserDefaults.standard.set(ids.map(\.uuidString).sorted(), forKey: key)
    }
}

private struct VenueOwnerAnalyticsDetailSelection: Identifiable {
    let id: UUID
    let row: VenueEventRow
}

private struct VenueAnalyticsLocationPerformance: Identifiable {
    let id: UUID
    let name: String
    let score: Int
    let signal: String
    let trendValues: [Int]
    let tint: Color
}

private struct VenueAnalyticsPerformanceWindow: Identifiable {
    let id: String
    let label: String
    let subtitle: String
}

private struct VenueAnalyticsBusinessInsight: Identifiable {
    let id: String
    let icon: String
    let title: String
    let value: String
    let subtitle: String?
    let tint: Color
}

private struct VenueAnalyticsDisplayCardRow: Identifiable {
    let id: String
    let eventID: UUID
    let row: VenueEventRow
}

private struct VenueAnalyticsBasicEventRow: Identifiable {
    let id: String
    let eventID: UUID?
    let title: String
    let schedule: String
    let sport: String
    let goingCount: Int
    let commentsCount: Int
    let status: String
}

private struct VenueAnalyticsTrendSportSummary: Identifiable {
    var id: String { sport }
    let sport: String
    let score: Int
    let tint: Color
}

private struct VenueAnalyticsLiveOpsGame: Identifiable {
    let id: String
    let eventID: UUID
    let row: VenueEventRow
    let title: String
    let sport: String
    let startDate: Date?
    let scheduleText: String
    let statusText: String
    let momentumScore: Int
    let interestedCount: Int
    let chatCount: Int
    let vibeCount: Int
    let activityScore: Int
    let isActiveNow: Bool
}

private struct VenueAnalyticsLiveOpsSnapshot {
    let activeGames: [VenueAnalyticsLiveOpsGame]
    let nextOpportunity: VenueAnalyticsLiveOpsGame?
    let alerts: [String]
    let activeGameCount: Int
    let activeChatCount: Int
    let crowdEnergy: Int
    let topLiveSport: String
    let statusText: String
    let momentumTrend: String

    var hasActiveActivity: Bool {
        !activeGames.isEmpty
    }
}

private struct BusinessAnalyticsChartPoint: Identifiable {
    let id: String
    let index: Int
    let label: String
    let value: Int
}

private struct BusinessAnalyticsRankedMetric: Identifiable {
    let id: String
    let rank: Int
    let title: String
    let subtitle: String?
    let valueText: String
    let progress: Double
    let icon: String
    let tint: Color
}

private enum BusinessAnalyticsHelpMetric: String, Identifiable {
    case engagementOverview = "Engagement Overview"
    case topPerformingEvents = "Top Performing Events"
    case busiestDays = "Busiest Days"

    var id: String { rawValue }

    var title: String { rawValue }

    var explanation: String {
        switch self {
        case .engagementOverview:
            return "Engagement measures fan activity across your venue, including interested fans, comments, chat activity, reactions, fan updates, and watch party participation."
        case .topPerformingEvents:
            return "Top Performing Events ranks events by overall engagement activity, including interested fans, comments, chat activity, energy votes, and fan interactions."
        case .busiestDays:
            return "Busiest Days shows which days generate the most fan activity so you can identify strong promotion opportunities."
        }
    }
}

private struct BusinessInsightsSparkline: View {
    let values: [Int]
    let tint: Color
    var lineWidth: CGFloat = 2

    var body: some View {
        Image(systemName: "waveform.path.ecg")
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(tint)
            .opacity(0.9)
            .padding(.vertical, 2)
            .accessibilityHidden(true)
    }
}

private enum BusinessHostedGameCycleDisplay {
    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let rangeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    static func resetText(from raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let date = SupabaseTimestampParsing.parseTimestamptz(raw) else {
            return nil
        }
        return "Resets \(resetFormatter.string(from: date))"
    }

    static func cycleRangeText(startRaw: String?, endRaw: String?) -> String? {
        guard let start = parseDate(startRaw),
              let end = parseDate(endRaw) else {
            return nil
        }
        return "\(rangeFormatter.string(from: start)) – \(rangeFormatter.string(from: end))"
    }

    static func gameDateText(scheduledStartAt: String?, eventDate: String?, eventTime: String?) -> String {
        if let start = parseDate(scheduledStartAt) {
            return rangeFormatter.string(from: start)
        }
        if let date = parseDate(eventDate) {
            let day = rangeFormatter.string(from: date)
            let time = eventTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return time.isEmpty ? day : "\(day) • \(time)"
        }
        return "Date unavailable"
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return SupabaseTimestampParsing.parseTimestamptz(raw)
    }
}

struct BusinessUsageCenterView: View {
    @Environment(\.colorScheme) private var colorScheme
    let status: BusinessVenueGamePostingStatus?
    var hostedGameCycleAudit: BusinessHostedGameCycleAudit? = nil
    var isHostedGameCycleLoading = false
    var hostedGameCycleAuditUnavailable = false

    private var isProActive: Bool {
        status?.computedIsPro == true
    }

    private var statisticsUnlocked: Bool {
        status?.statisticsAccessGranted == true
    }

    private var accent: Color {
        isProActive ? FGColor.accentGreen : FGColor.accentBlue
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                currentPlanSection
                usageMetricsSection
                hostedGamesThisCycleSection
                if status != nil && !isProActive {
                    proFeaturesPreviewSection
                }
            }
            .padding(20)
        }
        .background(FGAdaptiveSurface.sheetRoot.ignoresSafeArea())
        .onAppear {
            logBusinessUsageScreenDebug()
        }
        .onChange(of: status) { _, _ in
            logBusinessUsageScreenDebug()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Usage")
                .font(.largeTitle.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text("Operational limits and Business Pro access for this business.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var currentPlanSection: some View {
        usageSection(title: "Current Plan", systemImage: "building.2.crop.circle") {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(colorScheme == .dark ? 0.24 : 0.14))
                    Image(systemName: isProActive ? "sparkles.rectangle.stack.fill" : "briefcase.fill")
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(accent)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 5) {
                    Text(status?.businessPlanDisplayTitle ?? "Checking plan status…")
                        .font(.headline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(planStateText)
                        .font(.caption.weight(.bold))
                        .foregroundStyle(planStateColor)
                    if let detail = planDetailText {
                        Text(detail)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var usageMetricsSection: some View {
        usageSection(title: "Usage Metrics", systemImage: "chart.bar.xaxis") {
            VStack(alignment: .leading, spacing: 14) {
                usageCountRow(kind: .activeVenues)
                usageCountRow(kind: .hostedGames)
                statisticsUsageRow
                if anyFreeLimitReached {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(limitReachedTitle)
                            .font(.caption.weight(.black))
                            .foregroundStyle(FGColor.dangerRed)
                        Text(limitReachedMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                    .background(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private var hostedGamesThisCycleSection: some View {
        usageSection(title: "Hosted Games This Cycle", systemImage: "sportscourt") {
            VStack(alignment: .leading, spacing: 12) {
                if isHostedGameCycleLoading && hostedGameCycleAudit == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading hosted game details…")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    if let rangeText = hostedGameCycleRangeText {
                        Text(rangeText)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }

                    Text(hostedGameCycleSummaryText)
                        .font(.caption.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))

                    let games = hostedGameCycleAudit?.games ?? []
                    if hostedGameCycleAuditUnavailable && hostedGameCycleAudit == nil {
                        Text("Couldn’t load cycle games. Your usage count is still available above.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(FGAdaptiveSurface.sheetRoot.opacity(colorScheme == .dark ? 0.75 : 0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else if games.isEmpty && hostedGameCycleUsedCount == 0 {
                        Text("No hosted games counted in this cycle yet.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(FGAdaptiveSurface.sheetRoot.opacity(colorScheme == .dark ? 0.75 : 0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else if games.isEmpty {
                        Text("Couldn’t load cycle games. Your usage count is still available above.")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(10)
                            .background(FGAdaptiveSurface.sheetRoot.opacity(colorScheme == .dark ? 0.75 : 0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    } else {
                        VStack(spacing: 8) {
                            ForEach(games) { game in
                                hostedGameCycleAuditRow(game)
                            }
                        }

                        Text("\(games.count) \(games.count == 1 ? "game" : "games") counted this cycle")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 4)
                    }
                }
            }
        }
    }

    private var hostedGameCycleRangeText: String? {
        BusinessHostedGameCycleDisplay.cycleRangeText(
            startRaw: hostedGameCycleAudit?.cycleStartAt ?? status?.hostedGameCycleStartAt,
            endRaw: hostedGameCycleAudit?.cycleEndAt ?? status?.hostedGameCycleEndAt ?? status?.nextResetAt
        )
    }

    private var hostedGameCycleUsedCount: Int {
        hostedGameCycleAudit?.hostedGamesUsedThisCycle ?? status?.hostedGamesUsedForDisplay ?? 0
    }

    private var hostedGameCycleSummaryText: String {
        let used = hostedGameCycleUsedCount
        let unlimited = hostedGameCycleAudit?.isUnlimitedHosting ?? status.map { $0.unlimitedHosting || $0.isBusinessPro } ?? false
        if unlimited {
            return "\(used) hosted games • Unlimited"
        }
        let limit = status?.hostedGamesEffectiveMonthlyHostLimitForDisplay
            ?? hostedGameCycleAudit?.monthlyHostLimit
            ?? status.map { max(1, $0.monthlyHostedGameLimit ?? $0.monthlyHostLimit) }
            ?? BusinessMembershipPolicy.freeMonthlyVenueGameLimit
        return "\(used) / \(limit) used"
    }

    private func hostedGameCycleAuditRow(_ game: BusinessHostedGameCycleGame) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.title)
                    .font(.caption.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)

                Text(BusinessHostedGameCycleDisplay.gameDateText(
                    scheduledStartAt: game.scheduledStartAt,
                    eventDate: game.eventDate,
                    eventTime: game.eventTime
                ))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

                if let venueName = game.venueName?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !venueName.isEmpty {
                    Text(venueName)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 5) {
                hostedGameStatusBadge(game.status)
                Text("Counted")
                    .font(.system(size: 9, weight: .heavy, design: .rounded))
                    .foregroundStyle(FGColor.accentGreen)
            }
        }
        .padding(10)
        .background(FGAdaptiveSurface.sheetRoot.opacity(colorScheme == .dark ? 0.75 : 0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func hostedGameStatusBadge(_ rawStatus: String?) -> some View {
        let label = hostedGameStatusLabel(rawStatus)
        let tint = hostedGameStatusTint(label)
        return Text(label)
            .font(.system(size: 9, weight: .heavy, design: .rounded))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(tint.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule(style: .continuous))
    }

    private func hostedGameStatusLabel(_ rawStatus: String?) -> String {
        let status = rawStatus?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if status.contains("cancel") || status == "archived" || status == "deleted" { return "Cancelled" }
        if status.contains("complete") || status.contains("final") || status.contains("history") { return "Completed" }
        if status.contains("live") || status.contains("active") { return "Live" }
        return "Scheduled"
    }

    private func hostedGameStatusTint(_ label: String) -> Color {
        switch label {
        case "Live":
            return FGColor.dangerRed
        case "Completed":
            return FGColor.accentGreen
        case "Cancelled":
            return Color.gray
        default:
            return Color.orange
        }
    }

    private var proFeaturesPreviewSection: some View {
        usageSection(title: "Pro Features", systemImage: "sparkles") {
            VStack(spacing: 10) {
                proFeatureRow(title: "Unlimited active venues", value: "Business Pro", enabled: false)
                proFeatureRow(title: "Unlimited hosted games", value: "Business Pro", enabled: false)
                proFeatureRow(title: "Statistics", value: "Business Pro", enabled: false)
                proFeatureRow(title: "Sponsored visibility", value: "Included", enabled: status?.sponsoredPlacementAllowed == true)
            }
        }
    }

    private func usageSection<Content: View>(
        title: String,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(accent.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 1)
        }
    }

    private var statisticsUsageRow: some View {
        usageStatusRow(
            title: "Statistics",
            detail: status == nil ? "Checking usage…" : (statisticsUnlocked ? "Enabled" : "Upgrade to Pro"),
            rightValue: status == nil ? nil : (statisticsUnlocked ? "Enabled" : "Upgrade to Pro"),
            systemImage: statisticsUnlocked ? "chart.bar.xaxis" : "lock.fill",
            tint: statisticsUnlocked ? FGColor.accentGreen : FGColor.secondaryText(colorScheme)
        )
    }

    private enum UsageMetricKind {
        case activeVenues
        case hostedGames
    }

    private func usageCountRow(kind: UsageMetricKind) -> some View {
        guard let status else {
            return AnyView(
                usageStatusRow(
                    title: kind == .activeVenues ? "Active venues" : "Hosted games",
                    detail: "Checking usage…",
                    rightValue: nil,
                    systemImage: "hourglass",
                    tint: FGColor.secondaryText(colorScheme)
                )
            )
        }

        let value: Int
        let limit: Int?
        let title: String
        let unit: String
        let unlimited: Bool
        switch kind {
        case .activeVenues:
            value = status.activeVenueCount
            limit = status.activeVenueLimit
            title = "Active venues"
            unit = value == 1 ? "active venue" : "active venues"
            unlimited = status.unlimitedVenues || status.isBusinessPro
        case .hostedGames:
            value = status.hostedGamesUsedForDisplay
            limit = status.hostedGamesEffectiveMonthlyHostLimitForDisplay
            title = "Hosted games"
            unit = value == 1 ? "hosted game this cycle" : "hosted games this cycle"
            unlimited = status.unlimitedHosting || status.isBusinessPro
        }

        if unlimited {
            return AnyView(
                usageStatusRow(
                    title: title,
                    detail: kind == .hostedGames ? "Unlimited hosted games" : "\(value) \(unit) • Unlimited",
                    rightValue: "∞ Unlimited",
                    systemImage: "checkmark.seal.fill",
                    tint: FGColor.accentGreen
                )
            )
        }

        let resolvedLimit = max(1, limit ?? (kind == .activeVenues
            ? BusinessMembershipPolicy.freeVenueListingLimit
            : BusinessMembershipPolicy.freeMonthlyVenueGameLimit))
        let remaining = max(0, resolvedLimit - value)
        let resetText = kind == .hostedGames ? BusinessHostedGameCycleDisplay.resetText(from: status.nextResetAt) : nil
        let rightValue: String
        if kind == .hostedGames, let resetText {
            rightValue = remaining == 0 ? "Limit reached • \(resetText)" : resetText
        } else {
            rightValue = remaining == 0 ? "Limit reached" : "\(remaining) left"
        }
        return AnyView(
            usageMetricRow(
                title: title,
                detail: "\(value) / \(resolvedLimit) \(unit)",
                supplementalDetail: usageMetricSupplementalDetail(kind: kind, status: status, effectiveLimit: resolvedLimit),
                value: value,
                total: resolvedLimit,
                rightValue: rightValue,
                isUnlimited: false
            )
        )
    }

    private func usageMetricSupplementalDetail(
        kind: UsageMetricKind,
        status: BusinessVenueGamePostingStatus,
        effectiveLimit: Int
    ) -> String? {
        guard kind == .hostedGames,
              !status.isBusinessPro,
              !status.unlimitedHosting else {
            return nil
        }
        let bonus = max(0, status.hostedGameCycleBonusGames ?? 0)
        guard bonus > 0 || effectiveLimit != status.monthlyHostLimit else {
            return nil
        }
        return "Base limit: \(status.monthlyHostLimit)\nBonus this cycle: +\(bonus)\nEffective limit: \(effectiveLimit)"
    }

    private func usageMetricRow(
        title: String,
        detail: String,
        supplementalDetail: String? = nil,
        value: Int,
        total: Int,
        rightValue: String,
        isUnlimited: Bool = false
    ) -> some View {
        let clampedTotal = max(1, total)
        let ratio = isUnlimited ? 1.0 : min(1, Double(value) / Double(clampedTotal))
        let tint = isUnlimited ? FGColor.accentGreen : usageTint(value: value, total: clampedTotal)

        return VStack(alignment: .leading, spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(detail)
                        .font(.caption.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    if let supplementalDetail {
                        Text(supplementalDetail)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(rightValue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(tint)
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(FGAdaptiveSurface.capsuleUnselected)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(8, proxy.size.width * ratio))
                }
            }
            .frame(height: 8)
        }
    }

    private func usageStatusRow(title: String, detail: String, rightValue: String?, systemImage: String, tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 24, height: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text(detail)
                    .font(.caption.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            Spacer(minLength: 8)
            if let rightValue {
                Text(rightValue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(tint)
            }
        }
        .padding(10)
        .background(FGAdaptiveSurface.sheetRoot.opacity(colorScheme == .dark ? 0.75 : 0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func proFeatureRow(title: String, value: String, enabled: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: enabled ? "checkmark.seal.fill" : "lock.fill")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(enabled ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
                .frame(width: 24, height: 24)
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(enabled ? FGColor.accentGreen : FGColor.secondaryText(colorScheme))
        }
        .padding(10)
        .background(FGAdaptiveSurface.sheetRoot.opacity(colorScheme == .dark ? 0.75 : 0.65), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func usageTint(value: Int, total: Int) -> Color {
        guard total > 0 else { return FGColor.accentGreen }
        let ratio = Double(value) / Double(total)
        if ratio >= 1 { return FGColor.dangerRed }
        if ratio >= 0.8 { return Color.orange }
        return FGColor.accentGreen
    }

    private var planStateText: String {
        guard let status else { return "Checking access" }
        if status.computedIsPro {
            return status.businessPlanDisplaySubtitle
        }
        if status.planType != "free" { return "expired" }
        return normalizedPlanStatus(status.planStatus)
    }

    private var planStateColor: Color {
        switch planStateText.lowercased() {
        case "active":
            return FGColor.accentGreen
        case "paused":
            return Color.orange
        case "expired", "cancelled":
            return FGColor.dangerRed
        default:
            return FGColor.secondaryText(colorScheme)
        }
    }

    private var planDetailText: String? {
        guard let status else { return nil }
        if status.computedIsPro {
            if let promoText = status.businessProPromoEndDateText {
                return promoText
            }
            if let subscriptionText = status.businessProSubscriptionExpiryText {
                return subscriptionText
            }
            if let formatted = formattedBusinessProExpiry(status.proExpiresAt) {
                return "Expires \(formatted)"
            }
            return "No scheduled expiration."
        }
        if status.planType != "free", let formatted = formattedBusinessProExpiry(status.proExpiresAt) {
            return "Business Pro expired \(formatted). Free limits now apply."
        }
        return "Free limits are enforced by server entitlements."
    }

    private var anyFreeLimitReached: Bool {
        status?.freeVenueListingLimitReached == true || status?.freeMonthlyVenueGameLimitReached == true
    }

    private var monthlyHostLimitReached: Bool {
        status?.freeMonthlyVenueGameLimitReached == true
    }

    private var venueLimitReached: Bool {
        status?.freeVenueListingLimitReached == true
    }

    private var limitReachedTitle: String {
        if venueLimitReached && monthlyHostLimitReached {
            return "Plan limits reached"
        }
        if venueLimitReached {
            return "Active venue limit reached"
        }
        return "Hosted game cycle limit reached"
    }

    private var limitReachedMessage: String {
        if monthlyHostLimitReached {
            return BusinessLimitCopy.hostedGameLimitReached
        }
        return BusinessLimitCopy.venueLimitReached
    }

    private func normalizedPlanStatus(_ raw: String) -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return value.isEmpty ? "active" : value
    }

    private func formattedBusinessProExpiry(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let date = Self.expiryParserWithFractions.date(from: raw) ?? Self.expiryParser.date(from: raw)
        guard let date else { return nil }
        return Self.expiryDisplayFormatter.string(from: date)
    }

    private func logBusinessUsageScreenDebug() {
#if DEBUG
        let activeVenueLimit = status.map { $0.activeVenueLimit.map(String.init) ?? "unlimited" } ?? "unknown"
        let monthlyHostedGameLimit = status.map { $0.monthlyHostedGameLimit.map(String.init) ?? "unlimited" } ?? "unknown"
        print("[BusinessUsageScreenDebug] businessId=\(status?.businessId?.uuidString.lowercased() ?? "nil")")
        print("[BusinessUsageScreenDebug] isBusinessPro=\(status?.isBusinessPro.description ?? "unknown")")
        print("[BusinessUsageScreenDebug] activeVenueCount=\(status.map { String($0.activeVenueCount) } ?? "unknown")")
        print("[BusinessUsageScreenDebug] activeVenueLimit=\(activeVenueLimit)")
        print("[BusinessUsageScreenDebug] hostedGamesThisMonth=\(status.map { String($0.monthlyHostedGameCount) } ?? "unknown")")
        print("[BusinessUsageScreenDebug] hostedGamesUsedThisCycle=\(status.flatMap { $0.hostedGamesUsedThisCycle }.map(String.init) ?? "unknown")")
        print("[BusinessUsageScreenDebug] monthlyHostedGameLimit=\(monthlyHostedGameLimit)")
        print("[BusinessUsageScreenDebug] nextResetAt=\(status?.nextResetAt ?? "unknown")")
#endif
    }

    private static let expiryParserWithFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let expiryParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let expiryDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()
}

/// Which slice of the venue owner dashboard Settings (or other callers) presents.
enum VenueOwnerDashboardEntryPoint: Equatable {
    /// Profile, games, and analytics tabs (legacy / rare).
    case allTabs
    /// Settings → Business Dashboard: premium venue hub overview first, with quick actions into existing flows.
    case overviewDashboard
    /// Settings → Manage Venue: venue profile, address, photos, features only.
    case profileEditor
    /// Settings → Manage Games: add / edit / cancel venue games.
    case gamesManager
    /// Settings → Statistics: engagement analytics only.
    case analyticsViewer
}

struct VenueOwnerDashboardView: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    @ObservedObject private var businessProEntitlement = BusinessProEntitlementManager.shared
    var entryPoint: VenueOwnerDashboardEntryPoint = .allTabs
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    private let usePremiumCrowdInsights = false

    @State private var selectedSection: VenueDashboardSection = .overview

    @State private var gameTitle = ""
    @State private var gameTeam1 = ""
    @State private var gameTeam2 = ""
    @State private var gameTeam1Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
    @State private var gameTeam2Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
    @State private var lastGeneratedGameTitle = ""
    @State private var titleManuallyEdited = false
    @State private var gameLeague = ""
    @State private var seating = ""
    @State private var socialCoordination = ""
    @State private var gameDate = Date()
    @State private var gameStartTime = Date()
    @State private var hasFood = false
    @State private var hasWifi = false
    @State private var hasGarden = false
    @State private var hasProjector = false
    @State private var isPetFriendly = false
    /// Local-only until Supabase venue profile exposes matching columns (not sent in ``saveVenueProfile``).
    @State private var hasParkingAvailable = false
    @State private var hasEasyParking = false
    @State private var isFamilyFriendly = false
    @State private var hasHandicapParking = false
    @State private var hasLiveMusic = false
    @State private var hasPoolTables = false
    @State private var hasRooftop = false
    @State private var hasDJNights = false
    @State private var hasKaraoke = false
    @State private var hasCocktails = false
    @State private var hasCraftBeer = false
    @State private var totalScreens = 1
    @State private var businessDashboardQuickActionNotice: String?
    @State private var profileSaveMessage = ""
    @State private var venueStreetAddress = ""
    @State private var venueAddressLine2 = ""
    @State private var venueCity = ""
    @State private var venueState = ""
    @State private var venueZipCode = ""
    @State private var venueCountry = BusinessLocationCountryPolicy.defaultCountryCode
    @State private var venueLatitude: Double?
    @State private var venueLongitude: Double?
    @State private var venueFormattedAddress = ""
    @State private var selectedCoverPhoto: PhotosPickerItem?
    @State private var selectedMenuPhoto: PhotosPickerItem?
    @State private var showVenuePinPicker = false
    @State private var showVenueSupporterPicker = false
    @State private var showDeleteVenueConfirmation = false
    @State private var isDeletingVenue = false
    @State private var venueDeleteError = ""
    /// URLs used only for Bar/Menu previews (may include `?v=` / `&v=` cache bust). Supabase / viewModel URLs stay clean.
    @State private var displayedCoverPhotoURL = ""
    @State private var displayedMenuPhotoURL = ""
    @State private var analyticsGames: [VenueEventRow] = []
    @State private var analyticsIsLoading = false
    @State private var analyticsDatePreset: VenueAnalyticsDatePreset = .thisMonth
    @State private var analyticsSportFilter: String = "All"
    @State private var analyticsCustomStart = Date()
    @State private var analyticsCustomEnd = Date()
    @State private var analyticsHiddenEventIDs: Set<UUID> = []
    @State private var analyticsDetailSelection: VenueOwnerAnalyticsDetailSelection?
    @State private var analyticsGameHistoryForYear: [BusinessGameHistoryRow] = []
    @State private var analyticsGameHistoryYear: Int = Calendar.current.component(.year, from: Date())
    @State private var analyticsGameHistoryMonth: Int = 0
    @State private var analyticsGameHistoryLoading = false
    @State private var analyticsGameHistoryError = ""
    @State private var showBusinessAnalyticsGuide = false
    @State private var businessAnalyticsHelpMetric: BusinessAnalyticsHelpMetric?

    private enum VenueAnalyticsDatePreset: String, CaseIterable {
        case thisWeek = "This week"
        case thisMonth = "This month"
        case thisYear = "This year"
    }

    /// Top-level tabs inside the business **Analytics** card (keeps heavy game history off the engagement screen).
    private enum BusinessVenueAnalyticsTab: Int, CaseIterable {
        case venueAnalytics = 0
        case trends = 1
        case liveOps = 2
        case gameHistory = 3

        var title: String {
            switch self {
            case .venueAnalytics: return "Activity"
            case .trends: return "Analytics"
            case .liveOps: return "Live"
            case .gameHistory: return "History"
            }
        }

        var systemImage: String {
            switch self {
            case .venueAnalytics: return "chart.line.uptrend.xyaxis"
            case .trends: return "chart.pie"
            case .liveOps: return "record.circle"
            case .gameHistory: return "calendar"
            }
        }
    }

    @State private var businessVenueAnalyticsTab: BusinessVenueAnalyticsTab = .venueAnalytics

    /// Caps how many event cards render at once when the date filter is **All** (newest first).
    private enum VenueAnalyticsEngagementDisplay {
        static let maxCardRowsWhenAllDatesPreset = 500
    }

    private enum ManageGamesListTab: Int, CaseIterable {
        case scheduled = 0
        case add = 1
    }

    private enum BusinessGameCreationMode: String, CaseIterable {
        case manual = "Manual Entry"
        case importLive = "Import From Live Games"
    }

    private enum DashboardScrollTarget {
        static let addGameFormFields = "venue-owner-add-game-form-fields"
    }

    private var manualPredictionTeamValidationMessage: String {
        L10n.t("add_both_teams_predictions", languageCode: appLanguageRaw)
    }

    private var manualPredictionCompetitorValidationMessage: String {
        manualGameUsesPlayerCompetitorLabels
            ? "Add both players so fans can see the matchup."
            : manualPredictionTeamValidationMessage
    }

    @State private var manageGamesListTab: ManageGamesListTab = .scheduled
    @State private var gameCreationMode: BusinessGameCreationMode = .manual
    @State private var didPickInitialManageGamesTab = false
    @State private var myVenueGamesForManage: [VenueEventRow] = []
    @State private var manageGamesListLoading = false
    /// Prevents stacked ``refreshManageGamesList`` runs from freezing UI during lifecycle refreshes.
    @State private var manageGamesRefreshInFlight = false
    @State private var manageGamesFeedback = ""
    @State private var manageGamesError = ""
#if DEBUG
    @State private var manageGamesDebugErrorDetails = ""
#endif
    @State private var isSavingNewGame = false
    @State private var businessMembershipStatus: BusinessVenueGamePostingStatus?
    @State private var businessPlanRefreshInFlight = false
    @State private var manualBusinessPlanRefreshInFlight = false
    @State private var lastBusinessPlanRefreshAt: Date?
    @State private var lastBusinessPlanRefreshBusinessID: UUID?
    @State private var showBusinessProSubscriptionSheet = false
    @State private var showBusinessUsageSheet = false
    @State private var businessHostedGameCycleAudit: BusinessHostedGameCycleAudit?
    @State private var businessHostedGameCycleAuditLoading = false
    @State private var businessHostedGameCycleAuditUnavailable = false
    @State private var titleEditTarget: VenueOwnerGameTitleEditTarget?
    @State private var titleEditDraft = ""
    @State private var titleEditTeam1Draft = ""
    @State private var titleEditTeam2Draft = ""
    @State private var businessGameChatTarget: VenueOwnerGameChatTarget?
    @State private var showCancelGameDialog = false
    @State private var cancelGameRowSnapshot: VenueEventRow?
    @State private var showVenueOwnerContactSupport = false
    @State private var showAddLocationSheet = false
    @State private var addLocationSubmitBanner: String?
    @StateObject private var addLocationSheetFormState = AddLocationSheetFormState()
    @State private var showSchedulePicker = false
    @State private var schedulePickerDate = Date()
    @State private var importGamesDate = Date()
    @State private var importGamesBrowserExpanded = true
    @State private var importGamesCalendarExpanded = false
    @State private var addGameFormScrollRequestID = 0
    @State private var importGamesSportFilter = "All"
    @State private var importGamesMatches: [LiveMatch] = []
    @State private var isLoadingImportGames = false
    @State private var importGamesError = ""
    @State private var importedExternalGameID: String?
    @State private var importedExternalSource: String?
    @State private var importedExternalLeague: String?
    @State private var importedHomeTeam: String?
    @State private var importedAwayTeam: String?
    @State private var importedFromAPI = false

    init(
        viewModel: MapViewModel,
        entryPoint: VenueOwnerDashboardEntryPoint = .allTabs
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
        self.entryPoint = entryPoint
    }

    enum VenueDashboardSection: String, CaseIterable {
        case overview = "Overview"
        case profile = "Profile"
        case games = "Games"
        case analytics = "Analytics"

        /// Shown in the segmented control (may differ from ``rawValue`` for clarity).
        var pickerLabel: String {
            switch self {
            case .overview: rawValue
            case .profile, .games: rawValue
            case .analytics: "Analytics"
            }
        }
    }

    private var effectiveSection: VenueDashboardSection {
        switch entryPoint {
        case .allTabs:
            return selectedSection
        case .overviewDashboard:
            return .overview
        case .profileEditor:
            return .profile
        case .gamesManager:
            return .games
        case .analyticsViewer:
            return .analytics
        }
    }

    /// When true, venue name, address, region, and coordinates are read-only (FanGeo-approved active managed venue).
    private var venueCoreIdentityLocked: Bool {
        viewModel.venueCoreIdentityLockedForSelectedVenue()
    }

    private var selectedVenuePlanLocked: Bool {
        viewModel.selectedManagedVenueIsPlanLocked()
    }

    private var venueProfileEditingLocked: Bool {
        venueCoreIdentityLocked || selectedVenuePlanLocked
    }

    private var selectedVenueCanHostGames: Bool {
        businessCanHostGameFromServer && !selectedVenuePlanLocked
    }

    /// Games / analytics require ``MapViewModel/venueOwnerToolsUnlockedForUI()`` (at least one linked or legacy venue row).
    private var venueOwnerGamesAndAnalyticsLocked: Bool {
        !viewModel.venueOwnerToolsUnlockedForUI()
    }

    private func logVenueOwnerToolsGate(screen: String) {
#if DEBUG
        print("[VenueOwnerToolsGate] unlocked=\(viewModel.venueOwnerToolsUnlockedForUI())")
        print("[VenueOwnerToolsGate] managedVenuesCount=\(viewModel.managedVenuesForOwner().count)")
        print("[VenueOwnerToolsGate] screen=\(screen)")
#endif
    }

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] VenueOwnerReadsStore=true")
#endif
    }

    private var venueOwnerPendingApprovalCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pending approval")
                .font(.headline)
                .foregroundStyle(.primary)
            Text("Claim requests are reviewed before owner tools are enabled.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(Color(.separator).opacity(0.5), lineWidth: 1)
        )
    }

    @ViewBuilder
    var body: some View {
        let _: Void = logFanUpdatesStoreMigrationDebug()

        if entryPoint == .gamesManager {
            manageGamesSheetExperience
        } else {
            venueOwnerDashboardBody
        }
    }

    private var manageGamesSheetExperience: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    manageGamesSheetTabButton(title: "Scheduled", tab: .scheduled)
                    manageGamesSheetTabButton(title: "Add Game", tab: .add)
                }

                manageGamesStatusBanners

                if manageGamesListTab == .scheduled {
                    manageGamesListPane
                } else {
                    addGamePane
                }
            }
            .padding()
            .background(FGAdaptiveSurface.cardElevated)
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .overlay(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
            )
            .padding(.horizontal)
            .padding(.top, 40)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(FGAdaptiveSurface.sheetRoot)
        .onAppear {
#if DEBUG
            print("[ManageGamesDebug] manageGames onAppear ownerVenueId=\(viewModel.ownerVenueDatabaseId?.uuidString ?? "nil")")
#endif
            startManageGamesListRefresh()
            startAddGamePaneEntitlementRefreshIfNeeded()
        }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            startManageGamesListRefresh()
        }
        .onChange(of: manageGamesListTab) { _, _ in
            startAddGamePaneEntitlementRefreshIfNeeded()
        }
        .confirmationDialog(
            "Cancel this game?",
            isPresented: $showCancelGameDialog,
            titleVisibility: .visible
        ) {
            Button("Remove Game", role: .destructive) {
                guard let snap = cancelGameRowSnapshot else { return }
                cancelGameRowSnapshot = nil
                Task {
                    await performManageGameCancel(rowSnapshot: snap)
                }
            }
            Button("Keep Game", role: .cancel) {
                cancelGameRowSnapshot = nil
            }
        } message: {
            Text("This will remove the game from your venue schedule and FanGeo discovery.")
        }
        .sheet(item: $titleEditTarget) { target in
            titleEditSheet(for: target)
        }
        .sheet(isPresented: $showSchedulePicker) {
            VenueOwnerSchedulePickerSheet(
                matches: viewModel.liveMatches,
                isLoading: viewModel.isLoadingLiveMatches,
                selectedDate: $schedulePickerDate,
                onSelect: { choice in
                    applyScheduledGameChoice(choice)
                }
            )
        }
    }

    private func manageGamesSheetTabButton(title: String, tab: ManageGamesListTab) -> some View {
        let isSelected = manageGamesListTab == tab
        return Button {
            manageGamesListTab = tab
            if tab == .add {
                gameCreationMode = .manual
            }
        } label: {
            Text(title)
                .font(.caption.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(
                    isSelected
                        ? AnyShapeStyle(Color.accentColor)
                        : AnyShapeStyle(FGAdaptiveSurface.capsuleUnselected)
                )
                .foregroundStyle(isSelected ? Color.white : FGColor.primaryText(colorScheme))
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var venueOwnerDashboardBody: some View {
        ScrollViewReader { scrollProxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {

                    if effectiveSection != .overview {
                        header
                    }

                    if entryPoint == .allTabs {
                        sectionPicker
                    }

                    if effectiveSection == .overview {
                        businessProAccessSection
                    }

                    Group {
                        switch effectiveSection {
                        case .overview:
                            businessDashboardOverviewSection
                        case .profile:
                            profileSection
                        case .games:
                            if venueOwnerGamesAndAnalyticsLocked {
                                venueOwnerPendingApprovalCard
                            } else {
                                gamesSection
                            }
                        case .analytics:
                            if venueOwnerGamesAndAnalyticsLocked {
                                venueOwnerPendingApprovalCard
                            } else if !businessStatisticsAccessGranted {
                                businessStatisticsProLockedSection
                            } else {
                                venueAnalyticsSection
                            }
                        }
                    }
                    // Force a fresh subtree when the entry point or active tab changes so a prior section’s
                    // SwiftUI state cannot remain mounted under the venue profile editor sheet.
                    .id("\(String(describing: entryPoint))-\(effectiveSection.rawValue)")
                }
                .padding()
            }
        .background(FGAdaptiveSurface.sheetRoot)
        .onChange(of: addGameFormScrollRequestID) { _, _ in
            guard effectiveSection == .games, manageGamesListTab == .add else { return }
            DispatchQueue.main.async {
                withAnimation(.easeInOut(duration: 0.28)) {
                    scrollProxy.scrollTo(DashboardScrollTarget.addGameFormFields, anchor: .top)
                }
            }
        }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, newId in
#if DEBUG
            print("[ManageGamesDebug] ownerVenueDatabaseId changed → \(newId?.uuidString ?? "nil")")
#endif
            clearManageGamesTransientStateForVenueSwitch()
            clearAnalyticsGameHistoryState()
        }
        .onAppear {
            logBusinessDashboardRouteDebug()
            logBusinessProVisibilityDebug(dashboardVisible: true)
            if entryPoint == .overviewDashboard {
                selectedSection = .overview
#if DEBUG
                print("[BusinessDashboardRouteDebug] forcedOverview")
#endif
            }
            if entryPoint != .analyticsViewer {
                Task {
                    await viewModel.stopVenueOwnerAnalyticsRealtime()
                }
            }
            switch effectiveSection {
            case .overview:
                logBusinessDashboardDebug()
            case .games:
                logVenueOwnerToolsGate(screen: "ManageGames")
            case .analytics:
                logVenueOwnerToolsGate(screen: "Analytics")
            case .profile:
                break
            }
        }
        .onChange(of: effectiveSection) { _, newSection in
            switch newSection {
            case .overview:
                logBusinessDashboardDebug()
            case .games:
                logVenueOwnerToolsGate(screen: "ManageGames")
            case .analytics:
                logVenueOwnerToolsGate(screen: "Analytics")
            case .profile:
                break
            }
        }
        .onChange(of: selectedSection) { _, newValue in
            guard entryPoint == .allTabs || entryPoint == .overviewDashboard else { return }
            if newValue != .analytics {
                Task {
                    await viewModel.stopVenueOwnerAnalyticsRealtime()
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, effectiveSection == .overview else { return }
            Task {
                await refreshBusinessPlanStatus(source: "foreground")
            }
        }
        .onChange(of: addLocationSubmitBanner) { _, newValue in
            guard newValue?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
            Task {
                await refreshBusinessPlanStatus(source: "postMutation", force: true, refreshOwnedVenues: true)
            }
        }
        .onDisappear {
            Task {
                await viewModel.stopVenueOwnerAnalyticsRealtime()
            }
        }
        .task(id: effectiveSection) {
            if effectiveSection == .overview {
                await refreshBusinessPlanStatus(source: "onAppear")
                await refreshBusinessDashboardOverview()
            } else if effectiveSection == .analytics {
                await refreshBusinessStatisticsProStatus(reason: entryPoint == .analyticsViewer ? "analyticsViewer" : "analyticsSection")
                guard businessStatisticsAccessGranted else {
                    logBusinessStatisticsProGate(isPro: false, accessGranted: false, source: "analyticsSection")
                    if entryPoint == .analyticsViewer {
                        showBusinessProSubscriptionSheet = true
                    }
                    return
                }
                await loadVenueAnalytics()
            }
        }
        .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
            guard effectiveSection == .analytics else { return }
            Task {
                await refreshBusinessStatisticsProStatus(reason: entryPoint == .analyticsViewer ? "analyticsViewerVenueChanged" : "analyticsVenueChanged")
                guard businessStatisticsAccessGranted else {
                    logBusinessStatisticsProGate(isPro: false, accessGranted: false, source: "analyticsVenueChanged")
                    if entryPoint == .analyticsViewer {
                        showBusinessProSubscriptionSheet = true
                    }
                    return
                }
                await loadVenueAnalytics()
            }
        }
        .task(id: viewModel.ownerVenueDatabaseId) {
            let managed = await MainActor.run { viewModel.managedVenuesForOwner() }
            guard !managed.isEmpty else {
                await MainActor.run {
#if DEBUG
                    print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
                    viewModel.clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: viewModel.ownerVenueDatabaseId)
                    clearLocalVenueProfileFieldsForEmptyState()
                }
                return
            }

            guard let selectedVenueID = await MainActor.run(body: { viewModel.ownerVenueDatabaseId }),
                  managed.contains(where: { $0.id == selectedVenueID }) else {
                await MainActor.run {
                    let stale = viewModel.ownerVenueDatabaseId
                    viewModel.clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: stale)
                    clearLocalVenueProfileFieldsForEmptyState()
                }
                return
            }

            if let saved = await viewModel.loadVenueProfile() {
                await MainActor.run {
                    viewModel.applyVenueProfileRowToOwnerState(saved)
                    applyVenueProfileToLocalEditorFields(saved)
                }
            } else {
                await MainActor.run {
                    viewModel.clearSelectedVenueProfileForEmptyState(deletedSelectedVenue: selectedVenueID)
                    clearLocalVenueProfileFieldsForEmptyState()
                    if viewModel.pendingClaimVenueID != nil {
                        let street = viewModel.ownerVenueAddress.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueStreetAddress.isEmpty, !street.isEmpty {
                            venueStreetAddress = street
                        }
                        let line2 = viewModel.ownerVenueAddressLine2.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueAddressLine2.isEmpty, !line2.isEmpty {
                            venueAddressLine2 = line2
                        }
                        let city = viewModel.ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueCity.isEmpty, !city.isEmpty {
                            venueCity = city
                        }
                        let zip = viewModel.ownerVenueZipCode.trimmingCharacters(in: .whitespacesAndNewlines)
                        if venueZipCode.isEmpty, !zip.isEmpty {
                            venueZipCode = zip
                        }
                        let st = viewModel.ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !st.isEmpty {
                            venueState = st
                        }
                        let country = viewModel.ownerVenueCountry.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !country.isEmpty {
                            venueCountry = country
                        }
                    }
                }
            }
            syncDisplayedVenuePhotoURLsFromViewModel()
        }
        
        .onChange(of: selectedCoverPhoto) { _, newItem in
            Task {
                guard let newItem else { return }
                guard !selectedVenuePlanLocked else {
                    await MainActor.run {
                        selectedCoverPhoto = nil
                        profileSaveMessage = BusinessLimitCopy.planLockedVenueSubtitle
                    }
                    return
                }
                print("[VenuePhotoSaveDebug] pickedImage=true")
                guard let data = try? await newItem.loadTransferable(type: Data.self) else {
                    await MainActor.run {
                        selectedCoverPhoto = nil
                        profileSaveMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                    }
                    return
                }
                if let url = await viewModel.uploadVenuePhoto(data: data, fileName: "cover.jpg") {
                    await MainActor.run {
                        viewModel.venueCoverPhotoURL = url
                        displayedCoverPhotoURL = ImageDisplayURL.displayVersionedURLString(
                            ImageDisplayURL.canonicalStorageURLString(url),
                            refreshToken: UUID()
                        )
                        selectedCoverPhoto = nil
                        profileSaveMessage = "Cover photo uploaded. Tap Save Profile to save changes."
                    }
                } else {
                    await MainActor.run {
                        selectedCoverPhoto = nil
                        profileSaveMessage = "Business Photo upload failed. Try again, or check your connection."
                    }
                }
            }
        }
        .onChange(of: venueCountry) { _, newCountry in
            BusinessLocationCountryPolicy.clearDefaultRegionIfNeeded(&venueState, whenCountryChangesTo: newCountry)
#if DEBUG
            print("[InternationalAddressDebug] selectedCountry=\(BusinessLocationCountryPolicy.normalizedStoredCountryCode(newCountry))")
#endif
        }
        .alert(venueRemovalConfirmationTitle, isPresented: $showDeleteVenueConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button(venueRemovalActionTitle, role: .destructive) {
                logBusinessVenueDeleteDebug("deleteConfirmationAccepted")
                Task {
                    await performDeleteSelectedVenue()
                }
            }
        } message: {
            Text(venueRemovalConfirmationMessage)
        }
        .sheet(isPresented: $showVenuePinPicker) {
            BusinessVenueLocationPinPickerView(
                viewModel: viewModel,
                initialDraft: venueLocationDraft,
                fallbackCoordinate: viewModel.currentUserLocation ?? CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
                onCancel: {},
                onConfirm: applyVenueLocationDraft
            )
        }
        .sheet(isPresented: $showVenueSupporterPicker) {
            VenueSupporterCountryPickerSheet(
                currentCountry: viewModel.ownerVenueSupporterCountry,
                onSelect: { country in
                    Task {
                        let success = await viewModel.updateVenueSupporterCountry(country)
                        await MainActor.run {
                            profileSaveMessage = success ? "Fan Zone Identity updated" : "Unable to update Fan Zone Identity"
                        }
                    }
                },
                onClear: {
                    Task {
                        let success = await viewModel.updateVenueSupporterCountry(nil)
                        await MainActor.run {
                            profileSaveMessage = success ? "Fan Zone Identity cleared" : "Unable to clear Fan Zone Identity"
                        }
                    }
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .onChange(of: selectedMenuPhoto) { _, newItem in
            Task {
                guard let newItem else { return }
                guard !selectedVenuePlanLocked else {
                    await MainActor.run {
                        selectedMenuPhoto = nil
                        profileSaveMessage = BusinessLimitCopy.planLockedVenueSubtitle
                    }
                    return
                }
                print("[VenuePhotoSaveDebug] pickedImage=true")
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let url = await viewModel.uploadVenuePhoto(data: data, fileName: "menu.jpg") {
                    await MainActor.run {
                        viewModel.venueMenuPhotoURL = url
                        displayedMenuPhotoURL = VenueOwnerPhotoPickerCopy.urlWithCacheBust(url)
                        profileSaveMessage = "Photo uploaded. Tap Save Profile to save changes."
                    }
                } else {
                    await MainActor.run {
                        profileSaveMessage = VenueOwnerPhotoPickerCopy.pickFailureUserHint()
                    }
                }
            }
        }
        .sheet(isPresented: $showVenueOwnerContactSupport) {
            ContactGameOnSupportSheet(
                viewModel: viewModel,
                onRequestSignIn: {
                    showVenueOwnerContactSupport = false
                }
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(isPresented: $showAddLocationSheet) {
            AddBusinessLocationRequestSheet(
                viewModel: viewModel,
                form: addLocationSheetFormState,
                submitBanner: $addLocationSubmitBanner,
                isPresented: $showAddLocationSheet
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
            .onAppear {
                if !viewModel.hasAuthenticatedVenueOwnerSession {
                    showAddLocationSheet = false
                }
            }
        }
        .sheet(isPresented: $showBusinessProSubscriptionSheet) {
            BusinessProSubscriptionView(businessStatus: businessMembershipStatus)
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
            .presentationBackground(FGAdaptiveSurface.sheetRoot)
            .task {
                await refreshBusinessPlanStatus(source: "businessProSheet", force: true)
            }
            .onAppear {
                logBusinessProVisibilityDebug(dashboardVisible: true)
            }
        }
        .sheet(isPresented: $showBusinessUsageSheet) {
            BusinessUsageCenterView(
                status: businessMembershipStatus,
                hostedGameCycleAudit: businessHostedGameCycleAudit,
                isHostedGameCycleLoading: businessHostedGameCycleAuditLoading,
                hostedGameCycleAuditUnavailable: businessHostedGameCycleAuditUnavailable
            )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
                .task {
                    await refreshBusinessUsageSheetData()
                }
        }
        .sheet(item: $businessGameChatTarget) { target in
            VenueEventCommentsSheet(
                viewModel: viewModel,
                venueEventID: target.id,
                title: target.title
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
        }
    }
    
    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            managingVenueHeaderRow

            Text(headerTitle)
                .font(.largeTitle)
                .fontWeight(.bold)
                .foregroundStyle(.primary)

            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .onAppear {
            if viewModel.isVenueOwnerLoggedIn {
                viewModel.logBusinessSwitcherDebug()
            }
        }
    }

    @ViewBuilder
    private var managingVenueHeaderRow: some View {
        BusinessLocationVenuePicker(
            viewModel: viewModel,
            chrome: .dashboard,
            onRequestAddNewLocation: { openAddLocationFromBusinessDashboard() }
        )
    }

    private var headerTitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Venue Details"
        case .gamesManager:
            return "Manage games"
        case .analyticsViewer:
            return "Analytics"
        case .overviewDashboard:
            return "Business Dashboard"
        case .allTabs:
            return effectiveSection == .overview ? "Overview" : "Business dashboard"
        }
    }

    private var headerSubtitle: String {
        switch entryPoint {
        case .profileEditor:
            return "Photos, amenities, and venue profile for the selected location."
        case .gamesManager:
            return "Add, edit, or cancel games for the selected location."
        case .analyticsViewer:
            return "Live engagement by game for the selected location."
        case .overviewDashboard:
            return "Live venue energy, games, fans, and performance."
        case .allTabs:
            return effectiveSection == .overview
                ? "Live venue energy, games, fans, and performance."
                : "Manage your locations, schedule, and game-day experience."
        }
    }
    
    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                ForEach(VenueDashboardSection.allCases, id: \.self) { section in
                    Button {
                        withAnimation(.spring()) {
                            selectedSection = section
                        }
                    } label: {
                        Text(section.pickerLabel)
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                selectedSection == section
                                    ? AnyShapeStyle(Color.accentColor)
                                    : AnyShapeStyle(FGAdaptiveSurface.capsuleUnselected)
                            )
                            .foregroundStyle(selectedSection == section ? Color.white : Color.primary)
                            .clipShape(Capsule())
                    }
                    .disabled(
                        venueOwnerGamesAndAnalyticsLocked
                            && (section == .games || section == .analytics)
                    )
                }
            }
        }
    }

    private var businessProAccessSection: some View {
        let status = businessMembershipStatus
        let isProActive = status?.computedIsPro == true
        let accent = isProActive ? businessProGold : Color.orange
        let iconName = isProActive ? "crown.fill" : "lock.shield.fill"

        return HStack(alignment: .center, spacing: 12) {
            Button {
                logBusinessProVisibilityDebug(dashboardVisible: true, rowRendered: true)
                showBusinessProSubscriptionSheet = true
            } label: {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: iconName)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(accent)
                        .frame(width: 38, height: 38)
                        .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.13), in: RoundedRectangle(cornerRadius: 14, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(businessProStatusTitle(for: status))
                            .font(.headline.weight(.black))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text(businessProStatusSubtitle(for: status))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)

                        if isProActive {
                            businessProBadgePill
                        } else {
                            Text("Upgrade")
                                .font(.system(size: 10, weight: .heavy, design: .rounded))
                                .foregroundStyle(accent)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(accent.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Capsule(style: .continuous))
                        }
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .layoutPriority(1)

            Spacer(minLength: 0)

            HStack(spacing: 8) {
                businessPlanRefreshButton(accent: accent)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .frame(width: 14, height: 34)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(colorScheme == .dark ? 0.24 : 0.14),
                    (isProActive ? businessProGoldDeep : FGColor.accentBlue).opacity(colorScheme == .dark ? 0.12 : 0.07),
                    FGAdaptiveSurface.controlFill.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(accent.opacity(isProActive ? (colorScheme == .dark ? 0.54 : 0.38) : (colorScheme == .dark ? 0.32 : 0.20)), lineWidth: 1)
        }
        .shadow(color: isProActive ? businessProGold.opacity(colorScheme == .dark ? 0.14 : 0.10) : .clear, radius: 14, y: 6)
        .animation(.easeInOut(duration: 0.24), value: isProActive)
        .onAppear {
            logBusinessProVisibilityDebug(dashboardVisible: true, rowRendered: true)
            logBusinessProRefreshButtonDebug(isProActive: isProActive)
            logBusinessEntitlementStyleDebug(computedIsPro: isProActive, appliedStyle: isProActive ? "premiumGold" : "regularNeutral")
        }
        .onChange(of: isProActive) { _, newValue in
            logBusinessEntitlementStyleDebug(computedIsPro: newValue, appliedStyle: newValue ? "premiumGold" : "regularNeutral")
        }
    }

    private var businessProGold: Color {
        colorScheme == .dark
            ? Color(red: 0.94, green: 0.73, blue: 0.34)
            : Color(red: 0.72, green: 0.50, blue: 0.16)
    }

    private var businessProGoldDeep: Color {
        colorScheme == .dark
            ? Color(red: 0.62, green: 0.42, blue: 0.14)
            : Color(red: 0.50, green: 0.33, blue: 0.10)
    }

    private var businessProBadgePill: some View {
        Text("PRO")
            .font(.system(size: 10, weight: .heavy, design: .rounded))
            .tracking(0.6)
            .foregroundStyle(colorScheme == .dark ? Color(red: 0.10, green: 0.07, blue: 0.02) : .white)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                LinearGradient(
                    colors: [businessProGold, businessProGoldDeep],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.20 : 0.46), lineWidth: 0.75)
            }
    }

    private func businessPlanRefreshButton(accent: Color) -> some View {
        Button {
            Task {
                await refreshBusinessPlanStatus(source: "manualRefresh", force: true, refreshOwnedVenues: true)
            }
        } label: {
            Image(systemName: "arrow.clockwise")
                .font(.caption.weight(.heavy))
                .foregroundStyle(accent)
                .rotationEffect(.degrees(manualBusinessPlanRefreshInFlight ? 360 : 0))
                .animation(
                    manualBusinessPlanRefreshInFlight
                        ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                        : .default,
                    value: manualBusinessPlanRefreshInFlight
                )
                .frame(width: 34, height: 34)
                .background(.ultraThinMaterial, in: Circle())
                .background(accent.opacity(colorScheme == .dark ? 0.22 : 0.12), in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.18 : 0.42), lineWidth: 1)
                }
                .shadow(color: accent.opacity(colorScheme == .dark ? 0.16 : 0.10), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(manualBusinessPlanRefreshInFlight)
        .frame(width: 34, height: 34)
        .accessibilityLabel("Refresh plan status")
    }

    private func logBusinessProRefreshButtonDebug(isProActive: Bool) {
#if DEBUG
        print(
            "[BusinessProRefreshButtonDebug] rendered=true isProActive=\(isProActive) manualRefreshInFlight=\(manualBusinessPlanRefreshInFlight)"
        )
#endif
    }

    private func businessProStatusTitle(for status: BusinessVenueGamePostingStatus?) -> String {
        guard let status else { return "Checking plan status…" }
        return status.businessPlanDisplayTitle
    }

    private func businessProStatusSubtitle(for status: BusinessVenueGamePostingStatus?) -> String {
        guard let status else { return "Checking plan status…" }
        guard status.computedIsPro else {
            let activeVenueLimit = max(1, status.activeVenueLimit ?? status.venueLimit)
            let hostedGameLimit = max(1, status.monthlyHostedGameLimit ?? status.monthlyHostLimit)
            var parts = [
                "\(activeVenueLimit) active venues",
                "\(hostedGameLimit) hosted games/cycle"
            ]
            if let resetText = BusinessHostedGameCycleDisplay.resetText(from: status.nextResetAt) {
                parts.append(resetText)
            }
            return parts.joined(separator: " • ")
        }
        if let promoText = status.businessProPromoEndDateText {
            return promoText
        }
        if status.isBusinessSubscriptionPro {
            return [
                "Subscription Pro",
                status.businessProSubscriptionExpiryText
            ]
            .compactMap { $0 }
            .joined(separator: " • ")
        }
        return "Unlimited venues • Unlimited hosted games"
    }

    private func formattedBusinessProExpiry(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let date = Self.businessProExpiryParserWithFractions.date(from: raw)
            ?? Self.businessProExpiryParser.date(from: raw)
        guard let date else { return nil }
        return Self.businessProExpiryDisplayFormatter.string(from: date)
    }

    private static let businessProExpiryParserWithFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let businessProExpiryParser: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let businessProExpiryDisplayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d, yyyy"
        return formatter
    }()

    private func businessProBenefitPill(_ title: String) -> some View {
        Text("✓ \(title)")
            .font(.caption2.weight(.heavy))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28), lineWidth: 1)
            }
    }

    private var businessStatisticsProLockedSection: some View {
        Button {
            logBusinessStatisticsProGate(
                isPro: businessStatisticsAccessGranted,
                accessGranted: false,
                source: "analyticsLockedSection"
            )
            showBusinessProSubscriptionSheet = true
        } label: {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color(red: 1.0, green: 0.84, blue: 0.42).opacity(colorScheme == .dark ? 0.28 : 0.18),
                                    Color(red: 0.86, green: 0.63, blue: 0.22).opacity(colorScheme == .dark ? 0.18 : 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Color(red: 0.86, green: 0.63, blue: 0.22))
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text("Statistics")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text("PRO")
                            .font(.system(size: 9, weight: .heavy, design: .rounded))
                            .foregroundStyle(Color(red: 0.08, green: 0.06, blue: 0.025).opacity(0.94))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color(red: 0.86, green: 0.63, blue: 0.22), in: Capsule(style: .continuous))
                    }

                    Text("Upgrade for insights into fan interest, engagement, and venue performance.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.top, 6)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(FGColor.cardBackground(colorScheme))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(red: 0.86, green: 0.63, blue: 0.22).opacity(colorScheme == .dark ? 0.38 : 0.24), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private var businessDashboardOverviewSection: some View {
        BusinessVenueDashboardOverviewView(
            data: businessDashboardData,
            businessId: viewModel.currentBusinessIdForAddLocation(),
            businessUsageStatus: businessMembershipStatus,
            activeVenueSelectionNotice: businessDashboardQuickActionNotice,
            onNotifications: {
                withAnimation(.spring()) {
                    selectedSection = .analytics
                }
            },
            onMenu: {
                openBusinessDashboardVenueDetailsOrAddVenue()
            },
            onAddGame: {
                openBusinessDashboardVenueDetailsOrAddVenue()
            },
            onAddVenue: {
                openAddLocationFromBusinessDashboard()
            },
            onTonightGames: {
                openBusinessDashboardGames(tab: .scheduled)
            },
            onPredictions: {
                handleBusinessStatisticsEntryTapped(source: "predictionsQuickAction")
            },
            onAnalytics: {
                handleBusinessStatisticsEntryTapped(source: "statisticsQuickAction")
            },
            onUsage: {
                Task {
                    await refreshBusinessStatisticsProStatus(reason: "usageQuickAction")
                    showBusinessUsageSheet = true
                }
            },
            onCommentsReports: {
                handleBusinessStatisticsEntryTapped(source: "commentsReportsQuickAction")
            },
            onViewAllGames: {
                openBusinessDashboardGames(tab: .scheduled)
            },
            onRefreshVenues: {},
            onRefreshPendingVenue: { _ in false },
            onResendPendingVenue: { _ in false },
            onCancelPendingVenue: { _ in false },
            showsManagedVenuesSection: false,
            isStatisticsProActive: businessStatisticsAccessGranted,
            isAddVenueAllowed: businessCanCreateVenueFromServer,
            isHostedGameAllowed: selectedVenueCanHostGames
        )
        .onAppear {
            logBusinessDashboardDebug()
        }
        .task(id: businessStatisticsProRefreshToken) {
            await refreshBusinessPlanStatus(source: "onAppear")
        }
    }

    private var businessDashboardData: BusinessVenueDashboardData {
        BusinessVenueDashboardData(
            venueName: businessDashboardVenueName,
            locationLine: businessDashboardLocationLine,
            isVerified: viewModel.venueCoreIdentityLockedForSelectedVenue() || viewModel.venueIsApproved,
            managedVenueCount: viewModel.managedVenuesForOwner().count,
            venuePhotoURL: nil,
            venuePhotoThumbnailURL: nil,
            fansGoing: businessDashboardFansGoing,
            activeChats: businessDashboardActiveChats,
            predictions: businessDashboardPredictions,
            atmosphereRating: businessDashboardAtmosphereRating,
            gameSectionContext: businessDashboardGameSectionContext,
            games: businessDashboardGameItems,
            approvedVenues: [],
            pendingVenues: []
        )
    }

    private var businessStatisticsAccessGranted: Bool {
        businessMembershipStatus?.statisticsAccessGranted == true
    }

    private var businessCanCreateVenueFromServer: Bool {
        guard let status = businessMembershipStatus else { return true }
        return status.canAddVenue
    }

    private var businessCanHostGameFromServer: Bool {
        guard let status = businessMembershipStatus else { return true }
        return status.canHostBusinessGames
    }

    private var hostedGameCycleLimitReachedForRegularBusiness: Bool {
        guard let status = businessMembershipStatus else { return false }
        guard !status.computedIsPro && !status.unlimitedHosting else { return false }
        let limit = max(1, status.monthlyHostedGameLimit ?? status.monthlyHostLimit)
        return status.hostedGamesUsedForDisplay >= limit
    }

    private var hostedGameCycleUsageContextText: String {
        guard let status = businessMembershipStatus else {
            return "Checking hosted games usage..."
        }
        let limit = max(1, status.monthlyHostedGameLimit ?? status.monthlyHostLimit)
        let base = "You’ve used \(status.hostedGamesUsedForDisplay) of \(limit) hosted games this cycle."
        guard let resetText = BusinessHostedGameCycleDisplay.resetText(from: status.nextResetAt) else {
            return base
        }
        return "\(base) \(resetText)."
    }

    private var businessStatisticsProRefreshToken: String {
        let businessId = viewModel.currentBusinessIdForAddLocation()?.uuidString.lowercased() ?? "nil"
        let venueId = viewModel.ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil"
        return "\(businessId)|\(venueId)|\(businessProEntitlement.businessProActive)"
    }

    private var businessDashboardVenueName: String {
        let name = viewModel.ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "Your venue" : name
    }

    private var businessDashboardLocationLine: String {
        let city = venueCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let state = venueState.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerCity = viewModel.ownerVenueCity.trimmingCharacters(in: .whitespacesAndNewlines)
        let ownerState = viewModel.ownerVenueState.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedCity = city.isEmpty ? ownerCity : city
        let resolvedState = state.isEmpty ? ownerState : state
        let parts = [resolvedCity, resolvedState].filter { !$0.isEmpty }
        return parts.isEmpty ? "Venue dashboard" : parts.joined(separator: ", ")
    }

    private var venueAddressLabels: BusinessLocationAddressLabels {
        BusinessLocationCountryPolicy.labels(for: venueCountry)
    }

    private var venueLocationDraft: BusinessVenueLocationDraft {
        BusinessVenueLocationDraft(
            addressLine1: venueStreetAddress,
            addressLine2: venueAddressLine2,
            locality: venueCity,
            region: venueState,
            postalCode: venueZipCode,
            countryCode: venueCountry,
            latitude: venueLatitude,
            longitude: venueLongitude,
            formattedAddress: venueFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : venueFormattedAddress
        )
    }

    private var businessDashboardEventIDs: [UUID] {
        myVenueGamesForManage.compactMap(\.id)
    }

    private var businessDashboardFansGoing: Int {
        businessDashboardEventIDs.reduce(0) { $0 + viewModel.interestCountForVenueEvent($1) }
    }

    private var businessDashboardActiveChats: Int {
        businessDashboardEventIDs.reduce(0) { total, id in
            total + (fanUpdatesStore.venueEventComments[id]?.count ?? 0)
        }
    }

    private var businessDashboardPredictions: Int {
        businessDashboardEventIDs.reduce(0) { total, id in
            total + (viewModel.venueEventPredictionSummaries[id]?.totalCount ?? 0)
        }
    }

    private var businessDashboardTodayGamesCount: Int {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return myVenueGamesForManage.reduce(0) { total, row in
            guard let day = venueOwnerGameDay(row),
                  calendar.isDate(day, inSameDayAs: today) else {
                return total
            }
            return total + 1
        }
    }

    private var businessDashboardAtmosphereRating: String {
        guard let venueID = viewModel.ownerVenueDatabaseId,
              let bar = viewModel.bars.first(where: { $0.id == venueID }),
              viewModel.reviewCountDisplay(for: bar) > 0,
              let rating = viewModel.mergedDisplayRating(for: bar) else {
            return "New"
        }
        return String(format: "%.1f", rating)
    }

    private var businessDashboardGameSectionContext: BusinessVenueDashboardGameSectionContext {
        BusinessVenueDashboardGameSectionResolver.resolve(
            gameDates: businessDashboardUpcomingRows.map(\.start),
            calendar: Calendar.current
        )
    }

    private var businessDashboardUpcomingRows: [(row: VenueEventRow, start: Date)] {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        return myVenueGamesForManage.compactMap { row in
            guard let start = businessDashboardGameStartDate(row),
                  calendar.startOfDay(for: start) >= today else {
                return nil
            }
            return (row, start)
        }
        .sorted { $0.start < $1.start }
    }

    private var businessDashboardGameItems: [BusinessVenueDashboardGameItem] {
        let sourceRows = Array(businessDashboardUpcomingRows.prefix(3).map(\.row))

        return sourceRows.compactMap { row in
            guard let id = row.id else { return nil }
            let score = viewModel.venueOwnerEngagementScore(venueEventID: id)
            let energy = businessDashboardEnergy(score: score)
            let identity = HostedVenueGameCardIdentity(row: row)
            return BusinessVenueDashboardGameItem(
                id: id,
                title: identity.primaryTitle,
                subtitle: identity.secondaryLine,
                timeText: businessDashboardGameTimeText(row),
                sportIconName: viewModel.iconForSport(identity.sportDisplay),
                goingCount: viewModel.interestCountForVenueEvent(id),
                energyLabel: energy.label,
                energyTint: energy.tint
            )
        }
    }

    private func businessDashboardGameSubtitle(_ row: VenueEventRow) -> String {
        let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let league, !league.isEmpty { return league }
        let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines)
        return sport?.isEmpty == false ? (sport ?? "Venue game") : "Venue game"
    }

    private func businessDashboardGameTimeText(_ row: VenueEventRow) -> String {
        BusinessVenueDashboardGameDateTimeFormatter.compactLabel(
            startDate: FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at),
            eventDateRaw: row.event_date,
            eventTimeRaw: row.event_time,
            timeZoneOption: viewModel.selectedTimeZone,
            calendar: Calendar.current
        )
    }

    private func businessDashboardGameStartDate(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }
        return venueOwnerGameDay(row)
    }

    private func businessDashboardEnergy(score: Int) -> (label: String, tint: Color) {
        if score >= 30 { return ("High energy", FGColor.accentGreen) }
        if score >= 8 { return ("Building", FGColor.accentYellow) }
        return (L10n.t("normal", languageCode: appLanguageRaw), FGColor.accentBlue)
    }

    private func openBusinessDashboardGames(tab: ManageGamesListTab) {
        guard !viewModel.managedVenuesForOwner().isEmpty else {
#if DEBUG
            print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
            openAddLocationFromBusinessDashboard()
            return
        }
        guard !venueOwnerGamesAndAnalyticsLocked else { return }
        guard viewModel.ensureValidSelectedManagedVenueForPresentation(source: "businessDashboardGames") else {
            openAddLocationFromBusinessDashboard()
            return
        }
        clearManageGamesBanners()
        guard tab != .add || !selectedVenuePlanLocked else {
            manageGamesFeedback = ""
            manageGamesError = BusinessLimitCopy.planLockedVenueHostedGameBlocked
            withAnimation(.spring()) {
                selectedSection = .games
                manageGamesListTab = .scheduled
            }
            return
        }
        guard tab != .add || selectedVenueCanHostGames else {
            manageGamesFeedback = ""
            manageGamesError = BusinessLimitCopy.hostedGameLimitReached
            showBusinessUsageSheet = true
            withAnimation(.spring()) {
                selectedSection = .games
                manageGamesListTab = .scheduled
            }
            return
        }
        manageGamesListTab = tab
        if tab == .add {
            initializeAddGameScheduleFromDefaults()
        }
        withAnimation(.spring()) {
            selectedSection = .games
        }
    }

    private func openBusinessDashboardVenueDetailsOrAddVenue() {
        Task {
            guard await prepareBusinessDashboardVenueDetailsPresentation() else {
                return
            }
            await MainActor.run {
                businessDashboardQuickActionNotice = nil
                withAnimation(.spring()) {
                    selectedSection = .profile
                }
            }
        }
    }

    private func prepareBusinessDashboardVenueDetailsPresentation() async -> Bool {
        let hasValidatedSelection = await MainActor.run {
            viewModel.ensureValidSelectedManagedVenueForPresentation(source: "businessDashboardVenueDetails")
        }
        guard hasValidatedSelection else {
            showBusinessDashboardVenueDetailsUnavailable(reason: "noValidSelectedVenue")
            return false
        }

        guard let selectedVenueId = await MainActor.run(body: { viewModel.ownerVenueDatabaseId }) else {
            showBusinessDashboardVenueDetailsUnavailable(reason: "missingSelectedVenueId")
            return false
        }

        guard let row = await viewModel.loadVenueProfile(),
              row.id == selectedVenueId,
              venueDetailsRowIsActiveForPresentation(row) else {
            showBusinessDashboardVenueDetailsUnavailable(reason: "profileLoadFailedOrInactive")
            return false
        }

        await MainActor.run {
            viewModel.applyVenueProfileRowToOwnerState(row)
            applyVenueProfileToLocalEditorFields(row)
        }
        return true
    }

    @MainActor
    private func showBusinessDashboardVenueDetailsUnavailable(reason: String) {
        businessDashboardQuickActionNotice = "Venue Details are unavailable until an active managed venue is ready."
#if DEBUG
        print("[BusinessProfileHydrationDebug] blockedEarlyTap action=venueDetails reason=\(reason)")
#endif
    }

    private func venueDetailsRowIsActiveForPresentation(_ row: VenueProfileRow) -> Bool {
        let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status.isEmpty || status == "active"
    }

    private func handleBusinessStatisticsEntryTapped(source: String) {
        Task {
            await refreshBusinessStatisticsProStatus(reason: source)
            guard businessStatisticsAccessGranted else {
                logBusinessStatisticsProGate(isPro: false, accessGranted: false, source: source)
                showBusinessProSubscriptionSheet = true
                return
            }

            logBusinessStatisticsProGate(isPro: true, accessGranted: true, source: source)
            openBusinessDashboardAnalytics()
        }
    }

    private func openBusinessDashboardAnalytics() {
        guard !venueOwnerGamesAndAnalyticsLocked else { return }
        businessVenueAnalyticsTab = .venueAnalytics
        withAnimation(.spring()) {
            selectedSection = .analytics
        }
    }

    private func refreshBusinessStatisticsProStatus(reason: String) async {
        await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        await businessProEntitlement.prepare()
        let status = await viewModel.businessVenueGamePostingStatus(
            storeKitBusinessProActive: businessProEntitlement.businessProActive
        )
        businessMembershipStatus = status
        logBusinessStatisticsProGate(
            isPro: status.computedIsPro,
            accessGranted: status.statisticsAccessGranted,
            source: reason
        )
        logBusinessStatisticsGateDebug(status)
    }

    private func refreshBusinessUsageSheetData() async {
        await businessProEntitlement.prepare()
        let status = await viewModel.businessVenueGamePostingStatus(
            storeKitBusinessProActive: businessProEntitlement.businessProActive
        )
        businessMembershipStatus = status

        guard let businessId = status.businessId ?? viewModel.currentBusinessIdForAddLocation() else {
            businessHostedGameCycleAudit = nil
            businessHostedGameCycleAuditLoading = false
            return
        }

        businessHostedGameCycleAudit = nil
        businessHostedGameCycleAuditUnavailable = false
        businessHostedGameCycleAuditLoading = true
        do {
            let audit = try await viewModel.loadBusinessHostedGamesThisCycle(businessId: businessId)
            businessHostedGameCycleAudit = audit
        } catch {
            businessHostedGameCycleAudit = nil
            businessHostedGameCycleAuditUnavailable = true
        }
        businessHostedGameCycleAuditLoading = false
    }

    private func logBusinessStatisticsProGate(isPro: Bool, accessGranted: Bool, source: String) {
#if DEBUG
        let businessId = viewModel.currentBusinessIdForAddLocation()?.uuidString.lowercased() ?? "nil"
        print("[BusinessProGate] business id=\(businessId)")
        print("[BusinessProGate] isPro=\(isPro)")
        print("[BusinessProGate] statisticsAccessGranted=\(accessGranted)")
        print("[BusinessProGate] source=\(source)")
        if let status = businessMembershipStatus {
            print("[BusinessEntitlementDebug] statisticsGate planType=\(status.planType) planStatus=\(status.planStatus) proExpiresAt=\(status.proExpiresAt ?? "nil")")
        }
#endif
    }

    private func logBusinessStatisticsGateDebug(_ status: BusinessVenueGamePostingStatus) {
#if DEBUG
        print("[BusinessStatisticsGateDebug] businessId=\(status.businessId?.uuidString.lowercased() ?? "nil") planType=\(status.planType) planStatus=\(status.planStatus) statisticsEnabled=\(status.statisticsEnabled) computedIsPro=\(status.computedIsPro) isStatisticsLocked=\(status.isStatisticsLocked)")
#endif
    }

    private static let businessPlanAutoRefreshTTL: TimeInterval = 60

    private func refreshBusinessPlanStatus(
        source: String,
        force: Bool = false,
        refreshOwnedVenues: Bool = false
    ) async {
        if refreshOwnedVenues || force || source == "onAppear" || source == "foreground" {
            await viewModel.refreshOwnedBusinessesAndVenuesAfterOwnerLogin()
        }

        let businessId = viewModel.currentBusinessIdForAddLocation()
        let previousPlanState = businessPlanStateDescription(businessMembershipStatus)
        let isManualRefresh = source == "manualRefresh"

        guard let businessId else {
            logBusinessPlanRefresh(
                source: source,
                businessId: nil,
                skippedReason: "missingBusinessId",
                previousPlanState: previousPlanState,
                newPlanState: previousPlanState,
                isBusinessPro: businessMembershipStatus?.computedIsPro == true
            )
            return
        }

        if businessPlanRefreshInFlight {
            logBusinessPlanRefresh(
                source: source,
                businessId: businessId,
                skippedReason: "inFlight",
                previousPlanState: previousPlanState,
                newPlanState: previousPlanState,
                isBusinessPro: businessMembershipStatus?.computedIsPro == true
            )
            return
        }

        if !force,
           lastBusinessPlanRefreshBusinessID == businessId,
           let lastBusinessPlanRefreshAt,
           Date().timeIntervalSince(lastBusinessPlanRefreshAt) < Self.businessPlanAutoRefreshTTL {
            logBusinessPlanRefresh(
                source: source,
                businessId: businessId,
                skippedReason: "fresh",
                previousPlanState: previousPlanState,
                newPlanState: previousPlanState,
                isBusinessPro: businessMembershipStatus?.computedIsPro == true
            )
            return
        }

        businessPlanRefreshInFlight = true
        if isManualRefresh {
            manualBusinessPlanRefreshInFlight = true
            logBusinessProRefreshStarted(businessId: businessId, status: businessMembershipStatus)
        }
        defer {
            businessPlanRefreshInFlight = false
            if isManualRefresh {
                manualBusinessPlanRefreshInFlight = false
            }
        }

        if force {
            await businessProEntitlement.refreshPurchasedEntitlements()
        } else {
            await businessProEntitlement.prepare()
        }

        let status = await viewModel.businessVenueGamePostingStatus(
            storeKitBusinessProActive: businessProEntitlement.businessProActive
        )
        businessMembershipStatus = status
        lastBusinessPlanRefreshAt = Date()
        lastBusinessPlanRefreshBusinessID = businessId

        if isManualRefresh {
            logBusinessProRefreshCompleted(businessId: businessId, status: status)
        }
        logBusinessStatisticsGateDebug(status)

        logBusinessPlanRefresh(
            source: source,
            businessId: businessId,
            skippedReason: nil,
            previousPlanState: previousPlanState,
            newPlanState: businessPlanStateDescription(status),
            isBusinessPro: status.computedIsPro
        )
    }

    private func businessPlanStateDescription(_ status: BusinessVenueGamePostingStatus?) -> String {
        guard let status else { return "loading" }
        return status.computedIsPro ? "pro" : "regular"
    }

    private func logBusinessProRefreshStarted(
        businessId: UUID,
        status: BusinessVenueGamePostingStatus?
    ) {
#if DEBUG
        print("[BusinessProRefresh] refreshStarted=true")
        print("[BusinessProRefresh] businessId=\(businessId.uuidString.lowercased())")
        print("[BusinessProRefresh] isPro=\(status?.computedIsPro == true)")
        print("[BusinessProRefresh] planType=\(status?.planType ?? "loading")")
        print("[BusinessProRefresh] planStatus=\(status?.planStatus ?? "loading")")
#endif
    }

    private func logBusinessProRefreshCompleted(
        businessId: UUID,
        status: BusinessVenueGamePostingStatus
    ) {
#if DEBUG
        print("[BusinessProRefresh] refreshCompleted=true")
        print("[BusinessProRefresh] businessId=\(businessId.uuidString.lowercased())")
        print("[BusinessProRefresh] isPro=\(status.computedIsPro)")
        print("[BusinessProRefresh] planType=\(status.planType)")
        print("[BusinessProRefresh] planStatus=\(status.planStatus)")
#endif
    }

    private func logBusinessPlanRefresh(
        source: String,
        businessId: UUID?,
        skippedReason: String?,
        previousPlanState: String,
        newPlanState: String,
        isBusinessPro: Bool
    ) {
#if DEBUG
        print("[BusinessPlanRefresh] source=\(source)")
        print("[BusinessPlanRefresh] businessId=\(businessId?.uuidString.lowercased() ?? "nil")")
        if let skippedReason {
            print("[BusinessPlanRefresh] skippedReason=\(skippedReason)")
        }
        print("[BusinessPlanRefresh] previousPlanState=\(previousPlanState)")
        print("[BusinessPlanRefresh] newPlanState=\(newPlanState)")
        print("[BusinessPlanRefresh] isBusinessPro=\(isBusinessPro)")
#endif
    }

    private func refreshBusinessDashboardOverview() async {
        guard !venueOwnerGamesAndAnalyticsLocked else {
            logBusinessDashboardDebug()
            return
        }
        await refreshManageGamesList(isInitialPick: false)
        let ids = await MainActor.run { businessDashboardEventIDs }
        await viewModel.loadVenueEventPredictionSummaries(eventIDs: ids)
        await MainActor.run {
            logBusinessDashboardDebug()
        }
    }

    private func logBusinessDashboardDebug() {
#if DEBUG
        print("[BusinessDashboardDebug] openedOverview")
        print("[BusinessDashboardDebug] venueLoaded=\(!businessDashboardVenueName.isEmpty)")
        print("[BusinessDashboardDebug] todayGamesCount=\(businessDashboardTodayGamesCount)")
        print("[BusinessDashboardDebug] fansGoingTotal=\(businessDashboardFansGoing)")
        print("[BusinessDashboardDebug] activeChatsTotal=\(businessDashboardActiveChats)")
        print("[BusinessDashboardDebug] predictionsTotal=\(businessDashboardPredictions)")
#endif
    }

    private func openAddLocationFromBusinessDashboard() {
#if DEBUG
        print("[AddLocationForm] initialized fresh")
        print("[AddLocationForm] opened from businessDashboard")
#endif
        Task {
            await refreshBusinessStatisticsProStatus(reason: "addVenueQuickAction")
            await MainActor.run {
                guard businessCanCreateVenueFromServer else {
                    addLocationSubmitBanner = BusinessLimitCopy.venueLimitReached
                    showBusinessUsageSheet = true
                    return
                }
                addLocationSubmitBanner = nil
                addLocationSheetFormState.reset(reason: "businessDashboard")
                showAddLocationSheet = true
            }
        }
    }

    private func logBusinessDashboardRouteDebug() {
#if DEBUG
        print("[BusinessDashboardRouteDebug] entryPoint=\(String(describing: entryPoint))")
        print("[BusinessDashboardRouteDebug] effectiveSection=\(effectiveSection.rawValue)")
#endif
    }

    private func logBusinessProVisibilityDebug(
        dashboardVisible: Bool? = nil,
        rowRendered: Bool? = nil
    ) {
#if DEBUG
        if let dashboardVisible {
            print("[BusinessProVisibilityDebug] dashboardVisible=\(dashboardVisible)")
        }
        print("[BusinessProVisibilityDebug] hasAuthenticatedVenueOwnerSession=\(viewModel.hasAuthenticatedVenueOwnerSession)")
        if let rowRendered {
            print("[BusinessProVisibilityDebug] rowRendered=\(rowRendered)")
        }
#endif
    }

    private func logBusinessEntitlementStyleDebug(computedIsPro: Bool, appliedStyle: String) {
#if DEBUG
        print("[BusinessEntitlementStyleDebug] computedIsPro=\(computedIsPro) appliedStyle=\(appliedStyle)")
#endif
    }

    private func applyVenueLocationDraft(_ draft: BusinessVenueLocationDraft) {
        guard !venueProfileEditingLocked else { return }
        venueStreetAddress = draft.addressLine1
        venueAddressLine2 = draft.addressLine2
        venueCity = draft.locality
        venueState = draft.region
        venueZipCode = draft.postalCode
        venueCountry = BusinessLocationCountryPolicy.normalizedStoredCountryCode(draft.countryCode)
        venueLatitude = draft.latitude
        venueLongitude = draft.longitude
        venueFormattedAddress = draft.formattedAddress ?? draft.displayAddress
    }

    @MainActor
    private func applyVenueProfileToLocalEditorFields(_ saved: VenueProfileRow) {
        venueStreetAddress = saved.address ?? ""
        venueAddressLine2 = saved.address_line2 ?? ""
        venueCity = saved.city ?? ""
        venueState = saved.state ?? ""
        venueZipCode = saved.zip_code ?? ""
        venueCountry = saved.country ?? BusinessLocationCountryPolicy.defaultCountryCode
        venueLatitude = saved.latitude
        venueLongitude = saved.longitude
        venueFormattedAddress = saved.formatted_address ?? ""

        totalScreens = saved.screen_count ?? 1
        hasFood = saved.serves_food ?? false
        hasWifi = saved.has_wifi ?? false
        hasGarden = saved.has_garden ?? false
        hasProjector = saved.has_projector ?? false
        isPetFriendly = saved.pet_friendly ?? false
        syncModernFeatureToggles(from: saved.features ?? "")
        syncDisplayedVenuePhotoURLsFromViewModel()
    }

    @MainActor
    private func clearLocalVenueProfileFieldsForEmptyState() {
        venueStreetAddress = ""
        venueAddressLine2 = ""
        venueCity = ""
        venueState = ""
        venueZipCode = ""
        venueCountry = BusinessLocationCountryPolicy.defaultCountryCode
        venueLatitude = nil
        venueLongitude = nil
        venueFormattedAddress = ""
        totalScreens = 1
        hasFood = false
        hasWifi = false
        hasGarden = false
        hasProjector = false
        isPetFriendly = false
        displayedCoverPhotoURL = ""
        displayedMenuPhotoURL = ""
        selectedCoverPhoto = nil
        selectedMenuPhoto = nil
        myVenueGamesForManage = []
        manageGamesListLoading = false
        manageGamesRefreshInFlight = false
        clearManageGamesBanners()
    }
    
    private var profileSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            dashboardCard(
                title: entryPoint == .profileEditor ? "Venue listing" : "Location profile",
                subtitle: entryPoint == .profileEditor
                    ? "Editable items save to the venue selected above."
                    : "Basic listing information"
            ) {
                profileSectionCardContent
            }

            if shouldShowVenueDeleteDangerZone {
                deleteVenueDangerZone
            }
        }
    }

    private var profileSectionCardContent: AnyView {
        if shouldShowVenueDetailsEmptyState {
            return AnyView(noVenueYetEmptyState)
        }
        return AnyView(profileEditorContent)
    }

    private var profileEditorContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedVenuePlanLocked {
                venuePlanLockedExplainerCard()
            }
            if venueCoreIdentityLocked {
                venueFanGeoVerifiedExplainerCard()
            }

            field("Bar / Pub / Restaurant Name", text: $viewModel.ownerVenueName, locked: venueProfileEditingLocked)
            BusinessLocationCountryField(countryCode: $venueCountry)
                .disabled(venueProfileEditingLocked)
                .fanGeoInputFieldStyle()
                .opacity(venueProfileEditingLocked ? 0.78 : 1)
            field("Address Line 1", text: $venueStreetAddress, locked: venueProfileEditingLocked)
            field("Address Line 2 (optional)", text: $venueAddressLine2, locked: venueProfileEditingLocked)
            field(venueAddressLabels.locality, text: $venueCity, locked: venueProfileEditingLocked)

            HStack(alignment: .center, spacing: 10) {
                BusinessLocationRegionField(countryCode: venueCountry, labels: venueAddressLabels, region: $venueState)
                    .disabled(venueProfileEditingLocked)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                if venueProfileEditingLocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityLabel("Locked")
                }
            }
            .opacity(venueProfileEditingLocked ? 0.78 : 1)

            field(venueAddressLabels.postalCode, text: $venueZipCode, locked: venueProfileEditingLocked)
            BusinessVenueLocationPinPreview(
                draft: venueLocationDraft,
                isLocked: venueProfileEditingLocked,
                onAdjust: { showVenuePinPicker = true }
            )
            BusinessPhoneNumberField(dialISO: $viewModel.ownerVenuePhoneDialISO, localNumber: $viewModel.ownerVenuePhone)
                .disabled(selectedVenuePlanLocked)
                .opacity(selectedVenuePlanLocked ? 0.78 : 1)
            field("Website", text: $viewModel.ownerVenueWebsite, locked: selectedVenuePlanLocked)
            field("Short Description", text: $viewModel.ownerVenueDescription, locked: selectedVenuePlanLocked)
            field("Features: Big Screens, Terrace, Sound On", text: $viewModel.ownerVenueFeatures, locked: selectedVenuePlanLocked)
            venueSupporterCountryEditor()
                .disabled(selectedVenuePlanLocked)
                .opacity(selectedVenuePlanLocked ? 0.78 : 1)

            profilePhotoAndSaveSection
            profileStatusMessages
        }
    }

    private var profilePhotoAndSaveSection: some View {
        VStack(alignment: .leading, spacing: 28) {
            venueOwnerVenueFeaturesCard()
                .disabled(selectedVenuePlanLocked)
                .opacity(selectedVenuePlanLocked ? 0.78 : 1)

            businessVenueProfilePhotoEditor(
                title: "Business Photo",
                subtitle: "Main photo of your business",
                fullImageURL: displayedCoverPhotoURL,
                thumbnailURL: VenueOwnerPhotoPickerCopy.thumbnailURLAlignedWithDisplay(
                    storageURL: viewModel.venueCoverPhotoThumbnailURL,
                    displayTemplateURL: displayedCoverPhotoURL
                ),
                selection: $selectedCoverPhoto
            )
            .disabled(selectedVenuePlanLocked)
            .opacity(selectedVenuePlanLocked ? 0.78 : 1)

            venueProfilePhotoEditor(
                title: "Others",
                subtitle: "Examples: menu, gym, patio, bar, seating, entrance",
                fullImageURL: displayedMenuPhotoURL,
                thumbnailURL: VenueOwnerPhotoPickerCopy.thumbnailURLAlignedWithDisplay(
                    storageURL: viewModel.venueMenuPhotoThumbnailURL,
                    displayTemplateURL: displayedMenuPhotoURL
                ),
                selection: $selectedMenuPhoto
            )
            .disabled(selectedVenuePlanLocked)
            .opacity(selectedVenuePlanLocked ? 0.78 : 1)

            Button {
                saveVenueProfileFromEditor()
            } label: {
                primaryButtonText("Save Profile")
            }
            .disabled(selectedVenuePlanLocked || isDeletingVenue)
            .opacity(selectedVenuePlanLocked || isDeletingVenue ? 0.55 : 1)
        }
    }

    @ViewBuilder
    private var profileStatusMessages: some View {
        if !profileSaveMessage.isEmpty {
            Text(profileSaveMessage)
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(profileSaveMessage == BusinessLimitCopy.planLockedVenueSubtitle ? .orange : .green)
                .frame(maxWidth: .infinity, alignment: .center)
        }

        if !venueDeleteError.isEmpty {
            Text(venueDeleteError)
                .font(.caption.weight(.bold))
                .foregroundStyle(FGColor.dangerRed)
                .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    private var shouldShowVenueDeleteDangerZone: Bool {
        !shouldShowVenueDetailsEmptyState && selectedManagedVenueForRemoval != nil
    }

    private func saveVenueProfileFromEditor() {
        guard !isDeletingVenue else { return }
        guard !selectedVenuePlanLocked else {
            profileSaveMessage = BusinessLimitCopy.planLockedVenueSubtitle
            return
        }
        let nameBad = ModerationService.containsProfanity(viewModel.ownerVenueName)
        let descBad = ModerationService.containsProfanity(viewModel.ownerVenueDescription)
        if descBad || (!venueCoreIdentityLocked && nameBad) {
            profileSaveMessage = ModerationService.profanityRejectionUserMessage()
            return
        }

        profileSaveMessage = "Saving..."

        viewModel.ownerVenueAddress = venueStreetAddress
        viewModel.ownerVenueAddressLine2 = venueAddressLine2
        viewModel.ownerVenueCountry = venueCountry
        viewModel.ownerVenueFeatures = selectedVenueFeaturesLine()
#if DEBUG
        print("[VenueFeatureDebug] selectedFeatures=\(viewModel.ownerVenueFeatures)")
#endif
        Task {
            let success = await viewModel.saveVenueProfile(
                streetAddress: venueStreetAddress,
                addressLine2: venueAddressLine2,
                city: venueCity,
                state: venueState,
                zipCode: venueZipCode,
                country: venueCountry,
                pinnedLatitude: venueLatitude,
                pinnedLongitude: venueLongitude,
                pinnedFormattedAddress: venueFormattedAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : venueFormattedAddress,
                screenCount: totalScreens,
                servesFood: hasFood,
                hasWifi: hasWifi,
                hasGarden: hasGarden,
                hasProjector: hasProjector,
                petFriendly: isPetFriendly
            )

            if success, let saved = await viewModel.loadVenueProfile() {
                await MainActor.run {
                    viewModel.applyVenueProfileRowToOwnerState(saved)
                    applyVenueProfileToLocalEditorFields(saved)
                }
            }

            await MainActor.run {
                profileSaveMessage = success ? "Profile saved successfully" : "Unable to save profile"
            }
        }
    }

    private var shouldShowVenueDetailsEmptyState: Bool {
        guard let selectedVenueID = viewModel.ownerVenueDatabaseId else { return true }
        return !viewModel.managedVenuesForOwner().contains { $0.id == selectedVenueID }
    }

    private var selectedManagedVenueForRemoval: VenueProfileRow? {
        guard let selectedVenueID = viewModel.ownerVenueDatabaseId else { return nil }
        return viewModel.managedVenuesForOwner().first { $0.id == selectedVenueID }
    }

    private var selectedVenueIsCommunityClaim: Bool {
        selectedManagedVenueForRemoval?.origin_type?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "community"
    }

    private var venueRemovalActionTitle: String {
        selectedVenueIsCommunityClaim ? "Remove From My Business" : "Delete Venue"
    }

    private var venueRemovalProgressTitle: String {
        selectedVenueIsCommunityClaim ? "Removing From My Business..." : "Deleting Venue..."
    }

    private var venueRemovalConfirmationTitle: String {
        selectedVenueIsCommunityClaim ? "Remove venue from your business?" : "Delete Venue?"
    }

    private var venueRemovalTint: Color {
        selectedVenueIsCommunityClaim ? .orange : FGColor.dangerRed
    }

    private var noVenueYetEmptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            ZStack {
                Circle()
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.12))
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(FGColor.accentGreen)
            }
            .frame(width: 52, height: 52)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                Text("No venue yet")
                    .font(.headline.weight(.heavy))
                    .foregroundStyle(.primary)
                Text("Add your first venue to manage details and games.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                openAddLocationFromBusinessDashboard()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "plus.circle.fill")
                        .font(.subheadline.weight(.bold))
                    Text("Add Venue")
                        .font(.subheadline.weight(.heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(FGColor.accentGreen)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        )
        .onAppear {
            if viewModel.managedVenuesForOwner().isEmpty {
#if DEBUG
                print("[VenueOwnerEmptyStateDebug] noManagedVenues=true")
#endif
            }
        }
    }

    private var deleteVenueDangerZone: some View {
        VStack(alignment: .leading, spacing: 10) {
            Divider()
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 6) {
                Text(venueRemovalActionTitle)
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(venueRemovalTint)
                Text(selectedVenueIsCommunityClaim
                    ? "Remove your ownership, photos, games, and business details from this venue."
                    : "Permanently remove this venue, its games, fan chats, attendance, reactions, saved-venue links, stats, and uploaded venue photos. This does not delete the business account.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(role: .destructive) {
                Task {
                    await performDeleteSelectedVenue()
                }
            } label: {
                HStack(spacing: 8) {
                    if isDeletingVenue {
                        ProgressView()
                            .controlSize(.small)
                            .tint(.white)
                    } else {
                        Image(systemName: selectedVenueIsCommunityClaim ? "arrow.uturn.left.circle.fill" : "trash.fill")
                            .font(.caption.weight(.heavy))
                    }
                    Text(isDeletingVenue ? venueRemovalProgressTitle : venueRemovalActionTitle)
                        .font(.subheadline.weight(.heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(venueRemovalTint)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: venueRemovalTint.opacity(colorScheme == .dark ? 0.24 : 0.18), radius: 10, y: 4)
            }
            .opacity(viewModel.ownerVenueDatabaseId == nil ? 0.55 : 1)
            .accessibilityHint(selectedVenueIsCommunityClaim
                ? "Releases this venue back to the community marketplace."
                : "Permanently deletes only this venue and linked venue data.")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(venueRemovalTint.opacity(0.24), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }

    private var venueRemovalConfirmationMessage: String {
        if selectedVenueIsCommunityClaim {
            return "This removes your ownership, photos, games, and business details from this venue and returns it to the FanGeo community marketplace so another business can claim it."
        }
        return "This permanently deletes the venue and all linked content."
    }

    @MainActor
    private func performDeleteSelectedVenue() async {
        logBusinessVenueDeleteDebug("performDeleteStarted")
        guard let venueId = viewModel.ownerVenueDatabaseId else {
            logBusinessVenueDeleteDebug("blockedMissingVenueId")
            venueDeleteError = "Select a venue first."
            return
        }

        logBusinessVenueDeleteDebug("deleteStarted", venueId: venueId)
        isDeletingVenue = true
        venueDeleteError = ""
        profileSaveMessage = ""

        do {
            let result = try await viewModel.releaseOrDeleteBusinessVenue(venueId: venueId)
            await refreshBusinessPlanStatus(source: "venueDelete", force: true, refreshOwnedVenues: true)
            profileSaveMessage = result.releasedCommunityVenue ? "Venue released successfully." : "Venue deleted successfully."
            syncDisplayedVenuePhotoURLsFromViewModel()
            selectedCoverPhoto = nil
            selectedMenuPhoto = nil
            print("[BusinessVenueDeleteDebug] deleteSucceeded venueId=\(venueId.uuidString.lowercased())")

            if entryPoint == .profileEditor {
                try? await Task.sleep(nanoseconds: 450_000_000)
                dismiss()
            } else if effectiveSection == .profile {
                selectedSection = .overview
            }
        } catch {
            logBusinessVenueDeleteDebug("deleteFailed", venueId: venueId, error: error)
            venueDeleteError = userFacingVenueDeleteError(error)
        }

        isDeletingVenue = false
    }

    private func userFacingVenueDeleteError(_ error: Error) -> String {
        let raw = "\(error) \(error.localizedDescription)"
        if raw.localizedCaseInsensitiveContains("duplicate_venue_same_business") {
            return "Unable to delete this venue. Please refresh and try again."
        }
        let message = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty ? "Unable to delete this venue. Please try again." : message
    }

    private func logBusinessVenueDeleteDebug(
        _ event: String,
        venueId explicitVenueId: UUID? = nil,
        error: Error? = nil,
        errorDescription: String? = nil
    ) {
        let venueId = explicitVenueId ?? viewModel.ownerVenueDatabaseId
        let selectedVenueName = selectedManagedVenueForRemoval?.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let profileVenueName = viewModel.ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueName = selectedVenueName.isEmpty ? profileVenueName : selectedVenueName
        let adminStatus = venueId
            .flatMap { id in viewModel.managedVenuesForOwner().first(where: { $0.id == id })?.admin_status }
            .flatMap { raw -> String? in
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            } ?? "active"
        let venueIdText = venueId?.uuidString.lowercased() ?? "nil"
        var message: String
        switch event {
        case "deleteButtonTapped":
            message = "[BusinessVenueDeleteDebug] deleteButtonTapped selectedVenueId=\(venueIdText) selectedVenueName=\(venueName.isEmpty ? "nil" : venueName)"
        case "blockedMissingVenueId":
            message = "[BusinessVenueDeleteDebug] blockedMissingVenueId"
        default:
            message = "[BusinessVenueDeleteDebug] \(event) venueId=\(venueIdText)"
        }
        if event == "deleteTapped" {
            message += " venueName=\(venueName.isEmpty ? "nil" : venueName) adminStatus=\(adminStatus)"
        }
        if let error {
            message += " error=\(error.localizedDescription)"
        } else if let errorDescription {
            message += " error=\(errorDescription)"
        }
        print(message)
    }

    private func venueSupporterCountryEditor() -> some View {
        let display = VenueSupporterCountryMode.display(
            for: viewModel.ownerVenueSupporterCountry,
            languageCode: appLanguageRaw
        )

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Text(display?.flag ?? "🏆")
                    .font(.system(size: 30))
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.22 : 0.13)))

                VStack(alignment: .leading, spacing: 4) {
                    Text("Fan Zone Identity")
                        .font(.subheadline.weight(.heavy))
                        .foregroundStyle(.primary)
                    Text(display?.title ?? "Choose a watch-spot country or clear this any time.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 10) {
                Button {
                    showVenueSupporterPicker = true
                } label: {
                    Text(display == nil ? "Select country" : "Change country")
                        .font(.caption.weight(.heavy))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.18 : 0.12))
                        .foregroundStyle(FGColor.accentBlue)
                        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                }
                .buttonStyle(.plain)

                if display != nil {
                    Button {
                        Task {
                            let success = await viewModel.updateVenueSupporterCountry(nil)
                            await MainActor.run {
                                profileSaveMessage = success ? "Fan Zone Identity cleared" : "Unable to clear Fan Zone Identity"
                            }
                        }
                    } label: {
                        Text("Clear")
                            .font(.caption.weight(.heavy))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 11)
                            .background(Color.red.opacity(colorScheme == .dark ? 0.16 : 0.10))
                            .foregroundStyle(.red)
                            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
        }
        .onAppear {
#if DEBUG
            print("[VenueSupporterIdentityDebug] load venueId=\(viewModel.ownerVenueDatabaseId?.uuidString.lowercased() ?? "nil") supporterCountry=\(viewModel.ownerVenueSupporterCountry.isEmpty ? "nil" : viewModel.ownerVenueSupporterCountry)")
#endif
        }
    }

    private func venueFanGeoVerifiedExplainerCard() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title3)
                    .foregroundStyle(Color.accentColor)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 8) {
                    Text("Venue information verified by FanGeo.")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("To change the venue name, address, or core business information, please contact FanGeo Support.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Button {
#if DEBUG
                print("[VenueDetailsLock] support contact opened")
#endif
                showVenueOwnerContactSupport = true
            } label: {
                Text("Contact FanGeo Support")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.accentColor.opacity(0.18))
                    .foregroundStyle(Color.accentColor)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the in-app FanGeo support form.")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        )
    }

    private func venuePlanLockedExplainerCard() -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text(BusinessLimitCopy.planLockedVenueBanner)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(BusinessLimitCopy.planLockedVenueSubtitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.10))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.orange.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 1)
        )
    }

    private func venueOwnerVenueFeaturesCard() -> some View {
        let columns: [GridItem] = [
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6),
            GridItem(.flexible(), spacing: 6)
        ]

        return VStack(alignment: .leading, spacing: 10) {
            Text("Venue Features")
                .font(.headline)
                .fontWeight(.bold)

            LazyVGrid(columns: columns, alignment: .center, spacing: 8) {
                VenueOwnerScreensFeatureTile(totalScreens: $totalScreens)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.foodDrinks.iconName, label: VenueFeatureDefinitions.foodDrinks.label, isOn: $hasFood)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.wifi.iconName, label: VenueFeatureDefinitions.wifi.label, isOn: $hasWifi)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.projector.iconName, label: VenueFeatureDefinitions.projector.label, isOn: $hasProjector)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.patio.iconName, label: VenueFeatureDefinitions.patio.label, isOn: $hasGarden)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.rooftop.iconName, label: VenueFeatureDefinitions.rooftop.label, isOn: $hasRooftop)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.liveMusic.iconName, label: VenueFeatureDefinitions.liveMusic.label, isOn: $hasLiveMusic)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.djNights.iconName, label: VenueFeatureDefinitions.djNights.label, isOn: $hasDJNights)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.karaoke.iconName, label: VenueFeatureDefinitions.karaoke.label, isOn: $hasKaraoke)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.poolTables.iconName, label: VenueFeatureDefinitions.poolTables.label, isOn: $hasPoolTables)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.craftBeer.iconName, label: VenueFeatureDefinitions.craftBeer.label, isOn: $hasCraftBeer)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.cocktails.iconName, label: VenueFeatureDefinitions.cocktails.label, isOn: $hasCocktails)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.familyFriendly.iconName, label: VenueFeatureDefinitions.familyFriendly.label, isOn: $isFamilyFriendly)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.petFriendly.iconName, label: VenueFeatureDefinitions.petFriendly.label, isOn: $isPetFriendly)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.easyParking.iconName, label: VenueFeatureDefinitions.easyParking.label, isOn: $hasEasyParking)
                VenueOwnerFeatureToggleTile(icon: VenueFeatureDefinitions.handicapParking.iconName, label: VenueFeatureDefinitions.handicapParking.label, isOn: $hasHandicapParking)
            }
        }
        .padding(12)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func syncModernFeatureToggles(from rawFeatures: String) {
        hasRooftop = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.rooftop)
        hasLiveMusic = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.liveMusic)
        hasDJNights = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.djNights)
        hasKaraoke = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.karaoke)
        hasPoolTables = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.poolTables)
        hasCocktails = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.cocktails)
        hasCraftBeer = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.craftBeer)
        hasHandicapParking = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.handicapParking)
        hasParkingAvailable = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.parkingAvailable)
        hasEasyParking = hasParkingAvailable || venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.easyParking)
        isFamilyFriendly = venueRawFeaturesContain(rawFeatures, definition: VenueFeatureDefinitions.familyFriendly)
    }

    private func selectedVenueFeaturesLine() -> String {
        venueMergedRawFeaturesLine(
            existingRawFeatures: viewModel.ownerVenueFeatures,
            familyFriendly: isFamilyFriendly,
            parkingAvailable: hasParkingAvailable,
            easyParking: hasEasyParking,
            handicapParking: hasHandicapParking,
            liveMusic: hasLiveMusic,
            poolTables: hasPoolTables,
            rooftop: hasRooftop,
            djNights: hasDJNights,
            karaoke: hasKaraoke,
            cocktails: hasCocktails,
            craftBeer: hasCraftBeer
        )
    }

    private let usStates = [
        "AL","AK","AZ","AR","CA","CO","CT","DE","FL","GA",
        "HI","ID","IL","IN","IA","KS","KY","LA","ME","MD",
        "MA","MI","MN","MS","MO","MT","NE","NV","NH","NJ",
        "NM","NY","NC","ND","OH","OK","OR","PA","RI","SC",
        "SD","TN","TX","UT","VT","VA","WA","WV","WI","WY"
    ]

    private var analyticsSportFilterOptions: [String] {
        ["All"] + AppSportCatalog.sportsExcludingAll
    }

    private var venueAnalyticsFilterBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Filters")
                .font(.caption2.weight(.heavy))
                .foregroundStyle(businessAnalyticsSecondaryText)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(VenueAnalyticsDatePreset.allCases, id: \.rawValue) { preset in
                        Button {
                            analyticsDatePreset = preset
                            logBusinessAnalyticsDebug("dateFilter=\(preset.rawValue)")
                            Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
                        } label: {
                            analyticsFilterPill(
                                title: preset.rawValue,
                                isSelected: analyticsDatePreset == preset
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    Menu {
                        ForEach(analyticsSportFilterOptions, id: \.self) { sport in
                            Button(AppSportCatalog.displayLabel(forSportToken: sport)) {
                                analyticsSportFilter = sport
                                logBusinessAnalyticsDebug("sportFilter=\(sport)")
                                Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
                            }
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Text(AppSportCatalog.displayLabel(forSportToken: analyticsSportFilter))
                                .lineLimit(1)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .black))
                        }
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(businessAnalyticsPrimaryText)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 8)
                        .background(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.86), in: Capsule(style: .continuous))
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(businessAnalyticsGlassStroke.opacity(0.42), lineWidth: 1)
                        }
                    }
                }
                .padding(.vertical, 1)
            }
        }
    }

    private func analyticsFilterPill(title: String, isSelected: Bool) -> some View {
        Text(title)
            .font(.caption.weight(.heavy))
            .foregroundStyle(isSelected ? Color.white : businessAnalyticsPrimaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.82)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                isSelected ? FGColor.accentBlue : Color.white.opacity(colorScheme == .dark ? 0.08 : 0.86),
                in: Capsule(style: .continuous)
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? FGColor.accentBlue.opacity(0.30)
                            : businessAnalyticsGlassStroke.opacity(0.42),
                        lineWidth: 1
                    )
            }
    }

    @ViewBuilder
    private func venueAnalyticsSummaryStrip(displayed: [VenueEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let row = hottestAnalyticsGameRow(from: displayed) {
                HStack(spacing: 8) {
                    Text("Top Performing Match")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Text(row.event_title ?? "Game")
                        .font(.caption)
                        .fontWeight(.bold)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let id = row.id {
                        Text("\(viewModel.venueOwnerEngagementScore(venueEventID: id))")
                            .font(.caption)
                            .fontWeight(.black)
                            .contentTransition(.numericText())
                            .animation(.easeOut(duration: 0.2), value: viewModel.venueOwnerEngagementScore(venueEventID: id))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if let top = globalTopVibeSummary(from: displayed) {
                HStack(spacing: 8) {
                    Text("Fan Favorite Feature")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                    Text(top.label)
                        .font(.caption)
                        .fontWeight(.bold)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                    Text("\(top.total)")
                        .font(.caption)
                        .fontWeight(.black)
                        .contentTransition(.numericText())
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func crowdInsightsSummaryHeader(displayed: [VenueEventRow]) -> some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Text("Fan Engagement")
                            .font(.headline.weight(.black))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Image(systemName: "info.circle")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(venueEngagementScore100(displayed))")
                            .font(.system(size: 42, weight: .black, design: .rounded))
                            .foregroundStyle(FGColor.accentGreen)
                            .contentTransition(.numericText())
                        Text("engagement points this month")
                            .font(.caption.weight(.black))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                    }

                    Text("Fan engagement this month")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(FGColor.accentGreen)
                }

                HStack(spacing: 0) {
                    heroMetricBlock(
                        icon: "person.2.fill",
                        tint: FGColor.accentGreen,
                        value: "\(averageFansPerGame(displayed))",
                        label: "Avg fans\nper game"
                    )
                    heroDivider
                    heroMetricBlock(
                        icon: "bubble.left.and.bubble.right.fill",
                        tint: FGColor.accentBlue,
                        value: "\(totalFanDiscussions(displayed))",
                        label: "Active\ndiscussions"
                    )
                    heroDivider
                    heroMetricBlock(
                        icon: "trophy.fill",
                        tint: Color.purple,
                        value: topSportName(displayed),
                        label: "Top sport"
                    )
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [
                    FGColor.accentGreen.opacity(colorScheme == .dark ? 0.16 : 0.09),
                    FGColor.accentBlue.opacity(colorScheme == .dark ? 0.10 : 0.06),
                    FGAdaptiveSurface.controlFill.opacity(0.96)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.25 : 0.16), lineWidth: 1)
        }
        .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.14 : 0.10), radius: 18, x: 0, y: 10)
        .onAppear {
#if DEBUG
            print("[BusinessInsightsUI] premiumAnalyticsEnabled=true")
#endif
        }
    }

    private var heroDivider: some View {
        Rectangle()
            .fill(FGColor.divider(colorScheme).opacity(0.65))
            .frame(width: 1, height: 42)
            .padding(.horizontal, 8)
    }

    private func heroMetricBlock(icon: String, tint: Color, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .black))
                .foregroundStyle(tint)
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func mostPopularSportInsight(displayed: [VenueEventRow]) -> some View {
        if let summary = topSportEngagementSummary(displayed) {
            HStack(spacing: 12) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 18, weight: .black))
                    .foregroundStyle(Color.purple)
                    .frame(width: 38, height: 38)
                    .background(Color.purple.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Circle())

                VStack(alignment: .leading, spacing: 3) {
                    Text("Most Popular Sport")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(AppSportCatalog.displayLabel(forSportToken: summary.sport))
                        .font(.headline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                VStack(alignment: .trailing, spacing: 2) {
                    Text(verbatim: localizedSignedWholePercent(summary.percent))
                        .font(.headline.weight(.black))
                        .foregroundStyle(FGColor.accentGreen)
                    Text("of engagement")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            }
            .padding(13)
            .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.purple.opacity(colorScheme == .dark ? 0.20 : 0.12), lineWidth: 1)
            }
            .onAppear {
#if DEBUG
                print("[BusinessInsightsCrashFix] topSportSafe=true")
#endif
            }
        }
    }

    @ViewBuilder
    private func venueInsightsSection(displayed: [VenueEventRow]) -> some View {
        let insights = venueBusinessInsights(from: displayed)
        if !insights.isEmpty {
            let visibleInsights = Array(insights.prefix(4))
            VStack(alignment: .leading, spacing: 9) {
                Text("Venue Insights")
                    .font(.headline.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                LazyVGrid(
                    columns: [
                        GridItem(.flexible(), spacing: 8),
                        GridItem(.flexible(), spacing: 8)
                    ],
                    spacing: 8
                ) {
                    ForEach(visibleInsights) { insight in
                        venueInsightCard(insight)
                    }
                }
            }
        } else {
            notEnoughActivityCard
        }
    }

    private func venueInsightCard(_ insight: VenueAnalyticsBusinessInsight) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(insight.icon)
                .font(.system(size: 17))
                .accessibilityHidden(true)
            Text(insight.title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
            Text(insight.value)
                .font(.caption.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
                .minimumScaleFactor(0.76)
            if let subtitle = insight.subtitle {
                Text(subtitle)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(insight.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
            }
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(insight.tint.opacity(colorScheme == .dark ? 0.14 : 0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(insight.tint.opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: 1)
        }
    }

    private var notEnoughActivityCard: some View {
        Text("Not enough activity yet")
            .font(.caption.weight(.heavy))
            .foregroundStyle(FGColor.secondaryText(colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    @ViewBuilder
    private func venuePerformanceLeaderboard(displayed: [VenueEventRow]) -> some View {
        let rows = topPerformingLocations(from: displayed)
        if rows.count > 1 {
            let visibleRows = Array(rows.prefix(3).enumerated())
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Top Performing Locations")
                        .font(.headline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: 0)
                    Text("View all")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(FGColor.accentBlue)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(visibleRows, id: \.element.id) { index, item in
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(alignment: .top, spacing: 7) {
                                    Text("\(index + 1)")
                                        .font(.caption2.weight(.black))
                                        .foregroundStyle(Color.white)
                                        .frame(width: 18, height: 18)
                                        .background(item.tint, in: Circle())
                                    Image(systemName: "building.2.fill")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(item.tint)
                                    Text(item.name)
                                        .font(.caption.weight(.black))
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                        .lineLimit(2)
                                }

                                HStack(alignment: .bottom) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text("\(item.score)")
                                            .font(.title3.weight(.black))
                                            .foregroundStyle(item.tint)
                                        Text("Engagement")
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    }
                                    Spacer(minLength: 6)
                                    BusinessInsightsSparkline(values: item.trendValues, tint: item.tint, lineWidth: 1.8)
                                        .frame(width: 52, height: 24)
                                }

                                Text(item.signal)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.75)
                            }
                            .padding(11)
                            .frame(width: 138, alignment: .leading)
                            .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .strokeBorder(FGColor.divider(colorScheme).opacity(0.42), lineWidth: 1)
                            }
                        }
                    }
                }
            }
            .onAppear {
#if DEBUG
                print("[BusinessInsightsUI] leaderboardVisible=true")
                print("[BusinessInsightsCrashFix] leaderboardSafe=true")
#endif
            }
        } else {
            EmptyView()
                .onAppear {
#if DEBUG
                    print("[BusinessInsightsUI] leaderboardVisible=false")
                    print("[BusinessInsightsCrashFix] leaderboardSafe=true")
#endif
                }
        }
    }

    @ViewBuilder
    private func bestPerformanceWindowsSection(displayed: [VenueEventRow]) -> some View {
        let windows = bestPerformanceWindows(from: displayed)
        if !windows.isEmpty {
            let visibleWindows = Array(windows.prefix(2))
            HStack(spacing: 10) {
                Image(systemName: "clock")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(FGColor.accentYellow)
                    .frame(width: 34, height: 34)
                    .background(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("Best Performance Windows")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("When your venue gets the most fans")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                Spacer(minLength: 0)

                ForEach(visibleWindows) { window in
                    VStack(alignment: .center, spacing: 3) {
                        Text(window.label)
                            .font(.caption.weight(.black))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(1)
                        Text(window.subtitle)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.accentYellow)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                    .frame(minWidth: 74)
                }
            }
            .padding(12)
            .background(
                LinearGradient(
                    colors: [
                        FGColor.accentYellow.opacity(colorScheme == .dark ? 0.16 : 0.10),
                        FGAdaptiveSurface.controlFill.opacity(0.96)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 20, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(FGColor.accentYellow.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 1)
            }
            .onAppear {
#if DEBUG
                print("[BusinessInsightsCrashFix] bestWindowsSafe=true")
#endif
            }
        }
    }

    private var venueAnalyticsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            businessIntelligenceHeader
            venueAnalyticsDashboardInner()
        }
        .padding(16)
        .background(businessIntelligencePanelBackground)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .strokeBorder(businessAnalyticsGlassStroke.opacity(colorScheme == .dark ? 0.62 : 0.42), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.32 : 0.10), radius: 24, x: 0, y: 14)
        .onAppear {
            logBusinessAnalyticsDebug("sectionAppear tab=\(businessVenueAnalyticsTab.title) preset=\(analyticsDatePreset.rawValue) rows=\(analyticsGames.count)")
        }
        .sheet(item: $analyticsDetailSelection) { selection in
            NavigationStack {
                ScrollView {
                    VenueOwnerGameAnalyticsCard(
                        viewModel: viewModel,
                        fanUpdatesStore: fanUpdatesStore,
                        row: selection.row,
                        eventID: selection.id,
                        isLiveToday: isGameLiveToday(selection.row)
                    )
                    .padding(.vertical, 8)
                }
                .navigationTitle("Watch party insights")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { analyticsDetailSelection = nil }
                    }
                }
            }
        }
        .sheet(isPresented: $showBusinessAnalyticsGuide) {
            businessAnalyticsGuideSheet
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
        .sheet(item: $businessAnalyticsHelpMetric) { metric in
            businessAnalyticsMetricHelpSheet(metric)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationBackground(FGAdaptiveSurface.sheetRoot)
        }
    }

    private var businessIntelligenceHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Business Intelligence")
                .font(.system(size: 26, weight: .black, design: .rounded))
                .foregroundStyle(businessAnalyticsPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.82)

            Text("Insight and performance tools for your venue.")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(businessAnalyticsSecondaryText)

            Button {
#if DEBUG
                print("[BusinessAnalyticsHelpDebug] openedGuide")
#endif
                showBusinessAnalyticsGuide = true
            } label: {
                Label("How FanGeo Analytics Works", systemImage: "questionmark.circle.fill")
                    .font(.caption.weight(.black))
                    .foregroundStyle(businessAnalyticsPrimaryText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.78), in: Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(businessAnalyticsGlassStroke.opacity(0.48), lineWidth: 1)
                    }
            }
            .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: false))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var businessAnalyticsPrimaryText: Color {
        colorScheme == .dark ? Color.white : FGColor.primaryText(colorScheme)
    }

    private var businessAnalyticsSecondaryText: Color {
        colorScheme == .dark ? Color.white.opacity(0.62) : FGColor.secondaryText(colorScheme)
    }

    private var businessAnalyticsGlassStroke: Color {
        colorScheme == .dark ? Color.white.opacity(0.16) : Color.black.opacity(0.10)
    }

    private var businessIntelligencePanelBackground: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color(red: 0.035, green: 0.046, blue: 0.064),
                    Color(red: 0.050, green: 0.071, blue: 0.102),
                    Color(red: 0.030, green: 0.036, blue: 0.052)
                ]
                : [
                    Color.white,
                    Color(red: 0.945, green: 0.965, blue: 1.0)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var businessAnalyticsCardBackground: LinearGradient {
        LinearGradient(
            colors: colorScheme == .dark
                ? [
                    Color.white.opacity(0.075),
                    Color.white.opacity(0.035)
                ]
                : [
                    Color.white.opacity(0.92),
                    Color(red: 0.965, green: 0.975, blue: 1.0).opacity(0.92)
                ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func logBusinessAnalyticsDebug(_ message: String) {
#if DEBUG
        print("[BusinessAnalyticsDebug] \(message)")
#endif
    }

    private func openBusinessAnalyticsMetricHelp(_ metric: BusinessAnalyticsHelpMetric) {
#if DEBUG
        print("[BusinessAnalyticsHelpDebug] openedMetricHelp metric=\(metric.title)")
#endif
        businessAnalyticsHelpMetric = metric
    }

    private var businessAnalyticsGuideSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    businessAnalyticsGuideSection(
                        title: "Engagement Score",
                        body: "Engagement measures fan activity across your venue.",
                        bullets: [
                            "Interested fans",
                            "Comments",
                            "Chat activity",
                            "Reactions",
                            "Fan updates",
                            "Watch party participation"
                        ],
                        footer: "Higher engagement indicates stronger fan involvement."
                    )

                    businessAnalyticsGuideSection(
                        title: "Momentum",
                        body: "Momentum measures how much activity an event is generating right now.",
                        bullets: [
                            "Fan interest",
                            "Chat activity",
                            "Energy votes",
                            "Fan updates"
                        ],
                        footer: "Low = early activity\nMedium = growing activity\nHigh = strong activity"
                    )

                    businessAnalyticsGuideSection(
                        title: "Crowd Building",
                        body: "Crowd Building highlights events where fan activity is growing but attendance is still developing.",
                        footer: "These events may benefit from additional promotion."
                    )

                    businessAnalyticsGuideSection(
                        title: "Top Performing Events",
                        body: "Events are ranked by overall engagement activity.",
                        bullets: [
                            "Interested fans",
                            "Comments",
                            "Chat activity",
                            "Energy votes",
                            "Fan interactions"
                        ]
                    )

                    businessAnalyticsGuideSection(
                        title: "Busiest Days",
                        body: "Shows which days generate the most fan activity.",
                        footer: "Use this to identify strong promotion opportunities."
                    )

                    businessAnalyticsGuideSection(
                        title: "Fan Reach",
                        body: "Fan Reach estimates how many fans interacted with your venue content and events.",
                        footer: "This metric will continue improving as FanGeo grows."
                    )
                }
                .padding(FGSpacing.lg)
            }
            .navigationTitle("FanGeo Analytics Guide")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { showBusinessAnalyticsGuide = false }
                }
            }
            .fanGeoScreenBackground()
        }
    }

    private func businessAnalyticsMetricHelpSheet(_ metric: BusinessAnalyticsHelpMetric) -> some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "questionmark.circle.fill")
                    .font(.system(size: 34, weight: .bold))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(FGColor.accentBlue)

                Text(metric.title)
                    .font(.title3.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))

                Text(metric.explanation)
                    .font(FGTypography.body)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(FGSpacing.lg)
            .navigationTitle("Analytics Help")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { businessAnalyticsHelpMetric = nil }
                }
            }
            .fanGeoScreenBackground()
        }
    }

    private func businessAnalyticsGuideSection(
        title: String,
        body: String,
        bullets: [String] = [],
        footer: String? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption.weight(.black))
                .foregroundStyle(FGColor.accentBlue)

            Text(body)
                .font(FGTypography.body.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if !bullets.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(bullets, id: \.self) { bullet in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•")
                                .font(FGTypography.body.weight(.bold))
                                .foregroundStyle(FGColor.accentGreen)
                            Text(bullet)
                                .font(FGTypography.body)
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            if let footer {
                Text(footer)
                    .font(FGTypography.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.74), lineWidth: 1)
        }
    }

    private func businessAnalyticsMetricHelpButton(_ metric: BusinessAnalyticsHelpMetric) -> some View {
        Button {
            openBusinessAnalyticsMetricHelp(metric)
        } label: {
            Image(systemName: "info.circle")
                .font(.caption.weight(.bold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(businessAnalyticsSecondaryText)
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Learn about \(metric.title)")
    }

    private func venueAnalyticsDashboardInner() -> some View {
        VStack(alignment: .leading, spacing: 14) {
            businessIntelligenceTabBar

            switch businessVenueAnalyticsTab {
            case .venueAnalytics:
                venueAnalyticsVenueEngagementTab()
            case .trends:
                venueAnalyticsTrendsTab()
            case .liveOps:
                venueAnalyticsLiveOpsTab()
            case .gameHistory:
                venueAnalyticsHistoryTab()
                    .task(id: analyticsGameHistoryTaskKey) {
                        await refreshAnalyticsGameHistory()
                    }
                    .refreshable {
                        await refreshAnalyticsGameHistory()
                    }
            }
        }
    }

    private var businessIntelligenceTabBar: some View {
        HStack(spacing: 5) {
            ForEach(BusinessVenueAnalyticsTab.allCases, id: \.rawValue) { tab in
                businessIntelligenceTabButton(tab)
            }
        }
        .padding(6)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.08 : 0.62),
                    Color.black.opacity(colorScheme == .dark ? 0.34 : 0.06)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(businessAnalyticsGlassStroke.opacity(0.45), lineWidth: 1)
        }
    }

    private func businessIntelligenceTabButton(_ tab: BusinessVenueAnalyticsTab) -> some View {
        let isSelected = businessVenueAnalyticsTab == tab
        return Button {
            businessVenueAnalyticsTab = tab
            logBusinessAnalyticsDebug("tabSelected=\(tab.title)")
        } label: {
            VStack(spacing: 5) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 19, weight: .black))
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(isSelected ? FGColor.accentBlue : businessAnalyticsSecondaryText)
                    .frame(height: 22)

                Text(tab.title)
                    .font(.system(size: 11, weight: .black, design: .rounded))
                    .foregroundStyle(isSelected ? FGColor.accentBlue : businessAnalyticsPrimaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Capsule(style: .continuous)
                    .fill(isSelected ? FGColor.accentBlue : Color.clear)
                    .frame(width: 38, height: 2.5)
            }
            .frame(maxWidth: .infinity, minHeight: 58)
            .padding(.top, 8)
            .padding(.horizontal, 2)
            .background(
                isSelected
                    ? Color.white.opacity(colorScheme == .dark ? 0.10 : 0.86)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: false))
        .accessibilityLabel(tab.title)
    }

    /// Engagement tab: only ``venue_events`` rows still in the database (purged games never appear here).
    private func venueAnalyticsVenueEngagementTab() -> some View {
        let pack = displayedVenueAnalyticsGamesForCards()
        let displayed = pack.rows
        let isCapped = pack.isCapped

        return VStack(alignment: .leading, spacing: 12) {
            venueAnalyticsFilterBar

            if isCapped {
                Text("Showing the \(VenueAnalyticsEngagementDisplay.maxCardRowsWhenAllDatesPreset) most recent watch parties. Use a narrower date or sport filter for older results.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            businessAnalyticsActivityContent(displayed: displayed)
        }
        .onAppear {
            logBusinessAnalyticsDebug("activityAppear displayed=\(displayed.count) total=\(analyticsGames.count)")
        }
        .refreshable {
            await loadVenueAnalytics()
        }
    }

    private func venueAnalyticsTrendsTab() -> some View {
        let displayed = displayedVenueAnalyticsGamesForCards().rows

        return VStack(alignment: .leading, spacing: 12) {
            venueAnalyticsFilterBar

            if analyticsIsLoading && analyticsGames.isEmpty {
                venueAnalyticsLoadingState
            } else if analyticsGames.isEmpty {
                venueAnalyticsEmptyState
            } else if displayed.isEmpty {
                venueAnalyticsNoFilterMatchesState
            } else {
                businessAnalyticsDashboardContent(displayed: displayed)
            }
        }
        .onAppear {
            logBusinessAnalyticsDebug("analyticsAppear displayed=\(displayed.count) preset=\(analyticsDatePreset.rawValue) sport=\(analyticsSportFilter)")
        }
        .refreshable {
            await loadVenueAnalytics()
        }
    }

    private func venueAnalyticsLiveOpsTab() -> some View {
        let snapshot = venueAnalyticsLiveOpsSnapshot()

        return VStack(alignment: .leading, spacing: 12) {
            venueAnalyticsLiveOpsSportFilter
            businessAnalyticsLiveActivityCard(snapshot)

            if snapshot.hasActiveActivity {
                liveOpsActiveGamesSection(snapshot.activeGames)
            } else {
                liveOpsQuietState(nextOpportunity: snapshot.nextOpportunity)
            }

            liveOpsAlertsSection(snapshot.alerts)
        }
        .onAppear {
            logBusinessAnalyticsDebug("liveAppear active=\(snapshot.activeGameCount) chats=\(snapshot.activeChatCount)")
        }
        .task(id: venueAnalyticsLiveOpsTaskKey) {
            await refreshVenueAnalyticsLiveOpsEngagementOnly()
        }
        .refreshable {
            await loadVenueAnalytics()
            await refreshVenueAnalyticsLiveOpsEngagementOnly()
        }
    }

    private var venueAnalyticsLiveOpsSportFilter: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Real-time crowd activity for this location.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(businessAnalyticsSecondaryText)

            Picker("Sport", selection: $analyticsSportFilter) {
                ForEach(analyticsSportFilterOptions, id: \.self) { sport in
                    Text(AppSportCatalog.displayLabel(forSportToken: sport)).tag(sport)
                }
            }
            .pickerStyle(.menu)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.86), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(businessAnalyticsGlassStroke.opacity(0.42), lineWidth: 1)
            }
            .onChange(of: analyticsSportFilter) { _, _ in
                logBusinessAnalyticsDebug("liveSportFilter=\(analyticsSportFilter)")
                Task {
                    await refreshVenueAnalyticsLiveOpsEngagementOnly()
                }
            }
        }
    }

    @ViewBuilder
    private func businessAnalyticsActivityContent(displayed: [VenueEventRow]) -> some View {
        if analyticsIsLoading && analyticsGames.isEmpty {
            venueAnalyticsLoadingState
        } else if analyticsGames.isEmpty {
            venueAnalyticsEmptyState
        } else if displayed.isEmpty {
            venueAnalyticsNoFilterMatchesState
        } else {
            businessAnalyticsEngagementOverviewCard(displayed: displayed)
            venueAnalyticsMomentumSection(displayed: displayed)
            venueAnalyticsTopActiveSportsSection(displayed: displayed)
        }
    }

    private func businessAnalyticsDashboardContent(displayed: [VenueEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            businessAnalyticsEngagementOverviewCard(displayed: displayed)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                businessAnalyticsRankedCard(
                    title: "Top Sports",
                    subtitle: "by engagement",
                    metrics: businessAnalyticsTopSports(from: displayed)
                )
                businessAnalyticsRankedCard(
                    title: "Busiest Days",
                    subtitle: "by engagement",
                    metrics: businessAnalyticsBusiestDays(from: displayed),
                    helpMetric: .busiestDays
                )
            }

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                businessAnalyticsBestTimeWindowsCard(displayed: displayed)
                businessAnalyticsTopPerformingEventsCard(displayed: displayed)
            }
        }
    }

    private func businessAnalyticsEngagementOverviewCard(displayed: [VenueEventRow]) -> some View {
        let points = businessAnalyticsChartPoints(from: displayed)
        let total = businessAnalyticsTotalEngagement(displayed)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Engagement Overview")
                    .font(.headline.weight(.black))
                    .foregroundStyle(businessAnalyticsPrimaryText)
                businessAnalyticsMetricHelpButton(.engagementOverview)
                Spacer(minLength: 0)
                Text(analyticsDatePreset.rawValue)
                    .font(.caption.weight(.black))
                    .foregroundStyle(businessAnalyticsPrimaryText)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.78), in: Capsule(style: .continuous))
            }

            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(total.formatted())
                    .font(.system(size: 32, weight: .black, design: .rounded))
                    .foregroundStyle(FGColor.accentBlue)
                    .contentTransition(.numericText())
                Text("total engagement")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(businessAnalyticsSecondaryText)
                Spacer(minLength: 0)
                Text(crowdInsightsComparisonLine())
                    .font(.caption.weight(.black))
                    .foregroundStyle(crowdInsightsTrendTint())
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }

            businessAnalyticsLineChart(points: points)
                .frame(height: 128)
        }
        .padding(14)
        .background(businessAnalyticsCardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.13), lineWidth: 1)
        }
    }

    private func businessAnalyticsLineChart(points: [BusinessAnalyticsChartPoint]) -> some View {
        let maxValue = max(points.map(\.value).max() ?? 0, 10)
        let labelPoints = businessAnalyticsChartLabelPoints(from: points)
        let peakID = points.max { $0.value < $1.value }?.id

        return VStack(spacing: 5) {
            Chart(points) { point in
                AreaMark(
                    x: .value("Period", point.index),
                    y: .value("Engagement", point.value)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            FGColor.accentBlue.opacity(colorScheme == .dark ? 0.34 : 0.22),
                            FGColor.accentBlue.opacity(0.02)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                LineMark(
                    x: .value("Period", point.index),
                    y: .value("Engagement", point.value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(.init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .foregroundStyle(FGColor.accentBlue)

                if point.id == peakID && point.value > 0 {
                    PointMark(
                        x: .value("Period", point.index),
                        y: .value("Engagement", point.value)
                    )
                    .symbolSize(56)
                    .foregroundStyle(FGColor.accentBlue)
                }
            }
            .chartYScale(domain: 0...maxValue)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) {
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.6))
                        .foregroundStyle(businessAnalyticsGlassStroke.opacity(0.60))
                    AxisValueLabel()
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(businessAnalyticsSecondaryText)
                }
            }

            HStack {
                ForEach(labelPoints) { point in
                    Text(point.label)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(businessAnalyticsSecondaryText)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private func businessAnalyticsRankedCard(
        title: String,
        subtitle: String,
        metrics: [BusinessAnalyticsRankedMetric],
        helpMetric: BusinessAnalyticsHelpMetric? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(title)
                        .font(.headline.weight(.black))
                        .foregroundStyle(businessAnalyticsPrimaryText)
                    if let helpMetric {
                        businessAnalyticsMetricHelpButton(helpMetric)
                    }
                }
                Text(subtitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(businessAnalyticsSecondaryText)
            }

            if metrics.isEmpty {
                Text("No engagement yet")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(businessAnalyticsSecondaryText)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(metrics) { metric in
                        businessAnalyticsRankedRow(metric)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(businessAnalyticsCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(businessAnalyticsGlassStroke.opacity(0.44), lineWidth: 1)
        }
    }

    private func businessAnalyticsRankedRow(_ metric: BusinessAnalyticsRankedMetric) -> some View {
        HStack(spacing: 7) {
            Text("\(metric.rank)")
                .font(.caption.weight(.black))
                .foregroundStyle(businessAnalyticsSecondaryText)
                .frame(width: 12, alignment: .leading)

            Text(metric.icon)
                .font(.system(size: 15))
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(metric.title)
                        .font(.caption.weight(.black))
                        .foregroundStyle(businessAnalyticsPrimaryText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                    Spacer(minLength: 0)
                    Text(metric.valueText)
                        .font(.caption.weight(.black))
                        .foregroundStyle(businessAnalyticsPrimaryText)
                }

                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule(style: .continuous)
                            .fill(businessAnalyticsGlassStroke.opacity(0.35))
                        Capsule(style: .continuous)
                            .fill(metric.tint)
                            .frame(width: proxy.size.width * metric.progress)
                    }
                }
                .frame(height: 4)
            }
        }
    }

    private func businessAnalyticsBestTimeWindowsCard(displayed: [VenueEventRow]) -> some View {
        let windows = businessAnalyticsBestTimeWindows(from: displayed)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Best Time Windows")
                    .font(.headline.weight(.black))
                    .foregroundStyle(businessAnalyticsPrimaryText)
                Text("by engagement")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(businessAnalyticsSecondaryText)
            }

            if windows.isEmpty {
                Text("More activity will reveal the best hosting windows.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(businessAnalyticsSecondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(windows) { metric in
                        HStack(spacing: 10) {
                            ZStack {
                                Circle()
                                    .fill(metric.tint.opacity(colorScheme == .dark ? 0.20 : 0.12))
                                Text(metric.icon)
                                    .font(.system(size: 17))
                            }
                            .frame(width: 34, height: 34)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(metric.title)
                                    .font(.caption.weight(.black))
                                    .foregroundStyle(businessAnalyticsPrimaryText)
                                if let subtitle = metric.subtitle {
                                    Text(subtitle)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(businessAnalyticsSecondaryText)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(businessAnalyticsCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(businessAnalyticsGlassStroke.opacity(0.44), lineWidth: 1)
        }
    }

    private func businessAnalyticsTopPerformingEventsCard(displayed: [VenueEventRow]) -> some View {
        let events = businessAnalyticsTopPerformingEvents(from: displayed)

        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Top Performing Events")
                        .font(.headline.weight(.black))
                        .foregroundStyle(businessAnalyticsPrimaryText)
                    businessAnalyticsMetricHelpButton(.topPerformingEvents)
                }
                Text(analyticsDatePreset.rawValue.lowercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(businessAnalyticsSecondaryText)
            }

            if events.isEmpty {
                Text("No event performance yet.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(businessAnalyticsSecondaryText)
                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .leading)
            } else {
                VStack(spacing: 8) {
                    ForEach(events) { metric in
                        HStack(spacing: 8) {
                            Text("\(metric.rank)")
                                .font(.caption.weight(.black))
                                .foregroundStyle(businessAnalyticsSecondaryText)
                                .frame(width: 12, alignment: .leading)
                            Text(metric.icon)
                                .font(.system(size: 15))
                            Text(metric.title)
                                .font(.caption.weight(.black))
                                .foregroundStyle(businessAnalyticsPrimaryText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                            Spacer(minLength: 0)
                            Text(metric.valueText)
                                .font(.caption.weight(.black))
                                .foregroundStyle(businessAnalyticsPrimaryText)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(businessAnalyticsCardBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(businessAnalyticsGlassStroke.opacity(0.44), lineWidth: 1)
        }
    }

    private func businessAnalyticsLiveActivityCard(_ snapshot: VenueAnalyticsLiveOpsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Live Activity")
                        .font(.title3.weight(.black))
                        .foregroundStyle(businessAnalyticsPrimaryText)
                    Text("Real-time venue pulse")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(businessAnalyticsSecondaryText)
                        .textCase(.uppercase)
                }

                Spacer(minLength: 0)

                Text(snapshot.statusText)
                    .font(.caption.weight(.black))
                    .foregroundStyle(liveOpsStatusTint(snapshot.statusText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(liveOpsStatusTint(snapshot.statusText).opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                liveOpsMetricTile(title: "active games now", value: "\(snapshot.activeGameCount)", icon: "play.circle.fill")
                liveOpsMetricTile(title: "active chats", value: "\(snapshot.activeChatCount)", icon: "bubble.left.and.bubble.right.fill")
                liveOpsMetricTile(title: "crowd energy", value: "\(snapshot.crowdEnergy)", icon: "bolt.fill")
                liveOpsMetricTile(title: "top live sport", value: snapshot.topLiveSport, icon: "sportscourt.fill")
            }

            Text(snapshot.momentumTrend)
                .font(.caption.weight(.semibold))
                .foregroundStyle(businessAnalyticsSecondaryText)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(businessAnalyticsCardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(liveOpsStatusTint(snapshot.statusText).opacity(colorScheme == .dark ? 0.24 : 0.16), lineWidth: 1)
        }
    }

    private func venueAnalyticsHistoryTab() -> some View {
        let displayed = displayedVenueAnalyticsGamesForCards().rows

        return VStack(alignment: .leading, spacing: 12) {
            venueAnalyticsFilterBar
            businessAnalyticsHistoryTrendsCard(displayed: displayed)
            analyticsPurgedHistorySection
        }
        .onAppear {
            logBusinessAnalyticsDebug("historyAppear displayed=\(displayed.count) historyRows=\(analyticsGameHistoryForYear.count)")
        }
    }

    private func businessAnalyticsHistoryTrendsCard(displayed: [VenueEventRow]) -> some View {
        let topSport = businessAnalyticsTopSports(from: displayed).first?.title ?? "No leader yet"
        let bestDay = businessAnalyticsBusiestDays(from: displayed).first?.title ?? "No day yet"
        let total = businessAnalyticsTotalEngagement(displayed)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.20 : 0.12))
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.system(size: 18, weight: .black))
                        .foregroundStyle(FGColor.accentBlue)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 3) {
                    Text("History & Trends")
                        .font(.headline.weight(.black))
                        .foregroundStyle(businessAnalyticsPrimaryText)
                    Text("Long-range engagement patterns for this venue.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(businessAnalyticsSecondaryText)
                }
                Spacer(minLength: 0)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                businessAnalyticsHistoryStat("Engagement", value: total.formatted(), tint: FGColor.accentBlue)
                businessAnalyticsHistoryStat("Trend", value: crowdInsightsComparisonLine(), tint: crowdInsightsTrendTint())
                businessAnalyticsHistoryStat("Top sport", value: topSport, tint: FGColor.accentGreen)
                businessAnalyticsHistoryStat("Busiest day", value: bestDay, tint: FGColor.accentYellow)
            }
        }
        .padding(14)
        .background(businessAnalyticsCardBackground, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(businessAnalyticsGlassStroke.opacity(0.44), lineWidth: 1)
        }
    }

    private func businessAnalyticsHistoryStat(_ title: String, value: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(businessAnalyticsPrimaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.68)
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(businessAnalyticsSecondaryText)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func businessAnalyticsTotalEngagement(_ rows: [VenueEventRow]) -> Int {
        rows.reduce(0) { $0 + analyticsEngagementSignal(for: $1) }
    }

    private func businessAnalyticsChartPoints(from rows: [VenueEventRow]) -> [BusinessAnalyticsChartPoint] {
        let calendar = Calendar.current
        var scoresByKey: [String: Int] = [:]

        for row in rows {
            guard let start = venueAnalyticsEventStartDate(row) else { continue }
            let key: String
            switch analyticsDatePreset {
            case .thisWeek, .thisMonth:
                key = Self.analyticsDayFormatter.string(from: calendar.startOfDay(for: start))
            case .thisYear:
                let month = calendar.component(.month, from: start)
                key = String(format: "%04d-%02d", calendar.component(.year, from: start), month)
            }
            scoresByKey[key, default: 0] += analyticsEngagementSignal(for: row)
        }

        switch analyticsDatePreset {
        case .thisWeek:
            let interval = calendar.dateInterval(of: .weekOfYear, for: Date()) ?? DateInterval(start: Date(), duration: 6 * 86_400)
            return (0..<7).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
                let key = Self.analyticsDayFormatter.string(from: date)
                return BusinessAnalyticsChartPoint(
                    id: "week-\(offset)",
                    index: offset,
                    label: Self.analyticsShortWeekdayFormatter.string(from: date),
                    value: scoresByKey[key, default: 0]
                )
            }
        case .thisMonth:
            let interval = calendar.dateInterval(of: .month, for: Date()) ?? DateInterval(start: Date(), duration: 29 * 86_400)
            let dayCount = calendar.range(of: .day, in: .month, for: Date())?.count ?? 30
            return (0..<dayCount).compactMap { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: interval.start) else { return nil }
                let key = Self.analyticsDayFormatter.string(from: date)
                return BusinessAnalyticsChartPoint(
                    id: "month-\(offset)",
                    index: offset,
                    label: Self.analyticsMonthDayFormatter.string(from: date),
                    value: scoresByKey[key, default: 0]
                )
            }
        case .thisYear:
            let year = calendar.component(.year, from: Date())
            return (1...12).map { month in
                let key = String(format: "%04d-%02d", year, month)
                let components = DateComponents(year: year, month: month, day: 1)
                let date = calendar.date(from: components) ?? Date()
                return BusinessAnalyticsChartPoint(
                    id: "year-\(month)",
                    index: month - 1,
                    label: Self.analyticsShortMonthFormatter.string(from: date),
                    value: scoresByKey[key, default: 0]
                )
            }
        }
    }

    private func businessAnalyticsChartLabelPoints(from points: [BusinessAnalyticsChartPoint]) -> [BusinessAnalyticsChartPoint] {
        guard points.count > 5 else { return points }
        let last = points.count - 1
        let indexes = Set([0, last / 4, last / 2, (last * 3) / 4, last])
        return points.filter { indexes.contains($0.index) }
    }

    private func businessAnalyticsTopSports(from rows: [VenueEventRow]) -> [BusinessAnalyticsRankedMetric] {
        var scores: [String: Int] = [:]
        for row in rows {
            let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sport.isEmpty else { continue }
            let signal = max(analyticsEngagementSignal(for: row), row.id == nil ? 0 : 1)
            guard signal > 0 else { continue }
            scores[sport, default: 0] += signal
        }
        return businessAnalyticsRankedMetrics(from: scores, fallbackIcon: "🏟", tints: [
            FGColor.accentBlue,
            FGColor.accentGreen,
            Color.orange,
            Color.purple
        ]) { sport in
            let emoji = venueAnalyticsSportEmoji(for: sport)
            return (
                title: AppSportCatalog.displayLabel(forSportToken: sport),
                subtitle: nil,
                icon: emoji.isEmpty ? "🏟" : emoji
            )
        }
    }

    private func businessAnalyticsBusiestDays(from rows: [VenueEventRow]) -> [BusinessAnalyticsRankedMetric] {
        let calendar = Calendar.current
        var scores: [String: Int] = [:]

        for row in rows {
            guard let start = venueAnalyticsEventStartDate(row) else { continue }
            let weekday = Self.analyticsWeekdayFormatter.string(from: start)
            let signal = max(analyticsEngagementSignal(for: row), row.id == nil ? 0 : 1)
            guard signal > 0 else { continue }
            scores[weekday, default: 0] += signal
        }

        let weekdayOrder = calendar.weekdaySymbols
        return businessAnalyticsRankedMetrics(from: scores, fallbackIcon: "calendar", tints: [
            FGColor.accentBlue,
            Color.purple,
            FGColor.accentYellow,
            FGColor.accentGreen
        ]) { day in
            let rankSeed = weekdayOrder.firstIndex(of: day) ?? 0
            return (
                title: day,
                subtitle: nil,
                icon: "\(rankSeed + 1)"
            )
        }
    }

    private func businessAnalyticsRankedMetrics(
        from scores: [String: Int],
        fallbackIcon: String,
        tints: [Color],
        label: (String) -> (title: String, subtitle: String?, icon: String)
    ) -> [BusinessAnalyticsRankedMetric] {
        let total = max(scores.values.reduce(0, +), 1)
        let sorted = scores.sorted { lhs, rhs in
            if lhs.value == rhs.value { return lhs.key < rhs.key }
            return lhs.value > rhs.value
        }

        return sorted.prefix(4).enumerated().map { index, item in
            let meta = label(item.key)
            let percent = Int((Double(item.value) / Double(total) * 100).rounded())
            return BusinessAnalyticsRankedMetric(
                id: "\(item.key)-\(index)",
                rank: index + 1,
                title: meta.title,
                subtitle: meta.subtitle,
                valueText: localizedWholePercent(max(1, percent)),
                progress: min(1, max(0.06, Double(item.value) / Double(total))),
                icon: meta.icon.isEmpty ? fallbackIcon : meta.icon,
                tint: tints[index % max(tints.count, 1)]
            )
        }
    }

    private func businessAnalyticsBestTimeWindows(from rows: [VenueEventRow]) -> [BusinessAnalyticsRankedMetric] {
        bestPerformanceWindows(from: rows).enumerated().map { index, window in
            BusinessAnalyticsRankedMetric(
                id: "window-\(window.id)-\(index)",
                rank: index + 1,
                title: window.label,
                subtitle: window.subtitle,
                valueText: "",
                progress: 1,
                icon: index == 0 ? "👑" : "💬",
                tint: index == 0 ? FGColor.accentYellow : Color.purple
            )
        }
    }

    private func businessAnalyticsTopPerformingEvents(from rows: [VenueEventRow]) -> [BusinessAnalyticsRankedMetric] {
        let scoredRows = rows.compactMap { row -> (row: VenueEventRow, score: Int)? in
            guard row.id != nil else { return nil }
            let score = analyticsEngagementSignal(for: row)
            return (row, score)
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return (lhs.row.event_title ?? "") < (rhs.row.event_title ?? "")
            }
            return lhs.score > rhs.score
        }

        return scoredRows.prefix(3).enumerated().map { index, item in
            let title = item.row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sport = item.row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return BusinessAnalyticsRankedMetric(
                id: item.row.id?.uuidString ?? "event-\(index)",
                rank: index + 1,
                title: title.isEmpty ? "Watch party" : title,
                subtitle: sport.isEmpty ? nil : AppSportCatalog.displayLabel(forSportToken: sport),
                valueText: businessAnalyticsCompactNumber(max(item.score, 0)),
                progress: 1,
                icon: sport.isEmpty ? "🏟" : venueAnalyticsSportEmoji(for: sport),
                tint: [FGColor.accentBlue, FGColor.accentGreen, Color.purple][index % 3]
            )
        }
    }

    private func businessAnalyticsCompactNumber(_ value: Int) -> String {
        if value >= 1_000 {
            let compact = Double(value) / 1_000
            return String(format: "%.1fK", compact)
        }
        return "\(value)"
    }

    private func liveOpsHeroCard(_ snapshot: VenueAnalyticsLiveOpsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Live Ops")
                        .font(.title3.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Venue Status")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .textCase(.uppercase)
                }

                Spacer(minLength: 0)

                Text(snapshot.statusText)
                    .font(.caption.weight(.black))
                    .foregroundStyle(liveOpsStatusTint(snapshot.statusText))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(liveOpsStatusTint(snapshot.statusText).opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                liveOpsMetricTile(title: "active games now", value: "\(snapshot.activeGameCount)", icon: "play.circle.fill")
                liveOpsMetricTile(title: "active chats", value: "\(snapshot.activeChatCount)", icon: "bubble.left.and.bubble.right.fill")
                liveOpsMetricTile(title: "crowd energy", value: "\(snapshot.crowdEnergy)", icon: "bolt.fill")
                liveOpsMetricTile(title: "top live sport", value: snapshot.topLiveSport, icon: "sportscourt.fill")
            }

            Text(snapshot.momentumTrend)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(liveOpsStatusTint(snapshot.statusText).opacity(colorScheme == .dark ? 0.24 : 0.16), lineWidth: 1)
        }
    }

    private func liveOpsMetricTile(title: String, value: String, icon: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.caption.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(FGAdaptiveSurface.capsuleUnselected, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func liveOpsActiveGamesSection(_ games: [VenueAnalyticsLiveOpsGame]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Active Games")
                .font(.headline.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            LazyVStack(spacing: 8) {
                ForEach(games) { game in
                    liveOpsGameCard(game, titlePrefix: nil)
                }
            }
        }
    }

    private func liveOpsQuietState(nextOpportunity: VenueAnalyticsLiveOpsGame?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quiet right now")
                .font(.headline.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text("No active crowd activity detected.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            if let nextOpportunity {
                liveOpsGameCard(nextOpportunity, titlePrefix: "Next crowd opportunity")
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nothing scheduled yet")
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Create or promote a watch party to start building crowd activity.")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(13)
        .background(FGAdaptiveSurface.controlFill.opacity(0.72), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func liveOpsGameCard(_ game: VenueAnalyticsLiveOpsGame, titlePrefix: String?) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            if let titlePrefix {
                Text(titlePrefix)
                    .font(.caption.weight(.black))
                    .foregroundStyle(FGColor.accentBlue)
                    .textCase(.uppercase)
            }

            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.title)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text("\(AppSportCatalog.displayLabel(forSportToken: game.sport)) • \(game.scheduleText)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(2)
                }

                Spacer(minLength: 0)

                Text(game.statusText)
                    .font(.caption2.weight(.black))
                    .foregroundStyle(liveOpsStatusTint(game.statusText))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(liveOpsStatusTint(game.statusText).opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
            }

            HStack(spacing: 7) {
                liveOpsSmallMetric("Momentum", "\(game.momentumScore)")
                liveOpsSmallMetric("Interested", "\(game.interestedCount)")
                liveOpsSmallMetric("Chat", "\(game.chatCount)")
                liveOpsSmallMetric("Energy", "\(game.vibeCount)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.46), lineWidth: 1)
        }
    }

    private func liveOpsSmallMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.caption.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(FGAdaptiveSurface.capsuleUnselected, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func liveOpsAlertsSection(_ alerts: [String]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Live Alerts")
                .font(.headline.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            LazyVStack(alignment: .leading, spacing: 7) {
                ForEach(Array(alerts.enumerated()), id: \.offset) { _, alert in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(FGColor.accentYellow)
                        Text(alert)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
            }
        }
    }

    private func venueAnalyticsTopSportsTrendSection(
        first: VenueAnalyticsTrendSportSummary,
        second: VenueAnalyticsTrendSportSummary,
        third: VenueAnalyticsTrendSportSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Top sports this month")
                .font(.headline.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(spacing: 8) {
                trendSportCard(first, rank: "1")
                trendSportCard(second, rank: "2")
                trendSportCard(third, rank: "3")
            }
        }
        .padding(13)
        .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.40), lineWidth: 1)
        }
    }

    private func trendSportCard(_ item: VenueAnalyticsTrendSportSummary, rank: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("#\(rank)")
                .font(.caption2.weight(.black))
                .foregroundStyle(item.tint)

            HStack(alignment: .center, spacing: 6) {
                Text(venueAnalyticsSportEmoji(for: item.sport))
                    .font(.system(size: 16))
                    .frame(width: 26, height: 26)
                    .background(item.tint.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Circle())

                Text(AppSportCatalog.displayLabel(forSportToken: item.sport))
                    .font(.caption.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .minimumScaleFactor(0.80)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(item.score > 0 ? "\(item.score) pts" : "No activity yet")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(item.tint.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(item.tint.opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: 1)
        }
    }

    private func venueAnalyticsSportEmoji(for sport: String) -> String {
        let catalogEmoji = SportFilterCatalog.resolve(sport).emoji
        if !catalogEmoji.isEmpty { return catalogEmoji }

        let normalized = sport.lowercased()
        if normalized.contains("soccer") { return "⚽️" }
        if normalized.contains("basketball") { return "🏀" }
        if normalized.contains("football") { return "🏈" }
        if normalized.contains("baseball") { return "⚾️" }
        return "🏟"
    }

    private var venueAnalyticsBestHostingDaysTrendSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Best hosting days")
                .font(.headline.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            HStack(spacing: 8) {
                trendHostingDayCard("Sunday evenings", tint: FGColor.accentYellow)
                trendHostingDayCard("Friday nights", tint: FGColor.accentBlue)
                trendHostingDayCard("Saturday afternoons", tint: Color.purple)
            }
        }
        .padding(13)
        .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.40), lineWidth: 1)
        }
    }

    private func trendHostingDayCard(_ label: String, tint: Color) -> some View {
        Text(label)
            .font(.caption.weight(.black))
            .foregroundStyle(FGColor.primaryText(colorScheme))
            .lineLimit(2)
            .minimumScaleFactor(0.76)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            .padding(.horizontal, 8)
            .background(tint.opacity(colorScheme == .dark ? 0.14 : 0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.18 : 0.10), lineWidth: 1)
            }
    }

    @ViewBuilder
    private func venueAnalyticsVenueEngagementContent(displayed: [VenueEventRow]) -> some View {
        let _ = logBusinessInsightsEnteringContent(displayedCount: displayed.count)
        if analyticsIsLoading && analyticsGames.isEmpty {
            venueAnalyticsLoadingState
        } else if analyticsGames.isEmpty {
            venueAnalyticsEmptyState
        } else if displayed.isEmpty {
            venueAnalyticsNoFilterMatchesState
        } else if usePremiumCrowdInsights {
            venueAnalyticsPremiumContent(displayed: displayed)
        } else {
            venueAnalyticsBasicFallbackList(displayed: displayed)
        }
    }

    private func logBusinessInsightsEnteringContent(displayedCount: Int) -> Bool {
#if DEBUG
        print("[BusinessInsightsCrashFix] enteringContent displayedCount=\(displayedCount)")
#endif
        return true
    }

    @ViewBuilder
    private func venueAnalyticsRestoredStableLayout(displayed: [VenueEventRow]) -> some View {
        if analyticsIsLoading && analyticsGames.isEmpty {
            venueAnalyticsLoadingState
        } else if analyticsGames.isEmpty {
            venueAnalyticsEmptyState
        } else if displayed.isEmpty {
            venueAnalyticsNoFilterMatchesState
        } else {
            crowdInsightsSummaryHeader(displayed: displayed)
            venueAnalyticsEventPerformanceList(displayed: displayed)
        }
    }

    @ViewBuilder
    private func venueAnalyticsEmergencyRollbackFallback(displayed: [VenueEventRow]) -> some View {
        let rows = analyticsBasicEventRows(from: displayed)
        VStack(alignment: .leading, spacing: 10) {
            Text("Crowd Insights")
                .font(.headline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))

            Text("Analytics are being refreshed.")
                .font(.subheadline)
                .foregroundStyle(FGColor.secondaryText(colorScheme))

            if analyticsIsLoading && analyticsGames.isEmpty {
                venueAnalyticsLoadingState
            } else if analyticsGames.isEmpty {
                venueAnalyticsEmptyState
            } else if displayed.isEmpty {
                venueAnalyticsNoFilterMatchesState
            } else if rows.isEmpty {
                notEnoughActivityCard
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        venueAnalyticsBasicEventCard(row)
                    }
                }
                .padding(.top, 2)
            }
        }
        .onAppear {
#if DEBUG
            print("[BusinessInsightsCrashFix] enteringContent displayedCount=\(displayed.count)")
            print("[BusinessInsightsCrashFix] renderingBasicFallback=true")
            print("[BusinessInsightsCrashFix] stableEventRowsCount=\(rows.count)")
#endif
        }
    }

    private var venueAnalyticsLoadingState: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Loading analytics…")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var venueAnalyticsEmptyState: some View {
        Text("No games loaded for analytics yet. Add a game from the Games tab, or pull to refresh after cancellations.")
            .font(.subheadline)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var venueAnalyticsNoFilterMatchesState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No watch parties match this filter.")
                .font(.subheadline)
                .fontWeight(.semibold)
            Text("Try another date range or sport, or choose “All” to review more crowd activity.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private func venueAnalyticsPremiumContent(displayed: [VenueEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            crowdInsightsSummaryHeader(displayed: displayed)
            venueAnalyticsMomentumSection(displayed: displayed)
            venueAnalyticsTopActiveSportsSection(displayed: displayed)
        }
        .onAppear {
#if DEBUG
            print("[BusinessInsightsCrashFix] renderingPremiumSection=true")
#endif
        }
    }

    private func venueAnalyticsMomentumSection(displayed: [VenueEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Upcoming with momentum")
                    .font(.headline.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Spacer(minLength: 0)
                Text("View all")
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(FGColor.accentBlue)
            }

            venueAnalyticsEventPerformanceList(displayed: displayed)
        }
    }

    @ViewBuilder
    private func venueAnalyticsTopActiveSportsSection(displayed: [VenueEventRow]) -> some View {
        let sports = venueAnalyticsTopActiveSports(from: displayed)
        if !sports.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Top active sports")
                        .font(.headline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Spacer(minLength: 0)
                    Text("View all")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(FGColor.accentBlue)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(sports) { item in
                            venueAnalyticsActiveSportChip(item)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func venueAnalyticsActiveSportChip(_ item: VenueAnalyticsTrendSportSummary) -> some View {
        let emoji = SportFilterCatalog.resolve(item.sport).emoji
        return HStack(spacing: 8) {
            Text(emoji.isEmpty ? "🏟" : emoji)
                .font(.system(size: 17))
                .frame(width: 28, height: 28)
                .background(item.tint.opacity(colorScheme == .dark ? 0.20 : 0.12), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(AppSportCatalog.displayLabel(forSportToken: item.sport))
                    .font(.caption.weight(.black))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(1)
                    .minimumScaleFactor(0.76)
                Text("\(item.score) pts")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(item.tint.opacity(colorScheme == .dark ? 0.28 : 0.16), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func venueAnalyticsBasicFallbackList(displayed: [VenueEventRow]) -> some View {
        let rows = analyticsBasicEventRows(from: displayed)
        if rows.isEmpty {
            notEnoughActivityCard
                .onAppear {
#if DEBUG
                    print("[BusinessInsightsCrashFix] renderingBasicFallback=true")
                    print("[BusinessInsightsCrashFix] stableEventRowsCount=0")
#endif
                }
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(rows) { row in
                        venueAnalyticsBasicEventCard(row)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 520)
            .onAppear {
#if DEBUG
                print("[BusinessInsightsCrashFix] renderingBasicFallback=true")
                print("[BusinessInsightsCrashFix] stableEventRowsCount=\(rows.count)")
#endif
            }
        }
    }

    private func venueAnalyticsBasicEventCard(_ row: VenueAnalyticsBasicEventRow) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text(row.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Text(row.status)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(FGAdaptiveSurface.capsuleUnselected, in: Capsule(style: .continuous))
            }

            Text(row.schedule)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .lineLimit(1)

            HStack(spacing: 10) {
                Text(AppSportCatalog.displayLabel(forSportToken: row.sport))
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .lineLimit(1)
                Text("Going \(row.goingCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text("Comments \(row.commentsCount)")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme).opacity(0.55), lineWidth: 1)
        }
    }

    private func venueAnalyticsInsightsOverview(displayed: [VenueEventRow]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            crowdInsightsSummaryHeader(displayed: displayed)
            mostPopularSportInsight(displayed: displayed)
            venueInsightsSection(displayed: displayed)
            venuePerformanceLeaderboard(displayed: displayed)
        }
        .onAppear {
#if DEBUG
            print("[BusinessInsightsCrashFix] displayedCount=\(displayed.count)")
            print("[BusinessInsightsCrashFix] summarySafe=true")
            print("[BusinessInsightsCrashFix] leaderboardSafe=true")
            print("[BusinessInsightsCrashFix] topSportSafe=true")
            print("[BusinessInsightsCrashFix] bestWindowsSafe=true")
#endif
        }
    }

    @ViewBuilder
    private func venueAnalyticsEventPerformanceList(displayed: [VenueEventRow]) -> some View {
        let cardRows = analyticsDisplayCardRows(from: displayed)
        if cardRows.isEmpty {
            notEnoughActivityCard
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(cardRows) { card in
                        venueAnalyticsEventPerformanceCard(card)
                    }
                }
                .padding(.top, 4)
            }
            .frame(maxHeight: 520)
        }
    }

    private func venueAnalyticsEventPerformanceCard(_ card: VenueAnalyticsDisplayCardRow) -> some View {
        VenueOwnerCompactAnalyticsRow(
            viewModel: viewModel,
            fanUpdatesStore: fanUpdatesStore,
            row: card.row,
            eventID: card.eventID,
            isLiveToday: isGameLiveToday(card.row),
            onTapDetail: {
                analyticsDetailSelection = VenueOwnerAnalyticsDetailSelection(id: card.eventID, row: card.row)
            }
        )
        .contextMenu {
            Button("Details") {
                analyticsDetailSelection = VenueOwnerAnalyticsDetailSelection(id: card.eventID, row: card.row)
            }
            Button("Hide from analytics", role: .destructive) {
                hideVenueEventFromAnalytics(card.eventID)
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Hide") {
                hideVenueEventFromAnalytics(card.eventID)
            }
            .tint(.orange)
        }
    }

    private func analyticsDisplayCardRows(from rows: [VenueEventRow]) -> [VenueAnalyticsDisplayCardRow] {
        rows.enumerated().compactMap { index, row in
            guard let eventID = row.id else { return nil }
            let venuePart = row.venue_id?.uuidString ?? row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "venue"
            let datePart = row.scheduled_start_at ?? row.event_date ?? "date"
            return VenueAnalyticsDisplayCardRow(
                id: "\(eventID.uuidString)-\(venuePart)-\(datePart)-\(index)",
                eventID: eventID,
                row: row
            )
        }
    }

    private func analyticsBasicEventRows(from rows: [VenueEventRow]) -> [VenueAnalyticsBasicEventRow] {
        rows.enumerated().map { index, row in
            let eventID = row.id
            let venuePart = row.venue_id?.uuidString ?? row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "venue"
            let startPart = row.scheduled_start_at ?? row.event_date ?? "date"
            let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let going = eventID.map { viewModel.interestCountForVenueEvent($0) } ?? 0
            let comments = eventID.map { fanUpdatesStore.venueEventComments[$0]?.count ?? 0 } ?? 0
            return VenueAnalyticsBasicEventRow(
                id: "\(eventID?.uuidString ?? "missing-event")-\(venuePart)-\(startPart)-\(index)",
                eventID: eventID,
                title: title.isEmpty ? "Watch party" : title,
                schedule: basicAnalyticsScheduleLine(for: row),
                sport: sport.isEmpty ? "Sport not set" : sport,
                goingCount: going,
                commentsCount: comments,
                status: status.isEmpty ? "Active" : status.capitalized
            )
        }
    }

    private func basicAnalyticsScheduleLine(for row: VenueEventRow) -> String {
        if let start = venueAnalyticsEventStartDate(row) {
            return start.formatted(date: .abbreviated, time: .shortened)
        }
        let day = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let time = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !day.isEmpty && !time.isEmpty { return "\(day) • \(time)" }
        if !day.isEmpty { return day }
        if !time.isEmpty { return time }
        return "Date TBD"
    }

    /// Lightweight rows after a game listing is cleared from the database (no fan chat text). Populated when server retention runs.
    private var analyticsPurgedHistorySection: some View {
        let currentYear = Calendar.current.component(.year, from: Date())
        return VStack(alignment: .leading, spacing: 10) {
            Text("Event History")
                .font(.headline.weight(.bold))

            Text("Review finished watch parties by season and month without the noise of live fan chat.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(alignment: .firstTextBaseline, spacing: 16) {
                Picker("Year", selection: $analyticsGameHistoryYear) {
                    ForEach((currentYear - 5)...(currentYear + 1), id: \.self) { y in
                        Text(String(y)).tag(y)
                    }
                }
                .pickerStyle(.menu)

                Picker("Month", selection: $analyticsGameHistoryMonth) {
                    Text("All months").tag(0)
                    ForEach(1...12, id: \.self) { m in
                        Text(monthShortName(m)).tag(m)
                    }
                }
                .pickerStyle(.menu)

                Spacer(minLength: 0)
            }

            Text("Watch parties this year: \(totalAnalyticsGameHistoryInYear)")
                .font(.caption.weight(.semibold))
            if analyticsGameHistoryMonth != 0 {
                Text("Selected month: \(analyticsGameHistoryInSelectedMonthCount)")
                    .font(.caption.weight(.semibold))
            }

            if !analyticsGameHistoryError.isEmpty {
                Text(analyticsGameHistoryError)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
            }

            if analyticsGameHistoryLoading && analyticsGameHistoryForYear.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading cleared-game history…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if viewModel.currentBusinessIdForAddLocation() == nil {
                Text("Link a business to this account to load past watch party summaries.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else if analyticsGameHistoryFiltered.isEmpty {
                Text("No past watch parties for this year yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 8) {
                    ForEach(analyticsGameHistoryFiltered) { row in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(row.event_title ?? "Game")
                                .font(.headline.weight(.semibold))
                            Text(formatHistorySchedule(row.scheduled_start_at))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            HStack(spacing: 6) {
                                Text(AppSportCatalog.displayLabel(forSportToken: row.sport ?? "—"))
                                    .font(.caption2.weight(.semibold))
                                Text("·")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Text(row.venue_name ?? "—")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .background(FGAdaptiveSurface.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                }
            }
        }
    }

    private var venueAnalyticsLiveOpsTaskKey: String {
        let sport = analyticsSportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        let venue = viewModel.ownerVenueDatabaseId?.uuidString ?? "all"
        return "\(venue)|\(sport)|\(analyticsGames.count)|\(analyticsHiddenEventIDs.count)"
    }

    private func venueAnalyticsLiveOpsSnapshot() -> VenueAnalyticsLiveOpsSnapshot {
        let activeGames = venueAnalyticsLiveOpsActiveGames()
        let next = activeGames.isEmpty ? venueAnalyticsLiveOpsNextOpportunity() : nil
        let activeGameCount = activeGames.count
        let activeChatCount = activeGames.reduce(0) { $0 + $1.chatCount }
        let crowdEnergy = activeGames.reduce(0) { $0 + $1.activityScore }
        let topSport = venueAnalyticsLiveOpsTopSport(from: activeGames)
        let status = venueAnalyticsLiveOpsStatus(
            activeGameCount: activeGameCount,
            crowdEnergy: crowdEnergy,
            chatCount: activeChatCount
        )
        let alerts = venueAnalyticsLiveOpsAlerts(activeGames: activeGames, nextOpportunity: next, topSport: topSport)

        return VenueAnalyticsLiveOpsSnapshot(
            activeGames: activeGames,
            nextOpportunity: next,
            alerts: alerts,
            activeGameCount: activeGameCount,
            activeChatCount: activeChatCount,
            crowdEnergy: crowdEnergy,
            topLiveSport: topSport,
            statusText: status,
            momentumTrend: crowdInsightsTrendLine()
        )
    }

    private func venueAnalyticsLiveOpsRows(includeUpcoming: Bool = false) -> [VenueEventRow] {
        var rows = analyticsGames.filter { row in
            guard let id = row.id else { return false }
            guard !analyticsHiddenEventIDs.contains(id) else { return false }
            guard !venueAnalyticsLiveOpsIsCancelled(row) else { return false }
            return true
        }

        let sport = analyticsSportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if sport != "All" {
            rows = rows.filter { ($0.sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == sport }
        }

        if includeUpcoming {
            return rows.filter { row in
                venueAnalyticsLiveOpsIsActiveNow(row) || venueAnalyticsLiveOpsIsUpcoming(row)
            }
        }

        return rows.filter { venueAnalyticsLiveOpsIsActiveNow($0) }
    }

    private func venueAnalyticsLiveOpsActiveGames() -> [VenueAnalyticsLiveOpsGame] {
        venueAnalyticsLiveOpsRows()
            .compactMap { liveOpsGame(from: $0, isActiveNow: true) }
            .sorted { lhs, rhs in
                if lhs.activityScore != rhs.activityScore { return lhs.activityScore > rhs.activityScore }
                return (lhs.startDate ?? .distantFuture) < (rhs.startDate ?? .distantFuture)
            }
    }

    private func venueAnalyticsLiveOpsNextOpportunity() -> VenueAnalyticsLiveOpsGame? {
        venueAnalyticsLiveOpsRows(includeUpcoming: true)
            .filter { venueAnalyticsLiveOpsIsUpcoming($0) }
            .compactMap { liveOpsGame(from: $0, isActiveNow: false) }
            .sorted {
                ($0.startDate ?? .distantFuture) < ($1.startDate ?? .distantFuture)
            }
            .first
    }

    private func liveOpsGame(from row: VenueEventRow, isActiveNow: Bool) -> VenueAnalyticsLiveOpsGame? {
        guard let eventID = row.id else { return nil }
        let titleRaw = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sportRaw = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let score = engagementScore(for: row)
        let interested = viewModel.interestCountForVenueEvent(eventID)
        let chats = fanUpdatesStore.venueEventComments[eventID]?.count ?? 0
        let vibes = vibeTotal(for: row)
        let activity = max(0, score) + interested + chats + vibes
        let status = isActiveNow
            ? venueAnalyticsLiveOpsGameStatus(momentumScore: score, interested: interested, chats: chats, vibes: vibes)
            : "Ready for fans"

        return VenueAnalyticsLiveOpsGame(
            id: eventID.uuidString.lowercased(),
            eventID: eventID,
            row: row,
            title: titleRaw.isEmpty ? "Watch party" : titleRaw,
            sport: sportRaw.isEmpty ? "Sports" : sportRaw,
            startDate: venueAnalyticsEventStartDate(row),
            scheduleText: venueAnalyticsLiveOpsScheduleText(for: row, isActiveNow: isActiveNow),
            statusText: status,
            momentumScore: score,
            interestedCount: interested,
            chatCount: chats,
            vibeCount: vibes,
            activityScore: activity,
            isActiveNow: isActiveNow
        )
    }

    private func venueAnalyticsLiveOpsScheduleText(for row: VenueEventRow, isActiveNow: Bool) -> String {
        guard let start = venueAnalyticsEventStartDate(row) else {
            return basicAnalyticsScheduleLine(for: row)
        }
        if isActiveNow {
            return "Started \(start.formatted(date: .omitted, time: .shortened))"
        }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    private func venueAnalyticsLiveOpsIsCancelled(_ row: VenueEventRow) -> Bool {
        let status = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return status == "archived"
            || status == "cancelled"
            || status == "canceled"
            || status == "rejected"
            || status == "removed"
            || status == "deleted"
    }

    private func venueAnalyticsLiveOpsIsActiveNow(_ row: VenueEventRow, now: Date = Date()) -> Bool {
        guard !venueAnalyticsLiveOpsIsCancelled(row) else { return false }
        guard VenueGameExpiration.isActiveOnDiscoverSurfaces(row: row, now: now) else { return false }
        guard let start = venueAnalyticsEventStartDate(row) else {
            return isGameLiveToday(row)
        }
        guard now >= start else { return false }
        guard let end = VenueGameExpiration.purgeAfterDate(for: row, now: now) else {
            return Calendar.current.isDateInToday(start)
        }
        return now < end
    }

    private func venueAnalyticsLiveOpsIsUpcoming(_ row: VenueEventRow, now: Date = Date()) -> Bool {
        guard !venueAnalyticsLiveOpsIsCancelled(row) else { return false }
        guard let start = venueAnalyticsEventStartDate(row) else { return false }
        return start > now
    }

    private func venueAnalyticsLiveOpsGameStatus(
        momentumScore: Int,
        interested: Int,
        chats: Int,
        vibes: Int
    ) -> String {
        if momentumScore >= 35 || interested >= 25 || chats >= 12 || vibes >= 12 { return "High Activity" }
        if interested >= 12 || chats >= 5 || vibes >= 6 { return "Crowd Building" }
        if momentumScore >= 10 || interested > 0 || chats > 0 || vibes > 0 { return "Watch Party Active" }
        return "Quiet"
    }

    private func venueAnalyticsLiveOpsStatus(activeGameCount: Int, crowdEnergy: Int, chatCount: Int) -> String {
        guard activeGameCount > 0 else { return "Quiet right now" }
        if crowdEnergy >= 60 || chatCount >= 12 { return "High Activity" }
        if crowdEnergy >= 24 || chatCount >= 5 { return "Crowd Building" }
        if crowdEnergy > 0 { return "Moderate Activity" }
        return "Quiet Right Now"
    }

    private func venueAnalyticsLiveOpsTopSport(from games: [VenueAnalyticsLiveOpsGame]) -> String {
        var scores: [String: Int] = [:]
        for game in games {
            let sport = game.sport.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sport.isEmpty else { continue }
            scores[sport, default: 0] += max(1, game.activityScore)
        }
        guard let best = scores.max(by: { $0.value < $1.value })?.key else { return "None" }
        return AppSportCatalog.displayLabel(forSportToken: best)
    }

    private func venueAnalyticsLiveOpsAlerts(
        activeGames: [VenueAnalyticsLiveOpsGame],
        nextOpportunity: VenueAnalyticsLiveOpsGame?,
        topSport: String
    ) -> [String] {
        guard !activeGames.isEmpty else {
            if let nextOpportunity {
                return [
                    "No live activity detected right now",
                    "Next crowd opportunity: \(nextOpportunity.title)"
                ]
            }
            return ["No live activity detected right now"]
        }

        var alerts: [String] = []
        if let building = activeGames.first(where: { $0.statusText == "Crowd Building" || $0.statusText == "High Activity" }) {
            alerts.append("Crowd building for \(building.title)")
        }
        if topSport != "None" {
            alerts.append("\(topSport) is currently your most active sport")
        }
        if let chat = activeGames.first(where: { $0.chatCount > 0 }) {
            alerts.append("Chat activity is active for \(chat.title)")
        }
        if alerts.isEmpty {
            alerts.append("Watch party activity is live right now")
        }
        return Array(alerts.prefix(3))
    }

    private func liveOpsStatusTint(_ status: String) -> Color {
        let value = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("high") { return FGColor.accentGreen }
        if value.contains("building") { return FGColor.accentYellow }
        if value.contains("moderate") || value.contains("active") || value.contains("ready") { return FGColor.accentBlue }
        return FGColor.secondaryText(colorScheme)
    }

    private func refreshVenueAnalyticsLiveOpsEngagementOnly() async {
        let ids = await MainActor.run {
            venueAnalyticsLiveOpsRows(includeUpcoming: true)
                .compactMap(\.id)
                .prefix(40)
                .map { $0 }
        }

        guard !ids.isEmpty else { return }
        await viewModel.loadInterestCountsForVenueEventIDs(ids)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await viewModel.loadComments(for: id)
                    await viewModel.loadVibes(for: id)
                }
            }
        }
    }

    private func hottestAnalyticsGameRow(from rows: [VenueEventRow]) -> VenueEventRow? {
        rows
            .filter { analyticsEngagementSignal(for: $0) > 0 }
            .max { analyticsEngagementSignal(for: $0) < analyticsEngagementSignal(for: $1) }
    }

    private func globalTopVibeSummary(from rows: [VenueEventRow]) -> (label: String, total: Int)? {
        var totals: [String: Int] = [:]
        for row in rows {
            guard let id = row.id else { continue }
            let m = fanUpdatesStore.venueEventVibeCounts[id] ?? [:]
            for (k, v) in m {
                totals[k, default: 0] += v
            }
        }
        guard let best = totals.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return (venueOwnerVibeMetricLabel(best.key), best.value)
    }

    private func engagementScore(for row: VenueEventRow) -> Int {
        row.id.map { viewModel.venueOwnerEngagementScore(venueEventID: $0) } ?? 0
    }

    private func vibeTotal(for row: VenueEventRow) -> Int {
        guard let id = row.id else { return 0 }
        return fanUpdatesStore.venueEventVibeCounts[id]?.values.reduce(0, +) ?? 0
    }

    private func analyticsEngagementSignal(for row: VenueEventRow) -> Int {
        guard let id = row.id else { return 0 }
        let going = viewModel.interestCountForVenueEvent(id)
        let comments = fanUpdatesStore.venueEventComments[id]?.count ?? 0
        let vibes = fanUpdatesStore.venueEventVibeCounts[id]?.values.reduce(0, +) ?? 0
        return max(0, engagementScore(for: row)) + going + comments + vibes
    }

    private func totalFanDiscussions(_ rows: [VenueEventRow]) -> Int {
        rows.reduce(0) { total, row in
            guard let id = row.id else { return total }
            return total + (fanUpdatesStore.venueEventComments[id]?.count ?? 0)
        }
    }

    private func averageFansPerGame(_ rows: [VenueEventRow]) -> Int {
        guard !rows.isEmpty else { return 0 }
        let total = rows.reduce(0) { total, row in
            guard let id = row.id else { return total }
            return total + viewModel.interestCountForVenueEvent(id)
        }
        return Int((Double(total) / Double(rows.count)).rounded())
    }

    private func topSportName(_ rows: [VenueEventRow]) -> String {
        var scores: [String: Int] = [:]
        for row in rows {
            let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sport.isEmpty else { continue }
            let signal = analyticsEngagementSignal(for: row)
            guard signal > 0 else { continue }
            scores[sport, default: 0] += signal
        }
        return scores.max(by: { $0.value < $1.value })?.key ?? "Sports"
    }

    private func trendsTopSportsThisMonth() -> [VenueAnalyticsTrendSportSummary] {
        let calendar = Calendar.current
        let month = calendar.dateInterval(of: .month, for: Date())
        let rowsThisMonth = analyticsGames.filter { row in
            guard let month, let start = venueAnalyticsEventStartDate(row) else { return false }
            return month.contains(start)
        }
        let seed: [(sport: String, tint: Color)] = [
            ("Soccer", FGColor.accentGreen),
            ("Basketball", FGColor.accentBlue),
            ("Football", Color.purple)
        ]

        return seed
            .enumerated()
            .map { index, item in
                (
                    order: index,
                    summary: VenueAnalyticsTrendSportSummary(
                        sport: item.sport,
                        score: trendsEngagementScore(forSport: item.sport, in: rowsThisMonth),
                        tint: item.tint
                    )
                )
            }
            .sorted { lhs, rhs in
                if lhs.summary.score == rhs.summary.score { return lhs.order < rhs.order }
                return lhs.summary.score > rhs.summary.score
            }
            .map(\.summary)
    }

    private func trendsEngagementScore(forSport sport: String, in rows: [VenueEventRow]) -> Int {
        let target = sport.lowercased()
        return rows.reduce(0) { total, row in
            let rowSport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard rowSport == target || rowSport.contains(target) else { return total }
            return total + analyticsEngagementSignal(for: row)
        }
    }

    private func venueAnalyticsTopActiveSports(from rows: [VenueEventRow]) -> [VenueAnalyticsTrendSportSummary] {
        var scores: [String: Int] = [:]
        for row in rows {
            let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sport.isEmpty else { continue }
            let signal = analyticsEngagementSignal(for: row)
            guard signal > 0 else { continue }
            scores[sport, default: 0] += signal
        }

        let tints: [Color] = [
            FGColor.accentGreen,
            FGColor.accentBlue,
            Color.purple,
            FGColor.accentYellow
        ]

        return scores
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(4)
            .enumerated()
            .map { index, item in
                VenueAnalyticsTrendSportSummary(
                    sport: item.key,
                    score: item.value,
                    tint: tints[index % tints.count]
                )
            }
    }

    private func topSportEngagementSummary(_ rows: [VenueEventRow]) -> (sport: String, percent: Int, score: Int)? {
        var scores: [String: Int] = [:]
        for row in rows {
            let sport = row.sport?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !sport.isEmpty else { continue }
            let signal = analyticsEngagementSignal(for: row)
            guard signal > 0 else { continue }
            scores[sport, default: 0] += signal
        }
        let total = scores.values.reduce(0, +)
        guard total > 0, let best = scores.max(by: { $0.value < $1.value }) else { return nil }
        let percent = Int((Double(best.value) / Double(total) * 100).rounded())
        return (best.key, max(1, percent), best.value)
    }

    private func venueBusinessInsights(from rows: [VenueEventRow]) -> [VenueAnalyticsBusinessInsight] {
        var insights: [VenueAnalyticsBusinessInsight] = []

        if let window = bestPerformanceWindows(from: rows).first {
            insights.append(
                VenueAnalyticsBusinessInsight(
                    id: "best-window",
                    icon: "🕒",
                    title: "Best Hosting Window",
                    value: window.label,
                    subtitle: window.subtitle,
                    tint: FGColor.accentYellow
                )
            )
        }

        if let topSport = topSportEngagementSummary(rows) {
            insights.append(
                VenueAnalyticsBusinessInsight(
                    id: "highest-momentum",
                    icon: "🔥",
                    title: "Highest Fan Momentum",
                    value: "\(topSport.sport) watch parties",
                    subtitle: "\(topSport.percent)% of engagement",
                    tint: FGColor.accentGreen
                )
            )
        }

        if let conversation = mostDiscussedAnalyticsRow(from: rows) {
            insights.append(
                VenueAnalyticsBusinessInsight(
                    id: "active-conversations",
                    icon: "💬",
                    title: "Most Active Conversations",
                    value: conversation.title,
                    subtitle: "\(conversation.comments) fan chat",
                    tint: FGColor.accentBlue
                )
            )
        }

        if let fastest = hottestAnalyticsGameRow(from: rows) {
            let signal = analyticsEngagementSignal(for: fastest)
            guard signal > 0 else { return insights }
            insights.append(
                VenueAnalyticsBusinessInsight(
                    id: "fastest-growing",
                    icon: "⚡",
                    title: "Fastest Growing Event",
                    value: fastest.event_title?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? (fastest.event_title ?? "Watch party") : "Watch party",
                    subtitle: "\(signal) momentum",
                    tint: Color.purple
                )
            )
        }

        return insights
    }

    private func mostDiscussedAnalyticsRow(from rows: [VenueEventRow]) -> (title: String, comments: Int)? {
        let best = rows.compactMap { row -> (title: String, comments: Int)? in
            guard let id = row.id else { return nil }
            let comments = fanUpdatesStore.venueEventComments[id]?.count ?? 0
            guard comments > 0 else { return nil }
            let title = row.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return (title.isEmpty ? "Watch party" : title, comments)
        }
        .max { $0.comments < $1.comments }

        return best
    }

    private func venueEngagementScore100(_ rows: [VenueEventRow]) -> Int {
        min(100, rows.reduce(0) { $0 + engagementScore(for: $1) })
    }

    private func engagementTrendValues(from rows: [VenueEventRow]) -> [Int] {
        let sorted = rows
            .compactMap { row -> (Date, Int)? in
                guard let start = venueAnalyticsEventStartDate(row) else { return nil }
                return (start, engagementScore(for: row))
            }
            .sorted { $0.0 < $1.0 }

        let values = sorted.suffix(8).map(\.1)
        if values.count >= 2 { return values }
        let score = venueEngagementScore100(rows)
        return [max(0, score - 8), score]
    }

    private func shouldShowEngagementSparkline(_ rows: [VenueEventRow]) -> Bool {
        engagementTrendValues(from: rows).count >= 3
    }

    private func crowdInsightsTrendLine() -> String {
        let calendar = Calendar.current
        guard let currentMonth = calendar.dateInterval(of: .month, for: Date()),
              let previousStart = calendar.date(byAdding: .month, value: -1, to: currentMonth.start),
              let previousMonth = calendar.dateInterval(of: .month, for: previousStart) else {
            return "This month"
        }
        let currentScore = analyticsScore(in: currentMonth)
        let previousScore = analyticsScore(in: previousMonth)
        if previousScore > 0 {
            let delta = Int(((Double(currentScore - previousScore) / Double(previousScore)) * 100).rounded())
            return "\(delta >= 0 ? "↑" : "↓") \(abs(delta))% this month"
        }
        if currentScore > 0 { return "New activity this month" }
        return "Ready for crowd growth"
    }

    private func crowdInsightsComparisonLine() -> String {
        let line = crowdInsightsTrendLine()
        if line.contains("this month") {
            return line.replacingOccurrences(of: "this month", with: "vs last month")
        }
        return line
    }

    private func crowdInsightsTrendTint() -> Color {
        crowdInsightsTrendLine().hasPrefix("↓") ? FGColor.dangerRed : FGColor.accentGreen
    }

    private func analyticsScore(in interval: DateInterval) -> Int {
        analyticsGames.reduce(0) { total, row in
            guard let start = venueAnalyticsEventStartDate(row), interval.contains(start) else { return total }
            return total + engagementScore(for: row)
        }
    }

    private func topPerformingLocations(from rows: [VenueEventRow]) -> [VenueAnalyticsLocationPerformance] {
        let managedVenueIDs = Set(viewModel.managedVenuesForOwner().compactMap(\.id))
        guard managedVenueIDs.count > 1 else { return [] }

        struct LocationStats {
            var name: String
            var score: Int = 0
            var going: Int = 0
            var comments: Int = 0
            var games: Int = 0
            var trendValues: [Int] = []
        }

        var statsByVenueID: [UUID: LocationStats] = [:]
        for row in rows {
            guard let venueID = row.venue_id else { continue }
            let name = row.venue_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var stats = statsByVenueID[venueID] ?? LocationStats(name: name.isEmpty ? "Venue" : name)
            stats.score += engagementScore(for: row)
            if let eventID = row.id {
                stats.going += viewModel.interestCountForVenueEvent(eventID)
                stats.comments += fanUpdatesStore.venueEventComments[eventID]?.count ?? 0
            }
            stats.trendValues.append(engagementScore(for: row))
            stats.games += 1
            statsByVenueID[venueID] = stats
        }

        return statsByVenueID
            .map { venueID, stats in
                let averageCrowd = stats.games > 0 ? stats.going / stats.games : 0
                let signal: String
                let tint: Color
                if stats.comments >= stats.going && stats.comments > 0 {
                    signal = "💬 Strongest fan chat"
                    tint = FGColor.accentBlue
                } else if averageCrowd >= 10 {
                    signal = "👥 Largest average crowd"
                    tint = FGColor.accentGreen
                } else {
                    signal = "🔥 Highest engagement"
                    tint = FGColor.accentYellow
                }
                let trendValues = stats.trendValues.count >= 2
                    ? Array(stats.trendValues.suffix(8))
                    : [max(0, stats.score - 8), stats.score]
                return VenueAnalyticsLocationPerformance(
                    id: venueID,
                    name: stats.name,
                    score: min(100, stats.score),
                    signal: signal,
                    trendValues: trendValues,
                    tint: tint
                )
            }
            .sorted { lhs, rhs in
                let lhsScore = statsByVenueID[lhs.id]?.score ?? 0
                let rhsScore = statsByVenueID[rhs.id]?.score ?? 0
                return lhsScore > rhsScore
            }
    }

    private func bestPerformanceWindows(from rows: [VenueEventRow]) -> [VenueAnalyticsPerformanceWindow] {
        var scores: [String: (label: String, score: Int)] = [:]
        for row in rows {
            guard let start = venueAnalyticsEventStartDate(row) else { continue }
            let label = Self.performanceWindowFormatter.string(from: start)
            let signal = analyticsEngagementSignal(for: row)
            guard signal > 0 else { continue }
            scores[label, default: (label: label, score: 0)].score += signal
        }
        return scores.values
            .filter { $0.score > 0 }
            .sorted { $0.score > $1.score }
            .prefix(2)
            .enumerated()
            .map { index, value in
                VenueAnalyticsPerformanceWindow(
                    id: value.label,
                    label: value.label,
                    subtitle: index == 0 ? "Highest engagement" : "Most active chat"
                )
            }
    }

    private func venueAnalyticsEventStartDate(_ row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id) {
            return start
        }
        guard let day = venueOwnerGameDay(row) else { return nil }
        let time = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !time.isEmpty else { return day }
        return Self.analyticsDateTimeFormatter.date(from: "\(Self.analyticsDayFormatter.string(from: day)) \(time)") ?? day
    }

    private func venueOwnerVibeMetricLabel(_ key: String) -> String {
        switch key {
        case "audio_on": return "🔊 Audio confirmed"
        case "packed": return "🔥 Packed"
        case "seats_open": return "🪑 Seats open"
        case "specials": return "🍺 Specials / drinks"
        case "tv_visible": return "📺 TVs visible"
        default: return key.replacingOccurrences(of: "_", with: " ")
        }
    }

    private func isGameLiveToday(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        return Calendar.current.isDateInToday(d)
    }

    private func venueOwnerGameDay(_ row: VenueEventRow) -> Date? {
        guard let s = row.event_date else { return nil }
        let f = DateFormatter()
        f.calendar = Calendar.current
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s)
    }

    private static let analyticsDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let analyticsDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        return formatter
    }()

    private static let analyticsShortWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE"
        return formatter
    }()

    private static let analyticsWeekdayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEEE"
        return formatter
    }()

    private static let analyticsMonthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM d"
        return formatter
    }()

    private static let analyticsShortMonthFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "MMM"
        return formatter
    }()

    private static let performanceWindowFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE • h a"
        return formatter
    }()

    /// Wide date window for the analytics pool (client-side filters narrow further). Capped for performance.
    private static func venueAnalyticsGamesLoadingPool(_ rows: [VenueEventRow]) -> [VenueEventRow] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let windowStart = cal.date(byAdding: .day, value: -1095, to: today),
              let windowEnd = cal.date(byAdding: .day, value: 548, to: today)
        else {
            return rows.filter { $0.id != nil }
        }
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"

        return rows.filter { row in
            guard row.id != nil else { return false }
            guard let ds = row.event_date, let d = fmt.date(from: ds) else { return true }
            let day = cal.startOfDay(for: d)
            return day >= windowStart && day <= windowEnd
        }
    }

    private static func sortVenueAnalyticsEventsByDateDescending(_ rows: [VenueEventRow]) -> [VenueEventRow] {
        let cal = Calendar.current
        let fmt = DateFormatter()
        fmt.calendar = cal
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        return rows.sorted { a, b in
            let da: Date
            if let s = a.event_date, let d = fmt.date(from: s) { da = cal.startOfDay(for: d) } else { da = .distantPast }
            let db: Date
            if let s = b.event_date, let d = fmt.date(from: s) { db = cal.startOfDay(for: d) } else { db = .distantPast }
            if da != db { return da > db }
            return (a.event_title ?? "") < (b.event_title ?? "")
        }
    }

    private func displayedVenueAnalyticsGames() -> [VenueEventRow] {
        var rows = analyticsGames.filter { row in
            guard let id = row.id else { return false }
            return !analyticsHiddenEventIDs.contains(id)
        }

        let sport = analyticsSportFilter.trimmingCharacters(in: .whitespacesAndNewlines)
        if sport != "All" {
            rows = rows.filter { ($0.sport ?? "").trimmingCharacters(in: .whitespacesAndNewlines) == sport }
        }

        switch analyticsDatePreset {
        case .thisWeek:
            rows = rows.filter { gameDayMatchesThisWeek($0) }
        case .thisMonth:
            rows = rows.filter { gameDayMatchesThisMonth($0) }
        case .thisYear:
            rows = rows.filter { gameDayMatchesThisYear($0) }
        }

        return rows
    }

    /// Rows shown as cards in Crowd Insights.
    private func displayedVenueAnalyticsGamesForCards() -> (rows: [VenueEventRow], isCapped: Bool) {
        let full = displayedVenueAnalyticsGames()
        return (full, false)
    }

    private func gameDayMatchesThisWeek(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .weekOfYear)
    }

    private func gameDayIsUpcoming(_ row: VenueEventRow) -> Bool {
        guard let start = venueAnalyticsEventStartDate(row) else { return false }
        return start >= Date()
    }

    private func gameDayMatchesThisMonth(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .month)
    }

    private func gameDayMatchesThisYear(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        return Calendar.current.isDate(d, equalTo: Date(), toGranularity: .year)
    }

    private func gameDayMatchesCustomRange(_ row: VenueEventRow) -> Bool {
        guard let d = venueOwnerGameDay(row) else { return false }
        let cal = Calendar.current
        let start = cal.startOfDay(for: analyticsCustomStart)
        let end = cal.startOfDay(for: analyticsCustomEnd)
        let day = cal.startOfDay(for: d)
        let rangeEnd = max(start, end)
        let rangeStart = min(start, end)
        return day >= rangeStart && day <= rangeEnd
    }

    private func hideVenueEventFromAnalytics(_ eventID: UUID) {
        analyticsHiddenEventIDs.insert(eventID)
        analyticsDetailSelection = nil
        let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        if !email.isEmpty || viewModel.ownerVenueDatabaseId != nil {
            VenueOwnerAnalyticsHiddenEventsLocalStore.save(
                ownerEmail: email,
                venueDatabaseId: viewModel.ownerVenueDatabaseId,
                ids: analyticsHiddenEventIDs
            )
        }
        Task { await refreshVenueAnalyticsFilteredEngagementOnly() }
    }

    private func refreshVenueAnalyticsFilteredEngagementOnly() async {
        let displayed = await MainActor.run { displayedVenueAnalyticsGamesForCards().rows }
        let ids = displayed.compactMap(\.id)

        await viewModel.stopVenueOwnerAnalyticsRealtime()

        guard !ids.isEmpty else {
            await MainActor.run {
                logBusinessAnalyticsDebug("refreshEngagement skipped emptyIDs preset=\(analyticsDatePreset.rawValue) sport=\(analyticsSportFilter)")
            }
            return
        }

        await viewModel.loadInterestCountsForVenueEventIDs(ids)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await viewModel.loadComments(for: id)
                    await viewModel.loadVibes(for: id)
                }
            }
        }

        await viewModel.startVenueOwnerAnalyticsRealtime(trackedEventIDs: ids)
        await MainActor.run {
            logBusinessAnalyticsDebug("refreshEngagement trackedIDs=\(ids.count) preset=\(analyticsDatePreset.rawValue) sport=\(analyticsSportFilter)")
        }
    }

    private func loadVenueAnalytics() async {
        await viewModel.stopVenueOwnerAnalyticsRealtime()
        await MainActor.run {
            analyticsIsLoading = true
            logBusinessAnalyticsDebug("loadStart venue=\(viewModel.ownerVenueDatabaseId?.uuidString ?? "all")")
        }

        let rows = await viewModel.loadMyVenueGamesForAnalytics()
        let pool = Self.venueAnalyticsGamesLoadingPool(rows)
        let sorted = Self.sortVenueAnalyticsEventsByDateDescending(pool)
        let capped = Array(sorted.prefix(1500))

        await MainActor.run {
            let email = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
            if !email.isEmpty || viewModel.ownerVenueDatabaseId != nil {
                analyticsHiddenEventIDs = VenueOwnerAnalyticsHiddenEventsLocalStore.load(
                    ownerEmail: email,
                    venueDatabaseId: viewModel.ownerVenueDatabaseId
                )
            }
            analyticsGames = capped
        }

        await refreshVenueAnalyticsFilteredEngagementOnly()

        await MainActor.run {
            analyticsIsLoading = false
            logBusinessAnalyticsDebug("loadComplete rows=\(rows.count) pool=\(pool.count) capped=\(capped.count) hidden=\(analyticsHiddenEventIDs.count)")
        }
    }

    private var analyticsGameHistoryTaskKey: String {
        let bid = viewModel.currentBusinessIdForAddLocation()?.uuidString ?? ""
        return "\(analyticsGameHistoryYear)-\(bid)-\(viewModel.ownerVenueDatabaseId?.uuidString ?? "")"
    }

    private var analyticsGameHistoryFiltered: [BusinessGameHistoryRow] {
        guard analyticsGameHistoryMonth >= 1, analyticsGameHistoryMonth <= 12 else { return analyticsGameHistoryForYear }
        let p = String(format: "%04d-%02d-", analyticsGameHistoryYear, analyticsGameHistoryMonth)
        return analyticsGameHistoryForYear.filter { ($0.scheduled_start_at ?? "").hasPrefix(p) }
    }

    private var totalAnalyticsGameHistoryInYear: Int { analyticsGameHistoryForYear.count }

    private var analyticsGameHistoryInSelectedMonthCount: Int {
        guard analyticsGameHistoryMonth >= 1, analyticsGameHistoryMonth <= 12 else { return 0 }
        return analyticsGameHistoryFiltered.count
    }

    private var gamesSection: some View {
        manageGamesTabbedExperience
    }

    private var manageGamesTabbedExperience: some View {
        manageGamesTabbedCard
            .onAppear {
#if DEBUG
                print("[ManageGamesDebug] manageGames onAppear ownerVenueId=\(viewModel.ownerVenueDatabaseId?.uuidString ?? "nil")")
#endif
                startManageGamesListRefresh()
                startAddGamePaneEntitlementRefreshIfNeeded()
            }
            .onChange(of: viewModel.ownerVenueDatabaseId) { _, _ in
                startManageGamesListRefresh()
            }
            .onChange(of: manageGamesListTab) { _, _ in
                startAddGamePaneEntitlementRefreshIfNeeded()
            }
            .confirmationDialog(
                "Cancel this game?",
                isPresented: $showCancelGameDialog,
                titleVisibility: .visible
            ) {
                Button("Remove Game", role: .destructive) {
                    guard let snap = cancelGameRowSnapshot else { return }
                    cancelGameRowSnapshot = nil
                    Task {
                        await performManageGameCancel(rowSnapshot: snap)
                    }
                }
                Button("Keep Game", role: .cancel) {
                    cancelGameRowSnapshot = nil
                }
            } message: {
                Text("This will remove the game from your venue schedule and FanGeo discovery.")
            }
            .sheet(item: $titleEditTarget) { target in
                titleEditSheet(for: target)
            }
            .sheet(isPresented: $showSchedulePicker) {
                VenueOwnerSchedulePickerSheet(
                    matches: viewModel.liveMatches,
                    isLoading: viewModel.isLoadingLiveMatches,
                    selectedDate: $schedulePickerDate,
                    onSelect: { choice in
                        applyScheduledGameChoice(choice)
                    }
                )
            }
    }

    private var manageGamesTabbedCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if selectedVenuePlanLocked {
                venuePlanLockedExplainerCard()
            }

            manageGamesTabStrip
            manageGamesStatusBanners

            manageGamesSelectedPane
        }
        .padding()
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
        )
    }

    private var manageGamesTabStrip: some View {
        HStack(spacing: 8) {
            manageGamesTabButton(title: "Scheduled", tab: .scheduled, isLocked: false)
            manageGamesTabButton(
                title: "Add Game",
                tab: .add,
                isLocked: false
            )
        }
    }

    @ViewBuilder
    private var manageGamesStatusBanners: some View {
        if !manageGamesFeedback.isEmpty {
            Text(manageGamesFeedback)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.green)
        }
        if !manageGamesError.isEmpty {
            Text(manageGamesError)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.red)
#if DEBUG
            if !manageGamesDebugErrorDetails.isEmpty {
                Text(manageGamesDebugErrorDetails)
                    .font(.caption2.monospaced())
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FGAdaptiveSurface.controlFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(0.45), lineWidth: 1)
                    }
            }
#endif
        }
    }

    @ViewBuilder
    private var manageGamesSelectedPane: some View {
        switch manageGamesListTab {
        case .scheduled:
            manageGamesListPane
        case .add:
            addGamePane
        }
    }

    private func titleEditSheet(for target: VenueOwnerGameTitleEditTarget) -> some View {
        let isManual = target.isManualHostedGame
        let showsTeamFields = titleEditShowsTeamFields(for: target)
        let usesParticipantLabels = titleEditUsesParticipantLabels(for: target)
        let validationMessage = titleEditValidationMessage(for: target)

        return NavigationStack {
            Form {
                Section {
                    TextField("Event title", text: $titleEditDraft)
                        .textInputAutocapitalization(.words)

                    if showsTeamFields {
                        TextField(usesParticipantLabels ? "Player 1" : "Team 1", text: $titleEditTeam1Draft)
                            .textInputAutocapitalization(.words)
                        TextField(usesParticipantLabels ? "Player 2" : "Team 2", text: $titleEditTeam2Draft)
                            .textInputAutocapitalization(.words)
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.dangerRed)
                    }
                } footer: {
                    Text(isManual
                         ? "You can update the internal title and the teams or players fans see. Sport, date, and time stay locked."
                         : "This is the title fans see for your watch party. The sport, teams, date, and time stay locked.")
                }
            }
            .navigationTitle(isManual ? "Edit Event Details" : "Edit Event Title")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { titleEditTarget = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            await saveTitleEdit(target: target)
                        }
                    }
                    .disabled(validationMessage != nil || titleEditDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func titleEditShowsTeamFields(for target: VenueOwnerGameTitleEditTarget) -> Bool {
        guard target.isManualHostedGame else { return false }
        let sport = target.row.sport ?? ""
        return Self.hostedGameRequiresTeamMatchup(sport)
            || Self.hostedGameSupportsOptionalParticipantMatchup(sport)
    }

    private func titleEditUsesParticipantLabels(for target: VenueOwnerGameTitleEditTarget) -> Bool {
        Self.hostedGameUsesPlayerCompetitors(target.row.sport ?? "")
    }

    private func titleEditValidationMessage(for target: VenueOwnerGameTitleEditTarget) -> String? {
        guard titleEditShowsTeamFields(for: target) else { return nil }

        let team1 = titleEditTeam1Draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let team2 = titleEditTeam2Draft.trimmingCharacters(in: .whitespacesAndNewlines)

        if Self.hostedGameRequiresTeamMatchup(target.row.sport ?? ""), team1.isEmpty || team2.isEmpty {
            return titleEditUsesParticipantLabels(for: target)
                ? "Add both players so fans can see the matchup."
                : manualPredictionTeamValidationMessage
        }

        if !team1.isEmpty,
           !team2.isEmpty,
           team1.localizedCaseInsensitiveCompare(team2) == .orderedSame {
            return titleEditUsesParticipantLabels(for: target)
                ? "Player 1 and Player 2 must be different."
                : "Team 1 and Team 2 must be different."
        }

        return nil
    }

    private func saveTitleEdit(target: VenueOwnerGameTitleEditTarget) async {
        let allowsTeamEdits = titleEditShowsTeamFields(for: target)
        let err = await viewModel.updateVenueGameEventDetails(
            id: target.id,
            newTitle: titleEditDraft,
            homeTeam: allowsTeamEdits ? titleEditTeam1Draft : nil,
            awayTeam: allowsTeamEdits ? titleEditTeam2Draft : nil,
            allowTeamEdits: allowsTeamEdits
        )

        await MainActor.run {
            if let err {
                manageGamesError = err
                manageGamesFeedback = ""
            } else {
                manageGamesError = ""
                manageGamesFeedback = target.isManualHostedGame ? "Event details updated." : "Title updated."
                titleEditTarget = nil
            }
        }

        if err == nil {
            await refreshManageGamesList(isInitialPick: false)
        }
    }

    private func manageGamesTabButton(title: String, tab: ManageGamesListTab, isLocked: Bool) -> some View {
        let isSelected = manageGamesListTab == tab
        return Button {
#if DEBUG
            print("[ManageGamesDebug] manageGamesListTab tapped \(tab.rawValue) locked=\(isLocked)")
#endif
            guard !isLocked else {
                manageGamesFeedback = ""
                manageGamesError = selectedVenuePlanLocked
                    ? BusinessLimitCopy.planLockedVenueHostedGameBlocked
                    : BusinessLimitCopy.hostedGameLimitReached
                if !selectedVenuePlanLocked {
                    showBusinessUsageSheet = true
                }
                return
            }
            guard manageGamesListTab != tab else { return }
            manageGamesListTab = tab
            if tab == .add {
                initializeAddGameScheduleFromDefaults()
            }
        } label: {
            HStack(spacing: 6) {
                if isLocked {
                    Image(systemName: "lock.fill")
                        .font(.caption2.weight(.bold))
                }
                Text(title)
                    .font(.caption.weight(.bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background(
                isSelected
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(FGAdaptiveSurface.capsuleUnselected)
            )
            .foregroundStyle(isSelected ? Color.white : (isLocked ? FGColor.secondaryText(colorScheme) : FGColor.primaryText(colorScheme)))
            .clipShape(Capsule(style: .continuous))
            .opacity(isLocked ? 0.62 : 1)
        }
        .buttonStyle(.plain)
    }

    private var manageGamesListPane: some View {
        manageGamesListPaneContent
            .onAppear {
#if DEBUG
                print("[ManageGamesDebug] scheduled games list pane appear rows=\(myVenueGamesForManage.count) loading=\(manageGamesListLoading)")
#endif
            }
            .onDisappear {
#if DEBUG
                print("[ManageGamesDebug] scheduled games list pane disappear")
#endif
            }
    }

    private var manageGamesListPaneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scheduled games")
                .font(.title2)
                .fontWeight(.bold)

            Text("Upcoming and recently started listings stay here until they automatically close 12 hours after kickoff.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let bizEmail = resolvedManageGamesBusinessContactEmail() {
                VenueGameBusinessContactEmailRow(email: bizEmail)
                    .padding(.top, 2)
                    .onAppear {
                        let src = myVenueGamesForManage.contains(where: { VenueGameBusinessEmail.resolvedDisplayEmail(forEvent: $0) != nil })
                            ? "venue_events.owner_email"
                            : "session_venue_owner_email"
                        VenueGameBusinessEmail.logDebug(
                            venueId: viewModel.ownerVenueDatabaseId,
                            venueName: viewModel.ownerVenueName.trimmingCharacters(in: .whitespacesAndNewlines),
                            resolvedBusinessEmail: bizEmail,
                            source: src
                        )
                    }
            }

            if manageGamesListLoading && myVenueGamesForManage.isEmpty {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Loading games…")
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if myVenueGamesForManage.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No games yet")
                        .font(.headline)
                        .fontWeight(.bold)
                    Text("Host your first watch party and start building your local sports crowd.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button {
                        manageGamesListTab = .add
                        clearManageGamesBanners()
                    } label: {
                        Text("Add Game")
                            .fontWeight(.bold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.accentColor)
                            .foregroundStyle(.white)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
            } else {
                VStack(spacing: 10) {
                    ForEach(manageGamesIdentifiedRows) { item in
                        VenueOwnerManageGameRow(
                            viewModel: viewModel,
                            row: item.row,
                            eventID: item.id,
                            formattedDateTime: formattedManageGameDateTime(row: item.row),
                            statusLabel: derivedManageGameStatus(row: item.row),
                            goingCount: viewModel.interestCountForVenueEvent(item.id),
                            commentCount: fanUpdatesStore.venueEventComments[item.id]?.count ?? 0,
                            vibeTotal: aggregateVibeTotal(eventID: item.id),
                            onViewChat: {
                                businessGameChatTarget = VenueOwnerGameChatTarget(
                                    id: item.id,
                                    title: item.row.event_title ?? "Game Fan Chat"
                                )
                            },
                            onEditTitle: {
                                clearManageGamesBanners()
                                titleEditDraft = item.row.event_title ?? ""
                                titleEditTeam1Draft = item.row.home_team ?? ""
                                titleEditTeam2Draft = item.row.away_team ?? ""
                                titleEditTarget = VenueOwnerGameTitleEditTarget(id: item.id, row: item.row)
                            },
                            onCancel: {
                                clearManageGamesBanners()
                                guard item.row.id != nil else { return }
                                cancelGameRowSnapshot = item.row
                                showCancelGameDialog = true
                            }
                        )
                    }
                }
            }
        }
    }

    private var addGamePane: some View {
        addGamePaneContent(showsCreationModeControls: true)
            .onAppear {
                clearManageGamesErrorIfAddGameScheduleIsFutureValid()
                if Calendar.current.startOfDay(for: importGamesDate) != Calendar.current.startOfDay(for: gameDate) {
                    importGamesDate = gameDate
                }
#if DEBUG
                print("[ManageGamesAddPane] render")
                print("[BusinessGameImportDebug] selectedMode=\(gameCreationMode.rawValue)")
#endif
            }
            .onDisappear {
#if DEBUG
                print("[ManageGamesAddPane] disappear")
#endif
            }
    }

    private func addGamePaneContent(
        showsCreationModeControls: Bool,
        importPaneUsesLifecycle: Bool = true
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Game")
                .font(.title2)
                .fontWeight(.bold)

            Text("Tell fans what you’re showing. Same details as before — saved to your venue listing.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsCreationModeControls {
                gameCreationModePicker

                if gameCreationMode == .importLive {
                    if importPaneUsesLifecycle {
                        importFromLiveGamesPane
                    } else {
                        importFromLiveGamesPaneContent
                    }
                }
            }

            if !selectedVenueCanHostGames {
                Text(selectedVenuePlanLocked ? BusinessLimitCopy.planLockedVenueHostedGameBlocked : BusinessLimitCopy.hostedGameLimitReached)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(FGColor.dangerRed.opacity(colorScheme == .dark ? 0.16 : 0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }

            addGameFormFields
        }
    }

    private func startManageGamesListRefresh() {
        Task {
            await refreshManageGamesList(isInitialPick: !didPickInitialManageGamesTab)
        }
    }

    private func startAddGamePaneEntitlementRefreshIfNeeded() {
        guard manageGamesListTab == .add else { return }
        Task {
            await prepareAddGamePaneEntitlementsIfNeeded()
        }
    }

    private func prepareAddGamePaneEntitlementsIfNeeded() async {
        guard manageGamesListTab == .add else { return }
        await businessProEntitlement.prepare()
        businessMembershipStatus = await viewModel.businessVenueGamePostingStatus(
            storeKitBusinessProActive: businessProEntitlement.businessProActive
        )
    }

    private var manualGameRequiresStructuredTeams: Bool {
        gameCreationMode == .manual && Self.hostedGameRequiresTeamMatchup(viewModel.ownerVenuePrimarySport)
    }

    private var manualGameSupportsOptionalParticipants: Bool {
        gameCreationMode == .manual && Self.hostedGameSupportsOptionalParticipantMatchup(viewModel.ownerVenuePrimarySport)
    }

    private var manualGameUsesPlayerCompetitorLabels: Bool {
        gameCreationMode == .manual && Self.hostedGameUsesPlayerCompetitors(viewModel.ownerVenuePrimarySport)
    }

    private var manualGameShowsParticipantFields: Bool {
        manualGameRequiresStructuredTeams || manualGameSupportsOptionalParticipants
    }

    private var trimmedManualTeam1: String {
        gameTeam1.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedManualTeam2: String {
        gameTeam2.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var manualStructuredTeamsHaveBothTeams: Bool {
        !trimmedManualTeam1.isEmpty
            && !trimmedManualTeam2.isEmpty
    }

    private var manualStructuredTeamsAreDuplicate: Bool {
        manualStructuredTeamsHaveBothTeams
            && trimmedManualTeam1.localizedCaseInsensitiveCompare(trimmedManualTeam2) == .orderedSame
    }

    private var manualStructuredTeamsAreValid: Bool {
        manualStructuredTeamsHaveBothTeams && !manualStructuredTeamsAreDuplicate
    }

    private var manualOptionalParticipantFieldsAreValid: Bool {
        guard manualGameSupportsOptionalParticipants else { return true }
        let hasOneParticipant = !trimmedManualTeam1.isEmpty || !trimmedManualTeam2.isEmpty
        return !hasOneParticipant || manualStructuredTeamsAreValid
    }

    private var saveGameListingDisabled: Bool {
        isSavingNewGame
            || !selectedVenueCanHostGames
            || (manualGameRequiresStructuredTeams && !manualStructuredTeamsAreValid)
            || !manualOptionalParticipantFieldsAreValid
    }

    private var gameTitleBinding: Binding<String> {
        Binding(
            get: { gameTitle },
            set: { newValue in
                updateGameTitleFromManualEdit(newValue)
            }
        )
    }

    private static func hostedGameRequiresTeamMatchup(_ sport: String) -> Bool {
        VenueGameCompetitorDisplay.requiresCompetitors(for: sport)
    }

    private static func hostedGameSupportsOptionalParticipantMatchup(_ sport: String) -> Bool {
        false
    }

    private static func hostedGameUsesPlayerCompetitors(_ sport: String) -> Bool {
        VenueGameCompetitorDisplay.competitorMode(for: sport) == .player
    }

    private static func normalizedHostedGameMatchupSport(_ sport: String) -> String {
        VenueGameCompetitorDisplay.normalizedSportKey(sport)
    }

    private var gameCreationModePicker: some View {
        Picker("Game creation mode", selection: $gameCreationMode) {
            ForEach(BusinessGameCreationMode.allCases, id: \.self) { mode in
                Text(mode.rawValue).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: gameCreationMode) { _, newValue in
#if DEBUG
            print("[BusinessGameImportDebug] selectedMode=\(newValue.rawValue)")
#endif
            if newValue == .importLive {
                importGamesDate = gameDate
                importGamesBrowserExpanded = !importedFromAPI
                if importGamesBrowserExpanded {
                    Task { await fetchImportGames(forceRefresh: false) }
                }
            } else {
                clearImportedGameMetadata()
            }
        }
    }

    private var importFromLiveGamesPane: some View {
        importFromLiveGamesPaneContent
            .onAppear {
                if importGamesBrowserExpanded {
                    Task {
                        await fetchImportGames(forceRefresh: false)
                    }
                }
            }
    }

    private var importFromLiveGamesPaneContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Import From Live Games")
                        .font(.subheadline.weight(.bold))
                    Text("Pick a real game, then review and save it as a venue listing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if importedFromAPI && !importGamesBrowserExpanded {
                importedLiveGameSummaryCard
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                importLiveGamesBrowser
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.easeInOut(duration: 0.24), value: importGamesBrowserExpanded)
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.20), lineWidth: 1)
        )
    }

    private var importLiveGamesBrowser: some View {
        VStack(alignment: .leading, spacing: 12) {
            importGamesDateSelector

            importSportFilterChips

            if isLoadingImportGames {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading live/API games...")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if !importGamesError.isEmpty {
                importMessageCard(
                    icon: "wifi.exclamationmark",
                    title: "Couldn’t load games",
                    message: "\(importGamesError) Manual Entry is still available."
                )
            } else if filteredImportMatches.isEmpty {
                importMessageCard(
                    icon: "calendar.badge.exclamationmark",
                    title: "No games found for this day.",
                    message: "You can still add one manually."
                )
            } else {
                VStack(spacing: 10) {
                    ForEach(filteredImportMatches) { match in
                        Button {
                            Task { await selectImportedLiveGame(match) }
                        } label: {
                            importedGameCard(match)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var importGamesDateSelector: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeInOut(duration: 0.20)) {
                    importGamesCalendarExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "calendar")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.orange)
                        .accessibilityHidden(true)

                    Text("Game day")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)

                    Spacer(minLength: 8)

                    Text(Self.dateFormatter.string(from: importGamesDate))
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(Color.orange)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12))
                        .clipShape(Capsule(style: .continuous))

                    Image(systemName: importGamesCalendarExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                }
                .padding()
                .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Select import game day")

            if importGamesCalendarExpanded {
                DatePicker(
                    "Game day",
                    selection: $importGamesDate,
                    in: minimumSelectableGameCalendarDate...Date.distantFuture,
                    displayedComponents: .date
                )
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
                .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .onChange(of: importGamesDate) { _, newDate in
#if DEBUG
            print("[BusinessGameImportDebug] selectedDate=\(Self.debugDateFormatter.string(from: newDate))")
#endif
            withAnimation(.easeInOut(duration: 0.20)) {
                importGamesCalendarExpanded = false
            }
            Task { await fetchImportGames(forceRefresh: true) }
        }
    }

    private var importedLiveGameSummaryCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.green.opacity(0.16))
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Color.green)
                }
                .frame(width: 42, height: 42)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 5) {
                    Text("Imported Game")
                        .font(.caption.weight(.heavy))
                        .textCase(.uppercase)
                        .foregroundStyle(Color.green)

                    Text(importedLiveGameSummaryTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    Text(importedLiveGameSummaryCompetitionLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text("\(Self.dateFormatter.string(from: gameStartTime)) • \(Self.timeFormatter.string(from: gameStartTime))")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)
            }

            Button {
                withAnimation(.easeInOut(duration: 0.24)) {
                    importGamesBrowserExpanded = true
                }
                if importGamesMatches.isEmpty {
                    Task { await fetchImportGames(forceRefresh: false) }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.caption.weight(.bold))
                    Text("Change Game")
                        .font(.caption.weight(.heavy))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.orange.opacity(0.14))
                .foregroundStyle(Color.orange)
                .clipShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.74))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.green.opacity(0.24), lineWidth: 1)
        )
    }

    private var importedLiveGameSummaryTitle: String {
        let title = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty { return title }

        let teams = [
            importedHomeTeam?.trimmingCharacters(in: .whitespacesAndNewlines),
            importedAwayTeam?.trimmingCharacters(in: .whitespacesAndNewlines)
        ]
        .compactMap { $0 }
        .filter { !$0.isEmpty }

        return teams.isEmpty ? "Imported game" : teams.joined(separator: " vs ")
    }

    private var importedLiveGameSummaryCompetitionLine: String {
        let sport = viewModel.ownerVenuePrimarySport.trimmingCharacters(in: .whitespacesAndNewlines)
        let league = gameLeague.trimmingCharacters(in: .whitespacesAndNewlines)
        let importedLeague = importedExternalLeague?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parts = [
            sport.isEmpty ? "Sports" : sport,
            !league.isEmpty ? league : importedLeague
        ].filter { !$0.isEmpty }

        return parts.joined(separator: " • ")
    }

    private var availableImportSports: [String] {
        var seen = Set<String>()
        return importGamesMatches.compactMap { match in
            let sport = Self.mappedVenueSport(for: match).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !sport.isEmpty, seen.insert(sport.lowercased()).inserted else { return nil }
            return sport
        }.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var filteredImportMatches: [LiveMatch] {
        importGamesMatches.filter { match in
            guard importGamesSportFilter != "All" else { return true }
            let mapped = Self.mappedVenueSport(for: match)
            return mapped.localizedCaseInsensitiveCompare(importGamesSportFilter) == .orderedSame
                || SportFilterCatalog.storedSport(mapped, matchesSearchQuery: importGamesSportFilter)
        }
    }

    private var importSportFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                importSportChip("All")
                ForEach(availableImportSports, id: \.self) { sport in
                    importSportChip(sport)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func importSportChip(_ sport: String) -> some View {
        let isSelected = importGamesSportFilter == sport
        return Button {
            importGamesSportFilter = sport
#if DEBUG
            print("[BusinessGameImportDebug] apiFetchStarted sport=\(sport)")
#endif
            Task { await fetchImportGames(forceRefresh: false) }
        } label: {
            Text(AppSportCatalog.displayLabel(forSportToken: sport))
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.orange : FGAdaptiveSurface.sheetRoot.opacity(0.72))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func importMessageCard(icon: String, title: String, message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.orange)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.bold))
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func importedGameCard(_ match: LiveMatch) -> some View {
        let sport = Self.mappedVenueSport(for: match)
        let status = VenueOwnerScheduledGameChoice(match: match).statusLabel
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(Self.importedGameTitle(for: match))
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 8)
                Text(status)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(match.matchStatus.isHappeningNow ? Color.green : Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((match.matchStatus.isHappeningNow ? Color.green : Color.orange).opacity(0.14))
                    .clipShape(Capsule(style: .continuous))
            }

            HStack(spacing: 6) {
                Text(AppSportCatalog.displayLabel(forSportToken: sport))
                    .font(.caption.weight(.semibold))
                Text("/")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(match.league)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Text("\(Self.dateFormatter.string(from: match.startTime)) at \(Self.timeFormatter.string(from: match.startTime))")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Text("Imported game")
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(Color.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.orange.opacity(0.12))
                    .clipShape(Capsule(style: .continuous))
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.34), lineWidth: 1)
        )
    }

    private var pickFromSportsScheduleCard: some View {
        Button {
            schedulePickerDate = gameDate
            showSchedulePicker = true
#if DEBUG
            print("[BusinessAddGameDebug] openSchedulePicker=true")
#endif
            Task { await viewModel.refreshLiveMatchesForCalendar(forceRefresh: false) }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.14))
                    Image(systemName: "calendar.badge.clock")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 44, height: 44)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick from sports schedule")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text("Search upcoming and live games.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var manageGamesIdentifiedRows: [VenueOwnerIdentifiedVenueEvent] {
        myVenueGamesForManage.compactMap { row in
            guard let id = row.id else { return nil }
            return VenueOwnerIdentifiedVenueEvent(id: id, row: row)
        }
    }

    /// Business contact for Manage Games list: prefer `venue_events.owner_email`, else signed-in owner email.
    private func resolvedManageGamesBusinessContactEmail() -> String? {
        if let fromRow = myVenueGamesForManage.compactMap({ VenueGameBusinessEmail.resolvedDisplayEmail(forEvent: $0) }).first {
            return fromRow
        }
        let fb = OwnerBusinessEmail.normalized(viewModel.venueOwnerEmail)
        return OwnerBusinessEmail.isValidStrict(fb) ? fb : nil
    }

    private var minimumSelectableGameCalendarDate: Date {
        Calendar.current.startOfDay(for: Date())
    }

    private var endOfSelectedGameDate: Date {
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: gameDate)
        guard let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart) else {
            return gameDate
        }
        return nextDay.addingTimeInterval(-1)
    }

    private var startTimeLowerBoundForPicker: Date {
        let cal = Calendar.current
        let now = Date()
        let dayStart = cal.startOfDay(for: gameDate)
        if cal.compare(dayStart, to: cal.startOfDay(for: now), toGranularity: .day) == .orderedDescending {
            return dayStart
        }
        if cal.isDate(gameDate, inSameDayAs: now) {
            return max(now, dayStart)
        }
        return max(now, dayStart)
    }

    private var gameStartTimePickerClosedRange: ClosedRange<Date> {
        let lo = startTimeLowerBoundForPicker
        let hi = endOfSelectedGameDate
        if lo <= hi { return lo...hi }
        return lo...lo.addingTimeInterval(60)
    }

    private var addGameFormFields: some View {
        Group {
            field("Event title, example: World Cup Watch Party", text: gameTitleBinding)
                .id(DashboardScrollTarget.addGameFormFields)
                .onAppear {
#if DEBUG
                    print("[ManageGamesAddPane] title appear")
#endif
                }
            Text("Internal listing title. Fans will see the teams/players on the game card.")
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

            Group {
                DatePicker(
                    "Game Date",
                    selection: $gameDate,
                    in: minimumSelectableGameCalendarDate...Date.distantFuture,
                    displayedComponents: .date
                )
                .fontWeight(.semibold)
                .padding()
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))

                DatePicker(
                    "Start Time",
                    selection: $gameStartTime,
                    in: gameStartTimePickerClosedRange,
                    displayedComponents: .hourAndMinute
                )
                .fontWeight(.semibold)
                .padding()
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))
            }
            .onChange(of: gameDate) { oldDate, newDate in
                let cal = Calendar.current
                let sodOld = cal.startOfDay(for: oldDate)
                let sodNew = cal.startOfDay(for: newDate)
                guard sodOld != sodNew else { return }
                let before = gameStartTime
                let now = Date()
                let after = VenueOwnerGameScheduleValidation.recommendedStartTimeAfterGameDateChange(
                    newGameDate: newDate,
                    now: now,
                    calendar: cal
                )
                gameStartTime = after
                manageGamesError = ""
#if DEBUG
                VenueOwnerGameScheduleValidation.logBusinessAddGameTimeDateChange(
                    oldGameDate: oldDate,
                    newGameDate: newDate,
                    startTimeBefore: before,
                    startTimeAfter: after,
                    now: now,
                    calendar: cal
                )
#endif
            }
            .onChange(of: gameStartTime) { _, _ in
                clearManageGamesErrorIfAddGameScheduleIsFutureValid()
            }
            .onAppear {
#if DEBUG
                print("[ManageGamesAddPane] date picker appear")
#endif
            }

            GameSportSearchablePickerDashboardCard(selection: $viewModel.ownerVenuePrimarySport)
                .onAppear {
#if DEBUG
                    print("[ManageGamesAddPane] sport appear")
#endif
                    logBusinessManualGameTeamDebug()
                }
                .onChange(of: viewModel.ownerVenuePrimarySport) { _, _ in
                    handleManualGamePredictionSportChanged()
                }

            if manualGameShowsParticipantFields {
                manualStructuredTeamsFields
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if manualGameRequiresStructuredTeams && !manualStructuredTeamsHaveBothTeams {
                Text(manualPredictionCompetitorValidationMessage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }

            if manualGameSupportsOptionalParticipants
                && !manualOptionalParticipantFieldsAreValid
                && !manualStructuredTeamsAreDuplicate {
                Text("Add both participants to show a matchup, or leave both blank.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }

            if manualGameShowsParticipantFields && manualStructuredTeamsAreDuplicate {
                Text(manualGameUsesPlayerCompetitorLabels ? "Player 1 and Player 2 must be different." : "Team 1 and Team 2 must be different.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.dangerRed)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }

            field("League / competition (optional)", text: $gameLeague)

            addGameCleanupDelayCard

            if hostedGameCycleLimitReachedForRegularBusiness {
                hostedGameLimitUpgradeCTA
            } else {
                Button {
#if DEBUG
                    print("[ManageGamesAddPane] save tapped")
#endif
                    Task {
                        await saveNewVenueGameFromForm()
                    }
                } label: {
                    primaryButtonText("Save Game Listing")
                }
                .overlay {
                    if isSavingNewGame {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(FGAdaptiveSurface.sheetRoot.opacity(0.55))
                        ProgressView()
                            .tint(.primary)
                    }
                }
                .disabled(saveGameListingDisabled)
            }
        }
    }

    private var hostedGameLimitUpgradeCTA: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(hostedGameCycleUsageContextText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                manageGamesFeedback = ""
                manageGamesError = BusinessLimitCopy.hostedGameLimitReached
                showBusinessProSubscriptionSheet = true
            } label: {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("🔒 Upgrade to FanGeo Pro")
                            .font(.headline.weight(.black))
                        Text("Unlimited hosted games")
                            .font(.caption.weight(.bold))
                            .opacity(0.88)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "crown.fill")
                        .font(.headline.weight(.black))
                }
                .foregroundStyle(colorScheme == .dark ? Color(red: 0.10, green: 0.07, blue: 0.02) : .white)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(
                        colors: [businessProGold, businessProGoldDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.24 : 0.42), lineWidth: 1)
                }
                .shadow(color: businessProGold.opacity(colorScheme == .dark ? 0.20 : 0.14), radius: 14, y: 6)
            }
            .buttonStyle(.plain)
        }
    }

    private var addGameCleanupDelayCard: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle()
                    .fill(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.20 : 0.12))
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(FGColor.accentGreen)
            }
            .frame(width: 34, height: 34)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                Text("This game will automatically close 12 hours after kickoff.")
                    .font(.subheadline.weight(.heavy))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Fan comments, vibes, and attendance cleanup happen automatically.")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .onAppear {
#if DEBUG
            print("[ManageGamesAddPane] cleanup appear")
#endif
        }
    }

    private var manualStructuredTeamsFields: some View {
        let labels = VenueGameCompetitorDisplay.competitorLabels(for: viewModel.ownerVenuePrimarySport)
        return VStack(alignment: .leading, spacing: 8) {
            ManualTeamAutocompleteView(
                title: labels.0,
                text: Binding(
                get: { gameTeam1 },
                set: { updateManualGameTeam1($0) }
                ),
                sportName: viewModel.ownerVenuePrimarySport,
                unavailableTeamName: trimmedManualTeam2,
                onTextChanged: { query in
                    updateManualGameTeam1(query)
                    logManualTeamAutocompleteQuery(query)
                },
                onSelection: { selection in
                    applyManualGameTeamSelection(selection, teamIndex: 1)
                }
            )

            ManualTeamAutocompleteView(
                title: labels.1,
                text: Binding(
                get: { gameTeam2 },
                set: { updateManualGameTeam2($0) }
                ),
                sportName: viewModel.ownerVenuePrimarySport,
                unavailableTeamName: trimmedManualTeam1,
                onTextChanged: { query in
                    updateManualGameTeam2(query)
                    logManualTeamAutocompleteQuery(query)
                },
                onSelection: { selection in
                    applyManualGameTeamSelection(selection, teamIndex: 2)
                }
            )
        }
        .onAppear {
            synchronizeManualGameTitleWithTeams()
            logBusinessManualGameTeamDebug()
        }
    }

    private func updateGameTitleFromManualEdit(_ newValue: String) {
        gameTitle = newValue
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let generated = lastGeneratedGameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        titleManuallyEdited = generated.isEmpty ? !trimmed.isEmpty : trimmed != generated
        logBusinessManualGameTeamDebug()
    }

    private func updateManualGameTeam1(_ newValue: String) {
        gameTeam1 = newValue
        gameTeam1Selection = ManualVenueTeamResolver.resolve(newValue)
        logManualGameCountryDetection(gameTeam1Selection)
        synchronizeManualGameTitleWithTeams()
    }

    private func updateManualGameTeam2(_ newValue: String) {
        gameTeam2 = newValue
        gameTeam2Selection = ManualVenueTeamResolver.resolve(newValue)
        logManualGameCountryDetection(gameTeam2Selection)
        synchronizeManualGameTitleWithTeams()
    }

    private func applyManualGameTeamSelection(_ selection: ManualVenueTeamSelection, teamIndex: Int) {
        let otherTeam = teamIndex == 1 ? trimmedManualTeam2 : trimmedManualTeam1
        guard otherTeam.isEmpty || selection.name.localizedCaseInsensitiveCompare(otherTeam) != .orderedSame else { return }
        if teamIndex == 1 {
            gameTeam1 = selection.name
            gameTeam1Selection = selection
        } else {
            gameTeam2 = selection.name
            gameTeam2Selection = selection
        }
#if DEBUG
        print("[BusinessManualGameDebug] teamSuggestionSelected name=\(selection.name) type=\(selection.type.rawValue)")
        if selection.type == .custom {
            print("[BusinessManualGameDebug] customTeamUsed=\(selection.name)")
        }
#endif
        logManualGameCountryDetection(selection)
        synchronizeManualGameTitleWithTeams()
    }

    private func logManualTeamAutocompleteQuery(_ query: String) {
#if DEBUG
        print("[BusinessManualGameDebug] teamAutocompleteQuery=\(query)")
#endif
    }

    private func logManualGameCountryDetection(_ selection: ManualVenueTeamSelection) {
#if DEBUG
        guard selection.type == .country, let code = selection.countryCode else { return }
        print("[BusinessManualGameDebug] countryDetected code=\(code)")
#endif
    }

    private func handleManualGamePredictionSportChanged() {
        synchronizeManualGameTitleWithTeams()
        logBusinessManualGameTeamDebug()
    }

    private func synchronizeManualGameTitleWithTeams() {
        let team1 = trimmedManualTeam1
        let team2 = trimmedManualTeam2
        let previousGenerated = lastGeneratedGameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard manualGameShowsParticipantFields, !team1.isEmpty, !team2.isEmpty else {
            logBusinessManualGameTeamDebug(generatedTitle: previousGenerated)
            return
        }

        let generated = "\(team1) vs \(team2)"
        let currentTitle = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSyncTitle = currentTitle.isEmpty
            || !titleManuallyEdited
            || (!previousGenerated.isEmpty && currentTitle == previousGenerated)

        lastGeneratedGameTitle = generated
        if shouldSyncTitle {
            gameTitle = generated
            titleManuallyEdited = false
        }

        logBusinessManualGameTeamDebug(generatedTitle: generated)
    }

    private func logBusinessManualGameTeamDebug(generatedTitle: String? = nil) {
#if DEBUG
        let generated = generatedTitle ?? lastGeneratedGameTitle
        print("[BusinessManualGameDebug] selectedSport=\(viewModel.ownerVenuePrimarySport)")
        print("[BusinessManualGameDebug] requiresTeams=\(manualGameRequiresStructuredTeams)")
        print("[BusinessManualGameDebug] team1=\(trimmedManualTeam1)")
        print("[BusinessManualGameDebug] team2=\(trimmedManualTeam2)")
        print("[BusinessManualGameDebug] team1Type=\(gameTeam1Selection.type.rawValue) countryCode=\(gameTeam1Selection.countryCode ?? "none")")
        print("[BusinessManualGameDebug] team2Type=\(gameTeam2Selection.type.rawValue) countryCode=\(gameTeam2Selection.countryCode ?? "none")")
        if gameTeam1Selection.type == .custom, !trimmedManualTeam1.isEmpty {
            print("[BusinessManualGameDebug] customTeamUsed=\(trimmedManualTeam1)")
        }
        if gameTeam2Selection.type == .custom, !trimmedManualTeam2.isEmpty {
            print("[BusinessManualGameDebug] customTeamUsed=\(trimmedManualTeam2)")
        }
        print("[BusinessManualGameDebug] generatedTitle=\(generated)")
        print("[BusinessManualGameDebug] titleManuallyEdited=\(titleManuallyEdited)")
#endif
    }

    private func logVenueGameCreationCompetitorDebug(validationPassed: Bool) {
#if DEBUG
        let labels = VenueGameCompetitorDisplay.competitorLabels(for: viewModel.ownerVenuePrimarySport)
        let mode = VenueGameCompetitorDisplay.competitorMode(for: viewModel.ownerVenuePrimarySport)
        print("[VenueGameCreationCompetitorDebug] sport=\(viewModel.ownerVenuePrimarySport), mode=\(mode.rawValue), label1=\(labels.0), label2=\(labels.1), value1=\(trimmedManualTeam1), value2=\(trimmedManualTeam2), validationPassed=\(validationPassed)")
#endif
    }

    private func clearManageGamesBanners() {
        manageGamesFeedback = ""
        manageGamesError = ""
#if DEBUG
        manageGamesDebugErrorDetails = ""
#endif
    }

    /// Add Game tab: today at start-of-day + default start time; clears schedule error.
    private func initializeAddGameScheduleFromDefaults() {
        let cal = Calendar.current
        let now = Date()
        gameDate = cal.startOfDay(for: now)
        gameStartTime = VenueOwnerGameScheduleValidation.recommendedStartTimeAfterGameDateChange(
            newGameDate: gameDate,
            now: now,
            calendar: cal
        )
        manageGamesError = ""
    }

    /// Clears the red schedule banner when the combined date+time is valid (not strictly before `now`).
    private func clearManageGamesErrorIfAddGameScheduleIsFutureValid() {
        let cal = Calendar.current
        let now = Date()
        if !VenueOwnerGameScheduleValidation.isPastSchedule(
            gameDate: gameDate,
            gameStartTime: gameStartTime,
            now: now,
            calendar: cal
        ) {
            manageGamesError = ""
        }
    }

    private func applyScheduledGameChoice(_ choice: VenueOwnerScheduledGameChoice) {
        gameTitle = choice.title
        gameTeam1 = choice.homeTeam
        gameTeam2 = choice.awayTeam
        gameTeam1Selection = ManualVenueTeamResolver.resolve(choice.homeTeam)
        gameTeam2Selection = ManualVenueTeamResolver.resolve(choice.awayTeam)
        lastGeneratedGameTitle = choice.title
        titleManuallyEdited = false
        viewModel.ownerVenuePrimarySport = choice.sport
        gameDate = Calendar.current.startOfDay(for: choice.startTime)
        gameStartTime = choice.startTime
        manageGamesError = ""
        showSchedulePicker = false
        synchronizeManualGameTitleWithTeams()
#if DEBUG
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        print("[BusinessAddGameDebug] selectedScheduledGameId=\(choice.id)")
        print("[BusinessAddGameDebug] autopopulatedTitle=\(choice.title)")
        print("[BusinessAddGameDebug] autopopulatedSport=\(choice.sport)")
        print("[BusinessAddGameDebug] autopopulatedStartTime=\(f.string(from: choice.startTime))")
        logBusinessManualGameTeamDebug(generatedTitle: choice.title)
#endif
    }

    private func fetchImportGames(forceRefresh: Bool) async {
        let snapshot = await MainActor.run {
            (
                date: importGamesDate,
                sport: importGamesSportFilter
            )
        }

#if DEBUG
        print("[BusinessGameImportDebug] selectedDate=\(Self.debugDateFormatter.string(from: snapshot.date))")
        print("[BusinessGameImportDebug] apiFetchStarted sport=\(snapshot.sport)")
#endif

        await MainActor.run {
            isLoadingImportGames = true
            importGamesError = ""
        }

        do {
            let matches = try await LiveSportsService.shared.fetchLiveMatches(
                on: snapshot.date,
                sportFilter: nil,
                forceRefresh: forceRefresh
            )
            await MainActor.run {
                importGamesMatches = matches
                if importGamesSportFilter != "All",
                   !availableImportSports.contains(where: { $0.localizedCaseInsensitiveCompare(importGamesSportFilter) == .orderedSame }) {
                    importGamesSportFilter = "All"
                }
                isLoadingImportGames = false
            }
#if DEBUG
            print("[BusinessGameImportDebug] apiFetchResult count=\(matches.count)")
#endif
        } catch {
            await MainActor.run {
                importGamesMatches = []
                importGamesError = error.localizedDescription
                isLoadingImportGames = false
            }
#if DEBUG
            print("[BusinessGameImportDebug] apiFetchResult count=0 error=\(error.localizedDescription)")
#endif
        }
    }

    private func selectImportedLiveGame(_ match: LiveMatch) async {
        let title = Self.importedGameTitle(for: match)
        let mappedSport = Self.mappedVenueSport(for: match)
        let externalSource = LiveSportsService.providerDescription
        let venueId = await MainActor.run { viewModel.ownerVenueDatabaseId }

#if DEBUG
        print("[BusinessGameImportDebug] selectedExternalGame id=\(match.id)")
#endif

        let duplicate = await viewModel.venueGameImportDuplicateExists(
            externalGameID: match.id,
            externalSource: externalSource,
            venueId: venueId,
            gameDate: match.startTime
        )
        guard !duplicate else {
            await MainActor.run {
                manageGamesError = "This game already exists for this venue."
                manageGamesFeedback = ""
            }
            return
        }

        await MainActor.run {
            gameTitle = title
            lastGeneratedGameTitle = title
            titleManuallyEdited = false
            viewModel.ownerVenuePrimarySport = mappedSport
            gameDate = Calendar.current.startOfDay(for: match.startTime)
            gameStartTime = match.startTime
            gameLeague = match.league
            gameTeam1 = match.homeTeam
            gameTeam2 = match.awayTeam
            gameTeam1Selection = ManualVenueTeamResolver.resolve(match.homeTeam)
            gameTeam2Selection = ManualVenueTeamResolver.resolve(match.awayTeam)
            importedExternalGameID = match.id
            importedExternalSource = externalSource
            importedExternalLeague = match.league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : match.league
            importedHomeTeam = match.homeTeam
            importedAwayTeam = match.awayTeam
            importedFromAPI = true
            importGamesBrowserExpanded = false
            importGamesCalendarExpanded = false
            addGameFormScrollRequestID += 1
            manageGamesError = ""
            manageGamesFeedback = "Game details imported — review and save."
        }

#if DEBUG
        print("[BusinessGameImportDebug] populatedTitle=\(title)")
#endif
    }

    nonisolated fileprivate static func importedGameTitle(for match: LiveMatch) -> String {
        let home = match.homeTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        let away = match.awayTeam.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty, !away.isEmpty { return "\(home) vs \(away)" }
        return [home, away].filter { !$0.isEmpty }.joined(separator: " vs ")
    }

    nonisolated fileprivate static func mappedVenueSport(for match: LiveMatch) -> String {
        let direct = match.sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let visual = LiveSportVisualType.normalize(direct)
        switch visual {
        case .basketball:
            return "NBA"
        case .nfl:
            return "NFL"
        case .hockey:
            return "NHL"
        case .baseball:
            return "Baseball"
        case .soccer:
            return "Soccer"
        case .tennis:
            return "Tennis"
        case .badminton:
            return "badminton"
        case .golf:
            return "Golf"
        case .formula1:
            return "Formula 1"
        case .breakdance:
            return "Break Dance"
        case .ballet:
            return "Ballet"
        case .other:
            return direct.isEmpty ? "Sports" : direct
        }
    }

    /// Clears add/list transient UI when the owner switches managed location (see ``MapViewModel/ownerVenueDatabaseId``).
    private func clearManageGamesTransientStateForVenueSwitch() {
        clearManageGamesBanners()
        isSavingNewGame = false
        titleEditTarget = nil
        showCancelGameDialog = false
        cancelGameRowSnapshot = nil
        didPickInitialManageGamesTab = false
        manageGamesRefreshInFlight = false
        manageGamesListLoading = false
        gameCreationMode = .manual
        importGamesMatches = []
        importGamesError = ""
        clearImportedGameMetadata()
#if DEBUG
        print("[BusinessGameState] cleared transient game state for venue switch")
#endif
    }

    private func clearAnalyticsGameHistoryState() {
        analyticsGameHistoryForYear = []
        analyticsGameHistoryError = ""
        analyticsGameHistoryLoading = false
        businessVenueAnalyticsTab = .venueAnalytics
    }

    private static func venueEventManageListSortKey(_ r: VenueEventRow) -> String {
        if let s = r.scheduled_start_at?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty {
            return s
        }
        let d = r.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let t = r.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = r.event_title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return "\(d)|\(t)|\(title)"
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private func performManageGameCancel(rowSnapshot: VenueEventRow) async {
        await MainActor.run {
            myVenueGamesForManage.removeAll { $0.id == rowSnapshot.id }
            manageGamesFeedback = "Game cancelled"
            manageGamesError = ""
        }

        let err = await viewModel.deleteVenueGame(rowSnapshot)

        await MainActor.run {
            if let err {
                if !myVenueGamesForManage.contains(where: { $0.id == rowSnapshot.id }) {
                    myVenueGamesForManage.append(rowSnapshot)
                    myVenueGamesForManage.sort { Self.venueEventManageListSortKey($0) < Self.venueEventManageListSortKey($1) }
                }
                manageGamesError = err
                manageGamesFeedback = ""
            } else {
                manageGamesError = ""
                manageGamesFeedback = "Game cancelled."
                Task {
                    await refreshManageGamesList(isInitialPick: false)
                }
            }
        }
    }

    private func refreshManageGamesList(isInitialPick: Bool) async {
        let entered = await MainActor.run { () -> Bool in
            guard !manageGamesRefreshInFlight else { return false }
            manageGamesRefreshInFlight = true
            manageGamesListLoading = true
            return true
        }
        guard entered else {
#if DEBUG
            print("[ManageGamesDebug] refreshManageGamesList skipped (already in flight) isInitialPick=\(isInitialPick)")
#endif
            return
        }

#if DEBUG
        print("[ManageGamesDebug] refreshManageGamesList begin isInitialPick=\(isInitialPick)")
#endif

        let rows = await viewModel.loadMyVenueScheduledGames()
#if DEBUG
        print("[ManageGamesDebug] loadMyVenueScheduledGames returned count=\(rows.count)")
#endif
        let ids = rows.compactMap(\.id)
        await viewModel.loadInterestCountsForVenueEventIDs(ids)
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask {
                    await viewModel.loadComments(for: id)
                    await viewModel.loadVibes(for: id)
                }
            }
        }

        await MainActor.run {
            myVenueGamesForManage = rows
            manageGamesListLoading = false
            manageGamesRefreshInFlight = false

            if isInitialPick, !didPickInitialManageGamesTab {
                didPickInitialManageGamesTab = true
                let nextTab: ManageGamesListTab = rows.isEmpty ? .add : .scheduled
                if manageGamesListTab != nextTab {
                    manageGamesListTab = nextTab
                }
            }
#if DEBUG
            print("[ManageGamesDebug] refreshManageGamesList end rows=\(rows.count) tab=\(manageGamesListTab.rawValue)")
#endif
        }
    }

    private func saveNewVenueGameFromForm() async {
        let trimmedTitle: String
        let scheduleStillPast: Bool
        let requiresStructuredTeams: Bool
        let supportsOptionalParticipants: Bool
        let manualTeam1: String
        let manualTeam2: String
        (trimmedTitle, scheduleStillPast, requiresStructuredTeams, supportsOptionalParticipants, manualTeam1, manualTeam2) = await MainActor.run {
            let cal = Calendar.current
            let now = Date()
            let clamped = VenueOwnerGameScheduleValidation.clampGameDateAndTimeToMinimumNow(
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                now: now,
                calendar: cal
            )
            gameDate = clamped.0
            gameStartTime = clamped.1
            VenueOwnerGameScheduleValidation.logBusinessAddGameSaveDebug(
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                now: now,
                calendar: cal
            )
            let t = gameTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let past = VenueOwnerGameScheduleValidation.isPastSchedule(
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                now: now,
                calendar: cal
            )
            logBusinessManualGameTeamDebug()
            logVenueGameCreationCompetitorDebug(validationPassed: !manualGameRequiresStructuredTeams || manualStructuredTeamsAreValid)
            return (t, past, manualGameRequiresStructuredTeams, manualGameSupportsOptionalParticipants, trimmedManualTeam1, trimmedManualTeam2)
        }

        if requiresStructuredTeams, manualTeam1.isEmpty || manualTeam2.isEmpty {
            await MainActor.run {
                manageGamesError = manualPredictionCompetitorValidationMessage
                manageGamesFeedback = ""
                logBusinessManualGameTeamDebug()
                logVenueGameCreationCompetitorDebug(validationPassed: false)
            }
            return
        }

        if supportsOptionalParticipants,
           (manualTeam1.isEmpty != manualTeam2.isEmpty) {
            await MainActor.run {
                manageGamesError = "Add both participants to show a matchup, or leave both blank."
                manageGamesFeedback = ""
                logBusinessManualGameTeamDebug()
                logVenueGameCreationCompetitorDebug(validationPassed: false)
            }
            return
        }

        if (requiresStructuredTeams || supportsOptionalParticipants),
           !manualTeam1.isEmpty,
           !manualTeam2.isEmpty,
           manualTeam1.localizedCaseInsensitiveCompare(manualTeam2) == .orderedSame {
            await MainActor.run {
                manageGamesError = manualGameUsesPlayerCompetitorLabels ? "Player 1 and Player 2 must be different." : "Team 1 and Team 2 must be different."
                manageGamesFeedback = ""
                logBusinessManualGameTeamDebug()
                logVenueGameCreationCompetitorDebug(validationPassed: false)
            }
            return
        }

        guard !trimmedTitle.isEmpty else {
            await MainActor.run {
                manageGamesError = "Enter a game title before saving."
                manageGamesFeedback = ""
            }
            return
        }

        if scheduleStillPast {
            await MainActor.run {
                manageGamesError = VenueOwnerGameScheduleValidation.futureDateTimeMessage
                manageGamesFeedback = ""
            }
            return
        }

        await MainActor.run {
            isSavingNewGame = true
            clearManageGamesBanners()
        }

        await businessProEntitlement.prepare()
        let membershipStatus = await viewModel.businessVenueGamePostingStatus(
            storeKitBusinessProActive: businessProEntitlement.businessProActive
        )
        await MainActor.run {
            businessMembershipStatus = membershipStatus
        }
        if selectedVenuePlanLocked {
            await MainActor.run {
                isSavingNewGame = false
                manageGamesFeedback = ""
                manageGamesError = BusinessLimitCopy.planLockedVenueHostedGameBlocked
            }
            return
        }
        let canHostAfterRefresh = membershipStatus.canHostBusinessGames
        if !canHostAfterRefresh {
            await MainActor.run {
                isSavingNewGame = false
                manageGamesFeedback = ""
                manageGamesError = BusinessLimitCopy.hostedGameLimitReached
            }
            return
        }

        let snapshot = await MainActor.run {
            let shouldStoreManualMatchup = manualGameShowsParticipantFields && manualStructuredTeamsHaveBothTeams
            return (
                sport: viewModel.ownerVenuePrimarySport,
                gameDate: gameDate,
                gameStartTime: gameStartTime,
                soundOn: true,
                teamFanbase: "",
                gameLeague: gameLeague,
                crowdLevel: "Moderate",
                liveOccupancy: "Open seats",
                seating: seating,
                numberOfTVs: 1,
                gameSpecial: "",
                coverCharge: "",
                reservationsAvailable: false,
                waitlistAvailable: false,
                externalGameID: importedFromAPI ? importedExternalGameID : nil,
                externalSource: importedFromAPI ? importedExternalSource : nil,
                externalLeague: { () -> String? in
                    let manualLeague = gameLeague.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !manualLeague.isEmpty { return manualLeague }
                    return importedFromAPI ? importedExternalLeague : nil
                }(),
                importedFromAPI: importedFromAPI,
                homeTeam: importedFromAPI ? importedHomeTeam : (shouldStoreManualMatchup ? trimmedManualTeam1 : nil),
                awayTeam: importedFromAPI ? importedAwayTeam : (shouldStoreManualMatchup ? trimmedManualTeam2 : nil)
            )
        }

        if snapshot.importedFromAPI {
            let duplicate = await viewModel.venueGameImportDuplicateExists(
                externalGameID: snapshot.externalGameID,
                externalSource: snapshot.externalSource,
                venueId: viewModel.ownerVenueDatabaseId,
                gameDate: snapshot.gameDate
            )
            if duplicate {
                await MainActor.run {
                    isSavingNewGame = false
                    manageGamesError = "This game already exists for this venue."
                    manageGamesFeedback = ""
                }
                return
            }
        } else {
            let duplicate = await viewModel.venueGameManualDuplicateExists(
                venueId: viewModel.ownerVenueDatabaseId,
                gameTitle: trimmedTitle,
                sport: snapshot.sport,
                homeTeam: snapshot.homeTeam,
                awayTeam: snapshot.awayTeam,
                gameDate: snapshot.gameDate,
                gameStartTime: snapshot.gameStartTime
            )
            if duplicate {
                await MainActor.run {
                    isSavingNewGame = false
                    manageGamesError = "This game already exists for this venue."
                    manageGamesFeedback = ""
                }
                return
            }
        }

        let result = await viewModel.saveVenueGameListingAsync(
            gameTitle: trimmedTitle,
            sport: snapshot.sport,
            gameDate: snapshot.gameDate,
            gameStartTime: snapshot.gameStartTime,
            soundOn: snapshot.soundOn,
            audioType: snapshot.soundOn ? .full : .none,
            teamFanbase: snapshot.teamFanbase,
            atmosphere: "",
            crowdLevel: snapshot.crowdLevel,
            liveOccupancy: snapshot.liveOccupancy,
            seating: snapshot.seating,
            numberOfTVs: "\(snapshot.numberOfTVs)",
            drinkSpecial: snapshot.gameSpecial,
            coverCharge: snapshot.coverCharge,
            reservationInfo: snapshot.reservationsAvailable ? "Reservations available" : "",
            socialCoordination: snapshot.waitlistAvailable ? "Waitlist available" : "",
            externalGameID: snapshot.externalGameID,
            externalSource: snapshot.externalSource,
            importedFromAPI: snapshot.importedFromAPI,
            externalLeague: snapshot.externalLeague,
            homeTeam: snapshot.homeTeam,
            awayTeam: snapshot.awayTeam
        )

        await MainActor.run {
            isSavingNewGame = false
            switch result {
            case .failure(let err):
                manageGamesError = err.localizedDescription
                manageGamesFeedback = ""
#if DEBUG
                manageGamesDebugErrorDetails = (err as NSError).userInfo[MapViewModel.hostedGameRPCDebugDetailsUserInfoKey] as? String ?? ""
#endif
            case .success:
                manageGamesError = ""
#if DEBUG
                manageGamesDebugErrorDetails = ""
#endif
                manageGamesFeedback = "Game created."
#if DEBUG
                if let vid = viewModel.ownerVenueDatabaseId {
                    print("[BusinessGameState] success state set for venue_id=\(vid.uuidString)")
                } else {
                    print("[BusinessGameState] success state set for venue_id=nil")
                }
#endif
                resetAddGameFormAfterSave()
                manageGamesListTab = .scheduled
            }
        }

        if case .success = result {
            await refreshManageGamesList(isInitialPick: false)
            await refreshBusinessPlanStatus(source: "postMutation", force: true)
        }
    }

    private func resetAddGameFormAfterSave() {
        gameTitle = ""
        gameTeam1 = ""
        gameTeam2 = ""
        gameTeam1Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
        gameTeam2Selection = ManualVenueTeamSelection(name: "", type: .custom, countryCode: nil)
        lastGeneratedGameTitle = ""
        titleManuallyEdited = false
        gameLeague = ""
        seating = ""
        socialCoordination = ""
        initializeAddGameScheduleFromDefaults()
        clearImportedGameMetadata()
    }

    private func clearImportedGameMetadata() {
        importedExternalGameID = nil
        importedExternalSource = nil
        importedExternalLeague = nil
        importedHomeTeam = nil
        importedAwayTeam = nil
        importedFromAPI = false
        importGamesBrowserExpanded = true
        importGamesCalendarExpanded = false
    }

    private func refreshAnalyticsGameHistory() async {
        await MainActor.run {
            analyticsGameHistoryLoading = true
            analyticsGameHistoryError = ""
        }
        guard let bid = viewModel.currentBusinessIdForAddLocation() else {
            await MainActor.run {
                analyticsGameHistoryForYear = []
                analyticsGameHistoryLoading = false
                analyticsGameHistoryError = ""
            }
            return
        }
        do {
            let rows = try await viewModel.loadBusinessGameHistory(businessId: bid, year: analyticsGameHistoryYear)
            await MainActor.run {
                analyticsGameHistoryForYear = rows
                analyticsGameHistoryLoading = false
            }
        } catch {
            await MainActor.run {
                analyticsGameHistoryForYear = []
                analyticsGameHistoryLoading = false
                analyticsGameHistoryError = error.localizedDescription
            }
        }
    }

    private func monthShortName(_ month: Int) -> String {
        let f = DateFormatter()
        f.locale = .current
        let idx = max(0, min(11, month - 1))
        guard idx < f.shortMonthSymbols.count else { return "\(month)" }
        return f.shortMonthSymbols[idx]
    }

    private func formatHistorySchedule(_ iso: String?) -> String {
        guard let iso, !iso.isEmpty else { return "—" }
        let fIn = ISO8601DateFormatter()
        fIn.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate, .withColonSeparatorInTime]
        var d = fIn.date(from: iso)
        if d == nil {
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
            d = f2.date(from: iso)
        }
        guard let d else { return iso }
        let out = DateFormatter()
        out.locale = .current
        out.dateStyle = .medium
        out.timeStyle = .short
        return out.string(from: d)
    }

    private func formattedManageGameDateTime(row: VenueEventRow) -> String {
        let d = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "—"
        let t = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { return d }
        return "\(d) · \(t)"
    }

    private func derivedManageGameStatus(row: VenueEventRow) -> String? {
        guard let ds = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines), !ds.isEmpty else {
            return nil
        }
        let fmt = DateFormatter()
        fmt.calendar = Calendar.current
        fmt.timeZone = TimeZone.current
        fmt.dateFormat = "yyyy-MM-dd"
        guard let gameDay = fmt.date(from: ds) else { return nil }
        let today = Calendar.current.startOfDay(for: Date())
        let day = Calendar.current.startOfDay(for: gameDay)
        if day < today { return "Past" }
        if day == today { return "Today" }
        return "Scheduled"
    }

    private func aggregateVibeTotal(eventID: UUID) -> Int {
        let dict = fanUpdatesStore.venueEventVibeCounts[eventID] ?? [:]
        return dict.values.reduce(0, +)
    }
    
    private func dashboardCard<Content: View>(
        title: String,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2)
                .fontWeight(.bold)
            
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
            
            content()
        }
        .padding()
        .background(FGAdaptiveSurface.cardElevated)
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .overlay(
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color(.separator).opacity(0.45), lineWidth: 1)
                .allowsHitTesting(false)
        )
    }
    
    private func field(_ placeholder: String, text: Binding<String>, locked: Bool = false) -> some View {
        HStack(alignment: .center, spacing: 10) {
            TextField(placeholder, text: text)
                .foregroundStyle(.primary)
                .disabled(locked)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(FGAdaptiveSurface.controlFill)
                .clipShape(RoundedRectangle(cornerRadius: 16))

            if locked {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 22)
                    .accessibilityLabel("Verified — locked")
            }
        }
        .opacity(locked ? 0.78 : 1)
    }

    private func syncDisplayedVenuePhotoURLsFromViewModel() {
        displayedCoverPhotoURL = viewModel.venueCoverPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
        displayedMenuPhotoURL = viewModel.venueMenuPhotoURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func businessVenueProfilePhotoEditor(
        title: String,
        subtitle: String,
        fullImageURL: String,
        thumbnailURL: String,
        selection: Binding<PhotosPickerItem?>
    ) -> some View {
        let full = fullImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewURL = !full.isEmpty ? full : thumb
        return VenueOwnerBusinessPhotoPickerCard(
            title: title,
            subtitle: subtitle,
            pickerSelection: selection,
            remotePreviewURL: previewURL
        )
    }

    private func venueProfilePhotoEditor(
        title: String,
        subtitle: String,
        fullImageURL: String,
        thumbnailURL: String,
        selection: Binding<PhotosPickerItem?>
    ) -> some View {
        let full = fullImageURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let thumb = thumbnailURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewURL = !full.isEmpty ? full : thumb
        return VenueOwnerListingPhotoPickerCard(
            title: title,
            subtitle: subtitle,
            pickerSelection: selection,
            remotePreviewURL: previewURL,
            localPreviewData: nil
        )
    }

    private func primaryButtonText(_ text: String) -> some View {
        Text(text)
            .fontWeight(.bold)
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Manage Games list helpers

private struct VenueOwnerGameTitleEditTarget: Identifiable {
    let id: UUID
    let row: VenueEventRow

    var isManualHostedGame: Bool {
        if row.imported_from_api == true { return false }

        let externalSource = row.external_source?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        let externalGameID = row.external_game_id?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return externalGameID.isEmpty
            && (externalSource.isEmpty || externalSource == "manual")
    }
}

private struct VenueOwnerGameChatTarget: Identifiable {
    let id: UUID
    let title: String
}

private struct VenueOwnerIdentifiedVenueEvent: Identifiable {
    let id: UUID
    var row: VenueEventRow
}

private struct HostedVenueGameCardIdentity {
    let primaryTitle: String
    let secondaryLine: String
    let sportDisplay: String

    init(row: VenueEventRow) {
        let sportRaw = Self.trimmed(row.sport)
        let sport = sportRaw.isEmpty ? "Sports" : AppSportCatalog.displayLabel(forSportToken: sportRaw)
        let home = Self.trimmed(row.home_team)
        let away = Self.trimmed(row.away_team)
        let league = Self.trimmed(row.external_league)
        let rawTitle = Self.trimmed(row.event_title)
        let matchup = Self.matchupText(home: home, away: away, sport: sportRaw.isEmpty ? sport : sportRaw)
        let titleIsGeneric = Self.isGenericTitle(rawTitle, matchup: matchup, sportDisplay: sport)
        let titleIsCustom = !rawTitle.isEmpty && !titleIsGeneric

        sportDisplay = sport

        if let matchup {
            primaryTitle = matchup
        } else if titleIsCustom {
            primaryTitle = rawTitle
        } else if !league.isEmpty && !Self.equivalent(league, sport) {
            primaryTitle = league
        } else if sport == "Sports" {
            primaryTitle = "Watch party"
        } else {
            primaryTitle = "\(sport) Watch Party"
        }

        if let matchup, titleIsCustom, !Self.equivalent(rawTitle, matchup) {
            secondaryLine = "\(sport) • \(rawTitle)"
        } else if Self.sportCanUseLeagueSubtitle(sportRaw.isEmpty ? sport : sportRaw),
                  !league.isEmpty,
                  !Self.equivalent(league, primaryTitle),
                  !Self.equivalent(league, sport) {
            secondaryLine = "\(sport) • \(league)"
        } else {
            secondaryLine = sport
        }
    }

    private static func trimmed(_ value: String?) -> String {
        value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func matchupText(home: String, away: String, sport: String) -> String? {
        guard !home.isEmpty,
              !away.isEmpty,
              !equivalent(home, away),
              sportUsesOpponentLine(sport) else {
            return nil
        }
        return "\(home) vs \(away)"
    }

    private static func sportUsesOpponentLine(_ sport: String) -> Bool {
        VenueGameCompetitorDisplay.requiresCompetitors(for: sport)
    }

    private static func sportCanUseLeagueSubtitle(_ sport: String) -> Bool {
        let key = sport.lowercased()
        let nonMatchupSports = [
            "golf", "formula 1", "f1", "motogp", "moto gp", "nascar", "racing",
            "cycling", "track and field", "swimming", "skiing", "snowboarding"
        ]
        return !nonMatchupSports.contains { key.contains($0) }
    }

    private static func isGenericTitle(_ title: String, matchup: String?, sportDisplay: String) -> Bool {
        guard !title.isEmpty else { return true }
        if let matchup, equivalent(title, matchup) { return true }
        let genericTitles = [
            "game",
            "watch party",
            "watchparty",
            "sports watch party",
            "hosted game",
            "live game",
            "game night",
            "\(sportDisplay) watch party"
        ]
        return genericTitles.contains { equivalent(title, $0) }
    }

    private static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        normalized(lhs) == normalized(rhs)
    }

    private static func normalized(_ value: String) -> String {
        let scalars = value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }
}

private struct VenueSupporterCountryPickerSheet: View {
    let currentCountry: String
    let onSelect: (String) -> Void
    let onClear: () -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage(L10n.appLanguageKey) private var appLanguageRaw = L10n.defaultLanguageCode
    @State private var searchText = ""

    private var options: [NationalTeamCountryOption] {
        VenueSupporterCountryMode.allowedOptions(matching: searchText, languageCode: appLanguageRaw)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Fan Zone Identity")
                            .font(.title2.weight(.heavy))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        Text("Show fans your watch-spot country on venue cards.")
                            .font(.subheadline)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }

                    Button {
                        onClear()
                        dismiss()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "xmark.circle")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                                .frame(width: 34)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("None")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(FGColor.primaryText(colorScheme))
                                Text("Clear the watch-spot banner identity")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                            }
                            Spacer()
                            if VenueSupporterCountryMode.normalizedStorageValue(currentCountry) == nil {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(FGColor.accentGreen)
                            }
                        }
                        .padding(12)
                        .background(FGAdaptiveSurface.controlFill)
                        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)

                    HStack(spacing: 9) {
                        Image(systemName: "magnifyingglass")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                        TextField("Search countries", text: $searchText)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                    }
                    .padding()
                    .background(FGAdaptiveSurface.controlFill)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Allowed countries" : "Matching countries")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(.uppercase)
                        ForEach(options) { option in
                            countryRow(option)
                        }
                    }
                }
                .padding(18)
            }
            .background(FGColor.screenGradient(colorScheme).ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("cancel", languageCode: appLanguageRaw)) { dismiss() }
                }
            }
        }
    }

    private func countryRow(_ option: NationalTeamCountryOption) -> some View {
        let isSelected = currentCountry.caseInsensitiveCompare(option.name) == .orderedSame
            || VenueSupporterCountryMode.display(for: currentCountry, languageCode: appLanguageRaw)?.countryCode == option.code

        return Button {
#if DEBUG
            print("[VenueSupporterIdentityDebug] save venueId=ownerToolsPicker supporterCountry=\(option.name)")
#endif
            onSelect(option.name)
            dismiss()
        } label: {
            HStack(spacing: 12) {
                Text(option.flag)
                    .font(.title2)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text(VenueSupporterCountryMode.display(for: option.name, languageCode: appLanguageRaw)?.title ?? option.code)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            .padding(12)
            .background(FGAdaptiveSurface.controlFill)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private nonisolated struct VenueOwnerScheduledGameChoice: Identifiable, Equatable {
    let id: String
    let title: String
    let sport: String
    let league: String?
    let homeTeam: String
    let awayTeam: String
    let startTime: Date
    let status: MatchStatus
    let externalProviderId: String?

    init(match: LiveMatch) {
        id = match.id
        title = VenueOwnerDashboardView.importedGameTitle(for: match)
        sport = VenueOwnerDashboardView.mappedVenueSport(for: match)
        league = match.league.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : match.league
        homeTeam = match.homeTeam
        awayTeam = match.awayTeam
        startTime = match.startTime
        status = match.matchStatus
        externalProviderId = match.id
    }

    var isLive: Bool {
        status.isHappeningNow
    }

    var statusLabel: String {
        switch status {
        case .live:
            return "Live"
        case .halfTime:
            return "Halftime"
        case .scheduled:
            return "Upcoming"
        case .fullTime:
            return "Final"
        }
    }
}

private struct VenueOwnerSchedulePickerSheet: View {
    let matches: [LiveMatch]
    let isLoading: Bool
    @Binding var selectedDate: Date
    let onSelect: (VenueOwnerScheduledGameChoice) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var searchQuery = ""
    @State private var selectedSport = "All"

    private var allChoices: [VenueOwnerScheduledGameChoice] {
        let now = Date()
        return matches
            .filter { match in
                switch match.matchStatus {
                case .live, .halfTime:
                    return true
                case .scheduled:
                    return match.startTime >= now
                case .fullTime:
                    return false
                }
            }
            .map(VenueOwnerScheduledGameChoice.init(match:))
            .sorted { lhs, rhs in
                if lhs.isLive != rhs.isLive {
                    return lhs.isLive && !rhs.isLive
                }
                if lhs.startTime != rhs.startTime {
                    return lhs.startTime < rhs.startTime
                }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
    }

    private var availableSports: [String] {
        let sports = allChoices.map(\.sport)
        var seen = Set<String>()
        return sports.filter { sport in
            let key = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seen.contains(key) else { return false }
            seen.insert(key)
            return true
        }
    }

    private var filteredChoices: [VenueOwnerScheduledGameChoice] {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)

        return allChoices.filter { choice in
            let choiceDay = calendar.startOfDay(for: choice.startTime)
            let dateMatches = choiceDay == selectedDay || (choice.isLive && calendar.isDateInToday(selectedDay))
            guard dateMatches else { return false }

            return choiceMatchesActiveFilters(choice)
        }
    }

    private var gamesFoundForSelectedDate: Int {
        let calendar = Calendar.current
        let selectedDay = calendar.startOfDay(for: selectedDate)
        return allChoices.filter { choice in
            let choiceDay = calendar.startOfDay(for: choice.startTime)
            return choiceDay == selectedDay || (choice.isLive && calendar.isDateInToday(selectedDay))
        }.count
    }

    private var nextAvailableGames: [VenueOwnerScheduledGameChoice] {
        let now = Date()
        return allChoices.filter { choice in
            guard choice.startTime >= now else { return false }
            return choiceMatchesActiveFilters(choice)
        }
    }

    private var visibleNextAvailableGames: [VenueOwnerScheduledGameChoice] {
        Array(nextAvailableGames.prefix(3))
    }

    private var showingUpcomingFallback: Bool {
        filteredChoices.isEmpty && !visibleNextAvailableGames.isEmpty
    }

    private func choiceMatchesActiveFilters(_ choice: VenueOwnerScheduledGameChoice) -> Bool {
        if selectedSport != "All",
           choice.sport.localizedCaseInsensitiveCompare(selectedSport) != .orderedSame {
            return false
        }

        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return choice.title.localizedCaseInsensitiveContains(query)
            || choice.sport.localizedCaseInsensitiveContains(query)
            || (choice.league?.localizedCaseInsensitiveContains(query) ?? false)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 14) {
                searchField
                dateSelector
                sportFilterChips

                if isLoading && allChoices.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading games...")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                } else if filteredChoices.isEmpty {
                    emptyState
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(filteredChoices) { choice in
                                Button {
                                    onSelect(choice)
                                } label: {
                                    scheduleRow(choice)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.bottom, 10)
                    }
                }
            }
            .padding()
            .background(FGAdaptiveSurface.sheetRoot)
            .navigationTitle("Choose Game")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: searchQuery) { _, newValue in
#if DEBUG
            print("[BusinessAddGameDebug] scheduleSearchQuery=\(newValue)")
#endif
            logScheduleDebug()
        }
        .onAppear {
            logScheduleDebug()
        }
        .onChange(of: selectedDate) { _, _ in
            logScheduleDebug()
        }
        .onChange(of: selectedSport) { _, _ in
            logScheduleDebug()
        }
        .onChange(of: matches) { _, _ in
            logScheduleDebug()
        }
    }

    private var searchField: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("Search teams, league, sport", text: $searchQuery)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
        }
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var dateSelector: some View {
        DatePicker(
            "Date",
            selection: $selectedDate,
            in: Calendar.current.startOfDay(for: Date())...Date.distantFuture,
            displayedComponents: .date
        )
        .font(.subheadline.weight(.semibold))
        .padding()
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var sportFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                sportChip("All")
                ForEach(availableSports, id: \.self) { sport in
                    sportChip(sport)
                }
            }
            .padding(.vertical, 2)
        }
    }

    private func sportChip(_ sport: String) -> some View {
        let isSelected = selectedSport == sport
        return Button {
            selectedSport = sport
        } label: {
            Text(AppSportCatalog.displayLabel(forSportToken: sport))
                .font(.caption.weight(.bold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(isSelected ? Color.accentColor : FGAdaptiveSurface.controlFill)
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: emptyStateIconName)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: 4) {
                    Text(emptyStateTitle)
                        .font(.headline.weight(.bold))
                        .foregroundStyle(.primary)
                    Text(emptyStateSubtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !visibleNextAvailableGames.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Next major games")
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)

                    ForEach(visibleNextAvailableGames) { choice in
                        Button {
                            onSelect(choice)
                        } label: {
                            nextAvailableGameRow(choice)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.35), lineWidth: 1)
        )
    }

    private var emptyStateTitle: String {
        if allChoices.isEmpty {
            return "No sports schedule available right now."
        }

        if gamesFoundForSelectedDate > 0 {
            return "No games match these filters."
        }

        if let next = nextAvailableGames.first, Calendar.current.isDateInToday(next.startTime) {
            return "Next games begin later today."
        }

        if Calendar.current.isDateInToday(selectedDate) {
            return "No live games available right now."
        }

        return "No nearby games for this date."
    }

    private var emptyStateSubtitle: String {
        allChoices.isEmpty
            ? "You can still add a game manually."
            : "Try another date or add a game manually."
    }

    private var emptyStateIconName: String {
        if Calendar.current.isDateInToday(selectedDate) {
            return "dot.radiowaves.left.and.right"
        }
        return "calendar.badge.clock"
    }

    private func nextAvailableGameRow(_ choice: VenueOwnerScheduledGameChoice) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(choice.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(nextAvailableTimeLabel(for: choice.startTime))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Image(systemName: "plus.circle.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(FGAdaptiveSurface.sheetRoot.opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func nextAvailableTimeLabel(for date: Date) -> String {
        let calendar = Calendar.current
        let prefix: String
        if calendar.isDateInToday(date) {
            let hour = calendar.component(.hour, from: date)
            prefix = hour >= 17 ? "Tonight" : "Today"
        } else if calendar.isDateInTomorrow(date) {
            prefix = "Tomorrow"
        } else {
            prefix = Self.shortDateFormatter.string(from: date)
        }
        return "\(prefix) \(Self.timeFormatter.string(from: date))"
    }

    private func logScheduleDebug() {
#if DEBUG
        print("[BusinessScheduleDebug] selectedDate=\(Self.debugDateFormatter.string(from: selectedDate))")
        print("[BusinessScheduleDebug] gamesFoundForDate=\(gamesFoundForSelectedDate)")
        print("[BusinessScheduleDebug] nextAvailableGamesCount=\(nextAvailableGames.count)")
        print("[BusinessScheduleDebug] showingUpcomingFallback=\(showingUpcomingFallback)")
#endif
    }

    private func scheduleRow(_ choice: VenueOwnerScheduledGameChoice) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(choice.title)
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Spacer(minLength: 6)
                Text(choice.statusLabel)
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(choice.isLive ? Color.green : Color.accentColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background((choice.isLive ? Color.green : Color.accentColor).opacity(0.14))
                    .clipShape(Capsule(style: .continuous))
            }

            HStack(spacing: 6) {
                Text(AppSportCatalog.displayLabel(forSportToken: choice.sport))
                    .font(.caption.weight(.semibold))
                if let league = choice.league {
                    Text("/")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(league)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Text("\(Self.dateFormatter.string(from: choice.startTime)) at \(Self.timeFormatter.string(from: choice.startTime))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color(.separator).opacity(0.4), lineWidth: 1)
        )
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    private static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

private struct VenueOwnerManageGameRow: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme

    let row: VenueEventRow
    let eventID: UUID
    let formattedDateTime: String
    let statusLabel: String?
    let goingCount: Int
    let commentCount: Int
    let vibeTotal: Int
    let onViewChat: () -> Void
    let onEditTitle: () -> Void
    let onCancel: () -> Void

    var body: some View {
        let identity = HostedVenueGameCardIdentity(row: row)
        let sportDisplay = identity.sportDisplay
        let sportEmoji = viewModel.emojiForSport(sportDisplay)
        let sportIcon = viewModel.iconForSport(sportDisplay)
        let sportTint = viewModel.colorForSport(sportDisplay)
        let momentum = momentumState

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .fill(sportTint.opacity(colorScheme == .dark ? 0.22 : 0.13))
                    if !sportEmoji.isEmpty {
                        Text(sportEmoji)
                            .font(.system(size: 17))
                            .accessibilityHidden(true)
                    } else {
                        Image(systemName: sportIcon)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(sportTint)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 36, height: 36)

                VStack(alignment: .leading, spacing: 3) {
                    Text(identity.primaryTitle)
                        .font(.subheadline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(identity.secondaryLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.82))
                        .lineLimit(1)

                    Text(eventDateTimeLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                statusPill
            }

            if hasMetadataBadges {
                HStack(spacing: 6) {
                    if let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !league.isEmpty {
                        Text(league)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }

                    if row.imported_from_api == true {
                        Text("Imported")
                            .font(.caption2.weight(.heavy))
                            .foregroundStyle(Color.orange)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
                    }

                    Spacer(minLength: 0)
                }
            }

            HStack(spacing: 7) {
                metricChip(symbol: "👥", value: goingCount, label: "going", tint: FGColor.accentBlue)
                metricChip(symbol: "💬", value: commentCount, label: "chat", tint: FGColor.accentGreen)
                metricChip(symbol: "⚡", value: vibeTotal, label: "vibes", tint: FGColor.accentYellow)
            }

            HStack(spacing: 7) {
                Text(momentum.label)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(momentum.tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(momentum.tint.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule(style: .continuous))

                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let countdown = autoRemovalCountdownText(now: context.date) {
                        Text(countdown)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)
            }

            HStack(spacing: 8) {
                compactActionButton("View Chat", systemImage: "bubble.left.and.bubble.right.fill", tint: FGColor.accentBlue, action: onViewChat)
                compactActionButton("Edit", systemImage: "pencil", tint: FGColor.secondaryText(colorScheme), action: onEditTitle)
                compactActionButton("Cancel", systemImage: "xmark.circle.fill", tint: FGColor.dangerRed, action: onCancel)
                Spacer(minLength: 0)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(tint: momentum.tint))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(momentum.tint.opacity(colorScheme == .dark ? 0.24 : 0.16), lineWidth: 1)
        }
        .overlay(alignment: .topTrailing) {
            if momentum.isHighEnergy {
                Circle()
                    .fill(momentum.tint.opacity(colorScheme == .dark ? 0.22 : 0.14))
                    .frame(width: 46, height: 46)
                    .blur(radius: 18)
                    .offset(x: 2, y: -8)
                    .allowsHitTesting(false)
            }
        }
        .onAppear {
#if DEBUG
            print("[BusinessGamesUI] redesignedCardLoaded=\(eventID.uuidString.lowercased())")
            print("[BusinessGamesUI] momentumLabel=\(momentum.label)")
            print("[BusinessGamesUI] compactLayoutEnabled=true")
#endif
        }
    }

    private var statusPill: some View {
        let display = statusLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = display?.isEmpty == false ? (display ?? "Scheduled") : "Scheduled"
        let tint = title.localizedCaseInsensitiveContains("live") ? FGColor.accentGreen : FGColor.accentBlue

        return Text(title)
            .font(.caption2.weight(.black))
            .foregroundStyle(tint)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule(style: .continuous))
    }

    private var hasMetadataBadges: Bool {
        let league = row.external_league?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !league.isEmpty || row.imported_from_api == true
    }

    private var eventDateTimeLine: String {
        guard let start = VenueGameExpiration.scheduledStartDate(for: row) else {
            return formattedDateTime
        }
        return Self.dashboardDateTimeFormatter.string(from: start)
    }

    private var momentumState: (label: String, tint: Color, isHighEnergy: Bool) {
        let score = goingCount + (commentCount * 2) + vibeTotal
        if score >= 35 {
            return ("⚡ High Fan Activity", FGColor.accentGreen, true)
        }
        if goingCount >= 15 || commentCount >= 8 {
            return ("🔥 Crowd Building", FGColor.accentYellow, true)
        }
        if score >= 12 {
            return ("📈 Trending Nearby", FGColor.accentBlue, false)
        }
        if goingCount > 0 || commentCount > 0 || vibeTotal > 0 {
            return ("🏟️ Watch Party Active", FGColor.accentBlue, false)
        }
        return ("🏟️ Ready for fans", FGColor.secondaryText(colorScheme), false)
    }

    private func cardBackground(tint: Color) -> some ShapeStyle {
        LinearGradient(
            colors: [
                tint.opacity(colorScheme == .dark ? 0.13 : 0.07),
                FGAdaptiveSurface.controlFill.opacity(0.98)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private func metricChip(symbol: String, value: Int, label: String, tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.caption2)
                .accessibilityHidden(true)
            Text("\(value)")
                .font(.caption.weight(.black))
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .foregroundStyle(FGColor.primaryText(colorScheme))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.09), in: Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(tint.opacity(colorScheme == .dark ? 0.18 : 0.12), lineWidth: 1)
        }
    }

    private func compactActionButton(
        _ title: String,
        systemImage: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption.weight(.heavy))
                .labelStyle(.titleAndIcon)
                .foregroundStyle(tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(FGAdaptiveSurface.capsuleUnselected, in: Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func autoRemovalCountdownText(now: Date) -> String? {
        guard let start = VenueGameExpiration.scheduledStartDate(for: row),
              let expiration = Calendar.current.date(
                byAdding: .hour,
                value: VenueOwnerGameDataRetentionHours.fixedHoursAfterStart,
                to: start
              ) else {
            return nil
        }
        let remainingSeconds = expiration.timeIntervalSince(now)
        guard remainingSeconds > 0 else { return nil }
        if remainingSeconds <= 15 * 60 {
            return "Closing soon"
        }
        let totalMinutes = Int(ceil(remainingSeconds / 60))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return "Auto-removes in \(hours)h \(minutes)m"
        }
        return "Auto-removes in \(minutes)m"
    }

    private static let dashboardDateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE • MMM d • h:mm a"
        return formatter
    }()
}

// MARK: - Venue owner compact analytics row

private struct VenueOwnerCompactAnalyticsRow: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var fanUpdatesStore: FanUpdatesRealtimeStore
    @Environment(\.colorScheme) private var colorScheme

    let row: VenueEventRow
    let eventID: UUID
    let isLiveToday: Bool
    let onTapDetail: () -> Void

    private var score: Int {
        viewModel.venueOwnerEngagementScore(venueEventID: eventID)
    }

    private var going: Int {
        viewModel.interestCountForVenueEvent(eventID)
    }

    private var comments: Int {
        fanUpdatesStore.venueEventComments[eventID]?.count ?? 0
    }

    private var audioCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["audio_on"] ?? 0
    }

    private var packedCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["packed"] ?? 0
    }

    private var seatsOpenCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["seats_open"] ?? 0
    }

    private var specialsCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["specials"] ?? 0
    }

    private var tvVisibleCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["tv_visible"] ?? 0
    }

    private var title: String {
        HostedVenueGameCardIdentity(row: row).primaryTitle
    }

    private var dateTimeLine: String {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id) {
            return Self.analyticsRowDateFormatter.string(from: start)
        }
        let d = row.event_date ?? "Date TBD"
        let t = row.event_time ?? ""
        return t.isEmpty ? d : "\(d) • \(t)"
    }

    private var sportLine: String {
        let identity = HostedVenueGameCardIdentity(row: row)
        return "\(Self.sportEmoji(for: identity.sportDisplay)) \(identity.secondaryLine)"
    }

    private var sportIconText: String {
        Self.sportEmoji(for: HostedVenueGameCardIdentity(row: row).sportDisplay)
    }

    private var vibeTotal: Int {
        audioCount + packedCount + seatsOpenCount + specialsCount + tvVisibleCount
    }

    private var momentumState: (label: String, tint: Color) {
        if score >= 35 { return ("⚡ High Activity", FGColor.accentGreen) }
        if going >= 15 || comments >= 8 { return ("🔥 Crowd Building", FGColor.accentYellow) }
        if score >= 12 { return ("📈 Trending Nearby", FGColor.accentBlue) }
        if score > 0 { return ("🏟️ Watch Party Active", FGColor.accentBlue) }
        return ("Ready for fans", FGColor.secondaryText(colorScheme))
    }

    private var topVibeSnippet: String? {
        let m = fanUpdatesStore.venueEventVibeCounts[eventID] ?? [:]
        guard let best = m.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        return topFanSignal(for: best.key, value: best.value)
    }

    private func topFanSignal(for key: String, value: Int) -> String {
        switch key {
        case "audio_on": return "🎙 Audio"
        case "packed": return "🔥 Packed"
        case "seats_open": return "🪑 Seating"
        case "specials": return "🍺 Specials"
        case "tv_visible": return "📺 TVs visible"
        default: return "⭐️ \(key.replacingOccurrences(of: "_", with: " ")) \(value)"
        }
    }

    private static func sportEmoji(for sport: String) -> String {
        let catalogEmoji = SportFilterCatalog.resolve(sport).emoji
        if !catalogEmoji.isEmpty { return catalogEmoji }
        let s = sport.lowercased()
        if s.contains("soccer") { return "⚽️" }
        if s.contains("nba") || s.contains("basket") { return "🏀" }
        if s.contains("nfl") || s.contains("football") { return "🏈" }
        if s.contains("baseball") || s.contains("mlb") { return "⚾️" }
        if s.contains("hockey") || s.contains("nhl") { return "🏒" }
        if s.contains("tennis") { return "🎾" }
        if s.contains("golf") { return "⛳️" }
        if s.contains("ping") || s.contains("table") { return "🏓" }
        return "🏟"
    }

    var body: some View {
        let momentum = momentumState

        Button(action: onTapDetail) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Text(sportIconText)
                        .font(.system(size: 18))
                        .frame(width: 34, height: 34)
                        .background(FGAdaptiveSurface.capsuleUnselected, in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.subheadline.weight(.black))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(2)

                        Text(sportLine)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.82))
                            .lineLimit(2)

                        Text(dateTimeLine)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .lineLimit(2)
                    }

                    Spacer(minLength: 6)
                    momentumBadge
                }

                Text(momentum.label)
                    .font(.caption.weight(.heavy))
                    .foregroundStyle(momentum.tint)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(momentum.tint.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule(style: .continuous))

                if hasMeaningfulMetrics {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            if going > 0 { insightMetricPill("👥", going, "interested", FGColor.accentBlue) }
                            if comments > 0 { insightMetricPill("💬", comments, "chat", FGColor.accentGreen) }
                            if vibeTotal > 0 { insightMetricPill("⚡", vibeTotal, "energy", FGColor.accentYellow) }
                            if let topVibeSnippet {
                                topSignalPill(topVibeSnippet)
                            }
                        }
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [
                        momentum.tint.opacity(colorScheme == .dark ? 0.12 : 0.06),
                        FGAdaptiveSurface.controlFill.opacity(0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(momentum.tint)
                    .frame(width: 3)
                    .clipShape(Capsule(style: .continuous))
                    .padding(.vertical, 8)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(momentum.tint.opacity(colorScheme == .dark ? 0.22 : 0.14), lineWidth: 1)
            }
            .shadow(color: momentum.tint.opacity(colorScheme == .dark ? 0.10 : 0.07), radius: 10, x: 0, y: 5)
            .onAppear {
#if DEBUG
                print("[BusinessInsightsUI] momentumLabel=\(momentum.label)")
                print("[BusinessInsightsUI] compactMetricsApplied=true")
#endif
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.985, hapticOnPress: false))
    }

    private var hasMeaningfulMetrics: Bool {
        going > 0 || comments > 0 || vibeTotal > 0
    }

    @ViewBuilder
    private var momentumBadge: some View {
        let listingStatus = row.admin_status?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if listingStatus == "archived" {
            Text("Cancelled")
                .font(.caption2.weight(.black))
                .foregroundStyle(Color.orange)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
        } else if isLiveToday {
            Text("Live")
                .font(.caption2.weight(.black))
                .foregroundStyle(FGColor.accentGreen)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(FGColor.accentGreen.opacity(colorScheme == .dark ? 0.18 : 0.11), in: Capsule(style: .continuous))
        } else {
            Text("Momentum \(score)")
                .font(.caption2.weight(.black))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(FGAdaptiveSurface.capsuleUnselected, in: Capsule(style: .continuous))
        }
    }

    private func insightMetricPill(_ symbol: String, _ value: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.caption2)
                .accessibilityHidden(true)
            Text("\(value)")
                .font(.caption.weight(.black))
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .foregroundStyle(FGColor.primaryText(colorScheme))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.09), in: Capsule(style: .continuous))
    }

    private func topSignalPill(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text)
                .font(.caption2.weight(.black))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text("signal")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .foregroundStyle(FGColor.primaryText(colorScheme))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.14 : 0.08), in: Capsule(style: .continuous))
    }

    private static let analyticsRowDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE • MMM d • h:mm a"
        return formatter
    }()
}

// MARK: - Venue owner game analytics card

private struct VenueOwnerGameAnalyticsCard: View {
    @ObservedObject var viewModel: MapViewModel
    @ObservedObject var fanUpdatesStore: FanUpdatesRealtimeStore
    @Environment(\.colorScheme) private var colorScheme

    let row: VenueEventRow
    let eventID: UUID
    let isLiveToday: Bool

    private var goingCount: Int {
        viewModel.interestCountForVenueEvent(eventID)
    }

    private var commentCount: Int {
        fanUpdatesStore.venueEventComments[eventID]?.count ?? 0
    }

    private var audioCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["audio_on"] ?? 0
    }

    private var packedCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["packed"] ?? 0
    }

    private var seatsOpenCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["seats_open"] ?? 0
    }

    private var specialsCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["specials"] ?? 0
    }

    private var tvVisibleCount: Int {
        fanUpdatesStore.venueEventVibeCounts[eventID]?["tv_visible"] ?? 0
    }

    private var score: Int {
        viewModel.venueOwnerEngagementScore(venueEventID: eventID)
    }

    private var vibeTotal: Int {
        audioCount + packedCount + seatsOpenCount + specialsCount + tvVisibleCount
    }

    private var momentumState: (label: String, tint: Color) {
        if score >= 35 { return ("⚡ High Activity", FGColor.accentGreen) }
        if goingCount >= 15 || commentCount >= 8 { return ("🔥 Crowd Building", FGColor.accentYellow) }
        if score >= 12 { return ("📈 Trending Nearby", FGColor.accentBlue) }
        if score > 0 { return ("🏟️ Watch Party Active", FGColor.accentBlue) }
        return ("Ready for fans", FGColor.secondaryText(colorScheme))
    }

    private var dateTimeLine: String {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at, eventId: row.id) {
            return Self.analyticsDetailDateFormatter.string(from: start)
        }
        return [row.event_date, row.event_time]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • ")
    }

    private var topVibeLine: String? {
        let m = fanUpdatesStore.venueEventVibeCounts[eventID] ?? [:]
        guard let best = m.max(by: { $0.value < $1.value }), best.value > 0 else { return nil }
        switch best.key {
        case "audio_on": return "🎙 Audio confirmed"
        case "packed": return "🔥 Crowd density high"
        case "seats_open": return "🪑 Seating demand visible"
        case "specials": return "🍺 Drink specials popular"
        case "tv_visible": return "📺 TVs visible"
        default: return "⭐️ \(best.key.replacingOccurrences(of: "_", with: " "))"
        }
    }

    var body: some View {
        let momentum = momentumState
        let identity = HostedVenueGameCardIdentity(row: row)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(identity.primaryTitle)
                        .font(.headline.weight(.black))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                    Text(identity.secondaryLine)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.82))
                        .lineLimit(2)
                    Text(dateTimeLine.isEmpty ? "Schedule unavailable" : dateTimeLine)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                Spacer(minLength: 8)
                Text(isLiveToday ? "Live" : "Momentum \(score)")
                    .font(.caption2.weight(.black))
                    .foregroundStyle(isLiveToday ? FGColor.accentGreen : FGColor.primaryText(colorScheme))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background((isLiveToday ? FGColor.accentGreen : momentum.tint).opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule(style: .continuous))
            }

            Text(momentum.label)
                .font(.caption.weight(.heavy))
                .foregroundStyle(momentum.tint)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(momentum.tint.opacity(colorScheme == .dark ? 0.18 : 0.10), in: Capsule(style: .continuous))

            HStack(spacing: 8) {
                if goingCount > 0 { insightMetricPill("👥", goingCount, "interested", FGColor.accentBlue) }
                if commentCount > 0 { insightMetricPill("💬", commentCount, "fan chat", FGColor.accentGreen) }
                if vibeTotal > 0 { insightMetricPill("⚡", vibeTotal, "energy", FGColor.accentYellow) }
            }

            if let topVibeLine {
                HStack(spacing: 8) {
                    Text("Top Fan Signal")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(topVibeLine)
                        .font(.caption.weight(.heavy))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .background(
            LinearGradient(
                colors: [
                    momentum.tint.opacity(colorScheme == .dark ? 0.14 : 0.07),
                    FGAdaptiveSurface.cardElevated.opacity(0.98)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(momentum.tint.opacity(colorScheme == .dark ? 0.24 : 0.14), lineWidth: 1)
        }
    }

    private func metricCell(title: String, value: Int, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text("\(value)")
                .font(.title3)
                .fontWeight(.black)
                .foregroundStyle(accent)
                .contentTransition(.numericText())
                .animation(.easeOut(duration: 0.22), value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(FGAdaptiveSurface.controlFill)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var vibeBadgeRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Vibe taps")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    vibeChip("🔊 Audio", audioCount, Color.blue.opacity(0.22))
                    vibeChip("🔥 Packed", packedCount, Color.orange.opacity(0.25))
                    vibeChip("🪑 Seats open", seatsOpenCount, Color.green.opacity(0.22))
                    vibeChip("🍺 Specials", specialsCount, Color.purple.opacity(0.22))
                    vibeChip("📺 TVs", tvVisibleCount, Color.gray.opacity(0.2))
                }
            }
        }
    }

    private func vibeChip(_ title: String, _ count: Int, _ fill: Color) -> some View {
        Text("\(title) \(count)")
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(fill)
            .foregroundStyle(.primary)
            .clipShape(Capsule())
            .contentTransition(.numericText())
    }

    private func insightMetricPill(_ symbol: String, _ value: Int, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 5) {
            Text(symbol)
                .font(.caption2)
                .accessibilityHidden(true)
            Text("\(value)")
                .font(.caption.weight(.black))
            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .foregroundStyle(FGColor.primaryText(colorScheme))
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(tint.opacity(colorScheme == .dark ? 0.16 : 0.09), in: Capsule(style: .continuous))
    }

    private static let analyticsDetailDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.dateFormat = "EEE • MMM d • h:mm a"
        return formatter
    }()
}

