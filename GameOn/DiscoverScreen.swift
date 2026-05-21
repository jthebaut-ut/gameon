import CoreLocation
import SwiftUI
import MapKit
import UIKit

private enum GuestDiscoverLockedCopy {
    static let body =
        "Log in or create a FanGeo account to view details, join pickup games, save venues, and unlock the full FanGeo experience."
}

private struct DiscoverPredictionSheetContext: Identifiable {
    let venueEventID: UUID
    let teams: VenueEventPredictionTeams
    let predictionType: VenueEventPredictionType

    var id: String {
        "\(venueEventID.uuidString.lowercased())|\(predictionType.rawValue)"
    }
}

private enum PickupGameMapMarkerActivity {
    case low
    case medium
    case high

    var glowOpacity: Double {
        switch self {
        case .low: return 0.18
        case .medium: return 0.30
        case .high: return 0.42
        }
    }

    var pulseOpacity: Double {
        switch self {
        case .low: return 0
        case .medium: return 0.22
        case .high: return 0.34
        }
    }
}

private struct PickupGameMapMarker: View {
    let systemImage: String
    let accentColor: Color
    let activity: PickupGameMapMarkerActivity
    var demandBadgeText: String?
    var isSelected = false
    var isCluster = false
    var count: Int?

    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false
    @State private var demandBadgeVisible = false

    private var baseSize: CGFloat { isCluster ? 44 : 48 }
    private var glyphSize: CGFloat { isCluster ? 21 : 24 }
    private var scale: CGFloat {
        if isSelected { return 1.20 }
        return isCluster ? 0.94 : 1.0
    }

    private var markerFill: Color {
        colorScheme == .dark ? Color(red: 0.03, green: 0.06, blue: 0.09) : Color(red: 0.02, green: 0.05, blue: 0.08)
    }

    private var borderColor: Color {
        colorScheme == .dark ? Color.white.opacity(0.92) : Color.white
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(accentColor.opacity(activity.pulseOpacity), lineWidth: activity == .high ? 3 : 2)
                .frame(width: baseSize + 18, height: baseSize + 18)
                .scaleEffect(pulse ? 1.22 : 0.98)
                .opacity(activity.pulseOpacity)
                .animation(.easeInOut(duration: activity == .high ? 1.05 : 1.35).repeatForever(autoreverses: true), value: pulse)

            Circle()
                .fill(accentColor.opacity(activity.glowOpacity))
                .frame(width: baseSize + 14, height: baseSize + 14)
                .blur(radius: 5)

            Circle()
                .fill(markerFill)
                .frame(width: baseSize, height: baseSize)
                .overlay {
                    Circle()
                        .strokeBorder(borderColor, lineWidth: isSelected ? 3 : 2.25)
                }
                .overlay {
                    Circle()
                        .strokeBorder(accentColor.opacity(0.78), lineWidth: isSelected ? 2 : 1.5)
                        .padding(isSelected ? 4 : 4.5)
                }
                .shadow(color: .black.opacity(colorScheme == .dark ? 0.34 : 0.24), radius: isSelected ? 10 : 7, y: isSelected ? 6 : 4)

            Image(systemName: systemImage)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: glyphSize, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: baseSize * 0.64, height: baseSize * 0.64)
                .accessibilityHidden(true)

            if let count, isCluster {
                Text("\(count)")
                    .font(.system(size: 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(accentColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.white)
                    .clipShape(Capsule(style: .continuous))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.black.opacity(0.12), lineWidth: 0.75)
                    }
                    .offset(x: 15, y: 15)
            }

            if let demandBadgeText, !isCluster {
                Text(demandBadgeText)
                    .font(.system(size: demandBadgeText == "FULL" ? 8 : 10, weight: .heavy, design: .rounded))
                    .foregroundStyle(demandBadgeText == "FULL" ? Color.white : markerFill)
                    .padding(.horizontal, demandBadgeText == "FULL" ? 6 : 5)
                    .frame(minWidth: demandBadgeText == "FULL" ? 34 : 22, minHeight: 22)
                    .background {
                        Capsule(style: .continuous)
                            .fill(demandBadgeText == "FULL" ? Color.black.opacity(0.86) : Color.white)
                    }
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(accentColor.opacity(0.45), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1)
                    .scaleEffect(demandBadgeVisible ? 1.0 : 0.9)
                    .opacity(demandBadgeVisible ? 1 : 0)
                    .animation(.spring(response: 0.22, dampingFraction: 0.78), value: demandBadgeVisible)
                    .offset(x: 18, y: -18)
                    .accessibilityHidden(true)
            }
        }
        .frame(width: baseSize + 24, height: baseSize + 24)
        .scaleEffect(scale)
        .animation(.spring(response: 0.28, dampingFraction: 0.78), value: isSelected)
        .onAppear {
            pulse = activity != .low
            demandBadgeVisible = demandBadgeText != nil && !isCluster
        }
        .onChange(of: activity) { _, next in
            pulse = next != .low
        }
        .onChange(of: demandBadgeText) { _, next in
            demandBadgeVisible = next != nil && !isCluster
        }
    }
}

private struct MapDepthPulseRing: View {
    let tint: Color
    @State private var pulse = false

    var body: some View {
        Circle()
            .stroke(tint.opacity(pulse ? 0.10 : 0.22), lineWidth: 2)
            .scaleEffect(pulse ? 1.34 : 1.02)
            .opacity(pulse ? 0.16 : 0.30)
            .animation(.easeInOut(duration: 1.55).repeatForever(autoreverses: true), value: pulse)
            .allowsHitTesting(false)
            .onAppear {
                pulse = true
            }
    }
}

private struct FanChatActivityPulse: View {
    let tint: Color
    let isActive: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(isActive ? 0.22 : 0), lineWidth: 2)
                .frame(width: 18, height: 18)
                .scaleEffect(pulse && !reduceMotion ? 1.28 : 0.92)
                .opacity(isActive ? 1 : 0)
                .animation(.easeInOut(duration: 1.15).repeatForever(autoreverses: true), value: pulse)

            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .shadow(color: tint.opacity(isActive ? 0.45 : 0.18), radius: isActive ? 5 : 2, y: 0)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            pulse = isActive
        }
        .onChange(of: isActive) { _, next in
            pulse = next
        }
    }
}

private struct FanChatMiniActivityStack: View {
    let tint: Color
    let isHot: Bool

    private var colors: [Color] {
        isHot ? [FGColor.dangerRed, FGColor.accentYellow, FGColor.accentBlue] : [tint, FGColor.accentGreen, FGColor.accentYellow]
    }

    var body: some View {
        HStack(spacing: -5) {
            ForEach(Array(colors.enumerated()), id: \.offset) { index, color in
                Circle()
                    .fill(color.opacity(index == 0 ? 0.95 : 0.78))
                    .frame(width: 16, height: 16)
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.88), lineWidth: 1.4))
                    .shadow(color: color.opacity(0.18), radius: 3, y: 1)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Polished locked preview for Discover when ``MapViewModel/isGuestDiscoverMode`` (same fan auth sheet as Account).
private struct GuestDiscoverLockedPreviewCard<Preview: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let accent: Color
    let headline: String
    @ViewBuilder var teaser: () -> Preview
    let onLogIn: () -> Void
    let onCreateAccount: () -> Void
    let onDismiss: () -> Void
    var onNotNow: (() -> Void)?

    var body: some View {
        FGCard {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                ZStack {
                    Circle()
                        .fill(accent.opacity(colorScheme == .dark ? 0.22 : 0.14))
                        .frame(width: 44, height: 44)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(accent)
                }

                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(headline)
                        .font(FGTypography.caption.weight(.heavy))
                        .foregroundStyle(accent)

                    Text(GuestDiscoverLockedCopy.body)
                        .font(FGTypography.body)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Divider()
                .overlay(FGColor.divider(colorScheme))

            teaser()

            VStack(spacing: FGSpacing.sm) {
                FGPrimaryButton(title: "Log In", action: onLogIn)
                FGSecondaryButton(title: "Create Account", action: onCreateAccount)
                if let onNotNow {
                    FGSecondaryButton(title: "Not now", action: onNotNow)
                }
            }
        }
        .frame(maxHeight: 420)
    }
}

/// Primary map experience: search, date strip, clustered annotations, venue preview, and sheets for detail, comments, and vibes.
struct DiscoverScreen: View {

    @ObservedObject var viewModel: MapViewModel
    @ObservedObject private var fanUpdatesStore: FanUpdatesRealtimeStore
    @ObservedObject var chatViewModel: ChatViewModel
    @Binding var isCalendarOverlayPresented: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var isSearchFocused: Bool
    @State private var showVenueDetails = false
    @State private var showDatePicker = false
    @State private var discoverDatePickerSelection: Date?
    /// Month shown in the Discover calendar overlay (drives dot loads when switching Venues / Pickup).
    @State private var discoverCalendarDisplayedMonth = Date()
    @State private var fanUpdatesSheetEvent: FanUpdatesSheetEvent?
    @State private var predictionSheet: DiscoverPredictionSheetContext?
    @State private var showVenueRatingSheet = false
    @State private var fanFeatureGateAlertMessage: String?
    @State private var mapVenueReloadTask: Task<Void, Never>?
    @State private var lastMapVenueReloadRegion: MKCoordinateRegion?
    /// Multi-venue map cluster: sheet lists venues after tap (zoom runs first).
    @State private var clusterForSheet: VenueCluster?
    /// After opening Account from the Discover gate, restore this venue once fan login succeeds.
    @State private var pendingResumeVenueIDAfterLogin: UUID?
    /// Per-venue preview: local filter for the game list (does not change global map filters).
    @State private var venuePreviewGameFilter: VenuePreviewGameFilter = .all
    /// Bumps when returning to foreground so map user-dot visibility refreshes after Settings changes.
    @State private var discoverMapLocationAuthVersion = 0
    @State private var discoverLocationHint: String?
    @State private var mapDisplayModeHintText: String?
    @State private var mapDisplayModeHintTask: Task<Void, Never>?
    @State private var discoverTopAdLoadFailed = false
    @State private var showDiscoverSportMoreSheet = false
    @State private var pickupGameDetailNav: PickupDetailNavigationToken?
    @State private var discoverWeather: DiscoverWeather?
    @State private var discoverWeatherRefreshTask: Task<Void, Never>?
    @State private var isDiscoverHomeCrowdToggleInFlight = false
    @Namespace private var discoverModeToggleNamespace
    private let livePulseThreshold = 16

    private var acceptedFriendUserIDs: Set<UUID> {
        guard viewModel.canUseFanSocialFeatures else { return [] }
        return Set(chatViewModel.friendshipChipByOtherUserId.compactMap { userID, kind in
            kind == .friends ? userID : nil
        })
    }
    private let primaryMapUtilityButtonSize: CGFloat = 44
    private let secondaryMapUtilityButtonSize: CGFloat = 44
    private let discoverLightGlassCornerRadius: CGFloat = 28
    private let mapUtilityStackSpacing: CGFloat = 8
    private let discoverFilterRowSpacing: CGFloat = 6

    private enum VenuePreviewGameFilter: Int, CaseIterable, Identifiable {
        case all
        case going

        var id: Int { rawValue }

        var segmentTitle: String {
            switch self {
            case .all: return "All"
            case .going: return "Going"
            }
        }
    }

    private struct VenuePreviewMiniStat: Identifiable {
        let id: String
        let symbol: String
        let label: String
        let countColor: Color
        let background: Color
        let selectedBackground: Color
    }

    private struct DiscoverVenuePredictionVisibility {
        let eventID: UUID?
        let sportType: String
        let teams: VenueEventPredictionTeams?
        let hasHomeTeam: Bool
        let hasAwayTeam: Bool
        let startsAt: Date?
        let lockTime: Date?
        let isLocked: Bool
        let hiddenReason: String?

        var shouldRender: Bool {
            hiddenReason == nil || isLocked
        }
    }

    init(
        viewModel: MapViewModel,
        chatViewModel: ChatViewModel,
        isCalendarOverlayPresented: Binding<Bool>
    ) {
        _viewModel = ObservedObject(wrappedValue: viewModel)
        _fanUpdatesStore = ObservedObject(wrappedValue: viewModel.fanUpdatesStore)
        _chatViewModel = ObservedObject(wrappedValue: chatViewModel)
        _isCalendarOverlayPresented = isCalendarOverlayPresented
    }

    var body: some View {
        discoverScreenWithToolbar
    }

    private var discoverScreenWithToolbar: some View {
        discoverScreenWithTertiarySheets
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        dismissDiscoverSearchKeyboard()
                    }
                }
            }
    }

    private var discoverScreenWithTertiarySheets: some View {
        discoverScreenWithClusterSheet
            .sheet(item: $pickupGameDetailNav) { token in
                DiscoverPickupGameDetailSheet(viewModel: viewModel, gameId: token.id)
            }
            .sheet(isPresented: $showDiscoverSportMoreSheet) {
                DiscoverSportFilterMoreSheet(selectedSport: viewModel.selectedSport) { sport in
                    showDiscoverSportMoreSheet = false
                    withAnimation(.spring()) {
                        viewModel.sportChanged(to: sport)
                    }
                }
            }
    }

    private var discoverScreenWithClusterSheet: some View {
        discoverScreenWithPrimarySheets
            .sheet(item: $clusterForSheet) { cluster in
                discoverClusterVenuesSheet(cluster: cluster)
            }
    }

    private var discoverScreenWithPrimarySheets: some View {
        discoverScreenCore
            .sheet(isPresented: Binding(
                get: {
                    showVenueDetails
                        && viewModel.selectedBar != nil
                        && (viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode)
                },
                set: { if !$0 { showVenueDetails = false } }
            )) {
                discoverVenueDetailSheet()
            }
            .sheet(item: Binding(
                get: {
                    guard viewModel.isAuthenticatedForSocialFeatures else { return nil }
                    return fanUpdatesSheetEvent
                },
                set: { fanUpdatesSheetEvent = $0 }
            )) { event in
                VenueEventCommentsSheet(
                    viewModel: viewModel,
                    venueEventID: event.id
                )
            }
            .sheet(item: $predictionSheet) { context in
                VenueEventPredictionSheet(
                    venueEventID: context.venueEventID,
                    teams: context.teams,
                    predictionType: context.predictionType,
                    onSaved: {
                        await viewModel.refreshVenueEventPredictionSummary(eventID: context.venueEventID)
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            }
            .sheet(isPresented: Binding(
                get: { showVenueRatingSheet && viewModel.canRateVenues && viewModel.isAuthenticatedForSocialFeatures && viewModel.selectedBar != nil },
                set: { if !$0 { showVenueRatingSheet = false } }
            )) {
                if let bar = viewModel.selectedBar {
                    VenueUserRatingSheet(viewModel: viewModel, bar: bar)
                }
            }
    }

    private var discoverScreenCore: some View {
        GeometryReader { layoutGeo in
            let layoutWidth = layoutGeo.size.width
            ZStack(alignment: .top) {
                mapLayer

            }
            .overlay(alignment: .top) {
                discoverFixedTopOverlay
            }
            .overlay(alignment: .bottom) {
                discoverFixedBottomOverlay(layoutWidth: layoutWidth)
                    .opacity(showDatePicker ? 0.36 : 1)
                    .blur(radius: showDatePicker ? 1.25 : 0)
                    .allowsHitTesting(!showDatePicker)
                    .animation(.easeInOut(duration: 0.24), value: showDatePicker)
            }
            .overlay {
                if showDatePicker {
                    discoverMapDatePickerOverlay
                }
            }
        .onAppear {
            discoverLogLayoutDebug(layoutWidth: layoutWidth)
        }
        }
        .alert(
            "FanGeo",
            isPresented: Binding(
                get: { fanFeatureGateAlertMessage != nil },
                set: { if !$0 { fanFeatureGateAlertMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {
                fanFeatureGateAlertMessage = nil
            }
        } message: {
            Text(fanFeatureGateAlertMessage ?? "")
        }
        .task {
            viewModel.reloadVenueUserRatingsFromStorage()
            viewModel.logDiscoverAuthGateDebug()
            await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "discover_enter")
            viewModel.logBusinessOwnerSessionFlags(context: "discover_enter")
        }
        .onAppear {
            isCalendarOverlayPresented = showDatePicker
            viewModel.clampDiscoverMapSelectedDateToMinimumCalendarDayIfNeeded()
            discoverLogRedesignDebug()
            scheduleDiscoverWeatherRefresh(force: true)
            Task {
                await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "discover_on_appear")
                viewModel.logBusinessOwnerSessionFlags(context: "discover_on_appear")
            }
        }
        .onChange(of: viewModel.currentUserLocation?.latitude) { _, _ in
            scheduleDiscoverWeatherRefresh(force: false)
        }
        .onChange(of: showDatePicker) { _, isOpen in
            isCalendarOverlayPresented = isOpen
            guard isOpen else { return }
            #if DEBUG
            print(
                "[DiscoverCalendarDotsDebug] discoverDatePickerOpen discoverMapContentMode=\(viewModel.discoverMapContentMode.rawValue) selectedSport=\(viewModel.selectedSport) selectedDate=\(viewModel.selectedDate) bars=\(viewModel.bars.count) mapVisibleBars=\(viewModel.mapVisibleBars.count) venueEventRows=\(viewModel.venueEventRows.count) pickupGamesForDiscoverMap=\(viewModel.pickupGamesForDiscoverMap.count) venueGameCalendarDotDates=\(viewModel.venueGameCalendarDotDates.count) pickupGameCalendarDotDates=\(viewModel.pickupGameCalendarDotDates.count)"
            )
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                discoverMapLocationAuthVersion += 1
                scheduleDiscoverWeatherRefresh(force: false)
                if viewModel.discoverMapContentMode == .pickupGames {
                    Task {
                        await viewModel.refreshPickupGamesForDiscoverMap(force: true)
                    }
                }
            }
        }
        .onChange(of: viewModel.selectedDate) { _, _ in
            viewModel.pruneSelectionIfNeededAfterFilterChange()
        }
        .onChange(of: viewModel.searchText) { _, _ in
            viewModel.pruneSelectionIfNeededAfterFilterChange()
            viewModel.scheduleDiscoverSearchDebounce()
        }
        .onChange(of: viewModel.mapDisplayMode) { _, _ in
            guard let selectedBar = viewModel.selectedBar else { return }
            let stillVisible = viewModel.mapVisibleBars.contains { $0.id == selectedBar.id }
            if !stillVisible {
                viewModel.clearSelectedEvent()
            }
        }
        .onChange(of: viewModel.discoverMapContentMode) { oldMode, newMode in
            if newMode != .venues {
                mapDisplayModeHintTask?.cancel()
                mapDisplayModeHintText = nil
            }
            if newMode == .pickupGames {
                viewModel.onDiscoverMapBecamePickupGamesFromUserToggle()
            } else if newMode == .venues, oldMode == .pickupGames {
                let requestID = viewModel.beginDiscoverDateChange(to: viewModel.selectedDate)
                #if DEBUG
                print("[DiscoverNarrowRefreshDebug] modeSwitchPickupToVenuesUsingSelectedDayRefresh=true")
                print("[DiscoverNarrowRefreshDebug] skippedBroadLoadGamesOnModeSwitch=true")
                #endif
                viewModel.scheduleDiscoverSelectedDayRefresh(requestID: requestID)
            }
            let anchorMonth = showDatePicker ? discoverCalendarDisplayedMonth : viewModel.selectedDate
            Task { @MainActor in
                if newMode == .pickupGames {
                    await viewModel.refreshPickupGamesForDiscoverMap(force: false, preservePickupCalendarDotDatesCache: true)
                }
                viewModel.loadDiscoverCalendarDots(around: anchorMonth, reason: "mode_change")
            }
        }
        .onChange(of: viewModel.pendingFollowingMapVenueID) { _, id in
            guard id != nil else { return }
            Task {
                await viewModel.consumeFollowingVenueNavigationIfPending()
            }
        }
        .onChange(of: viewModel.discoverFocusVenueId) { _, venueId in
            guard let venueId else { return }
            viewModel.discoverFocusVenueId = nil
            Task { @MainActor in
                if viewModel.bars.first(where: { $0.id == venueId }) == nil
                    && viewModel.followingTabSavedVenues.first(where: { $0.id == venueId }) == nil {
                    await viewModel.loadVenuesFromSupabase()
                }
                let bar = viewModel.bars.first(where: { $0.id == venueId })
                    ?? viewModel.followingTabSavedVenues.first(where: { $0.id == venueId })
                guard let bar else { return }
                viewModel.selectedBar = bar
                showVenueDetails = true
            }
        }
        .onChange(of: viewModel.discoverAuthGateActive) { wasActive, isActive in
            viewModel.logDiscoverAuthGateDebug()
            if !isActive {
                showVenueDetails = false
                showVenueRatingSheet = false
                fanUpdatesSheetEvent = nil
                pendingResumeVenueIDAfterLogin = nil
            } else {
                resumeDiscoverSelectionAfterFanLoginIfNeeded(wasActive: wasActive, isActive: isActive)
            }
        }
    }

    @ViewBuilder
    private func discoverClusterVenuesSheet(cluster: VenueCluster) -> some View {
        NavigationStack {
            List {
                ForEach(cluster.bars.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) { bar in
                    Button {
                        clusterForSheet = nil
                        venuePreviewGameFilter = .all
                        withAnimation(.spring()) {
                            viewModel.centerMap(on: bar)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bar.name)
                                .font(.headline)
                                .foregroundStyle(.primary)
                            Text(bar.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(FGColor.cardBackground(colorScheme))
                }
            }
            .scrollContentBackground(.hidden)
            .fanGeoScreenBackground()
            .navigationTitle("\(cluster.count) venues")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        clusterForSheet = nil
                    }
                }
            }
        }
        .fanGeoScreenBackground()
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    /// Discover date chip opens this overlay (not a sheet) so the map stays visible—no UIKit sheet white chrome or Calendar tab behind it.
    private var discoverMapDatePickerOverlay: some View {
        ZStack {
            Color.black.opacity(0.055)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    dismissDiscoverDatePicker()
                }

            VStack {
                Spacer(minLength: 0)
                LiquidGlassCalendarPicker(
                    events: viewModel.events,
                    bars: viewModel.bars,
                    useVisibleMapRegionOnly: viewModel.calendarUsesVisibleMapRegionOnly,
                    eventDotDates: viewModel.discoverMapContentMode == .venues
                        ? viewModel.venueGameCalendarDotDates
                        : viewModel.pickupGameCalendarDotDates,
                    dotsLoading: viewModel.discoverMapContentMode == .venues
                        ? viewModel.isLoadingVenueCalendarDots
                        : viewModel.isLoadingPickupCalendarDots,
                    dotStatusText: viewModel.calendarDotStatusText,
                    selectedDate: Binding(
                        get: { discoverDatePickerSelection ?? viewModel.selectedDate },
                        set: { discoverDatePickerSelection = $0 }
                    ),
                    minimumSelectableDay: Calendar.current.startOfDay(for: Date()),
                    chrome: .discoverMap,
                    calendarDotPalette: viewModel.discoverMapContentMode == .venues ? .venueGames : .pickupGames,
                    onDone: {
                        applyDiscoverDatePickerSelection()
                    },
                    onDisplayedMonthChange: { month in
                        discoverCalendarDisplayedMonth = month
                        Task { @MainActor in
                            viewModel.loadDiscoverCalendarDots(around: month, reason: "month_change")
                        }
                    }
                )
                .padding(.horizontal, 8)
                .padding(.bottom, 116)
                .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.38 : 0.18), radius: 28, y: 16)
                .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 16, y: 4)
                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .transition(.opacity.combined(with: .scale(scale: 0.985, anchor: .center)))
        .zIndex(900)
    }

    private func resumeDiscoverSelectionAfterFanLoginIfNeeded(wasActive: Bool, isActive: Bool) {
        guard !wasActive, isActive, viewModel.isAuthenticatedForSocialFeatures, let venueID = pendingResumeVenueIDAfterLogin else { return }
        pendingResumeVenueIDAfterLogin = nil
        let fromBars = viewModel.bars.first(where: { $0.id == venueID })
        let fromFiltered = viewModel.filteredBars.first(where: { $0.id == venueID })
        guard let bar = fromBars ?? fromFiltered else { return }
        withAnimation(.spring()) {
            venuePreviewGameFilter = .all
            viewModel.selectedBar = bar
        }
    }

    @ViewBuilder
    private func discoverVenueDetailSheet() -> some View {
        if let selectedBar = viewModel.selectedBar {
            let claimStatus = viewModel.venueOwnershipClaimStatus(for: selectedBar)
            let showsBusinessOwnershipSection = viewModel.shouldShowVenueOwnershipClaimSection(for: selectedBar)
            let selectedDayGames = viewModel.selectedDayEventsForMap(selectedBar)
            let selectedVenueEvent = selectedEventForVenue(gamesToday: selectedDayGames)
            let ratingCount = viewModel.reviewCountDisplay(for: selectedBar)
            let supportedSports = venueSupportedSports(from: selectedDayGames)
            let displaySport = venueSportLabel(sportsSupported: supportedSports)
            let isBusinessConfirmed = venueIsBusinessConfirmed(bar: selectedBar, claimStatus: claimStatus)
            let liveEnergy = selectedVenueEvent.map {
                viewModel.liveEnergy(for: selectedBar, event: $0, friendUserIDs: acceptedFriendUserIDs)
            } ?? viewModel.strongestLiveEnergy(
                for: selectedBar,
                events: selectedDayGames,
                friendUserIDs: acceptedFriendUserIDs
            )
            VenueDetailView(
                bar: selectedBar,
                selectedEvent: selectedVenueEvent,
                isFavorite: viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(selectedBar.id),
                goingCount: viewModel.displayedGoingCount(for: selectedBar),
                liveEnergy: liveEnergy,
                livePresenceViewerUserID: viewModel.currentUserAuthId,
                iconForSport: viewModel.iconForSport,
                mergedRating: viewModel.mergedDisplayRating(for: selectedBar),
                ratingCount: ratingCount,
                displaySport: displaySport,
                sportsSupported: supportedSports,
                hasGamesScheduledToday: !selectedDayGames.isEmpty,
                venueEventRows: viewModel.venueEventRows,
                venuePredictionSummaries: viewModel.venueEventPredictionSummaries,
                isBusinessConfirmed: isBusinessConfirmed,
                onDirections: { viewModel.openDirections(to: selectedBar) },
                onCall: { viewModel.callVenue(selectedBar) },
                onFavorite: {
                    if viewModel.canFavoriteVenues {
                        viewModel.toggleFavorite(selectedBar)
                    } else if viewModel.isAuthenticatedForSocialFeatures {
                        viewModel.logBusinessUserGateBlocked(action: "favoriteVenue")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                    }
                },
                onAddressTap: { viewModel.openDirections(to: selectedBar) },
                onRateVenue: {
                    if viewModel.canRateVenues {
                        showVenueDetails = false
                        showVenueRatingSheet = true
                    } else if viewModel.isGuestDiscoverMode {
                        viewModel.discoverNavigateToAccountForUserAuth = true
                    } else if viewModel.isAuthenticatedForSocialFeatures {
                        viewModel.logBusinessUserGateBlocked(action: "rateVenue")
                        fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                    }
                },
                experience: viewModel.experience(for: selectedBar),
                coverPhotoURL: selectedBar.coverPhotoURL,
                menuPhotoURL: selectedBar.menuPhotoURL,
                onClaimThisBusiness: discoverVenueClaimAction(for: selectedBar),
                showsBusinessOwnershipSection: showsBusinessOwnershipSection,
                businessClaimStatus: claimStatus,
                showsFanOnlyActionButtons: viewModel.isGuestDiscoverMode || viewModel.canUseFanSocialFeatures,
                onFanFeatureBlocked: { action in
                    viewModel.logBusinessUserGateBlocked(action: action)
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                },
                locksScheduledGameDetailsForGuest: viewModel.isGuestDiscoverMode,
                onGuestGameLoginCTA: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onLoadVenuePredictionSummaries: { ids in
                    await viewModel.loadVenueEventPredictionSummaries(eventIDs: ids)
                },
                onRefreshVenuePredictionSummary: { id in
                    await viewModel.refreshVenueEventPredictionSummary(eventID: id)
                },
                showsHomeCrowdControls: viewModel.canUseFanSocialFeatures,
                isHomeCrowdVenue: viewModel.isHomeCrowdVenue(selectedBar.id),
                onToggleHomeCrowd: {
                    await viewModel.toggleHomeCrowd(for: selectedBar)
                }
            )
            .task {
                await viewModel.refreshApprovedVenueOwnershipState(for: selectedBar)
                await viewModel.ensureBusinessOwnerSessionFlagsIfPossible(context: "venue_detail_open")
                viewModel.logBusinessOwnerSessionFlags(context: "venue_detail_open")
            }
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private func venueIsBusinessConfirmed(bar: BarVenue, claimStatus: VenueOwnershipClaimStatus) -> Bool {
        guard bar.businessId != nil || bar.ownerEmail != nil else { return false }
        switch claimStatus {
        case .approved, .alreadyClaimedByOtherBusiness:
            return true
        case .unclaimed, .pendingReview, .rejected:
            return false
        }
    }

    private func venueSupportedSports(from gamesToday: [SportsEvent]) -> [String] {
        Array(Set(gamesToday.compactMap { trimmedSportLabel($0.sport) })).sorted()
    }

    private func venueSportLabel(sportsSupported: [String]) -> String? {
        if sportsSupported.count > 1 { return "Multi-sport" }
        if let sport = sportsSupported.first { return sport }
        return nil
    }

    private func trimmedSportLabel(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func selectedEventForVenue(gamesToday: [SportsEvent]) -> SportsEvent? {
        guard let selectedEvent = viewModel.selectedEvent else { return nil }
        return gamesToday.first {
            $0.title == selectedEvent.title &&
            $0.sport == selectedEvent.sport &&
            Calendar.current.isDate($0.date, inSameDayAs: selectedEvent.date)
        }
    }

    private func visibleVenuePreviewEventsForSocialPrefetch(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        selectedVenueEvent: SportsEvent?
    ) -> [SportsEvent] {
        if let selectedVenueEvent {
            return [selectedVenueEvent]
        }
        let filtered = gamesFilteredForVenuePreview(
            bar: bar,
            gamesToday: gamesToday,
            filter: venuePreviewGameFilter
        )
        return Array(filtered.prefix(12))
    }

    private func visibleVenuePreviewSocialPrefetchKey(bar: BarVenue, events: [SportsEvent]) -> String {
        let eventKey = events
            .map { "\($0.id)|\($0.title)|\(Int($0.date.timeIntervalSince1970))" }
            .joined(separator: ",")
        return "\(bar.id.uuidString.lowercased())|\(viewModel.selectedSport)|\(venuePreviewGameFilter.rawValue)|\(eventKey)"
    }

    private func prefetchVisibleVenueSocialData(bar: BarVenue, events: [SportsEvent]) async {
        guard !events.isEmpty else {
            await viewModel.prefetchVisibleDiscoverSocialData(eventIDs: [], predictionEventIDs: [])
            return
        }

        var eventIDs: [UUID] = []
        var predictionEventIDs: [UUID] = []
        for event in events {
            let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let venueEventID = await viewModel.venueEventID(for: bar, gameTitle: gameTitle, on: event.date) else { continue }
            eventIDs.append(venueEventID)
            let predictionVisibility = venuePredictionVisibility(
                bar: bar,
                event: event,
                venueEventID: venueEventID
            )
            if predictionVisibility.shouldRender, let predictionEventID = predictionVisibility.eventID {
                predictionEventIDs.append(predictionEventID)
            }
        }
        await viewModel.prefetchVisibleDiscoverSocialData(eventIDs: eventIDs, predictionEventIDs: predictionEventIDs)
    }

    private func discoverVenueClaimAction(for bar: BarVenue) -> ((BarVenue) async -> String?)? {
        guard viewModel.canSubmitVenueOwnershipClaim(for: bar) else { return nil }
        return { venue in
            await viewModel.submitVenueOwnershipClaimFromVenueDetail(bar: venue)
        }
    }

    /// Returns true when center or zoom changed enough to warrant another venue fetch.
    private func mapVenueRegionIsMeaningfullyDifferent(from previous: MKCoordinateRegion, to new: MKCoordinateRegion) -> Bool {
        let centerLatDiff = abs(previous.center.latitude - new.center.latitude)
        let centerLonDiff = abs(previous.center.longitude - new.center.longitude)
        let prevLatSpan = max(previous.span.latitudeDelta, 1e-9)
        let prevLonSpan = max(previous.span.longitudeDelta, 1e-9)
        let spanLatRatio = abs(previous.span.latitudeDelta - new.span.latitudeDelta) / prevLatSpan
        let spanLonRatio = abs(previous.span.longitudeDelta - new.span.longitudeDelta) / prevLonSpan
        let centerMoved = centerLatDiff > 0.0012 || centerLonDiff > 0.0012
        let zoomChanged = spanLatRatio > 0.08 || spanLonRatio > 0.08
        return centerMoved || zoomChanged
    }

    private enum VenuePinDisplayState {
        case gameScheduled
        case noGameScheduled
    }

    private enum ClusterDisplayState {
        case gameScheduled
        case noGameScheduled
    }

    private func mapDepthScale(isSelected: Bool, isNearby: Bool = true) -> CGFloat {
        if isSelected { return 1.10 }
        return isNearby ? 1.02 : 0.96
    }

    private func logMapDepthMarker(id: String, scale: CGFloat, selected: Bool) {
#if DEBUG
        print("[MapDepthDebug] selectedMarker=\(selected ? id : "nil")")
        print("[MapDepthDebug] markerScale=\(String(format: "%.2f", scale))")
        print("[MapDepthDebug] markerShadowApplied=true")
#endif
    }

    private func logMapDepthPulse(isSelected: Bool, id: String) {
#if DEBUG
        print(isSelected ? "[MapDepthDebug] pulseStarted=\(id)" : "[MapDepthDebug] pulseStopped=\(id)")
#endif
    }

    private func logMapDepthCluster(id: String) {
#if DEBUG
        print("[MapDepthDebug] clusterStyled=\(id)")
        print("[MapDepthDebug] markerShadowApplied=true")
#endif
    }

    private func mapDepthPulseRing(tint: Color) -> some View {
        MapDepthPulseRing(tint: tint)
    }

    private func mapDepthStyledMarker<Content: View>(
        id: String,
        isSelected: Bool,
        tint: Color = FGColor.accentBlue,
        @ViewBuilder content: () -> Content
    ) -> some View {
        let scale = mapDepthScale(isSelected: isSelected)
        return ZStack {
            if isSelected {
                mapDepthPulseRing(tint: tint)
                    .frame(width: 58, height: 58)
            }
            content()
        }
        .scaleEffect(scale)
        .shadow(color: .black.opacity(isSelected ? 0.22 : 0.13), radius: isSelected ? 8 : 5, y: isSelected ? 5 : 3)
        .zIndex(isSelected ? 20 : 1)
        .animation(.spring(response: 0.32, dampingFraction: 0.78), value: isSelected)
        .onAppear {
            logMapDepthMarker(id: id, scale: scale, selected: isSelected)
            logMapDepthPulse(isSelected: isSelected, id: id)
        }
        .onChange(of: isSelected) { _, selected in
            logMapDepthMarker(id: id, scale: mapDepthScale(isSelected: selected), selected: selected)
            logMapDepthPulse(isSelected: selected, id: id)
        }
    }

    private func mapDepthStyledCluster<Content: View>(
        id: String,
        tint: Color,
        @ViewBuilder content: () -> Content
    ) -> some View {
        content()
            .background {
                Circle()
                    .fill(tint.opacity(0.10))
                    .scaleEffect(1.18)
                    .blur(radius: 3)
                    .allowsHitTesting(false)
            }
            .shadow(color: tint.opacity(0.16), radius: 8, y: 3)
            .shadow(color: .black.opacity(0.12), radius: 5, y: 2)
            .transition(.scale(scale: 0.96).combined(with: .opacity))
            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: id)
            .onAppear { logMapDepthCluster(id: id) }
    }

    /// Chooses pin chrome from **venue + cached engagement** first; map zoom (`mapPinDisplayMode`) only caps density. Multi-game / trending venues never stay on the tiny sport-only pin at wide zoom.
    private func venueMarkerPinPresentation(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        base: MapViewModel.MapPinDisplayMode,
        energyOverride: Int? = nil
    ) -> (mode: MapViewModel.MapPinDisplayMode, energy: Int, wantsEnriched: Bool) {
        let energy = energyOverride ?? viewModel.mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
        let gamesOnSelectedDay = gamesToday.count
        let scheduledVenueGames = bar.games.count
        let wantsEnriched = gamesOnSelectedDay >= 2 || scheduledVenueGames >= 2 || energy > 0

        guard wantsEnriched else { return (base, energy, false) }

        let mode: MapViewModel.MapPinDisplayMode
        switch base {
        case .simple:
            mode = .compact
        case .compact:
            mode = .compact
        case .detailed:
            mode = gamesToday.isEmpty ? .compact : .detailed
        }
        return (mode, energy, true)
    }

    @ViewBuilder
    private func singleVenueMapPinButton(bar: BarVenue) -> some View {
        let pinSnapshot = viewModel.discoverMapRenderSnapshot.venuePinsByID[bar.id]
        let gamesToday = pinSnapshot?.selectedDayGames ?? viewModel.selectedDayEventsForMap(bar)
        let goingTotal = pinSnapshot?.goingTotal ?? gamesToday.reduce(0) { total, game in
            if let id = viewModel.cachedVenueEventID(for: bar, gameTitle: game.title) {
                return total + viewModel.interestCountForVenueEvent(id)
            }
            return total
        }

#if DEBUG
        let _: Void = {
            guard pinSnapshot != nil else { return }
            DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingPinSnapshot=true")
        }()
#endif

        let pin = venueMarkerPinPresentation(
            bar: bar,
            gamesToday: gamesToday,
            base: viewModel.mapPinDisplayMode,
            energyOverride: pinSnapshot?.pinEnergyScore
        )
        let effectiveMode = pin.mode
        let isSelected = viewModel.selectedBar?.id == bar.id
        let hasLiveNow = pinSnapshot?.hasLiveNow ?? viewModel.hasLiveVenueEventNow(for: bar, events: gamesToday)

#if DEBUG
        let _: Void = {
            guard pin.wantsEnriched else { return }
            let style: String = {
                switch effectiveMode {
                case .simple: return "simple"
                case .compact: return "compact"
                case .detailed: return "detailed"
                }
            }()
            DebugLogGate.noisy("[MapMarker] venue=\(bar.name) games=\(gamesToday.count)/\(bar.games.count) score=\(pin.energy) style=\(style)")
        }()
#endif

        Button {
            FGInteractionHaptics.selection()
            venuePreviewGameFilter = .all
            withAnimation(.spring()) {
                viewModel.clearPickupMapSelection()
                viewModel.centerMap(on: bar)
            }
        } label: {
            mapDepthStyledMarker(
                id: bar.id.uuidString.lowercased(),
                isSelected: isSelected,
                tint: hasLiveNow || pin.energy >= livePulseThreshold ? FGColor.accentGreen : FGColor.accentBlue
            ) {
                Group {
                    switch venuePinDisplayState(bar) {
                    case .gameScheduled:
                        switch effectiveMode {
                        case .simple:
                            simpleMapPin(bar: bar, gamesToday: gamesToday)

                        case .compact:
                            compactMapPin(
                                bar: bar,
                                gamesToday: gamesToday,
                                goingTotal: goingTotal,
                                liveScore: pin.energy,
                                hasLiveNow: hasLiveNow
                            )

                        case .detailed:
                            detailedMapPin(
                                bar: bar,
                                gamesToday: gamesToday,
                                goingTotal: goingTotal,
                                liveScore: pin.energy,
                                hasLiveNow: hasLiveNow
                            )
                        }
                    case .noGameScheduled:
                        noGameScheduledMapPin()
                    }
                }
            }
            .saturation(isSelected ? 0.82 : 0.66)
            .brightness(isSelected ? -0.01 : -0.035)
            .opacity(isSelected ? 0.96 : 0.82)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func multiVenueClusterAnnotation(cluster: VenueCluster) -> some View {
        let clusterSnapshot = viewModel.discoverMapRenderSnapshot.venueClustersByID[cluster.id]
        let energy = clusterSnapshot.map {
            (maxScore: $0.maxEnergyScore, dominantSport: $0.dominantSport)
        } ?? viewModel.clusterVenueAnnotationEnergy(cluster: cluster)
        let displayState = clusterDisplayState(cluster)
#if DEBUG
        let _: Void = {
            guard clusterSnapshot != nil else { return }
            DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingClusterSnapshot=true")
        }()
#endif
        Button {
            FGInteractionHaptics.selection()
            #if DEBUG
            print(
                "[DiscoverMap] cluster tap id=\(cluster.id) count=\(cluster.count) maxEnergy=\(energy.maxScore) center=(\(cluster.coordinate.latitude),\(cluster.coordinate.longitude))"
            )
            #endif
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                viewModel.zoomTowardCluster(center: cluster.coordinate)
            }
            clusterForSheet = cluster
        } label: {
            mapDepthStyledCluster(
                id: cluster.id,
                tint: energy.maxScore > 0 ? FGColor.accentGreen : FGColor.accentBlue
            ) {
                clusterMapPin(
                    cluster: cluster,
                    maxEnergy: energy.maxScore,
                    dominantSport: energy.dominantSport,
                    displayState: displayState
                )
            }
            .saturation(0.68)
            .brightness(-0.03)
            .opacity(0.82)
        }
        .buttonStyle(.plain)
    }

    private func discoverLocationAuthStatusLabel(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorizedAlways: return "authorizedAlways"
        case .authorizedWhenInUse: return "authorizedWhenInUse"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private var discoverPickupClustersForMap: [PickupGameCluster] {
        let rows = viewModel.pickupGamesForDiscoverMap.filter { row in
            guard let lat = row.latitude, let lon = row.longitude else { return false }
            return CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon))
        }
        return viewModel.clusteredPickupGamesForDiscoverMap(rows: rows)
    }

    private var discoverVenueClustersForMap: [VenueCluster] {
        let snapshotClusters = viewModel.discoverMapRenderSnapshotVenueClustersForMap()
        if !snapshotClusters.isEmpty {
#if DEBUG
            DebugLogGate.noisy("[PerfPhase1B] mapUsingSnapshotClusters count=\(snapshotClusters.count)")
#endif
            return snapshotClusters
        }
        let fallback = viewModel.clusteredBars()
#if DEBUG
        DebugLogGate.noisy("[PerfPhase1B] mapUsingFallbackClusters count=\(fallback.count)")
#endif
        return fallback
    }

    private func logPickupMapDebug(pickupGamesCount: Int, isPickupModeActive: Bool, annotationsRendered: Int) {
#if DEBUG
        DebugLogGate.noisy("[PickupMapDebug] pickupGames count=\(pickupGamesCount)")
        DebugLogGate.noisy("[PickupMapDebug] isPickupModeActive=\(isPickupModeActive)")
        DebugLogGate.noisy("[PickupMapDebug] annotationsRendered=\(annotationsRendered)")
#endif
    }

    private func logMapEmptyStateDebug(
        mode: DiscoverMapContentMode,
        pickupAnnotationsCount: Int,
        venueAnnotationsCount: Int,
        renderedAnnotationsCount: Int
    ) {
#if DEBUG
        DebugLogGate.noisy("[MapEmptyStateDebug] mode=\(mode.rawValue)")
        DebugLogGate.noisy("[MapEmptyStateDebug] pickupAnnotationsCount=\(pickupAnnotationsCount)")
        DebugLogGate.noisy("[MapEmptyStateDebug] venueAnnotationsCount=\(venueAnnotationsCount)")
        DebugLogGate.noisy("[MapEmptyStateDebug] renderedAnnotationsCount=\(renderedAnnotationsCount)")
#endif
    }

    /// Shows the system user location dot only after access is granted, so the map does not imply tracking before the user allows it.
    private func discoverMapShowsUserAnnotation() -> Bool {
        _ = discoverMapLocationAuthVersion
        switch CLLocationManager().authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse:
            return true
        default:
            return false
        }
    }

    private var mapLayer: some View {
        let pickupClusters = discoverPickupClustersForMap
        let venueClusters = discoverVenueClustersForMap
        let isPickupModeActive = viewModel.discoverMapContentMode == .pickupGames
        let _: Void = logPickupMapDebug(
            pickupGamesCount: viewModel.pickupGamesForDiscoverMap.count,
            isPickupModeActive: isPickupModeActive,
            annotationsRendered: isPickupModeActive ? pickupClusters.count : 0
        )

        return Map(position: $viewModel.cameraPosition) {
            if discoverMapShowsUserAnnotation() {
                UserAnnotation()
            }

            if viewModel.discoverMapContentMode == .venues {
                ForEach(venueClusters) { cluster in
                    Annotation(
                        cluster.count == 1 ? cluster.bars.first?.name ?? "Venue" : "\(cluster.count) venues",
                        coordinate: cluster.coordinate
                    ) {
                        if cluster.count == 1, let bar = cluster.bars.first {
                            singleVenueMapPinButton(bar: bar)
                        } else {
                            multiVenueClusterAnnotation(cluster: cluster)
                        }
                    }
                }
            }

            if viewModel.discoverMapContentMode == .pickupGames {
                ForEach(pickupClusters) { cluster in
                    Annotation(
                        cluster.count == 1 ? (cluster.rows.first?.title ?? "Pickup game") : "\(cluster.count) pickup games",
                        coordinate: cluster.coordinate
                    ) {
                        if cluster.count == 1, let row = cluster.rows.first {
                            pickupGameMapPinButton(row: row)
                        } else {
                            multiPickupGameClusterAnnotation(cluster: cluster)
                        }
                    }
                }
            }
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                dismissDiscoverSearchKeyboard()
            }
        )
        .onMapCameraChange(frequency: .continuous) { _ in
            if isSearchFocused {
                dismissDiscoverSearchKeyboard()
            }
        }
        .mapControls {
            MapCompass()
        }
        .onMapCameraChange(frequency: .onEnd) { context in
            dismissDiscoverSearchKeyboard()
            viewModel.visibleLatitudeDelta = context.region.span.latitudeDelta
            viewModel.cameraPosition = .region(context.region)

            let region = context.region
            mapVenueReloadTask?.cancel()
            mapVenueReloadTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .milliseconds(400))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                if let last = lastMapVenueReloadRegion,
                   !mapVenueRegionIsMeaningfullyDifferent(from: last, to: region) {
                    return
                }
                guard viewModel.discoverMapContentMode == .venues else { return }
                await viewModel.loadVenuesFromSupabase()
                lastMapVenueReloadRegion = region
            }
        }
        .ignoresSafeArea()
    }
    
    private var showDiscoverVisibleSearchEmptyHint: Bool {
        let pickupAnnotationsCount = discoverPickupClustersForMap.count
        let venueAnnotationsCount = discoverVenueClustersForMap.count
        let renderedAnnotationsCount = viewModel.discoverMapContentMode == .pickupGames
            ? pickupAnnotationsCount
            : venueAnnotationsCount
        logMapEmptyStateDebug(
            mode: viewModel.discoverMapContentMode,
            pickupAnnotationsCount: pickupAnnotationsCount,
            venueAnnotationsCount: venueAnnotationsCount,
            renderedAnnotationsCount: renderedAnnotationsCount
        )
        return renderedAnnotationsCount == 0
    }

    private func discoverLogRedesignDebug() {
#if DEBUG
        print("[DiscoverRedesignDebug] layout=map_overlay_light")
        print("[DiscoverRedesignDebug] venuePickupToggle=floating")
        print("[DiscoverRedesignDebug] infoPill=compact")
        print("[DiscoverRedesignDebug] weatherPill=enabled")
        print("[DiscoverSportsFilterDebug] compactPills=true")
        print("[DiscoverSportsFilterDebug] chipHeight=36")
        print("[DiscoverSportsFilterDebug] iconSize=13")
#endif
    }

    private var discoverFixedTopOverlay: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let discoverLocationHint {
                HStack(alignment: .top, spacing: FGSpacing.sm) {
                    Image(systemName: "location.slash.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(FGColor.accentYellow)
                    Text(discoverLocationHint)
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .discoverLightGlassCard(style: .overlay)
            }

            discoverFloatingSearchBar
            discoverSportsFilterGlassCard
            HStack(spacing: 10) {
                discoverWeatherPill
                Spacer(minLength: 0)
                discoverMapDisplayModeToggleCluster
            }

            if showDiscoverVisibleSearchEmptyHint {
                HStack(spacing: FGSpacing.sm) {
                    FGStatusPill(title: "No visible matches", kind: .custom(tint: FGColor.accentBlue))
                    Text("Zoom out or search this area.")
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .discoverLightGlassCard(style: .overlay)
            }

            if !viewModel.venueSearchResults.isEmpty {
                VStack(spacing: FGSpacing.sm) {
                    ForEach(viewModel.venueSearchResults.prefix(4)) { bar in
                        Button {
                            dismissDiscoverSearchKeyboard()
                            withAnimation(.spring()) {
                                venuePreviewGameFilter = .all
                                viewModel.selectVenueFromDiscoverSearchResult(bar)
                            }
                        } label: {
                            HStack(spacing: FGSpacing.md) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(FGColor.accentBlue)
                                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                                    Text(bar.name)
                                        .font(FGTypography.cardTitle)
                                        .foregroundStyle(FGColor.primaryText(colorScheme))
                                    Text(bar.address)
                                        .font(FGTypography.caption)
                                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                                        .lineLimit(1)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(FGColor.mutedText(colorScheme))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .discoverLightGlassCard(style: .overlay)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 6)
        .padding(.horizontal, 20)
    }

    private func discoverFixedBottomOverlay(layoutWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            VStack(spacing: 14) {
                if let mapHint = viewModel.followingMapNavigationMessage, !mapHint.isEmpty {
                    HStack(alignment: .top, spacing: FGSpacing.sm) {
                        FGStatusPill(title: "Going", kind: .custom(tint: FGColor.accentBlue))
                        Text(mapHint)
                            .font(FGTypography.caption)
                            .foregroundStyle(FGColor.secondaryText(colorScheme))
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .discoverLightGlassCard(style: .bottomControl)
                }

                if let socialToastText = viewModel.socialActionToastText,
                   !socialToastText.isEmpty {
                    discoverMapToastBanner(
                        text: socialToastText,
                        isError: viewModel.socialActionToastIsError
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                if let mapStatusText = viewModel.mapStatusText,
                   !mapStatusText.isEmpty {
                    discoverMapStatusBanner(
                        text: mapStatusText,
                        isLoading: viewModel.isUpdatingMapGames
                    )
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }

                if viewModel.selectedBar != nil || viewModel.selectedPickupGameForMap != nil {
                    discoverBottomLeadingCard
                        .padding(.bottom, 6)
                }

                discoverUnifiedInfoToggleControl(layoutWidth: layoutWidth)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)

            discoverBottomAdStrip(layoutWidth: layoutWidth)
                .padding(.top, 12)
                .padding(.bottom, 16)

            Color.clear
                .frame(height: 66)
                .allowsHitTesting(false)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 2)
    }

    private func discoverLogLayoutDebug(layoutWidth: CGFloat) {
#if DEBUG
        print("[DiscoverLayoutDebug] overlayArchitecture=fixed")
        print("[DiscoverLayoutDebug] topOverlayIndependent=true")
        print("[DiscoverLayoutDebug] bottomOverlayIndependent=true")
        print("[DiscoverLayoutDebug] adaptiveLayoutDisabled=true")
        print("[DiscoverLayoutDebug] layersButtonMovedToWeatherRow=true")
        print("[DiscoverLayoutDebug] sportsChipsReduced=true")
        print("[DiscoverLayoutDebug] bottomBarLowered=true")
        print("[DiscoverLayoutDebug] unifiedInfoToggle=true")
        print("[DiscoverLayoutDebug] standaloneInfoPillRemoved=true")
        print("[DiscoverLayoutDebug] unifiedControlWidth=\(discoverUnifiedControlMaxWidth(for: layoutWidth))")
        print("[DiscoverLayoutDebug] weatherUsesUserLocationOnly=true")
        print("[DiscoverVisualPolishDebug] strongGlassPassApplied=true")
        print("[DiscoverVisualPolishDebug] overlayOpacityReduced=true")
        print("[DiscoverVisualPolishDebug] shadowReductionVisible=true")
        print("[DiscoverVisualPolishDebug] finalTopLighteningPass=true")
        print("[DiscoverBottomControlDebug] animatedToggle=true")
        print("[DiscoverBottomControlDebug] infoTextTransition=true")
        print("[DiscoverBottomControlDebug] hapticOnModeSwitch=true")
        print("[DiscoverAdPolishDebug] adSystemStrip=true")
        print("[DiscoverAdPolishDebug] adUsesOuterLayoutWidth=true")
        print("[DiscoverAdPolishDebug] adChromeRemoved=true")
#endif
    }

    private func discoverAdBannerAvailableWidth(for layoutWidth: CGFloat) -> CGFloat {
        max(1, floor(layoutWidth - 40))
    }

    private func discoverAdaptiveBannerSize(for layoutWidth: CGFloat) -> CGSize {
        AdaptiveBannerLayout.adaptiveBannerSize(
            forAvailableWidth: discoverAdBannerAvailableWidth(for: layoutWidth)
        )
    }

    private var discoverBottomControlModeSpring: Animation {
        .spring(response: 0.28, dampingFraction: 0.82)
    }

    private var discoverBottomControlStatusTextAnimation: Animation {
        .easeInOut(duration: 0.2)
    }

    private func discoverUnifiedControlMaxWidth(for layoutWidth: CGFloat) -> CGFloat {
        min(layoutWidth - 40, 360)
    }

    private func discoverEmbeddedToggleWidth(for layoutWidth: CGFloat) -> CGFloat {
        layoutWidth < 390 ? 128 : 140
    }

    private func discoverUnifiedInfoToggleControl(layoutWidth: CGFloat) -> some View {
        HStack(spacing: 8) {
            discoverUnifiedStatusLeading
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)

            discoverEmbeddedVenuePickupToggle(layoutWidth: layoutWidth)
                .layoutPriority(1)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(width: discoverUnifiedControlMaxWidth(for: layoutWidth), height: 46)
        .discoverLightGlassCard(cornerRadius: 24, style: .bottomControl)
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.18 : 0.08), radius: 10, y: 5)
        .frame(maxWidth: .infinity)
    }

    private var discoverUnifiedStatusLeading: some View {
        HStack(spacing: 6) {
            if discoverSummaryLoadingFeedbackVisible {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: viewModel.discoverMapContentMode == .pickupGames ? "figure.run" : "map.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(FGColor.accentBlue)
                    .animation(discoverBottomControlModeSpring, value: viewModel.discoverMapContentMode)
            }

            Text(discoverInfoMessage)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
                .truncationMode(.tail)
                .minimumScaleFactor(0.8)
                .id(discoverInfoMessage)
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    )
                )
                .onAppear { discoverLogEmptyStateDebug() }
                .onChange(of: discoverInfoMessage) { _, _ in
                    discoverLogEmptyStateDebug()
                }
        }
        .animation(discoverBottomControlStatusTextAnimation, value: discoverInfoMessage)
    }

    private var discoverInfoMessage: String {
        discoverUnifiedStatusText
    }

    private func discoverLogBottomControlModeSwitch(to mode: DiscoverMapContentMode) {
#if DEBUG
        print("[DiscoverBottomControlDebug] animatedToggle=true mode=\(mode.rawValue)")
        print("[DiscoverBottomControlDebug] hapticOnModeSwitch=true")
        print("[DiscoverBottomControlDebug] matchedGeometrySelection=true")
        print("[DiscoverBottomControlDebug] infoTextTransition=true")
#endif
    }

    private func discoverLogEmptyStateDebug() {
#if DEBUG
        print("[DiscoverEmptyStateDebug] message=\(discoverUnifiedStatusText)")
#endif
    }

    private var discoverFloatingSearchBar: some View {
        ZStack(alignment: .trailing) {
            FGSearchBar(
                placeholder: "Search venues, teams, or locations",
                text: $viewModel.searchText,
                onClear: { dismissDiscoverSearchKeyboard() },
                onSubmit: {
                    dismissDiscoverSearchKeyboard()
                    viewModel.searchMapLocation()
                },
                submitLabel: .search,
                textInputAutocapitalization: .words,
                isFocused: $isSearchFocused,
                horizontalPadding: 16,
                verticalPadding: 14,
                cornerRadius: discoverLightGlassCornerRadius,
                contentSpacing: 8,
                textFont: .system(size: 16, weight: .regular, design: .rounded),
                showsBackground: false,
                trailingAccessoryInset: 50
            )

            HStack(spacing: 6) {
                if viewModel.isDiscoverVenueSearchLoading {
                    ProgressView()
                        .controlSize(.small)
                }
                discoverIntegratedLocationButton
            }
            .padding(.trailing, 18)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 56)
        .discoverLightGlassCard(cornerRadius: discoverLightGlassCornerRadius, style: .searchBar)
    }

    private var discoverIntegratedLocationButton: some View {
        Button {
            discoverCenterMapOnUserLocation()
        } label: {
            Image(systemName: "location.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(FGColor.accentBlue)
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(Color.white.opacity(colorScheme == .dark ? 0.19 : 0.34))
                )
        }
        .buttonStyle(DiscoverIntegratedLocationButtonStyle())
        .frame(width: 44, height: 44)
        .contentShape(Rectangle())
        .accessibilityLabel("Center map on your location")
    }

    private func discoverCenterMapOnUserLocation() {
        Task { @MainActor in
#if DEBUG
            print("[CurrentLocationButton] tapped")
#endif
            dismissDiscoverSearchKeyboard()
            let status = CLLocationManager().authorizationStatus
#if DEBUG
            print("[CurrentLocationButton] permission=\(discoverLocationAuthStatusLabel(status))")
#endif
            if status == .denied || status == .restricted {
                discoverLocationHint = "Location is turned off. You can enable it in Settings ▸ Privacy & Security ▸ Location Services ▸ FanGeo. The map still shows a default area you can pan and search."
                return
            }
            discoverLocationHint = nil
            let centered = await viewModel.centerDiscoverMapOnUserPhysicalLocationIfPossible()
            if centered {
                scheduleDiscoverWeatherRefresh(force: false)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                discoverMapLocationAuthVersion += 1
            }
        }
    }

    private var discoverSportsFilterGlassCard: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                discoverDateFilterChip
                DiscoverOverlaySportPillRow(
                    viewModel: viewModel,
                    showMoreSheet: $showDiscoverSportMoreSheet,
                    onSelect: { selection in
                        discoverSelectSport(selection)
                    }
                )
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 42)
        .discoverLightGlassCard(cornerRadius: 20, style: .sportsRow)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    @ViewBuilder
    private var discoverWeatherPill: some View {
        if let discoverWeather {
            HStack(spacing: 6) {
                Image(systemName: discoverWeather.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .symbolRenderingMode(.multicolor)
                Text("\(discoverWeather.temperature)°F")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(FGColor.primaryText(colorScheme))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .discoverLightGlassCard(cornerRadius: 18, style: .weather)
            .accessibilityLabel("Weather \(discoverWeather.temperature) degrees")
        }
    }

    private var discoverMapCenterCoordinate: CLLocationCoordinate2D? {
        viewModel.cameraPosition.region?.center
    }

    private enum DiscoverWeatherCoordinateBasis {
        case userLocation
        case mapCenterFallback
    }

    private func scheduleDiscoverWeatherRefresh(force: Bool) {
        discoverWeatherRefreshTask?.cancel()
        discoverWeatherRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }

            if force || viewModel.currentUserLocation == nil {
                _ = await viewModel.refreshCurrentUserLocationIfAuthorized()
            }

            let mapCenter = discoverMapCenterCoordinate
            guard let decision = resolveDiscoverWeatherCoordinate(mapCenter: mapCenter) else {
                discoverWeather = nil
                return
            }

            discoverLogWeatherRequest(decision, mapCenter: mapCenter)

            let weather = await DiscoverWeatherService.shared.weather(
                for: decision.coordinate,
                force: force,
                requestedBasis: decision.requestedBasisLabel
            )
            guard !Task.isCancelled else { return }

            discoverLogWeatherResult(decision, mapCenter: mapCenter, weather: weather)

            if let weather {
                discoverWeather = weather
            } else {
                discoverWeather = nil
            }
        }
    }

    private func resolveDiscoverWeatherCoordinate(
        mapCenter: CLLocationCoordinate2D?
    ) -> DiscoverWeatherCoordinateDecision? {
        let userCoordinate = viewModel.currentUserLocation
        let userAvailable = userCoordinate.map { CLLocationCoordinate2DIsValid($0) } ?? false

        let validMapCenter = mapCenter.flatMap { center -> CLLocationCoordinate2D? in
            CLLocationCoordinate2DIsValid(center) ? center : nil
        }

        if userAvailable, let userCoordinate {
            return DiscoverWeatherCoordinateDecision(
                coordinate: userCoordinate,
                basis: .userLocation,
                requestedBasis: .userLocation
            )
        }

        if let validMapCenter {
            return DiscoverWeatherCoordinateDecision(
                coordinate: validMapCenter,
                basis: .mapCenterFallback,
                requestedBasis: .mapCenterFallback
            )
        }

        return nil
    }

    private func discoverLogWeatherRequest(
        _ decision: DiscoverWeatherCoordinateDecision,
        mapCenter: CLLocationCoordinate2D?
    ) {
#if DEBUG
        print("[DiscoverWeatherDebug] requestedBasis=\(decision.requestedBasisLabel)")
        if let user = viewModel.currentUserLocation, CLLocationCoordinate2DIsValid(user) {
            print(String(format: "[DiscoverWeatherDebug] userLocationLat=%.4f", user.latitude))
            print(String(format: "[DiscoverWeatherDebug] userLocationLon=%.4f", user.longitude))
        } else {
            print("[DiscoverWeatherDebug] userLocationLat=nil")
            print("[DiscoverWeatherDebug] userLocationLon=nil")
        }
        if let mapCenter, CLLocationCoordinate2DIsValid(mapCenter) {
            print(String(format: "[DiscoverWeatherDebug] mapCenterLat=%.4f", mapCenter.latitude))
            print(String(format: "[DiscoverWeatherDebug] mapCenterLon=%.4f", mapCenter.longitude))
        } else {
            print("[DiscoverWeatherDebug] mapCenterLat=nil")
            print("[DiscoverWeatherDebug] mapCenterLon=nil")
        }
#endif
    }

    private func discoverLogWeatherResult(
        _ decision: DiscoverWeatherCoordinateDecision,
        mapCenter: CLLocationCoordinate2D?,
        weather: DiscoverWeather?
    ) {
#if DEBUG
        _ = mapCenter
        print("[DiscoverWeatherDebug] finalBasis=\(decision.basisLabel)")
        print("[DiscoverWeatherDebug] temp=\(weather.map { String($0.temperature) } ?? "nil")")
#endif
    }

    private struct DiscoverWeatherCoordinateDecision {
        let coordinate: CLLocationCoordinate2D
        let basis: DiscoverWeatherCoordinateBasis
        let requestedBasis: DiscoverWeatherCoordinateBasis

        var requestedBasisLabel: String {
            switch requestedBasis {
            case .userLocation: return "user_location"
            case .mapCenterFallback: return "map_center_fallback"
            }
        }

        var basisLabel: String {
            switch basis {
            case .userLocation: return "user_location"
            case .mapCenterFallback: return "map_center_fallback"
            }
        }
    }

    @ViewBuilder
    private var discoverMapDisplayModeToggleCluster: some View {
        if viewModel.discoverMapContentMode == .venues {
            HStack(spacing: 8) {
                if let mapDisplayModeHintText {
                    Text(mapDisplayModeHintText)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background {
                            Capsule(style: .continuous)
                                .fill(.ultraThinMaterial)
                                .overlay {
                                    Capsule(style: .continuous)
                                        .fill(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.50))
                                }
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(
                                    colorScheme == .dark ? Color.white.opacity(0.18) : FGColor.divider(colorScheme),
                                    lineWidth: 1
                                )
                        }
                        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.08), radius: 6, y: 2)
                        .transition(.opacity.combined(with: .move(edge: .trailing).combined(with: .scale(scale: 0.94))))
                }

                discoverMapDisplayModeToggleButton
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: mapDisplayModeHintText)
            .animation(.spring(response: 0.28, dampingFraction: 0.86), value: viewModel.mapDisplayMode)
        }
    }

    private var discoverMapDisplayModeToggleButton: some View {
        let isGamesOnly = viewModel.mapDisplayMode == .gamesOnly
        let iconName = isGamesOnly ? "sportscourt.fill" : "mappin.and.ellipse"

        return Button {
            cycleDiscoverMapDisplayMode()
        } label: {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isGamesOnly ? Color.white : FGColor.secondaryText(colorScheme))
                .frame(width: 36, height: 36)
                .background {
                    if isGamesOnly {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [FGColor.accentBlue, FGColor.accentGreen.opacity(0.92)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    } else {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .overlay {
                                Circle()
                                    .fill(Color.white.opacity(colorScheme == .dark ? 0.36 : 0.42))
                            }
                    }
                }
                .overlay {
                    Circle()
                        .strokeBorder(
                            isGamesOnly
                                ? Color.white.opacity(colorScheme == .dark ? 0.22 : 0.30)
                                : (colorScheme == .dark ? Color.white.opacity(0.14) : FGColor.divider(colorScheme)),
                            lineWidth: 1
                        )
                }
                .shadow(
                    color: isGamesOnly
                        ? FGColor.accentBlue.opacity(colorScheme == .dark ? 0.28 : 0.18)
                        : Color.black.opacity(colorScheme == .dark ? 0.11 : 0.08),
                    radius: isGamesOnly ? 6 : 5,
                    y: 1.5
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(viewModel.mapDisplayMode.title)
        .accessibilityHint("Double tap to switch map display mode")
    }

    private func cycleDiscoverMapDisplayMode() {
        dismissDiscoverSearchKeyboard()
        FGInteractionHaptics.softImpact()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewModel.mapDisplayMode = viewModel.mapDisplayMode.toggled
        }
        showMapDisplayModeHint(viewModel.mapDisplayMode.title)
    }

    private func showMapDisplayModeHint(_ text: String) {
        mapDisplayModeHintTask?.cancel()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            mapDisplayModeHintText = text
        }
        mapDisplayModeHintTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: 0.22)) {
                    mapDisplayModeHintText = nil
                }
            }
        }
    }

    @ViewBuilder
    private var discoverBottomLeadingCard: some View {
        if let selectedBar = viewModel.selectedBar {
            if viewModel.canViewDiscoverDetails() || viewModel.isGuestDiscoverMode {
                venuePreviewCard(selectedBar)
            } else {
                loggedOutVenueTeaserCard(selectedBar)
            }
        } else if let pickup = viewModel.selectedPickupGameForMap {
            discoverPickupPreviewCard(pickup, guestMapsActionsToLogin: viewModel.isGuestDiscoverMode) {
                pickupGameDetailNav = PickupDetailNavigationToken(id: pickup.id)
            }
            .id(pickup.id)
            .transition(
                .asymmetric(
                    insertion: .scale(scale: 0.94, anchor: .leading).combined(with: .opacity),
                    removal: .opacity
                )
            )
        }
    }

    private func discoverSelectSport(_ selection: String) {
        guard !DiscoverSportFilterRowLayout.selectionTokensMatch(viewModel.selectedSport, selection) else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
            viewModel.sportChanged(to: selection)
        }
    }

    private func discoverFriendlySportLabel(for token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "All" { return "" }
        switch trimmed {
        case "NBA": return "Basketball"
        case "NFL": return "Football"
        case "NHL": return "Hockey"
        case "MLB": return "Baseball"
        default:
            if let pair = AppSportCatalog.discoverMapDefaultPopularPairs.first(where: { $0.0 == trimmed }) {
                return pair.1
            }
            return trimmed
        }
    }

    private var discoverUnifiedStatusSuggestsZoomOut: Bool {
        if discoverSummaryLoadingFeedbackVisible { return false }
        if showDiscoverVisibleSearchEmptyHint { return true }

        if viewModel.discoverMapContentMode == .venues {
            guard discoverSummaryVenueCount == 0 else { return false }
            let sportFiltered = viewModel.selectedSport.trimmingCharacters(in: .whitespacesAndNewlines) != "All"
            let searchActive = !viewModel.effectiveDiscoverSearchQuery
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
            guard sportFiltered || searchActive else { return false }
            return viewModel.visibleBarCountInCurrentMapRegion() > 0
        }

        let bounds = viewModel.currentMapRegionBounds()
        let allPickupPins = viewModel.pickupGamesVisibleAsMapPins(for: bounds)
        let matchingPickupPins = discoverPickupPinsInBoundsMatchingSearch
        guard matchingPickupPins == 0, !allPickupPins.isEmpty else { return false }
        let sportFiltered = viewModel.selectedSport.trimmingCharacters(in: .whitespacesAndNewlines) != "All"
        let searchActive = !viewModel.effectiveDiscoverSearchQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        return sportFiltered || searchActive
    }

    private func discoverStatusSportDescriptor() -> String? {
        let label = discoverFriendlySportLabel(for: viewModel.selectedSport)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return nil }
        return label.lowercased()
    }

    private var discoverUnifiedStatusText: String {
        if discoverSummaryLoadingFeedbackVisible {
            return viewModel.discoverMapContentMode == .pickupGames ? "Updating pickup…" : "Updating venues…"
        }
        if discoverUnifiedStatusSuggestsZoomOut {
            return "Try zooming out"
        }

        if viewModel.discoverMapContentMode == .pickupGames {
            let count = discoverPickupPinsInBoundsMatchingSearch
            if count > 0 {
                if let sport = discoverStatusSportDescriptor() {
                    return count == 1 ? "1 \(sport) pickup" : "\(count) \(sport) pickups"
                }
                return count == 1 ? "1 pickup game" : "\(count) pickup games"
            }
            return "No pickup games"
        }

        let count = discoverSummaryVenueCount
        if count > 0 {
            if let sport = discoverStatusSportDescriptor() {
                return count == 1 ? "1 \(sport) spot" : "\(count) \(sport) spots"
            }
            return count == 1 ? "1 watch spot" : "\(count) watch spots"
        }
        return "No games nearby"
    }

    private var discoverDateFilterChip: some View {
        Button {
            openDiscoverDatePicker()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                Text(viewModel.formattedSelectedDate)
                if viewModel.isUpdatingMapGames {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                } else {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                }
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(height: 36)
            .background(FGColor.brandGradient.opacity(colorScheme == .dark ? 0.88 : 0.90))
            .clipShape(Capsule(style: .continuous))
            .shadow(color: FGColor.gradientEnd.opacity(0.12), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
    }

    private func dismissDiscoverSearchKeyboard() {
        isSearchFocused = false
    }

    private func openDiscoverDatePicker() {
        dismissDiscoverSearchKeyboard()
        viewModel.clampDiscoverMapSelectedDateToMinimumCalendarDayIfNeeded()
        let minDay = viewModel.discoverMapCalendarSelectionMinimumDayStart()
        let cal = Calendar.current
        let rawSelection = cal.startOfDay(for: viewModel.selectedDate)
        let selection = max(rawSelection, minDay)
        discoverDatePickerSelection = selection
        discoverCalendarDisplayedMonth = cal.date(from: cal.dateComponents([.year, .month], from: selection)) ?? selection
        #if DEBUG
        let openedLogFormatter = DateFormatter()
        openedLogFormatter.dateFormat = "yyyy-MM-dd"
        openedLogFormatter.timeZone = TimeZone.current
        print("[DiscoverCalendar] opened at today date=\(openedLogFormatter.string(from: selection))")
        #endif
        Task { @MainActor in
            if viewModel.discoverMapContentMode == .pickupGames {
                await viewModel.refreshPickupGamesForDiscoverMap(force: false, preservePickupCalendarDotDatesCache: true)
                #if DEBUG
                print("[PickupCalendarFix] pickup preload ensured count=\(viewModel.pickupGamesForDiscoverMap.count)")
                #endif
            }
            viewModel.loadDiscoverCalendarDots(
                around: discoverCalendarDisplayedMonth,
                reason: "calendar_open",
                logIfOpeningBeforeReady: true
            )
        }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = true
            isCalendarOverlayPresented = true
        }
    }

    private func dismissDiscoverDatePicker() {
        discoverDatePickerSelection = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = false
            isCalendarOverlayPresented = false
        }
    }

    private func applyDiscoverDatePickerSelection() {
        let minDay = viewModel.discoverMapCalendarSelectionMinimumDayStart()
        let raw = discoverDatePickerSelection ?? viewModel.selectedDate
        let appliedDate = max(Calendar.current.startOfDay(for: raw), minDay)
        let isPickup = viewModel.discoverMapContentMode == .pickupGames
        #if DEBUG
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        fmt.timeZone = TimeZone.current
        let appliedDateString = fmt.string(from: appliedDate)
        print("[CalendarPerf] Done tapped date=\(appliedDateString)")
        if isPickup {
            print("[PickupCalendarPerf] done tapped date=\(appliedDateString)")
        }
        if Calendar.current.startOfDay(for: raw) < minDay {
            print("[DiscoverCalendar] selected date clamped to today")
        }
        #endif

        // Dismiss overlay first so Done stays responsive; defer map/date refresh.
        discoverDatePickerSelection = nil
        withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
            showDatePicker = false
            isCalendarOverlayPresented = false
        }
        #if DEBUG
        print("[CalendarPerf] Calendar dismissed date=\(appliedDateString)")
        if isPickup {
            print("[PickupCalendarPerf] dismissed")
        }
        #endif

        let capturedDate = appliedDate
        Task { @MainActor in
            viewModel.noteDiscoverCalendarGuestDatePinnedByUser()
            #if DEBUG
            if isPickup {
                print("[PickupCalendarPerf] background refresh started")
            }
            #endif
            let requestID = viewModel.beginDiscoverDateChange(to: capturedDate)
            viewModel.scheduleDiscoverSelectedDayRefresh(requestID: requestID)
            #if DEBUG
            if isPickup {
                print("[PickupCalendarPerf] background refresh completed")
            }
            #endif
        }
    }
    
    /// Uses existing ``MapViewModel`` loading flags only (no extra fetches).
    private var discoverSummaryDataLoading: Bool {
        switch viewModel.discoverMapContentMode {
        case .pickupGames:
            return viewModel.isLoadingPickupGamesForMap
        case .venues:
            return viewModel.isLoadingEvents
                || viewModel.isRefreshingDiscoverEvents
                || viewModel.isLoadingMapVenues
                || viewModel.isRefreshingMapVenues
        }
    }

    private var discoverSummaryLoadingFeedbackVisible: Bool {
        discoverSummaryDataLoading
    }

    private var discoverSummaryVenueCount: Int {
        viewModel.mapVisibleBars.count
    }

    private var discoverAllFilterHasNoGamePins: Bool {
        guard viewModel.discoverMapContentMode == .venues,
              viewModel.selectedSport == "All",
              viewModel.mapDisplayMode == .allSpots else { return false }
        return viewModel.mapVisibleBars.contains { !viewModel.venueHasVisibleGameToday($0) }
    }

    private var discoverAllFilterHasNoGamesToday: Bool {
        guard viewModel.discoverMapContentMode == .venues,
              viewModel.selectedSport == "All",
              viewModel.mapDisplayMode == .allSpots else { return false }
        return !viewModel.mapVisibleBars.isEmpty && !viewModel.mapVisibleBars.contains { viewModel.venueHasVisibleGameToday($0) }
    }

    private var discoverNearbySummarySubtitle: String {
        if viewModel.discoverMapContentMode == .pickupGames {
            if viewModel.isLoadingPickupGamesForMap {
                return "Updating map…"
            }
            let n = discoverPickupPinsInBoundsMatchingSearch
            let q = viewModel.effectiveDiscoverSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty {
                return n > 0 ? "\(n) pickup games match your search in this area." : "No pickup games match your search in this area."
            }
            return n > 0 ? "Fan-run games for the selected day in this map area." : "No pickup games in this area for the selected day."
        }
        if discoverSummaryLoadingFeedbackVisible {
            return "Updating venues…"
        }
        if viewModel.selectedSport == "All" {
            switch viewModel.mapDisplayMode {
            case .allSpots:
                return "Showing nearby watch spots"
            case .gamesOnly:
                return discoverSummaryVenueCount > 0 ? "Showing venues with games today" : "No games scheduled today."
            }
        }
        if discoverSummaryVenueCount > 0 {
            return "\(discoverSummaryVenueCount) venues match your selection"
        }
        if viewModel.mapDisplayMode == .gamesOnly {
            return "No games scheduled today."
        }
        return "0 venues match your selection"
    }

    private func pickupPlayersNeededDisplay(_ row: PickupGameRow) -> Int {
        let confirmedPlayers = row.approvedJoinCount
        return max(0, row.playersNeededClamped - confirmedPlayers)
    }

    private func pickupDemandBadgeText(for playersNeeded: Int) -> String {
        switch playersNeeded {
        case 0:
            return "FULL"
        case 1...3:
            return "\(playersNeeded)"
        default:
            return "4+"
        }
    }

    private func logPickupBadgeDebug(row: PickupGameRow, playersNeeded: Int, badgeValue: String) {
#if DEBUG
        print("[PickupBadgeDebug] confirmedPlayers=\(row.approvedJoinCount)")
        print("[PickupBadgeDebug] maxPlayers=\(row.max_players ?? row.playersNeededClamped)")
        print("[PickupBadgeDebug] playersNeeded=\(playersNeeded)")
        print("[PickupBadgeDebug] badgeValue=\(badgeValue)")
#endif
    }

    private func pickupPreviewMetricCapsule(_ text: String, mainInk: Color) -> some View {
        Text(text)
            .font(FGTypography.caption.weight(.semibold))
            .foregroundStyle(mainInk)
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background {
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(colorScheme == .dark ? 0.16 : 0.45))
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.22 : 0.38), lineWidth: 0.75)
                    }
            }
    }

    private func dominantPickupClusterSport(_ rows: [PickupGameRow]) -> String? {
        var counts: [String: Int] = [:]
        for row in rows {
            let s = row.sport.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !s.isEmpty else { continue }
            counts[s, default: 0] += 1
        }
        return counts.max(by: { $0.value < $1.value })?.key
    }

    private func pickupMarkerActivity(for row: PickupGameRow) -> PickupGameMapMarkerActivity {
        if row.hasPickupGameStarted() || row.approvedJoinCount >= 3 {
            return .high
        }
        if row.approvedJoinCount > 0 || row.pickupOpenSlotsRemaining <= 2 {
            return .medium
        }
        return .low
    }

    private func pickupMarkerActivity(for rows: [PickupGameRow]) -> PickupGameMapMarkerActivity {
        if rows.contains(where: { $0.hasPickupGameStarted() || $0.approvedJoinCount >= 3 }) {
            return .high
        }
        if rows.count >= 3 || rows.contains(where: { $0.approvedJoinCount > 0 || $0.pickupOpenSlotsRemaining <= 2 }) {
            return .medium
        }
        return .low
    }

    private func pickupMarkerSportIcon(for sport: String) -> String {
        let key = sport.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch key {
        case "soccer", "mls", "premier league":
            return "soccerball"
        case "basketball", "nba":
            return "basketball.fill"
        case "tennis":
            return "tennisball.fill"
        case "baseball", "mlb":
            return "baseball.fill"
        case "softball":
            return "baseball.fill"
        case "football", "american football", "nfl":
            return "football.fill"
        case "hockey", "ice hockey", "nhl":
            return "hockey.puck.fill"
        case "volleyball":
            return "volleyball.fill"
        case "cricket":
            return "cricket.ball.fill"
        case "rugby":
            return "rugbyball.fill"
        case "golf":
            return "figure.golf"
        case "pickleball":
            return "figure.pickleball"
        case "ping pong", "pingpong", "table tennis", "tabletennis":
            return "figure.table.tennis"
        case "lacrosse":
            return "figure.lacrosse"
        default:
            return viewModel.iconForSport(sport)
        }
    }

    private func pickupGameMapPinButton(row: PickupGameRow) -> some View {
        let needed = pickupPlayersNeededDisplay(row)
        let isSelected = viewModel.selectedPickupGameForMap?.id == row.id
        let badgeValue = pickupDemandBadgeText(for: needed)
        logPickupBadgeDebug(row: row, playersNeeded: needed, badgeValue: badgeValue)
        return Button {
            FGInteractionHaptics.selection()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.86)) {
                viewModel.selectPickupGameOnMap(row)
            }
        } label: {
            PickupGameMapMarker(
                systemImage: pickupMarkerSportIcon(for: row.sport),
                accentColor: viewModel.colorForSport(row.sport),
                activity: pickupMarkerActivity(for: row),
                demandBadgeText: badgeValue,
                isSelected: isSelected
            )
            .zIndex(isSelected ? 30 : 10)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pickup \(row.sport), \(needed) spots open, \(row.title)")
    }

    @ViewBuilder
    private func multiPickupGameClusterAnnotation(cluster: PickupGameCluster) -> some View {
        let sportHint = dominantPickupClusterSport(cluster.rows)
        Button {
            FGInteractionHaptics.selection()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) {
                viewModel.zoomTowardCluster(center: cluster.coordinate)
            }
        } label: {
            PickupGameMapMarker(
                systemImage: pickupMarkerSportIcon(for: sportHint ?? ""),
                accentColor: viewModel.colorForSport(sportHint ?? ""),
                activity: pickupMarkerActivity(for: cluster.rows),
                isCluster: true,
                count: cluster.count
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(cluster.count) pickup games")
    }

    private func discoverPickupPreviewCard(
        _ row: PickupGameRow,
        guestMapsActionsToLogin: Bool,
        onOpenDetails: @escaping () -> Void
    ) -> some View {
        let locationLine: String = {
            guard !guestMapsActionsToLogin else { return "" }
            return [row.address, row.city, row.state]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: ", ")
        }()
        let detailSubtitle: String = {
            if guestMapsActionsToLogin {
                return "Sign in to see schedule, location, and roster details"
            }
            return "\(row.sport) • \(row.skillLevelEnum.displayTitle) • \(row.playEnvironmentEnum.shortLabel)"
        }()
        let sportTint = viewModel.colorForSport(row.sport)
        let sportEmoji = viewModel.emojiForSport(row.sport)
        let sportIconName = viewModel.iconForSport(row.sport)
        let mainInk = colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.primaryText(colorScheme)
        let subInk = colorScheme == .dark ? Color.white.opacity(0.72) : FGColor.secondaryText(colorScheme)
        let dismissIcon = colorScheme == .dark ? Color.white.opacity(0.72) : Color.secondary
        let previewCorner: CGFloat = 30

        let detailTitle = guestMapsActionsToLogin ? "Log in / Sign up" : "Details & join"
        let openDetailAction = {
            onOpenDetails()
        }
        let showStarted = !guestMapsActionsToLogin && row.hasPickupGameStarted()

        return VStack(alignment: .leading, spacing: FGSpacing.md) {
            HStack(alignment: .top, spacing: FGSpacing.md) {
                PickupGameStartedSportGlyphFrame(showStarted: showStarted) {
                    ZStack {
                        Circle()
                            .fill(.ultraThinMaterial)
                            .frame(width: 58, height: 58)
                            .overlay {
                                Circle()
                                    .strokeBorder(
                                        LinearGradient(
                                            colors: [
                                                Color.white.opacity(colorScheme == .dark ? 0.35 : 0.65),
                                                sportTint.opacity(0.55)
                                            ],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        ),
                                        lineWidth: 1.25
                                    )
                            }
                            .shadow(color: sportTint.opacity(0.35), radius: 10, y: 4)

                        if !sportEmoji.isEmpty {
                            Text(sportEmoji)
                                .font(.system(size: 30))
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: sportIconName)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(sportTint)
                                .accessibilityHidden(true)
                        }
                    }
                }

                Button {
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                        openDetailAction()
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Pickup game")
                            .font(.caption.weight(.heavy))
                            .foregroundStyle(Color.orange)
                            .tracking(0.4)
                        Text(guestMapsActionsToLogin ? row.sport : row.title)
                            .font(FGTypography.sectionTitle)
                            .foregroundStyle(mainInk)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(detailSubtitle)
                            .font(FGTypography.metadata.weight(.medium))
                            .foregroundStyle(subInk)
                            .lineLimit(2)
                            .minimumScaleFactor(0.88)

                        if !guestMapsActionsToLogin, let start = PickupGameModels.parseSupabaseTimestamptz(row.game_start_at) {
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Image(systemName: "clock.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(subInk)
                                Text(start.formatted(date: .abbreviated, time: .shortened))
                                    .font(FGTypography.metadata.weight(.semibold))
                                    .foregroundStyle(mainInk)
                            }
                            if showStarted {
                                PickupGameStartedLineCaption()
                                    .padding(.top, 2)
                            }
                        }

                        if !locationLine.isEmpty {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "mappin.circle.fill")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(FGColor.accentBlue)
                                Text(locationLine)
                                    .font(FGTypography.caption)
                                    .foregroundStyle(subInk)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !guestMapsActionsToLogin {
                            HStack(spacing: FGSpacing.sm) {
                                let playersNeeded = pickupPlayersNeededDisplay(row)
                                pickupPreviewMetricCapsule("\(playersNeeded) spots left", mainInk: mainInk)
                                pickupPreviewMetricCapsule("\(playersNeeded) players needed", mainInk: mainInk)
                            }
                            .padding(.top, 2)

                            PickupOrganizerPreviewIdentityRow(
                                viewModel: viewModel,
                                organizerUserId: row.creator_user_id,
                                stats: viewModel.pickupCreatorTrustStats(for: row.creator_user_id),
                                colorScheme: colorScheme
                            )
                                .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.88)) {
                        viewModel.clearPickupMapSelection()
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(dismissIcon)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: FGSpacing.sm) {
                if !guestMapsActionsToLogin, let lat = row.latitude, let lon = row.longitude {
                    Button {
                        if let url = URL(string: "http://maps.apple.com/?ll=\(lat),\(lon)&q=Pickup%20game") {
                            openURL(url)
                        }
                    } label: {
                        Label("Directions", systemImage: "map")
                            .font(FGTypography.metadata.weight(.semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(FGColor.accentBlue)
                }

                if viewModel.discoverMapContentMode == .pickupGames {
                    Button {
                        withAnimation(.spring(response: 0.38, dampingFraction: 0.88)) {
                            openDetailAction()
                        }
                    } label: {
                        Text(detailTitle)
                            .font(FGTypography.metadata.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .minimumScaleFactor(0.78)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(colorScheme == .dark ? Color.white.opacity(0.92) : FGColor.accentBlue)
                }
            }
        }
        .padding(FGSpacing.lg)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                    .fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [
                        Color.black.opacity(colorScheme == .dark ? 0.62 : 0.2),
                        Color.black.opacity(colorScheme == .dark ? 0.4 : 0.11)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: previewCorner, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: previewCorner, style: .continuous)
                .strokeBorder(discoverPreviewCardBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.42 : 0.16), radius: colorScheme == .dark ? 28 : 18, x: 0, y: colorScheme == .dark ? 16 : 10)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.1 : 0.05), radius: 14, x: 0, y: 3)
        .task(id: row.id) {
            guard !guestMapsActionsToLogin else { return }
            await viewModel.loadPickupCreatorProfilesIfNeeded(creatorUserIds: [row.creator_user_id])
            await viewModel.refreshPickupCreatorPublicRatingStats(creatorUserIds: [row.creator_user_id])
        }
        .onAppear {
            guard !guestMapsActionsToLogin else { return }
            PickupGameStartedStateDebug.log(
                row: row,
                now: Date(),
                allowedActions: "discover_map_preview"
            )
        }
    }

    private var discoverPickupPinsInBounds: Int {
        viewModel.pickupGamesVisibleAsMapPins(for: viewModel.currentMapRegionBounds()).count
    }

    private var discoverPickupPinsInBoundsMatchingSearch: Int {
        viewModel.pickupGamesVisibleAsMapPinsWithDiscoverSearch(for: viewModel.currentMapRegionBounds()).count
    }

    private func discoverEmbeddedVenuePickupToggle(layoutWidth: CGFloat) -> some View {
        let segmentWidth = discoverEmbeddedToggleWidth(for: layoutWidth) / 2

        return ZStack {
            Capsule(style: .continuous)
                .fill(colorScheme == .dark ? .thinMaterial : .ultraThinMaterial)
                .overlay {
                    Capsule(style: .continuous)
                        .fill(
                            colorScheme == .dark
                                ? Color.black.opacity(0.36)
                                : Color.white.opacity(0.86)
                        )
                }
                .overlay {
                    Capsule(style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.16 : 0.34),
                                    Color.white.opacity(colorScheme == .dark ? 0.04 : 0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

            HStack(spacing: 0) {
                discoverFloatingModeSegment(
                    mode: .venues,
                    title: "Venues",
                    systemImage: "building.2.fill",
                    segmentWidth: segmentWidth
                )
                discoverFloatingModeSegment(
                    mode: .pickupGames,
                    title: "Pickup",
                    systemImage: "figure.run",
                    segmentWidth: segmentWidth
                )
            }
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.24) : Color.black.opacity(0.07),
                    lineWidth: colorScheme == .dark ? 1 : 0.75
                )
        }
        .frame(width: discoverEmbeddedToggleWidth(for: layoutWidth), height: 36)
        .animation(discoverBottomControlModeSpring, value: viewModel.discoverMapContentMode)
    }

    private var discoverModeToggleSelectionCapsule: some View {
        Capsule(style: .continuous)
            .fill(
                LinearGradient(
                    colors: [FGColor.accentGreen, FGColor.accentGreen.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(colorScheme == .dark ? 0.34 : 0.22), lineWidth: 0.75)
            }
            .shadow(color: FGColor.accentGreen.opacity(colorScheme == .dark ? 0.34 : 0.2), radius: 6, y: 1)
    }

    private func discoverModeToggleInactiveForeground(_ selected: Bool) -> Color {
        if selected { return .white }
        return colorScheme == .dark ? Color.white.opacity(0.86) : FGColor.primaryText(colorScheme)
    }

    private func discoverFloatingModeSegment(
        mode: DiscoverMapContentMode,
        title: String,
        systemImage: String,
        segmentWidth: CGFloat
    ) -> some View {
        let selected = viewModel.discoverMapContentMode == mode
        return Button {
            guard viewModel.discoverMapContentMode != mode else { return }
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            discoverLogBottomControlModeSwitch(to: mode)
            withAnimation(discoverBottomControlModeSpring) {
                viewModel.clearDiscoverMapContentSelectionsWhenSwitching(to: mode)
                viewModel.discoverMapContentMode = mode
            }
        } label: {
            ZStack {
                if selected {
                    discoverModeToggleSelectionCapsule
                        .padding(2)
                        .matchedGeometryEffect(id: "discoverModeSelection", in: discoverModeToggleNamespace)
                }

                HStack(spacing: 2) {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .semibold))
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.65)
                }
                .foregroundStyle(discoverModeToggleInactiveForeground(selected))
            }
            .frame(width: segmentWidth)
            .frame(maxHeight: .infinity)
            .animation(discoverBottomControlModeSpring, value: viewModel.discoverMapContentMode)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(DiscoverModeSegmentButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func discoverBottomAdStrip(layoutWidth: CGFloat) -> some View {
        let availableWidth = discoverAdBannerAvailableWidth(for: layoutWidth)
        let bannerSize = discoverAdaptiveBannerSize(for: layoutWidth)
        let _ = discoverLogAdBannerDebug(
            availableWidth: availableWidth,
            bannerSize: bannerSize,
            containerSize: bannerSize
        )

        return Group {
            if discoverTopAdLoadFailed {
                Color.clear
                    .frame(width: bannerSize.width, height: bannerSize.height)
                    .allowsHitTesting(false)
            } else {
                AdaptiveBannerView(
                    placement: "discover.bottomStrip",
                    adUnitID: AdMobConfiguration.bannerAdUnitID,
                    layoutWidth: availableWidth,
                    onAdFailed: { _ in
                        discoverTopAdLoadFailed = true
                    }
                )
                .frame(width: bannerSize.width, height: bannerSize.height)
                .accessibilityElement(children: .contain)
            }
        }
        .frame(width: bannerSize.width, height: bannerSize.height, alignment: .center)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(colorScheme == .dark ? .thinMaterial : .ultraThinMaterial)
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(colorScheme == .dark ? Color.black.opacity(0.22) : Color.white.opacity(0.22))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(colorScheme == .dark ? 0.12 : 0.28),
                                    Color.white.opacity(0.03)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(colorScheme == .dark ? Color.white.opacity(0.20) : FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.20 : 0.08), radius: 12, y: 5)
        .opacity(0.94)
        .zIndex(8)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private func discoverLogAdBannerDebug(availableWidth: CGFloat, bannerSize: CGSize, containerSize: CGSize) {
        AdDebugDiagnostics.logEvent(
            event: "discoverStripLayout",
            format: "banner",
            placement: "discover.bottomStrip",
            fields: [
                "availableWidth": String(format: "%.1f", availableWidth),
                "adaptiveBannerW": String(format: "%.1f", bannerSize.width),
                "adaptiveBannerH": String(format: "%.1f", bannerSize.height),
                "containerW": String(format: "%.1f", containerSize.width),
                "containerH": String(format: "%.1f", containerSize.height),
                "zeroAvailableWidth": "\(availableWidth <= 0)",
                "iPad": "\(UIDevice.current.userInterfaceIdiom == .pad)"
            ]
        )
    }

    private func discoverMapStatusBanner(text: String, isLoading: Bool) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Group {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(FGColor.accentGreen)
                }
            }
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(1)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
    }

    private func discoverMapToastBanner(text: String, isError: Bool) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: isError ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .foregroundStyle(isError ? FGColor.accentYellow : FGColor.accentGreen)
            Text(text)
                .font(FGTypography.caption.weight(.semibold))
                .foregroundStyle(FGColor.primaryText(colorScheme))
                .lineLimit(2)
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .background(.ultraThinMaterial)
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(FGColor.divider(colorScheme), lineWidth: 1)
        }
        .shadow(color: .black.opacity(colorScheme == .dark ? 0.16 : 0.06), radius: 10, y: 4)
    }

    /// City / region line for logged-out teaser (no street-level detail).
    private func teaserAreaDescription(for bar: BarVenue) -> String {
        let parts = bar.address.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return "Location on map" }
        if parts.count == 1 { return String(parts[0]) }
        return parts.suffix(2).joined(separator: ", ")
    }

    private func loggedOutVenueTeaserCard(_ bar: BarVenue) -> some View {
        GuestDiscoverLockedPreviewCard(
            accent: FGColor.accentBlue,
            headline: "Preview only",
            teaser: {
                VStack(alignment: .leading, spacing: FGSpacing.xs) {
                    Text(bar.name)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                    Text("Watch spot")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                    Text(teaserAreaDescription(for: bar))
                        .font(FGTypography.caption)
                        .foregroundStyle(FGColor.secondaryText(colorScheme))
                }
            },
            onLogIn: {
                pendingResumeVenueIDAfterLogin = bar.id
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            },
            onCreateAccount: {
                pendingResumeVenueIDAfterLogin = bar.id
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: true)
            },
            onDismiss: {
                withAnimation(.spring()) {
                    viewModel.selectedBar = nil
                    viewModel.clearDiscoverRemotePreviewHold()
                    pendingResumeVenueIDAfterLogin = nil
                }
            },
            onNotNow: {
                withAnimation(.spring()) {
                    viewModel.selectedBar = nil
                    viewModel.clearDiscoverRemotePreviewHold()
                    pendingResumeVenueIDAfterLogin = nil
                }
            }
        )
    }

    private var discoverPreviewCardMaterial: Material {
        colorScheme == .dark ? .regularMaterial : .ultraThinMaterial
    }

    private var discoverPreviewCardTint: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.78)
            : Color.white.opacity(0.78)
    }

    private var discoverPreviewCardBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.15)
            : FGColor.divider(colorScheme)
    }

    private var discoverPreviewSecondaryTextColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.82)
            : FGColor.secondaryText(colorScheme)
    }

    private var discoverPreviewMutedIconColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.74)
            : .secondary
    }

    private var discoverPreviewControlBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.56)
            : FGColor.cardBackground(colorScheme)
    }

    private var discoverPreviewControlBorder: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.14)
            : FGColor.divider(colorScheme)
    }

    private var discoverPreviewInnerSurface: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.54)
            : FGColor.background(colorScheme).opacity(0.90)
    }

    private var discoverPreviewAccentSurface: Color {
        colorScheme == .dark
            ? FGColor.accentGreen.opacity(0.18)
            : FGColor.accentGreen.opacity(0.09)
    }
    
    /// Venue image, name, address, actions, rating, and experience — stays fixed while games scroll (sports are per game card only).
    @ViewBuilder
    private func venuePreviewCardStaticHeader(bar: BarVenue) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                venueHeroImage(bar)

                HStack(spacing: 8) {
                    discoverHomeCrowdHeroButton(bar: bar)

                    Button {
                        FGInteractionHaptics.softImpact()
                        if viewModel.canFavoriteVenues {
                            viewModel.toggleFavorite(bar)
                        } else if viewModel.isAuthenticatedForSocialFeatures {
                            viewModel.logBusinessUserGateBlocked(action: "favoriteVenue")
                            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                        } else {
                            viewModel.discoverNavigateToAccountForUserAuth = true
                        }
                    } label: {
                        Image(systemName: viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(bar.id) ? "heart.fill" : "heart")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(bar.id) ? .red : FGColor.primaryText(colorScheme))
                            .softActiveGlow(viewModel.canFavoriteVenues && viewModel.favoriteVenueIDs.contains(bar.id), color: .red)
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))

                    Button {
                        FGInteractionHaptics.selection()
                        withAnimation(.spring()) {
                            viewModel.selectedBar = nil
                            viewModel.clearDiscoverRemotePreviewHold()
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(FGColor.primaryText(colorScheme))
                            .frame(width: 34, height: 34)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
                }
                .padding(10)
            }
            .onAppear {
                let selected = viewModel.isHomeCrowdVenue(bar.id)
                print(
                    "[HomeCrowd] discoverHeroIconRendered venueId=\(bar.id.uuidString.lowercased()) selected=\(selected)"
                )
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: FGSpacing.sm) {
                    Text(bar.name)
                        .font(FGTypography.sectionTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(1)
                        .layoutPriority(1)

                    venuePreviewRatingButton(bar)
                }

                Button {
                    viewModel.openDirections(to: bar)
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: FGSpacing.xs) {
                        Image(systemName: "location.fill")
                            .font(.caption)
                        Text(bar.address)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        if !bar.distance.isEmpty {
                            Text("• \(bar.distance)")
                                .foregroundStyle(discoverPreviewSecondaryTextColor)
                                .lineLimit(1)
                        }
                    }
                    .font(FGTypography.caption)
                    .foregroundStyle(FGColor.accentBlue)
                }
                .buttonStyle(.plain)
            }
        }
        .onAppear {
#if DEBUG
            print("[VenueFeatureDebug] propagatedToDiscover=true")
            print("[VenueFeatureDebug] discoverCardFeatureChipsRemoved=true")
            print("[VenueFeatureDebug] sourceOfTruth=venues.features,venues.screen_count,venues.serves_food,venues.has_wifi,venues.has_garden,venues.has_projector,venues.pet_friendly")
            if bar.hasBusinessVerifiedFeatures {
                print("[VenueFeatureDebug] approvedBusinessVenueFeaturesVerified=true")
            }
#endif
        }
    }

    private func discoverHomeCrowdHeroButton(bar: BarVenue) -> some View {
        let isActive = viewModel.isHomeCrowdVenue(bar.id)

        return Button {
            FGInteractionHaptics.softImpact()
            let willSelect = !isActive
            print(
                "[HomeCrowd] toggleTap source=discoverHero venueId=\(bar.id.uuidString.lowercased()) selected=\(willSelect)"
            )
            if viewModel.canUseFanSocialFeatures {
                Task {
                    isDiscoverHomeCrowdToggleInFlight = true
                    defer { isDiscoverHomeCrowdToggleInFlight = false }
                    await viewModel.toggleHomeCrowd(for: bar)
                }
            } else if viewModel.isAuthenticatedForSocialFeatures {
                viewModel.logBusinessUserGateBlocked(action: "toggleHomeCrowd")
                fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            } else {
                viewModel.discoverNavigateToAccountForUserAuth = true
            }
        } label: {
            HomeCrowdShieldStarBadge(
                diameter: 34,
                visualState: isActive ? .active : .inactive
            )
            .background {
                if !isActive {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .frame(width: 34, height: 34)
                }
            }
            .overlay {
                Circle()
                    .strokeBorder(
                        isActive
                            ? Color(red: 0.72, green: 0.48, blue: 1.0).opacity(0.88)
                            : discoverPreviewControlBorder,
                        lineWidth: isActive ? 1.5 : 1
                    )
            }
        }
        .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
        .disabled(isDiscoverHomeCrowdToggleInFlight)
        .accessibilityLabel(isActive ? "Remove this Home Crowd" : "Make this my Home Crowd")
    }

    private func venuePreviewRatingButton(_ bar: BarVenue) -> some View {
        Button {
            if viewModel.canRateVenues {
                showVenueRatingSheet = true
            } else if viewModel.isGuestDiscoverMode {
                viewModel.discoverNavigateToAccountForUserAuth = true
            } else if viewModel.isAuthenticatedForSocialFeatures {
                viewModel.logBusinessUserGateBlocked(action: "rateVenue")
                fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            }
        } label: {
            let rating = viewModel.mergedDisplayRating(for: bar)
            let reviewCount = viewModel.reviewCountDisplay(for: bar)
            HStack(spacing: 5) {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                if let rating, reviewCount > 0 {
                    Text(String(format: "%.1f", rating))
                        .fontWeight(.bold)
                } else {
                    Text("Rate")
                        .fontWeight(.semibold)
                }
            }
            .font(FGTypography.metadata)
            .padding(.horizontal, FGSpacing.sm)
            .padding(.vertical, FGSpacing.xs)
            .background(discoverPreviewControlBackground)
            .clipShape(Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }

    private func venuePreviewCard(_ bar: BarVenue) -> some View {
        let resolved = viewModel.canonicalBarForDiscover(bar)
        let gamesToday = viewModel.gamesForVenuePreview(
            bar: resolved,
            date: viewModel.selectedDate,
            sportFilter: viewModel.selectedSport
        )
        let selectedVenueEvent = selectedEventForVenue(gamesToday: gamesToday)
        let visibleSocialPrefetchEvents = visibleVenuePreviewEventsForSocialPrefetch(
            bar: resolved,
            gamesToday: gamesToday,
            selectedVenueEvent: selectedVenueEvent
        )
        let visibleSocialPrefetchKey = visibleVenuePreviewSocialPrefetchKey(
            bar: resolved,
            events: visibleSocialPrefetchEvents
        )

        return VStack(alignment: .leading, spacing: 12) {
            venuePreviewCardStaticHeader(bar: resolved)

            Rectangle()
                .fill(FGColor.divider(colorScheme))
                .frame(height: 1)

            if let selectedEvent = selectedVenueEvent {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 12) {
                        selectedEventSection(bar: resolved, selectedEvent: selectedEvent)
                    }
                    .padding(.bottom, 4)
                }
                .frame(maxHeight: 292)
                .clipped()
            } else {
                gamesListSection(bar: resolved, gamesToday: gamesToday)
            }

            venuePreviewActionRow(bar: resolved)
        }
        .padding(.horizontal, FGSpacing.lg)
        .padding(.vertical, FGSpacing.md)
        .frame(maxHeight: 512)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .fill(discoverPreviewCardMaterial)
                RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                    .fill(discoverPreviewCardTint)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.sheet, style: .continuous)
                .strokeBorder(discoverPreviewCardBorder, lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.34 : 0.14), radius: colorScheme == .dark ? 24 : 16, x: 0, y: colorScheme == .dark ? 14 : 9)
        .shadow(color: FGColor.accentBlue.opacity(colorScheme == .dark ? 0.08 : 0.04), radius: 12, x: 0, y: 2)
        .onChange(of: viewModel.selectedBar?.id) { oldId, newId in
            guard oldId != newId else { return }
            venuePreviewGameFilter = .all
        }
        .task(id: visibleSocialPrefetchKey) {
            await viewModel.prefetchDiscoverVenueImages(for: resolved, includeMenu: false)
            guard viewModel.canViewDiscoverDetails() else { return }
            await prefetchVisibleVenueSocialData(bar: resolved, events: visibleSocialPrefetchEvents)
        }
    }

    
    private func venueHeroImage(_ bar: BarVenue) -> some View {
        let coverURLString = ImageDisplayURL.forList(thumbnail: bar.coverPhotoThumbnailURL, full: bar.coverPhotoURL)
        return Group {
            if let urlString = coverURLString,
               let url = URL(string: urlString) {
                DiscoverCachedRemoteImage(url: url, contentMode: .fill) {
                    venueHeroPlaceholder
                }
            } else {
                venueHeroPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .onAppear {
            logDiscoverCardPhotoDebug(bar: bar, urlString: coverURLString)
        }
        .overlay(alignment: .bottomLeading) {
            Text("Watch spot")
                .font(FGTypography.metadata.weight(.bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.black.opacity(0.58))
                .clipShape(Capsule(style: .continuous))
                .padding(12)
        }
    }

    private func logDiscoverCardPhotoDebug(bar: BarVenue, urlString: String?) {
#if DEBUG
        let resolved = urlString ?? ""
        let thumbnail = bar.coverPhotoThumbnailURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let usingThumbnail = !thumbnail.isEmpty && resolved == thumbnail
        print("[VenuePhotoDisplayDebug] discoverCardCoverURL=\(resolved)")
        print("[VenuePhotoDisplayDebug] usingThumbnail=\(usingThumbnail)")
        print("[VenuePhotoDisplayDebug] fallbackUsed=\(resolved.isEmpty)")
#endif
    }

    private var venueHeroPlaceholder: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        FGColor.accentBlue.opacity(colorScheme == .dark ? 0.30 : 0.18),
                        FGColor.accentGreen.opacity(colorScheme == .dark ? 0.24 : 0.14)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                Image(systemName: "building.2.crop.circle")
                    .font(.system(size: 40, weight: .semibold))
                    .foregroundStyle(FGColor.primaryText(colorScheme).opacity(0.34))
            }
    }

    private func venuePreviewActionRow(bar: BarVenue) -> some View {
        HStack(spacing: FGSpacing.sm) {
            Button {
                viewModel.openDirections(to: bar)
            } label: {
                Label("Directions", systemImage: "location.fill")
                    .font(FGTypography.cardTitle)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, FGSpacing.md)
                    .background(discoverPreviewControlBackground)
                    .clipShape(RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
                    }
            }
            .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: true))

            FGPrimaryButton(
                title: viewModel.isGuestDiscoverMode ? "View venue" : "Details",
                systemImage: viewModel.isGuestDiscoverMode ? "lock.fill" : nil
            ) {
                guard viewModel.canViewDiscoverDetails() else {
                    viewModel.showSocialActionToast("Sign in with a FanGeo account to view venue details.")
                    return
                }
                showVenueDetails = true
            }
        }
    }
    
    
    private func selectedEventSection(bar: BarVenue, selectedEvent: SportsEvent) -> some View {
        VStack(alignment: .leading, spacing: FGSpacing.sm) {
            FGStatusPill(title: "Showing selected game", kind: .custom(tint: FGColor.accentBlue))
            if viewModel.isGuestDiscoverMode {
                guestVenueGamePreviewRow(bar: bar, event: selectedEvent) {
                    showVenueDetails = true
                }
            } else {
                gameInterestRow(bar: bar, event: selectedEvent)
            }
        }
    }
    
    private func gamesListSection(bar: BarVenue, gamesToday: [SportsEvent]) -> some View {
        let filtered = gamesFilteredForVenuePreview(bar: bar, gamesToday: gamesToday, filter: venuePreviewGameFilter)

        return ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: FGSpacing.sm) {
                venuePreviewGameFilterPicker

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: FGSpacing.xs) {
                        if viewModel.isLoadingEvents && gamesToday.isEmpty {
                            loadingVenueGamesView
                        } else if gamesToday.isEmpty {
                            if bar.games.isEmpty, !viewModel.isLoadingEvents {
                                Text("No games listed yet.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                venuePreviewNoGamesForDateView
                            }
                        } else if filtered.isEmpty {
                            venueGameFilterEmptyView()
                        } else {
                            ForEach(Array(filtered.prefix(12)), id: \.id) { event in
                                if viewModel.isGuestDiscoverMode {
                                    guestVenueGamePreviewRow(bar: bar, event: event) {
                                        showVenueDetails = true
                                    }
                                } else {
                                    gameInterestRow(bar: bar, event: event)
                                }
                            }
                        }
                    }
                    .padding(.bottom, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 248)
                .clipped()
            }

            if viewModel.isRefreshingDiscoverEvents && !gamesToday.isEmpty {
                ProgressView()
                    .controlSize(.small)
                    .padding(.trailing, 2)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: venuePreviewGameFilter)
    }

    private var venuePreviewGameFilterPicker: some View {
        HStack(spacing: FGSpacing.xs) {
            ForEach(VenuePreviewGameFilter.allCases) { mode in
                let isOn = venuePreviewGameFilter == mode
                Button {
                    FGInteractionHaptics.selection()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        venuePreviewGameFilter = mode
                    }
                } label: {
                    VStack(spacing: 3) {
                        Text(mode.segmentTitle)
                            .font(FGTypography.metadata.weight(isOn ? .bold : .semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                        Capsule(style: .continuous)
                            .fill(isOn ? FGColor.accentBlue : Color.clear)
                            .frame(height: 2)
                    }
                        .padding(.horizontal, FGSpacing.md)
                        .padding(.vertical, 6)
                        .foregroundStyle(isOn ? FGColor.accentBlue : discoverPreviewSecondaryTextColor)
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    isOn
                                        ? AnyShapeStyle(FGColor.accentBlue.opacity(colorScheme == .dark ? 0.22 : 0.13))
                                        : AnyShapeStyle(Color.clear)
                                )
                        }
                        .overlay {
                            Capsule(style: .continuous)
                                .strokeBorder(isOn ? FGColor.accentBlue.opacity(0.36) : Color.clear, lineWidth: 1)
                        }
                }
                .buttonStyle(FGPremiumPressButtonStyle(hapticOnPress: false))
            }
        }
        .padding(.horizontal, 3)
        .padding(.vertical, 3)
        .background {
            Capsule(style: .continuous)
                .fill(discoverPreviewControlBackground)
        }
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Local optimistic key and/or server-backed venue_event_interests row.
    private func venuePreviewCurrentUserIsGoing(bar: BarVenue, game: SportsEvent) -> Bool {
        viewModel.userIsGoingToVenueGame(
            bar: bar,
            gameTitle: game.title,
            venueEventID: viewModel.cachedVenueEventID(for: bar, gameTitle: game.title)
        )
    }

    private func gamesFilteredForVenuePreview(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        filter: VenuePreviewGameFilter
    ) -> [SportsEvent] {
        let goingGames = gamesToday.filter {
            venuePreviewCurrentUserIsGoing(bar: bar, game: $0)
        }
#if DEBUG
        print("[VenuePreviewFilterDebug] selectedFilter=\(filter.segmentTitle)")
        print("[VenuePreviewFilterDebug] allCount=\(gamesToday.count)")
        print("[VenuePreviewFilterDebug] goingCount=\(goingGames.count)")
#endif
        switch filter {
        case .all:
            return gamesToday

        case .going:
            return goingGames
        }
    }

    private func venueGameFilterEmptyView() -> some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("No games match this filter.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(.horizontal, FGSpacing.md)
        .padding(.vertical, FGSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(discoverPreviewInnerSurface)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(discoverPreviewControlBorder.opacity(colorScheme == .dark ? 0.9 : 0.7), lineWidth: 1)
        }
    }

    private var venuePreviewNoGamesForDateView: some View {
        HStack(spacing: FGSpacing.sm) {
            Image(systemName: "calendar.badge.exclamationmark")
                .foregroundStyle(FGColor.mutedText(colorScheme))
            Text("No games scheduled for this date.")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(discoverPreviewInnerSurface)
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous)
                .strokeBorder(discoverPreviewControlBorder.opacity(colorScheme == .dark ? 0.9 : 0.7), lineWidth: 1)
        }
    }
    
    private func trendingScore(for venueEventID: UUID, goingCount: Int) -> Int {
        let commentCount = viewModel.fanUpdatesDisplayCommentCount(for: venueEventID)

        let vibeCount = fanUpdatesStore.venueEventVibeCounts[venueEventID]?
            .values
            .reduce(0, +) ?? 0

        return goingCount + commentCount + vibeCount
    }
    
    private func trendingLabel(for score: Int) -> String? {
        if score >= 40 {
            return "👑 Trending now"
        } else if score >= 16 {
            return "🚀 Hot"
        } else if score >= 6 {
            return "🔥 Active"
        } else if score >= 1 {
            return "✨ Starting up"
        }

        return nil
    }
    
    private func perGameGoingLine(venueEventID: UUID?, count: Int) -> String {
        guard let venueEventID else {
            return count > 0 ? "\(count) people are going" : "Be the first to go"
        }
        if count <= 0 { return "Be the first to go" }
        let im = viewModel.isInterestedInVenueEvent(venueEventID)
        if im {
            return count == 1 ? "You're going" : "You and \(count - 1) others are going"
        }
        return "\(count) people are going"
    }

    @ViewBuilder
    private func liveEnergyChips(_ energy: FanGeoLiveEnergy) -> some View {
        if energy.compactChips.isEmpty {
            Text(energy.goingCount > 0 ? "\(energy.goingCount) fans going" : "Start the crowd")
                .font(FGTypography.metadata)
                .fontWeight(.semibold)
                .foregroundStyle(energy.goingCount > 0 ? FGColor.accentGreen : discoverPreviewSecondaryTextColor)
        } else {
            FGWrappingLayout(horizontalSpacing: FGSpacing.xs, verticalSpacing: FGSpacing.xs) {
                ForEach(energy.compactChips, id: \.self) { chip in
                    liveEnergyChip(chip)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func liveEnergyChip(_ chip: String) -> some View {
        let tint = liveEnergyChipTint(chip)

        return Text(chip)
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background {
                Capsule(style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.18 : 0.12))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.28), lineWidth: 1)
            }
    }

    private func liveEnergyChipTint(_ chip: String) -> Color {
        if chip.contains("LIVE NOW") { return FGColor.dangerRed }
        if chip.contains("Crowd building") { return FGColor.accentYellow }
        return FGColor.accentBlue
    }

    private func guestVenueGamePreviewRow(bar: BarVenue, event: SportsEvent, onOpenLockedDetail: @escaping () -> Void) -> some View {
        Button {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                viewModel.selectedEvent = event
                onOpenLockedDetail()
            }
        } label: {
            HStack(alignment: .center, spacing: 12) {
                venueGameSportIconWithLabel(sport: event.sport)

                VStack(alignment: .leading, spacing: 3) {
                    Text(event.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)

                    Text("\(event.date.formatted(date: .abbreviated, time: .omitted)) · \(viewModel.displayTime(for: event))")
                        .font(FGTypography.caption.weight(.semibold))
                        .foregroundStyle(discoverPreviewSecondaryTextColor)

                    Text("Tap to open this venue · sign in for game details")
                        .font(FGTypography.caption)
                        .foregroundStyle(discoverPreviewSecondaryTextColor)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Image(systemName: "lock.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(discoverPreviewMutedIconColor)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                    .fill(discoverPreviewInnerSurface)
                    .overlay(
                        RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                            .strokeBorder(discoverPreviewControlBorder, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }

    private func venueGameSportIconWithLabel(sport: String) -> some View {
        let label = venueGameSportDisplayLabel(sport)
        let tint = viewModel.colorForSport(sport)

        return VStack(spacing: 3) {
            SportArtworkIconView(sport: sport, diameter: 42)

            Text(label)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 54, alignment: .top)
        .onAppear {
#if DEBUG
            print("[VenueGameCardDebug] sportLabelRendered=\(label)")
            print("[VenueGameCardDebug] sportIconAndLabelVisible=true")
#endif
        }
    }

    private func venueGameSportDisplayLabel(_ sport: String) -> String {
        let trimmed = sport.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = trimmed.lowercased()
        switch key {
        case "nba", "basketball":
            return "Basketball"
        case "mls", "premier league", "soccer":
            return "Soccer"
        case "nfl", "football", "american football":
            return "Football"
        case "mlb", "baseball":
            return "Baseball"
        case "nhl", "hockey", "ice hockey":
            return "Hockey"
        case "ufc", "mma", "combat sports":
            return "MMA"
        case "tennis":
            return "Tennis"
        case "formula 1", "formula1", "formula one", "f1", "racing":
            return "Formula 1"
        default:
            return trimmed.isEmpty ? "Sports" : trimmed
        }
    }

    private func gameInterestRow(bar: BarVenue, event: SportsEvent) -> some View {
        let gameTitle = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let venueEventID = viewModel.cachedVenueEventID(for: bar, gameTitle: gameTitle)

        let alreadyInterested = viewModel.userIsGoingToVenueGame(
            bar: bar,
            gameTitle: gameTitle,
            venueEventID: venueEventID
        )

        let energy = viewModel.liveEnergy(for: bar, event: event, friendUserIDs: acceptedFriendUserIDs)
        let previewEnergy = venueEventID.map {
            venuePreviewEnergy(for: $0, energy: energy)
        }
        let previewEnergyPalette = venueGamePreviewEnergyPalette(previewEnergy)
        let previewEnergyTint = previewEnergy.map { energyAccentColor(for: $0.score) } ?? FGColor.accentBlue
        let previewEnergyBorder = previewEnergy?.isHighEnergy == true
            ? previewEnergyTint.opacity(colorScheme == .dark ? 0.58 : 0.42)
            : discoverPreviewControlBorder
        let previewEnergyGlow = previewEnergy?.isHighEnergy == true
            ? previewEnergyTint.opacity(colorScheme == .dark ? 0.22 : 0.14)
            : Color.clear
        let predictionVisibility = venuePredictionVisibility(
            bar: bar,
            event: event,
            venueEventID: venueEventID
        )

        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 11) {
                venueGameSportIconWithLabel(sport: event.sport)

                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title)
                        .font(FGTypography.cardTitle)
                        .foregroundStyle(FGColor.primaryText(colorScheme))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("\(event.date.formatted(date: .abbreviated, time: .omitted)) · \(viewModel.displayTime(for: event))")
                        .font(FGTypography.caption)
                        .foregroundStyle(discoverPreviewSecondaryTextColor)
                }

                venuePreviewGoingButton(
                    bar: bar,
                    event: event,
                    venueEventID: venueEventID,
                    alreadyInterested: alreadyInterested
                )
            }

            HStack(alignment: .center, spacing: 10) {
                let socialProfiles = energy.socialPresenceProfiles
                if !socialProfiles.isEmpty {
                    GoingAvatarStack(profiles: socialProfiles, viewerUserID: viewModel.currentUserAuthId, diameter: 26)
                } else if let venueEventID {
                    let fallbackProfiles = viewModel.goingProfiles(for: venueEventID)
                    if !fallbackProfiles.isEmpty {
                        GoingAvatarStack(profiles: fallbackProfiles, viewerUserID: viewModel.currentUserAuthId, diameter: 26)
                    }
                }
                Text(energy.socialPresenceLabel ?? energy.friendPresenceLabel ?? perGameGoingLine(venueEventID: venueEventID, count: energy.goingCount))
                    .font(FGTypography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(FGColor.primaryText(colorScheme))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            if let predictionEventID = predictionVisibility.eventID,
               predictionVisibility.shouldRender,
               let teams = predictionVisibility.teams {
                VenueEventPredictionModule(
                    venueEventID: predictionEventID,
                    teams: teams,
                    summary: viewModel.venueEventPredictionSummaries[predictionEventID],
                    isLocked: predictionVisibility.isLocked,
                    onOpen: { type in
                        openDiscoverPredictionSheet(
                            eventID: predictionEventID,
                            teams: teams,
                            type: type,
                            isLocked: predictionVisibility.isLocked
                        )
                    },
                    onLockedTap: {
                        fanFeatureGateAlertMessage = "Predictions closed for this game."
                    }
                )
            }

            if let venueEventID {
                venueGameCardSocialActionRow(
                    venueEventID: venueEventID,
                    previewEnergy: previewEnergy
                )
                venuePreviewInteractionStrip(venueEventID: venueEventID)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                .fill(discoverPreviewInnerSurface)
                .overlay(
                    RoundedRectangle(cornerRadius: FGRadius.large, style: .continuous)
                        .strokeBorder(previewEnergyBorder, lineWidth: previewEnergy?.isHighEnergy == true ? 1.25 : 1)
                )
        )
        .overlay(alignment: .top) {
            if previewEnergy?.hasBadge == true {
                Capsule(style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: previewEnergyPalette.topEdgeColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 2)
                    .padding(.horizontal, 28)
                    .padding(.top, 1)
            }
        }
        .shadow(color: previewEnergyGlow, radius: 10, x: 0, y: 3)
    }

    private func openDiscoverPredictionSheet(
        eventID: UUID,
        teams: VenueEventPredictionTeams,
        type: VenueEventPredictionType,
        isLocked: Bool
    ) {
        guard !isLocked else {
            fanFeatureGateAlertMessage = "Predictions closed for this game."
            return
        }
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        guard viewModel.canUseFanSocialFeatures else {
            viewModel.logBusinessUserGateBlocked(action: "venuePrediction")
            fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
            return
        }
        predictionSheet = DiscoverPredictionSheetContext(
            venueEventID: eventID,
            teams: teams,
            predictionType: type
        )
    }

    private func venuePredictionVisibility(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?
    ) -> DiscoverVenuePredictionVisibility {
        let row = venueEventRowForPrediction(bar: bar, event: event, venueEventID: venueEventID)
        let resolvedEventID = venueEventID ?? row?.id
        let sportType = trimmedNonEmpty(row?.sport) ?? event.sport
        let homeTeam = trimmedNonEmpty(row?.home_team)
        let awayTeam = trimmedNonEmpty(row?.away_team)
        let startsAt = row.flatMap(venuePredictionStartDate(for:)) ?? venuePredictionFallbackStartDate(for: event)
        let lockTime = startsAt?.addingTimeInterval(10 * 60)
        let isLocked = lockTime.map { Date() > $0 } ?? false
        let hiddenReason: String?

        if resolvedEventID == nil {
            hiddenReason = "missingVenueEventId"
        } else if !venuePredictionSportIsSupported(sportType) {
            hiddenReason = "unsupportedSport"
        } else if homeTeam == nil {
            hiddenReason = "missingHomeTeam"
        } else if awayTeam == nil {
            hiddenReason = "missingAwayTeam"
        } else if startsAt == nil {
            hiddenReason = "missingStartTime"
        } else {
            hiddenReason = nil
        }

        let teams: VenueEventPredictionTeams?
        if let homeTeam, let awayTeam {
            teams = VenueEventPredictionTeams(home: homeTeam, away: awayTeam)
        } else {
            teams = nil
        }

        let visibility = DiscoverVenuePredictionVisibility(
            eventID: resolvedEventID,
            sportType: sportType,
            teams: teams,
            hasHomeTeam: homeTeam != nil,
            hasAwayTeam: awayTeam != nil,
            startsAt: startsAt,
            lockTime: lockTime,
            isLocked: isLocked,
            hiddenReason: hiddenReason
        )
        logVenuePredictionVisibilityIfHidden(visibility)
        return visibility
    }

    private func venueEventRowForPrediction(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?
    ) -> VenueEventRow? {
        if let venueEventID,
           let byID = viewModel.venueEventRows.first(where: { $0.id == venueEventID }) {
            return byID
        }

        let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return viewModel.venueEventRows.first { row in
            guard venueEventRowMatchesDiscoverVenue(row, bar: bar) else { return false }
            guard trimmedNonEmpty(row.event_title)?.caseInsensitiveCompare(title) == .orderedSame else { return false }
            guard let rowStart = venuePredictionStartDate(for: row) ?? venuePredictionFallbackDay(for: row) else { return true }
            return Calendar.current.isDate(rowStart, inSameDayAs: event.date)
        }
    }

    private func venueEventRowMatchesDiscoverVenue(_ row: VenueEventRow, bar: BarVenue) -> Bool {
        if row.venue_id == bar.id { return true }
        if let venueName = trimmedNonEmpty(row.venue_name),
           venueName.caseInsensitiveCompare(bar.name) == .orderedSame {
            return true
        }
        if let rowOwner = trimmedNonEmpty(row.owner_email),
           let barOwner = bar.ownerEmail,
           OwnerBusinessEmail.normalized(rowOwner) == OwnerBusinessEmail.normalized(barOwner) {
            return true
        }
        return false
    }

    private func venuePredictionSportIsSupported(_ value: String) -> Bool {
        switch venuePredictionNormalizedSport(value) {
        case "soccer", "baseball", "football", "hockey":
            return true
        default:
            return false
        }
    }

    private func venuePredictionNormalizedSport(_ value: String) -> String {
        let lowered = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lowered.contains("soccer") { return "soccer" }
        if lowered.contains("baseball") || lowered == "mlb" { return "baseball" }
        if lowered.contains("football") || lowered == "nfl" { return "football" }
        if lowered.contains("hockey") || lowered == "nhl" { return "hockey" }
        return lowered
    }

    private func venuePredictionStartDate(for row: VenueEventRow) -> Date? {
        if let start = FanGeoLiveEnergyTiming.parseScheduledStart(row.scheduled_start_at) {
            return start
        }

        guard let day = trimmedNonEmpty(row.event_date),
              let time = trimmedNonEmpty(row.event_time),
              time.lowercased() != "time tbd" else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: "\(day) \(time)")
    }

    private func venuePredictionFallbackDay(for row: VenueEventRow) -> Date? {
        guard let day = trimmedNonEmpty(row.event_date) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: day)
    }

    private func venuePredictionFallbackStartDate(for event: SportsEvent) -> Date? {
        let time = event.time.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !time.isEmpty, time.lowercased() != "time tbd" else { return nil }
        let dayFormatter = DateFormatter()
        dayFormatter.calendar = Calendar.current
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.dateFormat = "yyyy-MM-dd"
        dayFormatter.timeZone = TimeZone.current

        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd h:mm a"
        formatter.timeZone = TimeZone.current
        return formatter.date(from: "\(dayFormatter.string(from: event.date)) \(time)")
    }

    private func trimmedNonEmpty(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func logVenuePredictionVisibilityIfHidden(_ visibility: DiscoverVenuePredictionVisibility) {
#if DEBUG
        guard let hiddenReason = visibility.hiddenReason else { return }
        let startsAt = visibility.startsAt.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        let lockTime = visibility.lockTime.map { ISO8601DateFormatter().string(from: $0) } ?? "nil"
        print("[VenuePredictionVisibilityDebug] eventId=\(visibility.eventID?.uuidString.lowercased() ?? "nil")")
        print("[VenuePredictionVisibilityDebug] sportType=\(visibility.sportType)")
        print("[VenuePredictionVisibilityDebug] hasHomeTeam=\(visibility.hasHomeTeam)")
        print("[VenuePredictionVisibilityDebug] hasAwayTeam=\(visibility.hasAwayTeam)")
        print("[VenuePredictionVisibilityDebug] startsAt=\(startsAt)")
        print("[VenuePredictionVisibilityDebug] lockTime=\(lockTime)")
        print("[VenuePredictionVisibilityDebug] isLocked=\(visibility.isLocked)")
        print("[VenuePredictionVisibilityDebug] hiddenReason=\(hiddenReason)")
#endif
    }

    private func venuePreviewGoingButton(
        bar: BarVenue,
        event: SportsEvent,
        venueEventID: UUID?,
        alreadyInterested: Bool
    ) -> some View {
        let requiresLogin = !viewModel.isAuthenticatedForSocialFeatures
        let isBlocked = viewModel.isAuthenticatedForSocialFeatures && !viewModel.canMarkGoing
        let isPending = venueEventID.map { viewModel.isVenueEventInterestMutationInFlight($0) } ?? false
        let title = requiresLogin ? "Log in" : "Going"
        let tint = isBlocked ? Color.secondary : (alreadyInterested ? FGColor.accentGreen : FGColor.primaryText(colorScheme))
        let fill = isBlocked
            ? Color.gray.opacity(0.16)
            : (alreadyInterested ? FGColor.accentGreen.opacity(0.14) : discoverPreviewControlBackground)

        return Button {
            FGInteractionHaptics.softImpact()
            viewModel.toggleVenueGameGoingFromUI(
                bar: bar,
                gameTitle: event.title,
                eventDate: event.date,
                knownVenueEventID: venueEventID,
                source: "discoverVenueGameCard",
                onRequiresLogin: {
                    viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                },
                onBusinessBlocked: {
                    viewModel.logBusinessUserGateBlocked(action: "markGoing")
                    fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                }
            )
        } label: {
            HStack(spacing: 5) {
                if isPending {
                    ProgressView()
                        .controlSize(.mini)
                } else if !requiresLogin {
                    Image(systemName: alreadyInterested ? "checkmark.circle.fill" : "checkmark")
                        .font(.caption.weight(.bold))
                }
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .lineLimit(1)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(fill)
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(isBlocked ? 0.18 : 0.26), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(isPending)
        .opacity(isPending ? 0.72 : 1)
    }

    private func venueGameCardSocialActionRow(
        venueEventID: UUID,
        previewEnergy: VenueGamePreviewEnergy?
    ) -> some View {
        let source = "discoverVenueGameCard"
        let commentCount = viewModel.fanUpdatesDisplayCommentCount(for: venueEventID)
        let _ = logFanChatEntryUXRendered(source: source, eventId: venueEventID, count: commentCount)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 10) {
                if let previewEnergy, previewEnergy.hasBadge {
                    venueGamePreviewEnergyCompactBadge(previewEnergy)
                }

                Spacer(minLength: 8)

                venueGameFanChatActionButton(
                    venueEventID: venueEventID,
                    source: source,
                    commentCount: commentCount
                )
            }

            if commentCount == 0 {
                Text("Join the game conversation")
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(discoverPreviewSecondaryTextColor)
                    .lineLimit(1)
            }
        }
    }

    private func venueGamePreviewEnergyCompactBadge(_ energy: VenueGamePreviewEnergy) -> some View {
        let palette = venueGamePreviewEnergyPalette(energy)

        return Text(energy.label ?? "Active")
            .font(FGTypography.metadata.weight(.bold))
            .foregroundStyle(palette.text)
            .lineLimit(1)
            .padding(.horizontal, 11)
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(energyGradient(for: energy.score))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: palette.borderColors,
                            startPoint: .leading,
                            endPoint: .trailing
                        ),
                        lineWidth: 1
                    )
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private func venueGameFanChatActionButton(
        venueEventID: UUID,
        source: String,
        commentCount: Int
    ) -> some View {
        let title = commentCount > 0 ? "Fan Chat · \(commentCount)" : "Fan Chat"
        let tint = FGColor.accentBlue
        let fill = tint.opacity(colorScheme == .dark ? 0.20 : 0.12)

        return Button {
            print(
                "[FanChatEntryUX] tapped source=\(source) eventId=\(venueEventID.uuidString.lowercased())"
            )
            FGInteractionHaptics.selection()
            presentFanUpdatesSheet(venueEventID: venueEventID)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                Text(title)
                    .font(FGTypography.metadata.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background {
                Capsule(style: .continuous)
                    .fill(.ultraThinMaterial)
                    .background {
                        Capsule(style: .continuous)
                            .fill(fill)
                    }
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.34 : 0.26), lineWidth: 1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            commentCount > 0
                ? "Open Fan Chat, \(commentCount) comments"
                : "Open Fan Chat"
        )
    }

    private func logFanChatEntryUXRendered(source: String, eventId: UUID, count: Int) {
        print(
            "[FanChatEntryUX] rendered source=\(source) eventId=\(eventId.uuidString.lowercased()) count=\(count)"
        )
    }

    private func presentFanUpdatesSheet(venueEventID: UUID) {
        guard viewModel.isAuthenticatedForSocialFeatures else {
            viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
            return
        }
        FanUpdatesTapPerf.handleTap(eventId: venueEventID) {
            fanUpdatesSheetEvent = FanUpdatesSheetEvent(id: venueEventID)
        }
    }

    private var venuePreviewMiniStats: [VenuePreviewMiniStat] {
        [
            VenuePreviewMiniStat(id: "packed", symbol: "🔥", label: "On fire", countColor: .red, background: Color(red: 1.00, green: 0.90, blue: 0.92), selectedBackground: .red.opacity(0.18)),
            VenuePreviewMiniStat(id: "seats_open", symbol: "🪑", label: "Seats", countColor: .green, background: Color(red: 0.90, green: 0.97, blue: 0.91), selectedBackground: .green.opacity(0.18)),
            VenuePreviewMiniStat(id: "tv_visible", symbol: "📺", label: "TVs", countColor: .primary, background: Color(red: 0.90, green: 0.95, blue: 1.00), selectedBackground: .blue.opacity(0.18)),
            VenuePreviewMiniStat(id: "audio_on", symbol: "🔊", label: "Sound", countColor: .orange, background: Color(red: 1.00, green: 0.96, blue: 0.84), selectedBackground: .yellow.opacity(0.24)),
            VenuePreviewMiniStat(id: "crowd", symbol: "👥", label: "Crowd", countColor: .blue, background: Color(red: 0.92, green: 0.93, blue: 1.00), selectedBackground: .blue.opacity(0.16))
        ]
    }

    private func venuePreviewInteractionStrip(venueEventID: UUID) -> some View {
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]
        let selected = fanUpdatesStore.myVenueEventVibes[venueEventID] ?? []
        let _ = logFanUpdatesStoreMigrationDebug()
        let _ = logVenueMiniStatsDebug(eventId: venueEventID, counts: counts)

        return HStack(spacing: 6) {
            ForEach(venuePreviewMiniStats) { stat in
                venuePreviewMiniStatChip(
                    stat,
                    venueEventID: venueEventID,
                    counts: counts,
                    selected: selected
                )
            }
        }
        .padding(.top, 1)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func venuePreviewMiniStatChip(
        _ stat: VenuePreviewMiniStat,
        venueEventID: UUID,
        counts: [String: Int],
        selected: Set<String>
    ) -> some View {
        let count = counts[stat.id] ?? 0
        let isSelected = selected.contains(stat.id)
        return Button {
            FGInteractionHaptics.softImpact()
            guard viewModel.isAuthenticatedForSocialFeatures else {
                viewModel.discoverPresentFanUserAuthSheet(openRegisterMode: false)
                return
            }
            guard viewModel.canUseFanSocialFeatures else {
                viewModel.logBusinessUserGateBlocked(action: "toggleVibe")
                fanFeatureGateAlertMessage = BusinessFanGateCopy.actionTapBlocked
                return
            }
            Task {
                await viewModel.toggleVibe(for: venueEventID, vibeType: stat.id)
            }
        } label: {
            HStack(spacing: 4) {
                Text(stat.symbol)
                    .font(.system(size: 17))
                Text("\(count)")
                    .font(.subheadline.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(stat.countColor)
            }
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, minHeight: 38, maxHeight: 38)
                .background {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(isSelected ? stat.selectedBackground : stat.background)
                }
        }
        .buttonStyle(FGPremiumPressButtonStyle(pressedScale: 0.965, hapticOnPress: false))
        .accessibilityLabel("\(stat.label), \(count) votes")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func logVenueMiniStatsDebug(eventId: UUID, counts: [String: Int]) {
#if DEBUG
        print("[VenueMiniStatsDebug] eventId=\(eventId.uuidString)")
        print("[VenueMiniStatsDebug] counts=packed:\(counts["packed"] ?? 0),seats:\(counts["seats_open"] ?? 0),tv:\(counts["tv_visible"] ?? 0),sound:\(counts["audio_on"] ?? 0),crowd:\(counts["crowd"] ?? 0)")
        print("[VenueMiniStatsDebug] packed=\(counts["packed"] ?? 0)")
        print("[VenueMiniStatsDebug] seats=\(counts["seats_open"] ?? 0)")
        print("[VenueMiniStatsDebug] tv=\(counts["tv_visible"] ?? 0)")
        print("[VenueMiniStatsDebug] sound=\(counts["audio_on"] ?? 0)")
        print("[VenueMiniStatsDebug] crowd=\(counts["crowd"] ?? 0)")
        print("[VenueMiniStatsDebug] rowRendered=true")
#endif
    }

    private func logFanUpdatesStoreMigrationDebug() {
#if DEBUG
        print("[FanUpdatesStoreMigrationDebug] DiscoverObservesStore=true")
        print("[FanUpdatesStoreMigrationDebug] DiscoverPreviewReadsStore=true")
#endif
    }

    private func venuePreviewInteractionTint(for type: String) -> Color {
        switch type {
        case "packed":
            return FGColor.dangerRed
        case "seats_open", "crowd":
            return FGColor.accentGreen
        case "tv_visible":
            return FGColor.accentBlue
        case "audio_on":
            return FGColor.accentYellow
        default:
            return FGColor.accentBlue
        }
    }

    private func venuePreviewEnergy(for venueEventID: UUID, energy: FanGeoLiveEnergy) -> VenueGamePreviewEnergy {
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]
        let previewEnergy = VenueGamePreviewEnergy.evaluate(
            fireCount: counts["packed"] ?? 0,
            seatsCount: counts["seats_open"] ?? 0,
            tvCount: counts["tv_visible"] ?? 0,
            soundCount: counts["audio_on"] ?? 0,
            crowdCount: counts["crowd"] ?? 0,
            goingCount: energy.goingCount,
            friendGoingCount: energy.friendGoingCount,
            commentCount: energy.commentCount,
            isLiveNow: energy.isLiveNow,
            startsSoon: energy.startsSoon
        )
        logVenueEnergyDebug(eventId: venueEventID, energy: previewEnergy)
        return previewEnergy
    }

    private func venueGamePreviewEnergyHeader(_ energy: VenueGamePreviewEnergy) -> some View {
        let palette = venueGamePreviewEnergyPalette(energy)

        return HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(energy.label ?? "Quiet") • \(energy.score)")
                    .font(FGTypography.metadata.weight(.bold))
                    .foregroundStyle(palette.text)
                    .lineLimit(1)

                Text(energy.subtitle)
                    .font(FGTypography.caption.weight(.medium))
                    .foregroundStyle(FGColor.secondaryText(colorScheme))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            Capsule(style: .continuous)
                .fill(energyGradient(for: energy.score))
        }
        .overlay {
            Capsule(style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: palette.borderColors,
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 1
                )
        }
        .shadow(color: palette.glowColor, radius: palette.glowRadius, x: 0, y: 3)
    }

    private func venueGamePreviewEnergyPalette(_ energy: VenueGamePreviewEnergy?) -> VenueEnergyColorPalette {
        venueEnergyColorPalette(for: energy?.score ?? 0)
    }

    private func logVenueEnergyDebug(eventId: UUID, energy: VenueGamePreviewEnergy) {
#if DEBUG
        DebugLogGate.noisy("[VenueEnergyDebug] eventId=\(eventId.uuidString.lowercased())")
        DebugLogGate.noisy("[VenueEnergyDebug] score=\(energy.score)")
        DebugLogGate.noisy("[VenueEnergyDebug] label=\(energy.label ?? "none")")
        DebugLogGate.noisy("[VenueEnergyDebug] fire=\(energy.fireCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] crowd=\(energy.crowdCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] going=\(energy.goingCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] friends=\(energy.friendGoingCount)")
        DebugLogGate.noisy("[VenueEnergyDebug] comments=\(energy.commentCount)")
        let palette = venueGamePreviewEnergyPalette(energy)
        DebugLogGate.noisy("[VenueEnergyColorDebug] score=\(energy.score)")
        DebugLogGate.noisy("[VenueEnergyColorDebug] tier=\(palette.tier.rawValue)")
        DebugLogGate.noisy("[VenueEnergyColorDebug] accent=\(String(describing: energyAccentColor(for: energy.score)))")
#endif
    }

    private func liveScoreEmoji(for score: Int) -> String {
        if score >= 40 {
            return "👑"
        } else if score >= 16 {
            return "🚀"
        } else if score >= 6 {
            return "🔥"
        } else if score >= 1 {
            return "✨"
        }

        return ""
    }
    
    
    private func simpleMapPin(bar: BarVenue, gamesToday: [SportsEvent]) -> some View {
        let sport = gamesToday.first?.sport ?? bar.primarySport

        return Image(systemName: viewModel.iconForSport(sport))
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(Circle().fill(Color.black).shadow(radius: 5))
    }

    private func noGameScheduledMapPin() -> some View {
        Image(systemName: "building.2.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(Color.white.opacity(0.92))
            .frame(width: 38, height: 38)
            .background(
                Circle()
                    .fill(Color.gray.opacity(0.62))
                    .shadow(radius: 4)
            )
            .opacity(0.6)
    }

    private func compactMapPin(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        goingTotal: Int,
        liveScore: Int? = nil,
        hasLiveNow: Bool? = nil
    ) -> some View {
        let liveScore = liveScore ?? liveActivityScore(for: bar, gamesToday: gamesToday)
        let hasLiveNow = hasLiveNow ?? viewModel.hasLiveVenueEventNow(for: bar, events: gamesToday)

        return HStack(spacing: 6) {
            Image(systemName: viewModel.iconForSport(gamesToday.first?.sport ?? bar.primarySport))
                .font(.system(size: 14, weight: .bold))

            if hasLiveNow {
                Text("LIVE")
                    .font(.caption2.weight(.heavy))
            } else if liveScore > 0 {
                Text("\(liveScoreEmoji(for: liveScore)) \(liveScore)")
                    .font(.caption2)
                    .fontWeight(.bold)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background {
            ZStack {
                if hasLiveNow || liveScore >= livePulseThreshold {
                    LivePulseView(
                        isTrending: hasLiveNow || liveScore >= 40
                    )
                }

                Capsule()
                    .fill(Color.black)
                    .shadow(radius: 5)
            }
        }
    }
    
    private func liveActivityScore(for bar: BarVenue, gamesToday: [SportsEvent]) -> Int {
        viewModel.mapPinEnergyScore(bar: bar, gamesOnMapDay: gamesToday)
    }

    private func venuePinDisplayState(_ venue: BarVenue) -> VenuePinDisplayState {
        if let pinSnapshot = viewModel.discoverMapRenderSnapshot.venuePinsByID[venue.id] {
#if DEBUG
            DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingPinSnapshot=true")
#endif
            return pinSnapshot.selectedDayGames.isEmpty ? .noGameScheduled : .gameScheduled
        }

        return viewModel.venueHasVisibleGameToday(venue) ? .gameScheduled : .noGameScheduled
    }

    private func clusterDisplayState(_ cluster: VenueCluster) -> ClusterDisplayState {
        let snapshot = viewModel.discoverMapRenderSnapshot
        if let clusterSnapshot = snapshot.venueClustersByID[cluster.id] {
            let pinSnapshots = clusterSnapshot.venueIDs.compactMap { snapshot.venuePinsByID[$0] }
            if pinSnapshots.count == clusterSnapshot.venueIDs.count {
#if DEBUG
                DebugLogGate.noisy("[DiscoverMapSnapshotDebug] usingClusterSnapshot=true")
#endif
                return pinSnapshots.contains { !$0.selectedDayGames.isEmpty } ? .gameScheduled : .noGameScheduled
            }
        }

        return cluster.bars.contains { viewModel.venueHasVisibleGameToday($0) } ? .gameScheduled : .noGameScheduled
    }

    private func detailedMapPin(
        bar: BarVenue,
        gamesToday: [SportsEvent],
        goingTotal: Int,
        liveScore: Int? = nil,
        hasLiveNow: Bool? = nil
    ) -> some View {
        
        VStack(spacing: 4) {
            let hasLiveNow = hasLiveNow ?? viewModel.hasLiveVenueEventNow(for: bar, events: gamesToday)
            let liveScore = liveScore ?? liveActivityScore(for: bar, gamesToday: gamesToday)
            HStack(spacing: -6) {
                ForEach(gamesToday.prefix(3), id: \.id) { game in
                    Image(systemName: viewModel.iconForSport(game.sport))
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background {
                            ZStack {
                                if hasLiveNow || liveScore >= livePulseThreshold {
                                    LivePulseView(
                                        isTrending: hasLiveNow || liveScore >= 40
                                    )
                                }

                                Circle()
                                    .fill(Color.black)
                                    .shadow(radius: 5)
                            }
                        }
                }
            }
            Text(gamesToday.count == 1 ? gamesToday.first?.sport ?? bar.primarySport : "\(gamesToday.count) games")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.black.opacity(0.75))
                .clipShape(Capsule())

            if hasLiveNow || liveScore > 0 {
                Text(hasLiveNow ? "LIVE NOW" : "🔥 \(liveScore) live")
                    .font(.caption2)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((hasLiveNow ? FGColor.dangerRed : Color.orange).opacity(0.95))
                    .clipShape(Capsule())
            }

            Text(bar.name)
                .font(.caption2)
                .foregroundStyle(.primary)
        }
    }
    
    private var loadingVenueGamesView: some View {
        HStack(spacing: FGSpacing.sm) {
            ProgressView()
                .scaleEffect(0.85)

            Text("Loading venue games...")
                .font(FGTypography.caption)
                .foregroundStyle(FGColor.secondaryText(colorScheme))
        }
        .padding(FGSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(FGColor.background(colorScheme).opacity(colorScheme == .dark ? 0.60 : 0.92))
        .clipShape(RoundedRectangle(cornerRadius: FGRadius.medium, style: .continuous))
    }
        
    
    private func clusterMapPin(
        cluster: VenueCluster,
        maxEnergy: Int,
        dominantSport: String?,
        displayState: ClusterDisplayState
    ) -> some View {
        let caption = viewModel.mapClusterEnergyCaption(maxScore: maxEnergy)
        return VStack(spacing: 3) {
            if case .gameScheduled = displayState,
               let sport = dominantSport,
               maxEnergy > 0 {
                Image(systemName: viewModel.iconForSport(sport))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(viewModel.colorForSport(sport))
                    .padding(5)
                    .background(Circle().fill(Color.white.opacity(0.95)))
            } else if case .noGameScheduled = displayState {
                Image(systemName: "building.2.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.9))
                    .padding(5)
                    .background(Circle().fill(Color.gray.opacity(0.8)))
            }

            Text("\(cluster.count)")
                .font(.headline)
                .fontWeight(.bold)

            Text("venues")
                .font(.caption2)
                .fontWeight(.bold)

            if case .gameScheduled = displayState, maxEnergy > 0 {
                Text("\(maxEnergy)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.yellow.opacity(0.95))
            }

            if case .gameScheduled = displayState, let caption {
                Text(caption)
                    .font(.system(size: 9, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .foregroundStyle(.white)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 6)
        .padding(.vertical, 7)
        .frame(minWidth: 58, minHeight: 58)
        .background(
            Circle()
                .fill(displayState == .gameScheduled ? Color.black : Color.gray.opacity(0.72))
                .shadow(radius: 7)
        )
        .opacity(displayState == .gameScheduled ? 1 : 0.62)
    }

    private func topVibeText(for venueEventID: UUID) -> String? {
        let counts = fanUpdatesStore.venueEventVibeCounts[venueEventID] ?? [:]

        guard let top = counts.max(by: { $0.value < $1.value }),
              top.value > 0 else {
            return nil
        }

        switch top.key {
        case "audio_on":
            return "🔊 Audio confirmed · \(top.value)"
        case "packed":
            return "🔥 Packed · \(top.value)"
        case "seats_open":
            return "🪑 Seats open · \(top.value)"
        case "specials":
            return "🍺 Specials · \(top.value)"
        case "tv_visible":
            return "📺 TVs visible · \(top.value)"
        case "crowd":
            return "👥 Crowd checked · \(top.value)"
        default:
            return nil
        }
    }

}

// MARK: - Discover light overlay chrome

private enum DiscoverOverlaySportChip: String, CaseIterable, Identifiable {
    case allSports
    case soccer
    case basketball
    case football
    case tennis
    case baseball
    case more

    var id: String { rawValue }

    var selection: String {
        switch self {
        case .allSports: return "All"
        case .soccer: return "Soccer"
        case .basketball: return "NBA"
        case .football: return "NFL"
        case .tennis: return "Tennis"
        case .baseball: return "Baseball"
        case .more: return "More"
        }
    }

    var label: String {
        switch self {
        case .allSports: return "All Sports"
        case .soccer: return "Soccer"
        case .basketball: return "Basketball"
        case .football: return "Football"
        case .tennis: return "Tennis"
        case .baseball: return "Baseball"
        case .more: return "More"
        }
    }

    static func isPinnedPopularSelection(_ selectedSport: String) -> Bool {
        let trimmed = selectedSport.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == "All" { return true }
        return allCases.contains { chip in
            chip != .more && DiscoverSportFilterRowLayout.selectionTokensMatch(trimmed, chip.selection)
        }
    }
}

private struct DiscoverOverlaySportPillRow: View {
    @ObservedObject var viewModel: MapViewModel
    @Binding var showMoreSheet: Bool
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if !DiscoverOverlaySportChip.isPinnedPopularSelection(viewModel.selectedSport) {
                DiscoverOverlaySportPill(
                    selection: viewModel.selectedSport,
                    label: viewModel.selectedSport,
                    isSelected: true,
                    action: { onSelect(viewModel.selectedSport) }
                )
            }

            ForEach(DiscoverOverlaySportChip.allCases) { chip in
                if chip == .more {
                    DiscoverOverlaySportPill(
                        selection: "More",
                        label: chip.label,
                        isSelected: false,
                        action: { showMoreSheet = true }
                    )
                } else {
                    DiscoverOverlaySportPill(
                        selection: chip.selection,
                        label: chip.label,
                        isSelected: DiscoverSportFilterRowLayout.selectionTokensMatch(
                            viewModel.selectedSport,
                            chip.selection
                        ),
                        action: { onSelect(chip.selection) }
                    )
                }
            }
        }
    }
}

private struct DiscoverOverlaySportPill: View {
    @Environment(\.colorScheme) private var colorScheme

    let selection: String
    let label: String
    let isSelected: Bool
    let action: () -> Void

    private static let chipHeight: CGFloat = 36
    private static let chipCornerRadius: CGFloat = 18
    private static let chipSymbolPointSize: CGFloat = 13
    private static let chipEmojiPointSize: CGFloat = 15

    private var visual: SportFilterCatalog.ChipVisual {
        SportFilterCatalog.resolve(selection)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Group {
                    if selection == "All" {
                        Image(systemName: visual.systemImage)
                            .font(.system(size: Self.chipSymbolPointSize, weight: .semibold))
                            .foregroundStyle(visual.accent)
                    } else if selection == "More" {
                        Image(systemName: "ellipsis")
                            .font(.system(size: Self.chipSymbolPointSize, weight: .bold))
                            .foregroundStyle(FGColor.mutedText(colorScheme))
                    } else if !visual.emoji.isEmpty {
                        Text(visual.emoji)
                            .font(.system(size: Self.chipEmojiPointSize))
                            .frame(width: 15, height: 15)
                            .minimumScaleFactor(0.85)
                            .lineLimit(1)
                    } else {
                        Image(systemName: visual.systemImage)
                            .font(.system(size: Self.chipSymbolPointSize, weight: .semibold))
                            .foregroundStyle(visual.accent)
                    }
                }

                Text(label)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(isSelected ? 0.96 : 0.86) : FGColor.primaryText(colorScheme))
                    .lineLimit(1)
            }
            .padding(.horizontal, 11)
            .frame(height: Self.chipHeight)
            .background {
                RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                    .fill(colorScheme == .dark ? .thinMaterial : .ultraThinMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                            .fill(colorScheme == .dark ? Color.black.opacity(isSelected ? 0.24 : 0.34) : Color.clear)
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                            .fill(
                                Color.white.opacity(
                                    isSelected
                                        ? (colorScheme == .dark ? 0.18 : 0.62)
                                        : (colorScheme == .dark ? 0.10 : 0.44)
                                )
                            )
                    }
            }
            .overlay {
                RoundedRectangle(cornerRadius: Self.chipCornerRadius, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? FGColor.accentGreen
                            : (colorScheme == .dark ? Color.white.opacity(0.18) : Color.black.opacity(0.04)),
                        lineWidth: isSelected ? 1.25 : (colorScheme == .dark ? 0.75 : 0.5)
                    )
            }
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.14 : 0.025),
                radius: colorScheme == .dark ? 3 : 1,
                y: colorScheme == .dark ? 1.5 : 0.5
            )
        }
        .buttonStyle(.plain)
    }
}

private enum DiscoverGlassChromeStyle {
    /// Lighter floating chrome for map-adjacent top overlays.
    case overlay
    case searchBar
    case sportsRow
    case weather
    /// Preserves prior heavier glass for bottom controls (unchanged layout).
    case bottomControl
}

private struct DiscoverLightGlassCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let style: DiscoverGlassChromeStyle

    private var material: Material {
        switch style {
        case .searchBar, .bottomControl:
            return .thinMaterial
        case .sportsRow, .weather, .overlay:
            return .ultraThinMaterial
        }
    }

    /// Translucent white tint stacked on material (final top lightening pass).
    private var whiteOverlayOpacity: CGFloat {
        switch style {
        case .searchBar:
            return colorScheme == .dark ? 0.17 : 0.44
        case .sportsRow:
            return colorScheme == .dark ? 0.13 : 0.33
        case .weather:
            return colorScheme == .dark ? 0.18 : 0.42
        case .overlay:
            return colorScheme == .dark ? 0.16 : 0.39
        case .bottomControl:
            return colorScheme == .dark ? 0.12 : 0.94
        }
    }

    private var darkSeparationScrimOpacity: CGFloat {
        guard colorScheme == .dark else { return 0 }
        switch style {
        case .searchBar:
            return 0.30
        case .sportsRow:
            return 0.24
        case .weather, .overlay:
            return 0.28
        case .bottomControl:
            return 0.34
        }
    }

    private var borderColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(style == .bottomControl ? 0.24 : 0.19)
            : FGColor.divider(colorScheme)
    }

    private var shadowOpacity: Double {
        switch style {
        case .searchBar:
            return colorScheme == .dark ? 0.24 : 0.081
        case .sportsRow:
            return colorScheme == .dark ? 0.18 : 0.045
        case .weather, .overlay:
            return colorScheme == .dark ? 0.22 : 0.072
        case .bottomControl:
            return colorScheme == .dark ? 0.28 : 0.1
        }
    }

    private var shadowRadius: CGFloat {
        switch style {
        case .searchBar:
            return 6
        case .sportsRow:
            return 4
        case .weather, .overlay:
            return 5
        case .bottomControl:
            return 14
        }
    }

    private var shadowYOffset: CGFloat {
        switch style {
        case .searchBar:
            return 2
        case .sportsRow:
            return 1.5
        case .weather, .overlay:
            return 2
        case .bottomControl:
            return 5
        }
    }

    private var showsSpecularHighlight: Bool {
        switch style {
        case .searchBar, .weather, .overlay:
            return true
        case .sportsRow, .bottomControl:
            return false
        }
    }

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(material)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.black.opacity(darkSeparationScrimOpacity))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill(Color.white.opacity(whiteOverlayOpacity))
                    }
                    .overlay {
                        if showsSpecularHighlight {
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(colorScheme == .dark ? 0.09 : 0.19),
                                            Color.white.opacity(0.02)
                                        ],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                    }
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(borderColor, lineWidth: colorScheme == .dark ? 1 : 0.75)
            }
            .shadow(
                color: Color.black.opacity(shadowOpacity),
                radius: shadowRadius,
                y: shadowYOffset
            )
    }
}

private struct DiscoverFloatingMapCircleButtonModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let fill: AnyShapeStyle

    func body(content: Content) -> some View {
        content
            .frame(width: 44, height: 44)
            .background {
                Circle()
                    .fill(fill)
            }
            .overlay {
                Circle()
                    .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.12 : 0.06), lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(colorScheme == .dark ? 0.22 : 0.12), radius: 10, y: 4)
    }
}

private struct DiscoverIntegratedLocationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.68), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
    }
}

private struct DiscoverModeSegmentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: configuration.isPressed)
    }
}

private extension View {
    func discoverLightGlassCard(
        cornerRadius: CGFloat = 22,
        style: DiscoverGlassChromeStyle = .overlay
    ) -> some View {
        modifier(DiscoverLightGlassCardModifier(cornerRadius: cornerRadius, style: style))
    }

    func discoverFloatingMapCircleButton(fill: AnyShapeStyle = AnyShapeStyle(Color.white)) -> some View {
        modifier(DiscoverFloatingMapCircleButtonModifier(fill: fill))
    }
}
