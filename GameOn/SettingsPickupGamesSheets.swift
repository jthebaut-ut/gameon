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
            if viewModel.myPickupGamesForSettings.isEmpty {
                SettingsPickupGamesEmptyStateCard(colorScheme: colorScheme) {
                    formMode = .add
                }
                .listRowInsets(EdgeInsets(top: 20, leading: 20, bottom: 28, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(viewModel.myPickupGamesForSettings) { row in
                        let pendingHere = viewModel.organizerPendingPickupJoinRequests(for: row.id)
                        SettingsPickupMyGameListCard(
                            row: row,
                            pendingJoinCount: pendingHere,
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
                .accessibilityLabel("Add pickup game")
            }
        }
        .task {
            await viewModel.loadMyPickupGamesForSettings()
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
        .alert("Delete pickup game?", isPresented: Binding(
            get: { deleteTarget != nil },
            set: { if !$0 { deleteTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) { deleteTarget = nil }
            Button("Delete", role: .destructive) {
                guard let row = deleteTarget else { return }
                deleteTarget = nil
                Task { await performDelete(row) }
            }
        } message: {
            Text("This permanently deletes the game, all join requests, and removes it from Discover, the calendar, and Games to Join.")
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
        let rows = viewModel.myPickupGamesForSettings
        let anyPast = rows.contains { row in
            guard let deadline = SettingsPickupCleanupDisplay.cleanupDeadline(for: row) else { return false }
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
                Text("Add pickup game")
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

private struct SettingsPickupMyGameListCard: View {
    let row: PickupGameRow
    let pendingJoinCount: Int
    let now: Date
    let colorScheme: ColorScheme
    var onEdit: () -> Void
    var onDelete: () -> Void
    var onManageRequests: () -> Void

    private var status: SettingsPickupGameListCardStatus {
        Self.computeStatus(row: row, pendingJoinCount: pendingJoinCount, now: now)
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

    private var spotsLine: String {
        let open = row.pickupOpenSlotsRemaining
        let need = row.playersNeededClamped
        if row.isPickupFullForDiscover {
            return "Roster full · \(need) players"
        }
        return "\(open) of \(need) spots left"
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 14) {
                SportArtworkIconView(sport: row.sport, diameter: 50)

                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        Text(row.title)
                            .font(.title3.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .lineLimit(3)
                            .frame(maxWidth: .infinity, alignment: .leading)

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

                    if pendingJoinCount > 0 {
                        Button(action: onManageRequests) {
                            HStack(spacing: 8) {
                                Image(systemName: "person.crop.circle.badge.clock")
                                    .font(.system(size: 15, weight: .semibold))
                                    .foregroundStyle(Color.orange)
                                Text(pendingJoinCount == 1 ? "1 pending request" : "\(pendingJoinCount) pending requests")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(Color.orange)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(Color.orange.opacity(0.85))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.orange.opacity(colorScheme == .dark ? 0.16 : 0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(pendingJoinCount) pending join requests. Tap to review.")
                    }
                }
            }
            .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 10) {
                if let dateTimeLine {
                    SettingsPickupCardMetaRow(systemImage: "calendar", title: "When", value: dateTimeLine)
                }
                if let locationLine {
                    SettingsPickupCardMetaRow(systemImage: "mappin.and.ellipse", title: "Location", value: locationLine)
                }
                SettingsPickupCardMetaRow(systemImage: "person.3", title: "Players", value: spotsLine)
                SettingsPickupCardMetaRow(systemImage: "chart.bar", title: "Skill", value: row.skillLevelEnum.displayTitle)
                SettingsPickupCardMetaRow(
                    systemImage: row.playEnvironmentEnum == .indoor ? "house.fill" : (row.playEnvironmentEnum == .outdoor ? "sun.max.fill" : "arrow.left.arrow.right"),
                    title: "Play",
                    value: row.playEnvironmentEnum.shortLabel
                )
                SettingsPickupCardMetaRow(systemImage: row.is_free ? "gift.fill" : "dollarsign.circle", title: "Cost", value: row.entryFeeDisplayLine)
            }
            .padding(.top, 6)

            if !row.is_visible {
                Text("Hidden from map")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .padding(.top, 8)
            }

            VStack(alignment: .leading, spacing: 10) {
                if pendingJoinCount > 0 {
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

                HStack(spacing: 10) {
                    Button(action: onEdit) {
                        Label("Edit", systemImage: "pencil")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(FGColor.accentBlue)

                    Button(role: .destructive, action: onDelete) {
                        Label("Delete", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(.top, 14)

            Divider()
                .opacity(colorScheme == .dark ? 0.35 : 0.5)
                .padding(.vertical, 10)

            SettingsPickupCleanupCountdownRow(row: row, now: now, isFooterStyle: true)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: shape)
        .overlay(
            shape.strokeBorder(Color.primary.opacity(colorScheme == .dark ? 0.14 : 0.08), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.1), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
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
        if let rem = row.remove_after_at, let d = PickupGameModels.parseSupabaseTimestamptz(rem) {
            return d
        }
        guard let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else { return nil }
        return start.addingTimeInterval(Double(PickupGameAutoRemoval.hoursAfterGameStart) * 3600)
    }

    static func snapshot(row: PickupGameRow, now: Date) -> Snapshot {
        guard let deadline = cleanupDeadline(for: row) else {
            return Snapshot(label: "Clears 24h after start", symbolName: "clock.arrow.circlepath", tone: .normal)
        }
        guard let gameStart = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) else {
            if now >= deadline {
                return Snapshot(label: "Clearing now…", symbolName: "clock.arrow.circlepath", tone: .danger)
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
            return Snapshot(label: "Clearing now…", symbolName: "clock.arrow.circlepath", tone: .danger)
        }

        if now < gameStart {
            return Snapshot(label: "Clears 24h after start", symbolName: "clock.arrow.circlepath", tone: .normal)
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
    @State private var description: String = ""
    @State private var playEnvironment: PickupPlayEnvironment = .either
    @State private var skillLevel: PickupGameSkillLevel = .casual
    @State private var participantPreference: PickupParticipantPreference = .everyone
    @State private var costKind: PickupCostKind = .free
    @State private var entryFeeText: String = ""
    @State private var playersNeeded: Int = 1
    @State private var useMaxPlayers: Bool = false
    @State private var maxPlayers: Int = 10
    @State private var isVisible: Bool = true
    @State private var isSaving = false
    @State private var errorText: String?
    @State private var showPickupMapLocationPicker = false
    @State private var coordinatesLockedFromMap = false
    @State private var mapPinnedCoordinate: CLLocationCoordinate2D?

    private var trimmedAddress: String {
        address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedCity: String {
        city.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedState: String {
        state.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasCompleteTypedAddress: Bool {
        !trimmedAddress.isEmpty && !trimmedCity.isEmpty && !trimmedState.isEmpty
    }

    /// Post/Save enabled when address fields are complete (typed or filled from map picker).
    private var hasPlacedLocationForPostButton: Bool {
        hasCompleteTypedAddress
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

    private var locationGuidanceFootnote: String? {
        if hasCompleteTypedAddress { return nil }
        if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty {
            return "Location missing"
        }
        return "Enter a complete street address, city, and state"
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

            Section("Game") {
                TextField("Title", text: $title)
                GameSportSearchablePickerFormRow(selection: $sport)
                DatePicker("Date", selection: $gameDate, displayedComponents: .date)
                DatePicker("Start time", selection: $gameTime, displayedComponents: .hourAndMinute)
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

            Section("Details") {
                TextField("Description (optional)", text: $description, axis: .vertical)
                    .lineLimit(2...6)
                Toggle("Visible on Discover map", isOn: $isVisible)

                HStack(alignment: .top, spacing: FGSpacing.sm) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(FGColor.accentBlue)
                        .padding(.top, 1)
                    Text("This pickup game will be automatically deleted \(PickupGameAutoRemoval.hoursAfterGameStart) hours after the start time.")
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
        .scrollContentBackground(.hidden)
        .fanGeoScreenBackground()
        .navigationTitle(mode == .add ? "Add pickup game" : "Edit pickup game")
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
                        || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !hasPlacedLocationForPostButton
                )
            }
        }
        .onAppear {
            applyModeToFields()
        }
        .onAppear {
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
                onConfirm: { coord, street, cityName, stateAbbr in
                    if let s = street, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        address = s
                    }
                    if let c = cityName, !c.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        city = c
                    }
                    if let st = stateAbbr, !st.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        state = st
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
            description = ""
            playEnvironment = .either
            skillLevel = .casual
            participantPreference = .everyone
            costKind = .free
            entryFeeText = ""
            playersNeeded = 1
            useMaxPlayers = false
            maxPlayers = 10
            isVisible = true
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
            state = row.state ?? ""
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
            isVisible = row.is_visible
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

        guard hasCompleteTypedAddress else {
            if trimmedAddress.isEmpty && trimmedCity.isEmpty && trimmedState.isEmpty {
                errorText = "Location missing"
            } else {
                errorText = "Enter a complete street address, city, and state"
            }
            return
        }

        let addressLine = [trimmedAddress, trimmedCity, trimmedState].joined(separator: ", ")

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
        let st = trimmedState

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
                    isVisible: isVisible,
                    playersNeeded: playersN,
                    playEnvironment: playEnvironment.rawValue,
                    participantPreference: participantPreference.rawValue,
                    isFree: isFree,
                    entryFeeAmount: feeParsed,
                    maxPlayers: maxP
                )
            case .edit(let row):
                let patch = PickupGameFullUpdate(
                    title: trimmedTitle,
                    sport: sport,
                    description: desc.isEmpty ? nil : desc,
                    skill_level: skillLevel.rawValue,
                    game_start_at: PickupGameModels.encodeSupabaseTimestamptz(start),
                    address: addr.isEmpty ? nil : addr,
                    city: c.isEmpty ? nil : c,
                    state: st.isEmpty ? nil : st,
                    latitude: latFinal,
                    longitude: lonFinal,
                    is_visible: isVisible,
                    players_needed: playersN,
                    play_environment: playEnvironment.rawValue,
                    participant_preference: participantPreference.rawValue,
                    is_free: isFree,
                    entry_fee_amount: feeParsed,
                    max_players: maxP,
                    cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart
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
