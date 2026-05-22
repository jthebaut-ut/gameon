import SwiftUI
import Combine
import CoreLocation
import MapKit

enum PickupGameFormMode: Identifiable, Equatable {
    case add
    case edit(PickupGameRow)

    var id: String {
        switch self {
        case .add: return "pickup-form-add"
        case .edit(let row): return "pickup-form-\(row.id.uuidString)"
        }
    }
}

/// Settings → list of the signed-in fan’s pickup games (nested sheet for add / edit).
struct SettingsPickupGamesListSheet: View {
    @ObservedObject var viewModel: MapViewModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dismiss) private var dismiss

    @State private var formMode: PickupGameFormMode?
    @State private var deleteTarget: PickupGameRow?
    @State private var banner: String?
    @State private var organizerRequestsGame: PickupGameRow?
    /// Drives local countdown label refresh every minute without refetching Supabase.
    @State private var listClockTick: Date = Date()
    /// At most one delayed refresh per sheet visit when any row passes its cleanup deadline.
    @State private var didScheduleExpiryListRefresh = false

    private let listMinuteTicker = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    var body: some View {
        List {
            if viewModel.myPickupGamesForSettings.isEmpty, viewModel.myRemovedPickupGamesForSettings.isEmpty {
                SettingsPickupGamesEmptyStateCard(colorScheme: colorScheme) {
                    formMode = .add
                }
                .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 28, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                if !viewModel.myPickupGamesForSettings.isEmpty {
                    Section {
                        ForEach(viewModel.myPickupGamesForSettings) { row in
                            let pendingHere = viewModel.organizerPendingPickupJoinRequests(for: row.id)
                            SettingsPickupMyGameListCard(
                                viewModel: viewModel,
                                row: row,
                                pendingJoinCount: pendingHere,
                                withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
                                now: listClockTick,
                                colorScheme: colorScheme,
                                onEdit: {
                                    viewModel.logPickupGamesEditRequested(id: row.id)
                                    formMode = .edit(row)
                                },
                                onDelete: { deleteTarget = row },
                                onManageRequests: { organizerRequestsGame = row }
                            )
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        if viewModel.pendingPickupGameJoinRequestCount > 0 {
                            HStack(alignment: .center, spacing: FGSpacing.sm) {
                                Image(systemName: "person.crop.circle.badge.clock")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                                Text(
                                    viewModel.pendingPickupGameJoinRequestCount == 1
                                        ? "1 player asked to join a game you host — review below."
                                        : "\(viewModel.pendingPickupGameJoinRequestCount) players asked to join games you host — review below."
                                )
                                .font(FGTypography.caption.weight(.semibold))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.vertical, 6)
                            .textCase(nil)
                        }
                    }
                }

                if !viewModel.myRemovedPickupGamesForSettings.isEmpty {
                    Section {
                        ForEach(viewModel.myRemovedPickupGamesForSettings) { row in
                            SettingsPickupRemovedHistoryCard(
                                viewModel: viewModel,
                                row: row,
                                withdrawnJoinRows: viewModel.pickupOrganizerWithdrawnRequestsByGameId[row.id] ?? [],
                                now: listClockTick,
                                colorScheme: colorScheme,
                                useCompactCopy: horizontalSizeClass == .compact
                            )
                            .listRowInsets(EdgeInsets(top: 10, leading: 20, bottom: 10, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        }
                    } header: {
                        Text("History")
                            .font(FGTypography.caption.weight(.semibold))
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .textCase(nil)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle("My pickup games")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") { dismiss() }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    formMode = .add
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .accessibilityLabel("Host Pickup Game")
            }
        }
        .task {
            await viewModel.loadMyPickupGamesForSettings()
            if let uid = viewModel.currentUserAuthId {
                await viewModel.refreshPickupCreatorPublicRatingStats(creatorUserIds: [uid])
            }
        }
        .onAppear {
            listClockTick = Date()
            didScheduleExpiryListRefresh = false
            scheduleOneShotListRefreshIfAnyRowPastCleanup(now: Date())
            if !viewModel.canFanUsePickupGamesUI {
                dismiss()
            }
        }
        .onReceive(listMinuteTicker) { date in
            listClockTick = date
            scheduleOneShotListRefreshIfAnyRowPastCleanup(now: date)
        }
        .sheet(item: $formMode) { mode in
            NavigationStack {
                SettingsPickupGameFormView(viewModel: viewModel, mode: mode) {
                    formMode = nil
                    Task { await viewModel.loadMyPickupGamesForSettings() }
                }
            }
        }
        .sheet(item: $organizerRequestsGame, onDismiss: {
            Task { await viewModel.loadMyPickupGamesForSettings() }
        }) { game in
            PickupOrganizerRequestsSheet(viewModel: viewModel, game: game)
        }
        .alert("Cancel this pickup game?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Keep game", role: .cancel) { deleteTarget = nil }
            Button("Cancel game", role: .destructive) {
                guard let row = deleteTarget else { return }
                deleteTarget = nil
                Task { await performDelete(row) }
            }
        } message: {
            Text("Players who requested or joined will be notified.")
        }
        .overlay(alignment: .bottom) {
            if let banner, !banner.isEmpty {
                Text(banner)
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .padding(.horizontal, FGSpacing.md)
                    .padding(.vertical, FGSpacing.sm)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .padding()
            }
        }
    }

    private func scheduleOneShotListRefreshIfAnyRowPastCleanup(now: Date) {
        guard !didScheduleExpiryListRefresh else { return }
        let rows = viewModel.myPickupGamesForSettings + viewModel.myRemovedPickupGamesForSettings
        let anyPast = rows.contains { row in
            guard let deadline = row.pickupHistoryClientCleanupDeadline() else { return false }
            return now >= deadline
        }
        guard anyPast else { return }
        didScheduleExpiryListRefresh = true
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await viewModel.loadMyPickupGamesForSettings()
        }
    }

    private func performDelete(_ row: PickupGameRow) async {
        do {
            try await viewModel.deletePickupGame(id: row.id)
            banner = nil
            await viewModel.loadMyPickupGamesForSettings()
            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
        } catch {
            banner = error.localizedDescription
        }
    }
}

// MARK: - My pickup games list (Settings) — card UI only

private struct SettingsPickupGamesEmptyStateCard: View {
    let colorScheme: ColorScheme
    var onAdd: () -> Void

    var body: some View {
        VStack(alignment: .center, spacing: 14) {
            Image(systemName: "figure.run.circle.fill")
                .font(.system(size: 44, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(FGColor.accentBlue.opacity(0.85))

            Text("No pickup games yet")
                .font(.title3.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .multilineTextAlignment(.center)

            Text("Create one and invite nearby players.")
                .font(FGTypography.body)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button(action: onAdd) {
                Text("Host Pickup Game")
                    .font(FGTypography.body.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(FGColor.accentBlue)
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.45 : 0.08), radius: 16, x: 0, y: 8)
        .accessibilityElement(children: .contain)
    }
}

enum SettingsPickupMyGameListCardDisplayStyle: Equatable {
    case settingsFull
    case followingCompact
}

private enum SettingsPickupGameListCardStatus: Equatable {
    case open
    case full
    case pendingRequests
    case clearingSoon
    case expiredClearing

    var pillTitle: String {
        switch self {
        case .open: return "Open"
        case .full: return "Full"
        case .pendingRequests: return "Pending requests"
        case .clearingSoon: return "Clearing soon"
        case .expiredClearing: return "Expired"
        }
    }

    func pillForeground(colorScheme: ColorScheme) -> Color {
        switch self {
        case .open:
            return FGColor.secondaryText(colorScheme)
        case .full:
            return FGColor.accentYellow
        case .pendingRequests:
            return Color.orange
        case .clearingSoon:
            return Color.orange
        case .expiredClearing:
            return FGColor.dangerRed
        }
    }

    func pillBackground(colorScheme: ColorScheme) -> Color {
        switch self {
        case .open:
            return Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06)
        case .full:
            return FGColor.accentYellow.opacity(colorScheme == .dark ? 0.22 : 0.14)
        case .pendingRequests:
            return Color.orange.opacity(colorScheme == .dark ? 0.22 : 0.14)
        case .clearingSoon:
            return Color.orange.opacity(colorScheme == .dark ? 0.2 : 0.12)
        case .expiredClearing:
            return FGColor.dangerRed.opacity(colorScheme == .dark ? 0.22 : 0.12)
        }
    }
}

// MARK: - Organizer pickup roster (Settings → My pickup games)

private struct PickupOrganizerApprovedRosterStripView: View {
    @ObservedObject var viewModel: MapViewModel
    let game: PickupGameRow
    let colorScheme: ColorScheme
    let approvedUserIds: [UUID]
    var onAvatarTapped: (UUID) -> Void

    private let avatarDiameter: CGFloat = 34
    private var avatarOverlapInset: CGFloat { -(avatarDiameter - 12) }

    private var organizerStatsApproved: Int {
        viewModel.pickupOrganizerJoinStatsByGameId[game.id]?.approved ?? 0
    }

    private var totalApproved: Int {
        max(approvedUserIds.count, game.approvedJoinCount, organizerStatsApproved)
    }

    private var visibleFaceUserIds: [UUID] {
        if approvedUserIds.count <= 5 { return approvedUserIds }
        return Array(approvedUserIds.prefix(5))
    }

    private var overflowCountLabel: String? {
        guard approvedUserIds.count > 5 else { return nil }
        return "+\(approvedUserIds.count - 5)"
    }

    var body: some View {
        HStack(spacing: 0) {
            if totalApproved > 0, approvedUserIds.isEmpty {
                ProgressView()
                    .scaleEffect(0.85)
                    .padding(.trailing, 8)
            }

            HStack(spacing: avatarOverlapInset) {
                ForEach(Array(visibleFaceUserIds.enumerated()), id: \.element) { idx, uid in
                    rosterFace(for: uid)
                        .zIndex(Double(idx))
                }
                if let overflowCountLabel {
                    overflowChip(text: overflowCountLabel)
                        .zIndex(Double(visibleFaceUserIds.count))
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .accessibilityElement(children: .contain)
        .onAppear { logPickupRosterUI(reason: "appear") }
        .onChange(of: approvedUserIds.count) { _, _ in logPickupRosterUI(reason: "idsCount") }
        .onChange(of: game.approved_join_count ?? -1) { _, _ in logPickupRosterUI(reason: "approvedJoinCount") }
        .onChange(of: game.pickupOpenSlotsRemaining) { _, _ in logPickupRosterUI(reason: "openSlots") }
    }

    @ViewBuilder
    private func rosterFace(for userId: UUID) -> some View {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[userId]
        let profileName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = profileName.isEmpty ? "Player" : profileName
        let emailLine = (profile?.email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let fullRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb: String? = thumbRaw.isEmpty ? nil : thumbRaw
        let full = fullRaw.isEmpty ? "" : fullRaw
        let token = viewModel.pickupJoinRequesterAvatarTokenByUserId[userId] ?? UUID()
        let fallback: UserAvatarView.FallbackStyle = colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome

        Button {
            onAvatarTapped(userId)
        } label: {
            UserAvatarView(
                avatarThumbnailURL: thumb,
                avatarURL: full,
                avatarDisplayRefreshToken: token,
                displayName: displayName,
                email: emailLine,
                size: avatarDiameter,
                fallbackStyle: fallback,
                imagePlaceholderTint: colorScheme == .dark ? .white.opacity(0.75) : nil
            )
            .overlay(
                Circle()
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.35 : 0.72), lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.35 : 0.12), radius: 3, x: 0, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Joined player \(displayName)")
    }

    private func overflowChip(text: String) -> some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(colorScheme == .dark ? 0.22 : 0.1))
            Text(text)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
        }
        .frame(width: avatarDiameter, height: avatarDiameter)
        .overlay(
            Circle()
                .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.35 : 0.72), lineWidth: 1.5)
        )
        .accessibilityLabel("\(text) more players")
    }

    private func logPickupRosterUI(reason: String) {
#if DEBUG
        let visFaces = visibleFaceUserIds.count + (overflowCountLabel != nil ? 1 : 0)
        print("[PickupRosterUI] gameId=\(game.id.uuidString.lowercased()) reason=\(reason)")
        print("[PickupRosterUI] approvedCount=\(totalApproved)")
        print("[PickupRosterUI] visibleAvatars=\(visFaces)")
#endif
    }
}

struct SettingsPickupMyGameListCard: View {
    @ObservedObject var viewModel: MapViewModel
    @EnvironmentObject private var chatViewModel: ChatViewModel
    let row: PickupGameRow
    let pendingJoinCount: Int
    let withdrawnJoinRows: [PickupGameRequestRow]
    let now: Date
    let colorScheme: ColorScheme
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onManageRequests: () -> Void
    var displayStyle: SettingsPickupMyGameListCardDisplayStyle = .settingsFull
    var onOpenDetails: (() -> Void)? = nil

    @State private var rosterActionUserId: UUID?
    @State private var showRosterPlayerActions: Bool = false

    private var approvedJoinerUserIds: [UUID] {
        viewModel.pickupOrganizerApprovedJoinerUserIdsByGameId[row.id] ?? []
    }

    private var isFollowingCompact: Bool {
        displayStyle == .followingCompact
    }

    private var status: SettingsPickupGameListCardStatus {
        Self.computeStatus(row: row, pendingJoinCount: pendingJoinCount, now: now)
    }

    private var isExpiredClearing: Bool {
        status == .expiredClearing
    }

    private var usesExpiredArchivedStyle: Bool {
        isFollowingCompact && isExpiredClearing
    }

    private var cardTextOpacity: Double {
        usesExpiredArchivedStyle ? 0.62 : 1
    }

    private var cardPrimaryTextColor: Color {
        usesExpiredArchivedStyle
            ? FGColor.secondaryText(colorScheme)
            : FGColor.primaryText(colorScheme)
    }

    private var cardBackgroundStyle: AnyShapeStyle {
        if usesExpiredArchivedStyle {
            let fill = colorScheme == .dark
                ? Color.white.opacity(0.035)
                : Color(.systemGray6).opacity(0.98)
            return AnyShapeStyle(fill)
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }

    private var cardStrokeColor: Color {
        if usesExpiredArchivedStyle {
            return colorScheme == .dark
                ? Color.white.opacity(0.08)
                : Color.black.opacity(0.055)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08)
    }

    private var gameStarted: Bool {
        row.hasPickupGameStarted(now: now)
    }

    private static func computeStatus(row: PickupGameRow, pendingJoinCount: Int, now: Date) -> SettingsPickupGameListCardStatus {
        guard let deadline = SettingsPickupCleanupDisplay.cleanupDeadline(for: row) else {
            if pendingJoinCount > 0 { return .pendingRequests }
            return row.isPickupFullForDiscover ? .full : .open
        }
        if now >= deadline { return .expiredClearing }
        let remaining = deadline.timeIntervalSince(now)
        if remaining < 3600 { return .clearingSoon }
        if pendingJoinCount > 0 { return .pendingRequests }
        if row.isPickupFullForDiscover { return .full }
        return .open
    }

    private var locationLine: String? {
        let parts = [row.address, row.city, row.state]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: ", ")
    }

    private var dateTimeLine: String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return nil }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    private var organizerStatsApproved: Int {
        viewModel.pickupOrganizerJoinStatsByGameId[row.id]?.approved ?? 0
    }

    private var displayedJoinedPlayerCount: Int {
        max(organizerStatsApproved, row.approvedJoinCount, approvedJoinerUserIds.count)
    }

    private var displayedOpenSlots: Int {
        max(0, row.playersNeededClamped - displayedJoinedPlayerCount)
    }

    private var displayedRosterIsFull: Bool {
        displayedJoinedPlayerCount >= row.playersNeededClamped
    }

    private var playersSummaryLine: String {
        let need = row.playersNeededClamped
        let joined = displayedJoinedPlayerCount
        let open = displayedOpenSlots
        if displayedRosterIsFull {
            return "Roster full"
        }
        if joined == 0 {
            return open == 1 ? "1 spot open" : "\(open) spots open"
        }
        let base = "\(joined)/\(need) players joined"
        if open <= 0 { return base }
        let spotPhrase = open == 1 ? "1 spot open" : "\(open) spots open"
        return "\(base) · \(spotPhrase)"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: isFollowingCompact ? 16 : 24, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: isFollowingCompact ? 10 : 14) {
                PickupGameStartedSportGlyphFrame(showStarted: gameStarted && !usesExpiredArchivedStyle) {
                    SportArtworkIconView(sport: row.sport, diameter: isFollowingCompact ? 44 : 50)
                }
                .saturation(usesExpiredArchivedStyle ? 0 : 1)
                .opacity(usesExpiredArchivedStyle ? 0.48 : 1)

                VStack(alignment: .leading, spacing: isFollowingCompact ? 4 : 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.title)
                            .font(isFollowingCompact ? .headline.weight(.bold) : .title3.weight(.bold))
                            .foregroundStyle(cardPrimaryTextColor)
                            .lineLimit(isFollowingCompact ? 2 : 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .opacity(cardTextOpacity)

                        Text(status.pillTitle)
                            .font(.caption.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                            .foregroundStyle(status.pillForeground(colorScheme: colorScheme))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(status.pillBackground(colorScheme: colorScheme), in: Capsule(style: .continuous))
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.08), lineWidth: 1)
                            )
                            .fixedSize(horizontal: true, vertical: false)
                            .accessibilityLabel("Status: \(status.pillTitle)")
                    }

                    if !isFollowingCompact {
                        PickupCreatorTrustLineView(stats: viewModel.pickupCreatorTrustStats(for: row.creator_user_id))
                    }

                    if pendingJoinCount > 0, !usesExpiredArchivedStyle {
                        Button(action: onManageRequests) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.clock")
                                    .font(.system(size: isFollowingCompact ? 14 : 15, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                                Text(pendingJoinCount == 1 ? "1 player waiting" : "\(pendingJoinCount) players waiting")
                                    .font(isFollowingCompact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                                    .foregroundStyle(Color.orange)
                                    .opacity(cardTextOpacity)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.orange.opacity(0.85))
                            }
                            .padding(.horizontal, isFollowingCompact ? 10 : 12)
                            .padding(.vertical, isFollowingCompact ? 6 : 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pendingJoinCount) players waiting. Tap to review.")
                    }
                }
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: isFollowingCompact ? 8 : 10) {
                if let dateTimeLine {
                    SettingsPickupCardMetaRow(systemImage: "calendar", title: "When", value: dateTimeLine)
                        .opacity(cardTextOpacity)
                    if gameStarted && !usesExpiredArchivedStyle {
                        HStack(alignment: .center, spacing: 10) {
                            Image(systemName: "play.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(FGColor.accentGreen.opacity(0.65))
                                .frame(width: 22, alignment: .center)
                            PickupGameStartedLineCaption()
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if let locationLine {
                    SettingsPickupCardMetaRow(systemImage: "mappin.and.ellipse", title: "Location", value: locationLine)
                        .opacity(cardTextOpacity)
                }
                SettingsPickupCardMetaRow(systemImage: "person.3", title: "Players", value: playersSummaryLine)
                    .opacity(cardTextOpacity)
                if !usesExpiredArchivedStyle {
                    PickupOrganizerApprovedRosterStripView(
                        viewModel: viewModel,
                        game: row,
                        colorScheme: colorScheme,
                        approvedUserIds: approvedJoinerUserIds,
                        onAvatarTapped: { uid in
                            viewModel.presentPublicProfile(
                                userId: uid,
                                context: "pickup_roster_avatar",
                                activeSheet: "settings_pickup_games"
                            )
                        }
                    )
                }
                if !isFollowingCompact {
                    SettingsPickupCardMetaRow(systemImage: "chart.bar", title: "Skill", value: row.skillLevelEnum.displayTitle)
                        .opacity(cardTextOpacity)
                    SettingsPickupCardMetaRow(
                        systemImage: row.playEnvironmentEnum == .indoor ? "house.fill" : (row.playEnvironmentEnum == .outdoor ? "sun.max.fill" : "arrow.left.arrow.right"),
                        title: "Play",
                        value: row.playEnvironmentEnum.shortLabel
                    )
                    .opacity(cardTextOpacity)
                    SettingsPickupCardMetaRow(systemImage: row.is_free ? "gift.fill" : "dollarsign.circle", title: "Cost", value: row.entryFeeDisplayLine)
                        .opacity(cardTextOpacity)
                }
            }
            .padding(.top, 6)

            if !row.is_visible {
                Text("Hidden from map")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: isFollowingCompact ? 8 : 10) {
                if pendingJoinCount > 0, !isFollowingCompact {
                    Button(action: onManageRequests) {
                        Label("Manage requests", systemImage: "person.badge.clock")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.orange)
                    .accessibilityHint("Review pending join requests")

                    Text("Tap above to review who asked to join.")
                        .font(.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }

                if !withdrawnJoinRows.isEmpty, !usesExpiredArchivedStyle {
                    VStack(alignment: .leading, spacing: isFollowingCompact ? 6 : 10) {
                        Text("Can’t make it")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                        ForEach(withdrawnJoinRows) { wr in
                            SettingsPickupWithdrawnJoinRow(
                                viewModel: viewModel,
                                request: wr,
                                organizerCanceledJoinCopy: false,
                                useCompact: horizontalSizeClass == .compact || isFollowingCompact
                            )
                        }
                    }
                    .padding(.top, pendingJoinCount > 0 && !isFollowingCompact ? 8 : 0)
                }

                HStack(spacing: 10) {
                    if !(isFollowingCompact && isExpiredClearing) {
                        Button(action: onEdit) {
                            Label(gameStarted ? "Manage" : "Edit", systemImage: "pencil")
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .tint(FGColor.accentBlue)
                    }

                    Button(role: .destructive, action: onDelete) {
                        Label(isFollowingCompact && isExpiredClearing ? "Clear expired" : "Cancel game", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                if isFollowingCompact, !isExpiredClearing, let onOpenDetails {
                    Button(action: onOpenDetails) {
                        Label("Details & cleanup", systemImage: "ellipsis.circle")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, isFollowingCompact ? 10 : 14)

            if !isFollowingCompact {
                Divider()
                    .opacity(colorScheme == .dark ? 0.35 : 0.5)
                    .padding(.vertical, 10)

                SettingsPickupCleanupCountdownRow(row: row, now: now, isFooterStyle: true)
            } else {
                let snap = SettingsPickupCleanupDisplay.snapshot(row: row, now: now)
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: snap.symbolName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(snap.label)
                        .font(FGTypography.metadata)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .padding(.top, 4)
            }
        }
        .padding(isFollowingCompact ? 14 : 18)
        .background(cardBackgroundStyle, in: shape)
        .overlay(
            shape.strokeBorder(cardStrokeColor, lineWidth: 1)
        )
        .shadow(
            color: Color.black.opacity(usesExpiredArchivedStyle ? (colorScheme == .dark ? 0.18 : 0.035) : (colorScheme == .dark ? 0.42 : 0.1)),
            radius: isFollowingCompact ? (usesExpiredArchivedStyle ? 4 : 8) : 14,
            x: 0,
            y: isFollowingCompact ? (usesExpiredArchivedStyle ? 1 : 3) : 6
        )
        .accessibilityElement(children: .contain)
        .onAppear {
            let actions = gameStarted ? "manage_players,roster_capacity_only" : "full_edit,delete,manage_requests"
            PickupGameStartedStateDebug.log(row: row, now: now, allowedActions: actions)
        }
        .confirmationDialog("Player", isPresented: $showRosterPlayerActions, titleVisibility: .visible) {
            if let uid = rosterActionUserId,
               viewModel.isAuthenticatedForSocialFeatures,
               viewModel.currentUserAuthId != uid {
                rosterPlayerAvatarSocialActions(for: uid)
            }
            Button("Cancel", role: .cancel) {
                rosterActionUserId = nil
            }
        } message: {
            if let u = rosterActionUserId {
                Text(Self.rosterActionMessage(userId: u, viewModel: viewModel))
            }
        }
    }

    @ViewBuilder
    private func rosterPlayerAvatarSocialActions(for uid: UUID) -> some View {
        switch chatViewModel.chipKind(forOtherUserId: uid) {
        case .friends:
            Button("Message friend") {
                rosterActionUserId = nil
                showRosterPlayerActions = false
                guard let p = userPreviewForRoster(userId: uid) else {
                    print("[PickupRosterAvatarFriendship] error=missing_user_preview userId=\(uid.uuidString.lowercased())")
                    viewModel.showSocialActionToast("Couldn’t open chat. Try again.", isError: true)
                    return
                }
                Task { await openMessageFriendFromRoster(preview: p, peerUserId: uid) }
            }
        case .addFriend, .declinedOutgoing:
            Button("Request friendship") {
                rosterActionUserId = nil
                Task { await sendRosterFriendRequest(to: uid) }
            }
        case .pendingOutgoing, .pendingIncoming:
            Button("Friendship requested") {}
                .disabled(true)
        }
    }

    private func userPreviewForRoster(userId: UUID) -> UserPreview? {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[userId]
        let name = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let display = name.isEmpty ? "Player" : name
        let email = profile?.email
        let full = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let handle = profile?.username?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return UserPreview(
            id: userId,
            displayName: display,
            username: handle.isEmpty ? nil : FanGeoHandleRules.normalizeForStorage(handle),
            email: email,
            avatarURL: full.isEmpty ? nil : full,
            avatarThumbnailURL: thumb.isEmpty ? nil : thumb
        )
    }

    private static func rosterActionMessage(userId: UUID, viewModel: MapViewModel) -> String {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[userId]
        let name = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "Joined player" : name
    }

    private static func tappedPlayerEmailLine(userId: UUID, viewModel: MapViewModel) -> String {
        let raw = (viewModel.pickupJoinRequesterProfileByUserId[userId]?.email ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.isEmpty ? "(none)" : raw
    }

    private static func friendshipStatusLog(chip: ChatViewModel.FriendshipChipKind) -> String {
        switch chip {
        case .addFriend: return "addFriend"
        case .friends: return "friends"
        case .pendingOutgoing: return "pendingOutgoing"
        case .pendingIncoming: return "pendingIncoming"
        case .declinedOutgoing: return "declinedOutgoing"
        }
    }

    private static func pickupRosterFriendshipActionShown(chip: ChatViewModel.FriendshipChipKind) -> String {
        switch chip {
        case .friends:
            return "Message friend"
        case .addFriend, .declinedOutgoing:
            return "Request friendship"
        case .pendingOutgoing, .pendingIncoming:
            return "Friendship requested(disabled)"
        }
    }

    private static func logPickupRosterAvatarFriendship(
        tappedPlayerId: UUID,
        tappedPlayerEmail: String,
        friendshipStatus: String,
        actionShown: String,
        requestCreated: Bool,
        existingRequestFound: Bool,
        openedDM: Bool
    ) {
#if DEBUG
        print("[PickupRosterAvatarFriendship] tappedPlayerId=\(tappedPlayerId.uuidString.lowercased())")
        print("[PickupRosterAvatarFriendship] tappedPlayerEmail=\(tappedPlayerEmail)")
        print("[PickupRosterAvatarFriendship] friendshipStatus=\(friendshipStatus)")
        print("[PickupRosterAvatarFriendship] actionShown=\(actionShown)")
        print("[PickupRosterAvatarFriendship] requestCreated=\(requestCreated)")
        print("[PickupRosterAvatarFriendship] existingRequestFound=\(existingRequestFound)")
        print("[PickupRosterAvatarFriendship] openedDM=\(openedDM)")
#endif
    }

    private static func logPickupRosterMessageFriendOpen(
        messageFriendTapped: Bool,
        tappedPlayerId: UUID,
        tappedPlayerEmail: String,
        friendshipStatus: String,
        conversationId: UUID?,
        openedDM: Bool,
        error: String
    ) {
#if DEBUG
        print("[PickupRosterAvatarFriendship] messageFriendTapped=\(messageFriendTapped)")
        print("[PickupRosterAvatarFriendship] tappedPlayerId=\(tappedPlayerId.uuidString.lowercased())")
        print("[PickupRosterAvatarFriendship] tappedPlayerEmail=\(tappedPlayerEmail)")
        print("[PickupRosterAvatarFriendship] friendshipStatus=\(friendshipStatus)")
        if let conversationId {
            print("[PickupRosterAvatarFriendship] conversationId=\(conversationId.uuidString.lowercased())")
        } else {
            print("[PickupRosterAvatarFriendship] conversationId=")
        }
        print("[PickupRosterAvatarFriendship] openedDM=\(openedDM)")
        print("[PickupRosterAvatarFriendship] error=\(error)")
#endif
    }

    private func openMessageFriendFromRoster(preview: UserPreview, peerUserId: UUID) async {
        let emailLine = Self.tappedPlayerEmailLine(userId: peerUserId, viewModel: viewModel)
        let friendshipStatus = Self.friendshipStatusLog(chip: .friends)
        do {
            let cid = try await chatViewModel.startDirectConversationWithFriend(friendUserId: peerUserId)
            await chatViewModel.refreshInboxSummaries()
            await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
            await MainActor.run {
                chatViewModel.pendingDmOpenPreview = preview
            }
            Self.logPickupRosterMessageFriendOpen(
                messageFriendTapped: true,
                tappedPlayerId: peerUserId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: friendshipStatus,
                conversationId: cid,
                openedDM: true,
                error: ""
            )
        } catch {
            print("[PickupRosterAvatarFriendship] error=\(error.localizedDescription)")
            Self.logPickupRosterMessageFriendOpen(
                messageFriendTapped: true,
                tappedPlayerId: peerUserId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: friendshipStatus,
                conversationId: nil,
                openedDM: false,
                error: error.localizedDescription
            )
            await MainActor.run {
                viewModel.showSocialActionToast("Couldn’t open chat. Try again.", isError: true)
            }
        }
    }

    private func sendRosterFriendRequest(to userId: UUID) async {
        let emailLine = Self.tappedPlayerEmailLine(userId: userId, viewModel: viewModel)
        let chipBefore = chatViewModel.chipKind(forOtherUserId: userId)
        if chipBefore == .pendingOutgoing || chipBefore == .pendingIncoming {
            Self.logPickupRosterAvatarFriendship(
                tappedPlayerId: userId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: Self.friendshipStatusLog(chip: chipBefore),
                actionShown: Self.pickupRosterFriendshipActionShown(chip: chipBefore),
                requestCreated: false,
                existingRequestFound: true,
                openedDM: false
            )
            return
        }
        await chatViewModel.sendFriendRequestFromComments(to: userId)
        if let err = chatViewModel.errorMessage, !err.isEmpty {
            let duplicate = err.localizedCaseInsensitiveContains("already exists")
            Self.logPickupRosterAvatarFriendship(
                tappedPlayerId: userId,
                tappedPlayerEmail: emailLine,
                friendshipStatus: Self.friendshipStatusLog(chip: chatViewModel.chipKind(forOtherUserId: userId)),
                actionShown: "Request friendship",
                requestCreated: false,
                existingRequestFound: duplicate,
                openedDM: false
            )
            if duplicate {
                await chatViewModel.refreshFriendRequestListsOnly()
                await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
                viewModel.showSocialActionToast("Friend request already pending.", isError: false)
            } else {
                viewModel.showSocialActionToast(err, isError: true)
            }
            return
        }
        Self.logPickupRosterAvatarFriendship(
            tappedPlayerId: userId,
            tappedPlayerEmail: emailLine,
            friendshipStatus: Self.friendshipStatusLog(chip: chatViewModel.chipKind(forOtherUserId: userId)),
            actionShown: Self.pickupRosterFriendshipActionShown(chip: chatViewModel.chipKind(forOtherUserId: userId)),
            requestCreated: true,
            existingRequestFound: false,
            openedDM: false
        )
        viewModel.showSocialActionToast("Friend request sent", isError: false)
        await chatViewModel.ensureSignedInSocialRealtimeIfNeeded()
    }
}

/// Soft-removed pickup (`status = removed`) shown under History.
struct SettingsPickupRemovedHistoryCard: View {
    @ObservedObject var viewModel: MapViewModel
    let row: PickupGameRow
    let withdrawnJoinRows: [PickupGameRequestRow]
    let now: Date
    let colorScheme: ColorScheme
    var useCompactCopy: Bool

    private var dateTimeLine: String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return nil }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                SportArtworkIconView(sport: row.sport, diameter: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(row.title)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(3)
                    if let dateTimeLine {
                        Text(dateTimeLine)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                Spacer(minLength: 0)
                Text("Removed")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.mutedText(colorScheme))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.06), in: Capsule(style: .continuous))
            }

            Text("This pickup was canceled and is hidden from Discover and player lists.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            if !withdrawnJoinRows.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Players affected")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    ForEach(withdrawnJoinRows) { wr in
                        SettingsPickupWithdrawnJoinRow(
                            viewModel: viewModel,
                            request: wr,
                            organizerCanceledJoinCopy: true,
                            useCompact: useCompactCopy
                        )
                    }
                }
            }

            SettingsPickupRemovedHistoryCleanupFooter(
                viewModel: viewModel,
                row: row,
                now: now,
                colorScheme: colorScheme
            )
        }
        .padding(18)
        .background(.ultraThinMaterial, in: shape)
        .overlay(
            shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
        )
    }
}

/// Footer for removed games: explicit clear action + auto-clear hint (no “in progress” copy unless something is actually running).
private struct SettingsPickupRemovedHistoryCleanupFooter: View {
    @ObservedObject var viewModel: MapViewModel
    let row: PickupGameRow
    let now: Date
    let colorScheme: ColorScheme

    private var cleanupDeadline: Date? {
        row.pickupHistoryClientCleanupDeadline()
    }

    private var autoClearCaption: String {
        guard let deadline = cleanupDeadline else {
            return "Auto-clears 12h after start"
        }
        if now >= deadline {
            return "Auto-clears 12h after start"
        }
        return "Auto-clears \(deadline.formatted(date: .abbreviated, time: .shortened))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(autoClearCaption)
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
                .fixedSize(horizontal: false, vertical: true)

            Button {
                viewModel.markPickupOrganizerSettingsHistoryUserCleared(pickupGameId: row.id)
            } label: {
                Text("Clear now")
                    .font(FGTypography.metadata.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.bordered)
            .tint(Color.red.opacity(0.88))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One withdrawn / cancelled joiner row on the organizer’s Settings pickup card.
private struct SettingsPickupWithdrawnJoinRow: View {
    @ObservedObject var viewModel: MapViewModel
    let request: PickupGameRequestRow
    var organizerCanceledJoinCopy: Bool
    var useCompact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let profile = viewModel.pickupJoinRequesterProfileByUserId[request.requester_user_id]
        let profileName = profile?.display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = profileName.isEmpty ? request.requesterNameForUI : profileName
        let emailLine = (profile?.email ?? request.requester_email ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let thumbRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_thumbnail_url)
        let fullRaw = ImageDisplayURL.canonicalStorageURLString(profile?.avatar_url)
        let thumb: String? = thumbRaw.isEmpty ? nil : thumbRaw
        let full = fullRaw.isEmpty ? "" : fullRaw
        let token = viewModel.pickupJoinRequesterAvatarTokenByUserId[request.requester_user_id] ?? UUID()

        HStack(alignment: .top, spacing: 12) {
            PublicProfileAvatarTap(
                userId: request.requester_user_id,
                context: "pickup_withdrawn_joiner",
                activeSheet: "settings_pickup_games"
            ) {
                UserAvatarView(
                    avatarThumbnailURL: thumb,
                    avatarURL: full,
                    avatarDisplayRefreshToken: token,
                    displayName: displayName,
                    email: emailLine,
                    size: 40,
                    fallbackStyle: colorScheme == .dark ? .darkCardTranslucent : .lightOnWhiteChrome
                )
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(displayName)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                Text(organizerCanceledJoinCopy ? "Canceled by organizer" : request.organizerFanWithdrawnSubtitle())
                    .font(.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                if let stamp = request.organizerFanWithdrawnTimestampLine(compactWidth: useCompact) {
                    Text(stamp)
                        .font(.caption2)
                        .foregroundStyle(FGColor.mutedText(colorScheme))
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(colorScheme == .dark ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: request.requester_user_id) {
            await viewModel.loadPickupJoinRequesterProfilesForOrganizerSheet(requesterIds: [request.requester_user_id])
        }
    }
}

private struct SettingsPickupCardMetaRow: View {
    let systemImage: String
    let title: String
    let value: String
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue.opacity(0.85))
                .frame(width: 22, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(title.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                Text(value)
                    .font(.subheadline)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(value)")
    }
}

/// Local-only cleanup countdown copy for organizer Settings list rows.
private enum SettingsPickupCleanupDisplay {
    enum Tone {
        case normal
        case amber
        case danger
    }

    struct Snapshot {
        let label: String
        let symbolName: String
        let tone: Tone
    }

    static func cleanupDeadline(for row: PickupGameRow) -> Date? {
        row.pickupHistoryClientCleanupDeadline()
    }

    static func snapshot(row: PickupGameRow, now: Date) -> Snapshot {
        guard let deadline = cleanupDeadline(for: row) else {
            return Snapshot(label: "Auto-clears 12h after start", symbolName: "clock.arrow.circlepath", tone: .normal)
        }
        guard let gameStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
            if now >= deadline {
                return Snapshot(label: "Past auto-clear time", symbolName: "clock", tone: .normal)
            }
            let remaining = deadline.timeIntervalSince(now)
            if remaining < 3600 {
                let minutes = max(1, Int(ceil(remaining / 60)))
                return Snapshot(label: "Clears in \(minutes)m", symbolName: "timer", tone: .amber)
            }
            let totalSeconds = Int(remaining)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            return Snapshot(label: "Clears in \(hours)h \(minutes)m", symbolName: "timer", tone: .normal)
        }

        if now >= deadline {
            return Snapshot(label: "Past auto-clear time", symbolName: "clock", tone: .normal)
        }

        if now < gameStart {
            return Snapshot(label: "Auto-clears 12h after start", symbolName: "clock.arrow.circlepath", tone: .normal)
        }

        let remaining = deadline.timeIntervalSince(now)
        if remaining < 3600 {
            let minutes = max(1, Int(ceil(remaining / 60)))
            return Snapshot(label: "Clears in \(minutes)m", symbolName: "timer", tone: .amber)
        }

        let totalSeconds = Int(remaining)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        return Snapshot(label: "Clears in \(hours)h \(minutes)m", symbolName: "timer", tone: .normal)
    }
}

private struct SettingsPickupCleanupCountdownRow: View {
    let row: PickupGameRow
    let now: Date
    /// Footer uses smaller type and neutral gray until amber/red.
    var isFooterStyle: Bool = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let snap = SettingsPickupCleanupDisplay.snapshot(row: row, now: now)
        let iconSize: CGFloat = isFooterStyle ? 11 : 13
        let spacing: CGFloat = isFooterStyle ? 5 : 6
        HStack(alignment: .center, spacing: spacing) {
            Image(systemName: snap.symbolName)
                .font(.system(size: iconSize, weight: .semibold))
                .symbolRenderingMode(isFooterStyle && snap.tone == .normal ? .monochrome : .hierarchical)
                .foregroundStyle(labelColor(for: snap.tone))
            Text(snap.label)
                .font(isFooterStyle ? .footnote : FGTypography.caption)
                .foregroundStyle(labelColor(for: snap.tone))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(snap.label)
    }

    private func labelColor(for tone: SettingsPickupCleanupDisplay.Tone) -> Color {
        if isFooterStyle {
            switch tone {
            case .normal:
                return Color.secondary
            case .amber:
                return Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.92)
            case .danger:
                return FGColor.dangerRed
            }
        }
        return ink(for: tone)
    }

    private func ink(for tone: SettingsPickupCleanupDisplay.Tone) -> Color {
        switch tone {
        case .normal:
            return FGColor.secondaryText(colorScheme)
        case .amber:
            return Color.orange.opacity(colorScheme == .dark ? 0.95 : 0.92)
        case .danger:
            return FGColor.dangerRed
        }
    }
}

private enum PickupCostKind: String, CaseIterable, Identifiable {
    case free
    case paid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .free: return "Free"
        case .paid: return "Paid"
        }
    }
}

/// Add or edit a pickup game (fan accounts only; caller gates).
struct SettingsPickupGameFormView: View {
    @ObservedObject var viewModel: MapViewModel
    let mode: PickupGameFormMode
    var onFinished: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dismiss) private var dismiss

    @State private var title: String = ""
    @State private var sport: String = "Soccer"
    @State private var gameDate: Date = Date()
    @State private var gameTime: Date = Date()
    @State private var address: String = ""
    @State private var city: String = ""
    @State private var state: String = ""
    @State private var zipCode: String = ""
    @State private var description: String = ""
    @State private var playEnvironment: PickupPlayEnvironment = .either
    @State private var skillLevel: PickupGameSkillLevel = .casual
    @State private var participantPreference: PickupParticipantPreference = .everyone
    @State private var costKind: PickupCostKind = .free
    @State private var entryFeeText: String = ""
    @State private var playersNeeded: Int = 1
    @State private var useMaxPlayers: Bool = false
    @State private var maxPlayers: Int = 10
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var showPickupMapLocationPicker = false
    @State private var showGameDatePopover = false
    @State private var suppressGameDatePickerChangeLog = false
    @State private var coordinatesLockedFromMap = false
    @State private var mapPinnedCoordinate: CLLocationCoordinate2D?

    private var organizerPostStartLockedRow: PickupGameRow? {
        if case .edit(let row) = mode, row.hasPickupGameStarted(), isCurrentUserCreator(of: row) {
            return row
        }
        return nil
    }

    private var isOrganizerPostStartManage: Bool { organizerPostStartLockedRow != nil }

    private func isCurrentUserCreator(of row: PickupGameRow) -> Bool {
        guard let uid = viewModel.currentUserAuthId else { return false }
        return row.creator_user_id == uid
    }

    private var lockedGameStartDisplay: String {
        guard case .edit(let row) = mode,
              let d = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCity: String {
        city.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedState: String {
        state.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedZipCode: String {
        zipCode.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCompleteTypedAddress: Bool {
        !trimmedAddress.isEmpty && !trimmedCity.isEmpty && !trimmedState.isEmpty && !trimmedZipCode.isEmpty
    }

    /// Post/Save stays tappable once the major address fields are present so ZIP validation can show a clear error.
    private var hasPlacedLocationForPostButton: Bool {
        !trimmedAddress.isEmpty && !trimmedCity.isEmpty && !trimmedState.isEmpty
    }

    private var pickMapSeedCoordinate: CLLocationCoordinate2D {
        if case .edit(let row) = mode,
           let la = row.latitude,
           let lo = row.longitude {
            return CLLocationCoordinate2D(latitude: la, longitude: lo)
        }
        if let r = viewModel.cameraPosition.region {
            return r.center
        }
        return CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.00902)
    }

    private var addressBinding: Binding<String> {
        Binding(
            get: { address },
            set: { newValue in
                address = newValue
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
        )
    }

    private var cityBinding: Binding<String> {
        Binding(
            get: { city },
            set: { newValue in
                city = newValue
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
        )
    }

    private var stateBinding: Binding<String> {
        Binding(
            get: { state },
            set: { newValue in
                state = newValue
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
        )
    }

    private var zipCodeBinding: Binding<String> {
        Binding(
            get: { zipCode },
            set: { newValue in
                zipCode = newValue
                coordinatesLockedFromMap = false
                mapPinnedCoordinate = nil
            }
        )
    }

    private var locationGuidanceFootnote: String? {
        if hasCompleteTypedAddress { return nil }
        if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty && trimmedZipCode.isEmpty {
            return "Location missing"
        }
        if trimmedZipCode.isEmpty {
            return "Enter the ZIP code for this pickup game."
        }
        return "Enter a complete street address, city, state, and ZIP code."
    }

    var body: some View {
        Form {
            if let errorText, !errorText.isEmpty {
                Section {
                    Text(errorText)
                        .font(FGTypography.caption)
                        .foregroundStyle(Color.red)
                }
            }

            if isOrganizerPostStartManage {
                Section {
                    Text(
                        "This game has already started. You can still manage players and open spots, but core details can no longer be changed."
                    )
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Game") {
                if isOrganizerPostStartManage {
                    LabeledContent("Title") {
                        Text(title)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("Sport") {
                        SportSelectionValueView(sport: sport)
                    }
                    LabeledContent("Start") {
                        Text(lockedGameStartDisplay)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                    }
                } else {
                    TextField("Title", text: $title)
                    GameSportSearchablePickerFormRow(selection: $sport)
                    LabeledContent("Date") {
                        Button {
                            showGameDatePopover = true
                        } label: {
                            Text(gameDate.formatted(.dateTime.month(.abbreviated).day().year(.defaultDigits)))
                                .foregroundStyle(FGColor.primaryText(colorScheme))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .buttonStyle(.borderless)
                    }
                    .popover(isPresented: $showGameDatePopover) {
                        pickupGameDatePopover
                    }
                    DatePicker("Start time", selection: $gameTime, displayedComponents: .hourAndMinute)
                }
                Stepper(value: $playersNeeded, in: 1...20) {
                    HStack {
                        Text("Players needed")
                        Spacer(minLength: 0)
                        Text(playersNeeded == 1 ? "1 player" : "\(playersNeeded) players")
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }
                Toggle("Set max players (capacity)", isOn: $useMaxPlayers)
                if useMaxPlayers {
                    Stepper(value: $maxPlayers, in: 1...100) {
                        HStack {
                            Text("Max players")
                            Spacer(minLength: 0)
                            Text("\(maxPlayers)")
                                .foregroundStyle(FGColor.secondaryText(colorScheme))
                        }
                    }
                }
            }

            if !isOrganizerPostStartManage {
                Section("How you play") {
                    Picker("Indoor / outdoor", selection: $playEnvironment) {
                        ForEach(PickupPlayEnvironment.allCases) { env in
                            Text(env.displayTitle).tag(env)
                        }
                    }
                    Picker("Skill level", selection: $skillLevel) {
                        ForEach(PickupGameSkillLevel.allCases) { level in
                            Text(level.displayTitle).tag(level)
                        }
                    }
                    Picker("Who’s welcome", selection: $participantPreference) {
                        ForEach(PickupParticipantPreference.allCases) { pref in
                            Text(pref.displayTitle).tag(pref)
                        }
                    }
                }

                Section("Cost") {
                    Picker("Entry", selection: $costKind) {
                        ForEach(PickupCostKind.allCases) { k in
                            Text(k.title).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    if costKind == .paid {
                        TextField("Amount (USD)", text: $entryFeeText)
                            .keyboardType(.decimalPad)
                        Text("Paid games require an entry amount greater than zero.")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                    }
                }

                Section("Location") {
                    Button {
                        showPickupMapLocationPicker = true
                    } label: {
                        Label("Pick location from map", systemImage: "mappin.and.ellipse")
                            .font(FGTypography.metadata.weight(.semibold))
                    }

                    TextField("Street address", text: addressBinding, axis: .vertical)
                        .lineLimit(1...3)
                    TextField("City", text: cityBinding)
                    TextField("State", text: stateBinding)
                    TextField("ZIP code", text: zipCodeBinding)
                        .textInputAutocapitalization(.characters)
                        .keyboardType(.numbersAndPunctuation)

                    if coordinatesLockedFromMap {
                        Text("Using exact coordinates from your map pin.")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.accentBlue)
                    }

                    if let foot = locationGuidanceFootnote {
                        Text(foot)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.accentYellow)
                    }
                }
            } else {
                Section("Location") {
                    LabeledContent("Street") {
                        Text(trimmedAddress.isEmpty ? "—" : trimmedAddress)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.trailing)
                    }
                    LabeledContent("City") {
                        Text(trimmedCity.isEmpty ? "—" : trimmedCity)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                    }
                    LabeledContent("State") {
                        Text(trimmedState.isEmpty ? "—" : trimmedState)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                    }
                    LabeledContent("ZIP") {
                        Text(trimmedZipCode.isEmpty ? "—" : trimmedZipCode)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                    }
                }
            }

            Section("Details") {
                if isOrganizerPostStartManage {
                    let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)
                    LabeledContent("Description") {
                        Text(desc.isEmpty ? "—" : desc)
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .multilineTextAlignment(.trailing)
                    }
                } else {
                    TextField("Description (optional)", text: $description, axis: .vertical)
                        .lineLimit(2...6)
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(FGColor.accentBlue)
                            .padding(.top, 1)
                        Text("This pickup game will be automatically deleted 12 hours after the start time.")
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(FGSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                            .strokeBorder(FGColor.divider(colorScheme).opacity(colorScheme == .dark ? 0.55 : 0.4), lineWidth: 1)
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle(
            mode == .add ? "Host Pickup Game" : (isOrganizerPostStartManage ? "Manage pickup game" : "Edit pickup game")
        )
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { onFinished(); dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(mode == .add ? "Post" : "Save") {
                    Task { await save() }
                }
                .disabled(
                    isSaving
                        || (!isOrganizerPostStartManage && title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        || (!isOrganizerPostStartManage && !hasPlacedLocationForPostButton)
                )
            }
        }
        .onAppear {
            applyModeToFields()
            if case .edit(let row) = mode {
                let now = Date()
                let actions: String
                if isOrganizerPostStartManage {
                    actions = "roster_capacity_only,manage_requests_sheet"
                } else {
                    actions = "full_edit_before_start"
                }
                PickupGameStartedStateDebug.log(row: row, now: now, allowedActions: actions)
            }
            if !viewModel.canFanUsePickupGamesUI {
                onFinished()
                dismiss()
            }
        }
        .fullScreenCover(isPresented: $showPickupMapLocationPicker) {
            PickupGameMapLocationPickerSheet(
                viewModel: viewModel,
                initialCoordinate: pickMapSeedCoordinate,
                onCancel: { showPickupMapLocationPicker = false },
                onConfirm: { coord, street, cityName, stateAbbr, postalCode in
                    if let s = street, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        address = s
                    }
                    if let c = cityName, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        city = c
                    }
                    if let st = stateAbbr, !st.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        state = st
                    }
                    if let zip = postalCode, !zip.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        zipCode = zip
                    }
                    mapPinnedCoordinate = coord
                    coordinatesLockedFromMap = true
                    showPickupMapLocationPicker = false
                }
            )
        }
    }

    private func applyModeToFields() {
        switch mode {
        case .add:
            title = ""
            sport = AppSportCatalog.formPickerSportsOrdered.first ?? "Soccer"
            let now = Date()
            gameDate = now
            gameTime = now
            address = ""
            city = ""
            state = ""
            zipCode = ""
            description = ""
            playEnvironment = .either
            skillLevel = .casual
            participantPreference = .everyone
            costKind = .free
            entryFeeText = ""
            playersNeeded = 1
            useMaxPlayers = false
            maxPlayers = 10
            coordinatesLockedFromMap = false
            mapPinnedCoordinate = nil
        case .edit(let row):
            title = row.title
            sport = row.sport
            if let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
                gameDate = start
                gameTime = start
            }
            address = row.address ?? ""
            city = row.city ?? ""
            let splitState = Self.splitStoredStateAndZip(row.state)
            state = splitState.state
            zipCode = splitState.zipCode
            description = row.description ?? ""
            playEnvironment = row.playEnvironmentEnum
            skillLevel = row.skillLevelEnum
            participantPreference = row.participantPreferenceEnum
            if row.is_free {
                costKind = .free
                entryFeeText = ""
            } else {
                costKind = .paid
                if let amt = row.entry_fee_amount {
                    entryFeeText = Self.feeTextFieldString(from: amt)
                } else {
                    entryFeeText = ""
                }
            }
            playersNeeded = row.playersNeededClamped
            if let cap = row.max_players {
                useMaxPlayers = true
                maxPlayers = min(100, Swift.max(1, cap))
            } else {
                useMaxPlayers = false
                maxPlayers = Swift.max(row.playersNeededClamped, 2)
            }
            coordinatesLockedFromMap = false
            mapPinnedCoordinate = nil
        }
    }

    private static func feeTextFieldString(from amount: Double) -> String {
        let n = NSNumber(value: amount)
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        return f.string(from: n) ?? String(format: "%.2f", amount)
    }

    private static func splitStoredStateAndZip(_ raw: String?) -> (state: String, zipCode: String) {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return ("", "") }
        let parts = trimmed.split(separator: " ").map(String.init)
        guard parts.count > 1,
              let last = parts.last,
              last.rangeOfCharacter(from: .decimalDigits) != nil else {
            return (trimmed, "")
        }
        return (parts.dropLast().joined(separator: " "), last)
    }

    private static func storedStateWithZip(state: String, zipCode: String) -> String {
        [state, zipCode]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func logPickupDatePicker(todayTapped: Bool, doneTapped: Bool, selectedDate: Date) {
#if DEBUG
        let f = ISO8601DateFormatter()
        f.timeZone = .current
        f.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        print("[PickupDatePicker] todayTapped=\(todayTapped)")
        print("[PickupDatePicker] doneTapped=\(doneTapped)")
        print("[PickupDatePicker] selectedDate=\(f.string(from: selectedDate))")
#endif
    }

    /// Sets the game calendar day to today; if the combined start is still in the past, advances clock time using shared venue rules.
    private func applyPickupDatePickerJumpToToday() {
        let cal = Calendar.current
        let now = Date()
        let todayStart = cal.startOfDay(for: now)
        suppressGameDatePickerChangeLog = true
        gameDate = todayStart
        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameTime, now: now) {
            gameTime = VenueOwnerGameScheduleValidation.recommendedStartTimeAfterGameDateChange(newGameDate: todayStart, now: now)
        }
        suppressGameDatePickerChangeLog = false
        logPickupDatePicker(todayTapped: true, doneTapped: false, selectedDate: gameDate)
    }

    private var pickupGameDatePopover: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Button("Today") {
                    applyPickupDatePickerJumpToToday()
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(FGColor.accentBlue)

                Spacer(minLength: 0)

                Button("Done") {
                    logPickupDatePicker(todayTapped: false, doneTapped: true, selectedDate: gameDate)
                    showGameDatePopover = false
                }
                .font(.subheadline.weight(.bold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)

            Divider()
                .opacity(colorScheme == .dark ? 0.35 : 0.45)

            DatePicker("", selection: $gameDate, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(.horizontal, 6)
                .padding(.top, 4)
                .padding(.bottom, 12)
                .onChange(of: gameDate) { _, newValue in
                    guard !suppressGameDatePickerChangeLog else { return }
                    logPickupDatePicker(todayTapped: false, doneTapped: false, selectedDate: newValue)
                }
        }
        .frame(minWidth: 320)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.18 : 0.1), lineWidth: 1)
        }
    }

    private func combinedStartDate() -> Date {
        VenueOwnerGameScheduleValidation.combinedLocalStart(gameDate: gameDate, gameStartTime: gameTime)
    }

    private func parsedEntryFeeAmount() -> Double? {
        let t = entryFeeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        let normalized = t.replacingOccurrences(of: ",", with: "")
        return Double(normalized)
    }

    private func save() async {
        errorText = nil

        if let postStartRow = organizerPostStartLockedRow {
            let playersN = min(20, max(1, playersNeeded))
            let approved = postStartRow.approvedJoinCount
            guard playersN >= approved else {
                errorText = "Players needed can’t be fewer than the number already approved (\(approved))."
                return
            }
            var maxP: Int?
            if useMaxPlayers {
                let capped = min(100, max(1, maxPlayers))
                guard capped >= playersN else {
                    errorText = "Max players must be at least the number of players needed."
                    return
                }
                maxP = capped
            }

            isSaving = true
            defer { isSaving = false }

            do {
                try await viewModel.updatePickupGameRosterCapacity(
                    id: postStartRow.id,
                    playersNeeded: playersN,
                    maxPlayers: maxP
                )
                await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                onFinished()
                dismiss()
            } catch {
                errorText = error.localizedDescription
            }
            return
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            errorText = "Title is required."
            return
        }
        if VenueOwnerGameScheduleValidation.isPastSchedule(gameDate: gameDate, gameStartTime: gameTime) {
            errorText = VenueOwnerGameScheduleValidation.futureDateTimeMessage
            return
        }

        let isFree = costKind == .free
        var feeParsed: Double?
        if !isFree {
            guard let amt = parsedEntryFeeAmount(), amt > 0, amt <= 999_999 else {
                errorText = "Enter a valid entry fee (USD)."
                return
            }
            feeParsed = (amt * 100.0).rounded() / 100.0
        }

        let playersN = min(20, max(1, playersNeeded))
        var maxP: Int?
        if useMaxPlayers {
            let capped = min(100, max(1, maxPlayers))
            guard capped >= playersN else {
                errorText = "Max players must be at least the number of players needed."
                return
            }
            maxP = capped
        }

        isSaving = true
        defer { isSaving = false }

        let start = combinedStartDate()

        let missingZip = trimmedZipCode.isEmpty
#if DEBUG
        print("[PickupLocationDebug] postValidationMissingZip=\(missingZip)")
#endif
        guard hasCompleteTypedAddress else {
            if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty && trimmedZipCode.isEmpty {
                errorText = "Location missing"
            } else if missingZip {
                errorText = "Enter the ZIP code for this pickup game."
            } else {
                errorText = "Enter a complete street address, city, state, and ZIP code."
            }
            return
        }

        let addressLine = [trimmedAddress, trimmedCity, trimmedState, trimmedZipCode].joined(separator: ", ")

        let latFinal: Double
        let lonFinal: Double
        if coordinatesLockedFromMap, let pin = mapPinnedCoordinate {
            latFinal = pin.latitude
            lonFinal = pin.longitude
        } else {
            guard let coord = await viewModel.geocodeAddress(addressLine) else {
                errorText = "Could not find that address. Please check the street address, city, and state."
                return
            }
            latFinal = coord.latitude
            lonFinal = coord.longitude
        }

        let addr = trimmedAddress
        let c = trimmedCity
        let st = Self.storedStateWithZip(state: trimmedState, zipCode: trimmedZipCode)

        let desc = description.trimmingCharacters(in: .whitespacesAndNewlines)

        do {
            switch mode {
            case .add:
                _ = try await viewModel.insertPickupGame(
                    title: trimmedTitle,
                    sport: sport,
                    description: desc.isEmpty ? nil : desc,
                    skillLevel: skillLevel.rawValue,
                    gameStartAt: start,
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    playersNeeded: playersN,
                    playEnvironment: playEnvironment.rawValue,
                    participantPreference: participantPreference.rawValue,
                    isFree: isFree,
                    entryFeeAmount: feeParsed,
                    maxPlayers: maxP
                )
            case .edit(let row):
                let gameStartISO = PickupGameModels.encodeSupabaseTimestamptz(start)
                let removeISO = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: gameStartISO)
                let patch = PickupGameFullUpdate(
                    title: trimmedTitle,
                    sport: sport,
                    description: desc.isEmpty ? nil : desc,
                    skill_level: skillLevel.rawValue,
                    game_start_at: gameStartISO,
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    is_visible: true,
                    players_needed: playersN,
                    play_environment: playEnvironment.rawValue,
                    participant_preference: participantPreference.rawValue,
                    is_free: isFree,
                    entry_fee_amount: feeParsed,
                    max_players: maxP,
                    cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
                    remove_after_at: removeISO
                )
                try await viewModel.updatePickupGame(id: row.id, full: patch)
            }
            await viewModel.refreshPickupGamesForDiscoverMap(force: true)
            onFinished()
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }
}
