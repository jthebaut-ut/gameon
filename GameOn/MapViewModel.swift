import Foundation
import SwiftUI
import MapKit
import Combine
import CoreLocation
import EventKit
import Supabase

/// Central `@MainActor` observable object: map camera and selection, venue and schedule data, Supabase auth, venue-owner tools, favorites, and social (interests, comments, vibes).
///
/// Feature code is split across `MapViewModel+*.swift` extensions. This declaration holds `@Published` state, `EventKit` store, and static sample references.
@MainActor
final class MapViewModel: ObservableObject {
    
    @Published var selectedDate: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            guard !Calendar.current.isDate(oldValue, inSameDayAs: selectedDate) else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "selectedDate")
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=selectedDate")
#endif
            scheduleInitialVenueGameCardGoingRefresh(reason: "selectedDate")
        }
    }
    /// Bottom-tab Calendar only (never drives Discover map date).
    @Published var calendarTabSelectedDate: Date = Calendar.current.startOfDay(for: Date())
    @Published var calendarTabGameFilter: CalendarTabGameFilter = .venueGames
    /// Guest Discover: set when the user confirms a date from the map calendar (`Done`); blocks automatic “jump to next day with games” for that cold start / session.
    var discoverCalendarGuestUserPinnedDateThisSession: Bool = false
    @Published var selectedSport: String = "All" {
        didSet {
            guard oldValue != selectedSport else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "selectedSport")
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=selectedSport")
#endif
            scheduleInitialVenueGameCardGoingRefresh(reason: "selectedSport")
        }
    }
    @Published var selectedEvent: SportsEvent?
    @Published var selectedBar: BarVenue? {
        didSet {
            guard oldValue?.id != selectedBar?.id else { return }
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=selectedBar")
#endif
            scheduleInitialVenueGameCardGoingRefresh(
                reason: selectedBar == nil ? "selectedBarCleared" : "selectedBar"
            )
        }
    }
    @Published var searchText: String = ""
    var pendingCitySearchVenueDebugContext: CitySearchVenueDebugContext?
    /// Debounced copy of ``searchText`` for Discover map/event filtering and live venue suggestions (see ``MapViewModel+DiscoverSearch``).
    @Published var debouncedDiscoverSearchText: String = "" {
        didSet {
            guard oldValue != debouncedDiscoverSearchText else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "debouncedDiscoverSearchText")
        }
    }
    @Published var favoriteVenueIDs: Set<UUID> = []
    @Published var interestedVenueEventKeys: Set<String> = []
    /// Prevents overlapping save/remove writes for the same venue while keeping the UI on the optimistic state.
    var favoriteVenueWriteInFlightIDs: Set<UUID> = []
    /// Prevents overlapping going/interested writes for the same event while keeping the UI on the optimistic state.
    @Published var venueEventInterestWriteInFlightIDs: Set<UUID> = []
    /// Target Going state for in-flight venue-event interest writes. Distinguishes add vs remove so optimistic un-going can hide immediately.
    var venueEventInterestPendingTargets: [UUID: Bool] = [:]
    /// Short-lived local Going confirmations so Supabase reloads cannot flash the UI back to not-going.
    var recentlyConfirmedVenueEventGoingAt: [UUID: Date] = [:]
    /// Short-lived local not-going confirmations so reloads cannot re-add a deleted row before read replicas catch up.
    var recentlyConfirmedVenueEventNotGoingAt: [UUID: Date] = [:]
    let venueEventInterestLocalReconcileTTL: TimeInterval = 15
    @Published var selectedTimeZone: TimeZoneOption = .mountain
    @Published var isLoggedIn: Bool = false
    @Published var currentUserEmail: String = ""
    /// Supabase Auth user id; mirrors ``supabase.auth.session.user.id`` when signed in (fan session).
    @Published var currentUserAuthId: UUID?
    /// Bumped whenever private authenticated state is explicitly cleared so sibling view models can synchronously wipe their own caches.
    @Published var privateSessionClearNonce: UUID = UUID()
    /// Shared social/chat auth gate: regular fan auth, business-owner auth, or an already-restored Supabase session id.
    var isAuthenticatedForSocialFeatures: Bool {
        isLoggedIn || isVenueOwnerLoggedIn || currentUserAuthId != nil
    }
    /// Discover map and public pickup rows: no fan session and no venue-owner session (same as ``!isAuthenticatedForSocialFeatures``).
    var isGuestDiscoverMode: Bool {
        !isAuthenticatedForSocialFeatures
    }
    /// True only when the active authenticated session is currently operating as a venue-owner/business account.
    var hasAuthenticatedVenueOwnerSession: Bool {
        isVenueOwnerLoggedIn
            && venueOwnerMode
            && currentUserAuthId != nil
            && OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(venueOwnerEmail))
    }
    /// Back-compat alias for older Following/favorites call sites.
    var hasSupabaseSessionForFollowingTab: Bool {
        isAuthenticatedForSocialFeatures
    }
    @Published var venueOwnerMode: Bool = false
    /// `public.venues.id` for the signed-in venue owner’s active profile row, when loaded (used for ``venue_events.venue_id`` on insert).
    @Published var ownerVenueDatabaseId: UUID?
    /// `public.businesses` rows for the signed-in venue owner (`owner_email` + active); see ``refreshOwnedBusinessesAndVenuesAfterOwnerLogin()``.
    @Published var ownedBusinesses: [BusinessRow] = []
    /// UI-only archived `public.businesses` rows for the signed-in venue owner. Never used to unlock tools or resolve active business ids.
    @Published var archivedOwnedBusinesses: [BusinessRow] = []
    /// `public.venues` rows linked via `business_id` to ``ownedBusinesses``.
    @Published var ownedBusinessVenues: [VenueProfileRow] = []
    /// Unapproved ``venue_claims`` rows for the signed-in owner / their businesses (Settings “Pending locations”; Phase C1).
    @Published var pendingVenueClaimsForSettings: [VenueClaimPendingSettingsRow] = []
    /// Rejected, not-yet-dismissed ``venue_claims`` for Settings (“Rejected locations”). Rows with ``rejection_acknowledged_at`` set are excluded at fetch time.
    @Published var rejectedVenueClaimsForSettings: [VenueClaimPendingSettingsRow] = []
    /// From ``refreshVenueClaimStatusLineFromDatabase()`` scan of recent ``venue_claims`` by owner email: any row is rejected and ``rejection_acknowledged_at`` is unset.
    @Published var hasUnackedRejectedVenueClaimForOwnerEmail: Bool = false
    /// Per-venue approved ownership resolved from `venue_claims.venue_id` for Venue Detail claim visibility.
    @Published var approvedVenueOwnershipByVenueID: [UUID: ApprovedVenueOwnershipSummary] = [:]

    /// Red rejection chrome / modals: unacked rejections from email-scoped status refresh and/or business-scoped Settings list.
    var hasActiveVenueClaimRejectionForBusinessUI: Bool {
        hasUnackedRejectedVenueClaimForOwnerEmail || !rejectedVenueClaimsForSettings.isEmpty
    }
    /// When ``ownedBusinessVenues`` is empty, venues matched by ``venueOwnerEmail`` only (pre-backfill); used by ``primaryOwnedVenueForLegacyCompatibility()``.
    /// Pre-backfill venues keyed only by email; written only from ``MapViewModel+VenueOwnerAndClaims``.
    var legacyOwnerVenuesForEmailFallback: [VenueProfileRow] = []
    @Published var ownerVenueName: String = ""
    @Published var ownerVenueAddress: String = ""
    @Published var ownerVenueAddressLine2: String = ""
    @Published var ownerVenueCity: String = ""
    @Published var ownerVenueState: String = ""
    @Published var ownerVenueZipCode: String = ""
    @Published var ownerVenueCountry: String = BusinessLocationCountryPolicy.defaultCountryCode
    @Published var ownerVenueSupporterCountry: String = ""
    /// ITU dial country (ISO 3166-1 alpha-2) for ``ownerVenuePhone`` national portion; combined with local digits on save.
    @Published var ownerVenuePhoneDialISO: String = BusinessPhoneFields.defaultISO
    @Published var ownerVenuePhone: String = ""
    @Published var ownerVenueWebsite: String = ""
    @Published var ownerVenueDescription: String = ""
    @Published var ownerVenueFeatures: String = ""
    @Published var ownerVenuePrimarySport: String = "Soccer"
    @Published var isVenueOwnerLoggedIn: Bool = false
    @Published var venueOwnerEmail: String = ""
    @Published var venueClaimSubmitted: Bool = false
    @Published var venueClaimStatus: String = "Not submitted"
    @Published var venueBusinessEmail: String = ""
    @Published var venueProofNote: String = ""
    @Published var isAdminLoggedIn: Bool = false
    @Published var adminEmail: String = ""
    @Published var venueClaims: [VenueClaim] = []
    @Published var venueIsApproved: Bool = false
    @Published var authErrorMessage = ""
    @Published var venueAuthErrorMessage = ""
    /// Set after a fan/user password-reset email is requested (`MapViewModel+AuthAndProfile`).
    @Published var userPasswordResetMessage = ""
    @Published var userPasswordResetError = ""
    /// Set after a venue-owner password-reset email is requested (same Auth API, separate UI feedback).
    @Published var venuePasswordResetMessage = ""
    @Published var venuePasswordResetError = ""
    @Published var venueClaimSubmittedDate = ""
    /// True while ``refreshOwnedBusinessesAndVenuesAfterOwnerLogin()`` is fetching businesses/venues (venue owner sheet loading indicator).
    @Published var isVenueOwnerBusinessDataLoading = false
    /// After successful business-owner signup (auth + business + first claim); drives a one-shot success card in the Business auth sheet until dismissed.
    @Published var venueOwnerJustCompletedRegistration: Bool = false
    /// When non-nil, the fan started a “Claim this business” flow from Discover for this public venue id (Phase A; not yet sent to `venue_claims` as `venue_id`).
    @Published var pendingClaimVenueID: UUID?
    @Published var pendingClaimVenueName: String = ""
    @Published var pendingClaimVenueAddress: String = ""
    @Published var pendingClaimVenueCity: String = ""
    @Published var pendingClaimVenueState: String = ""
    @Published var pendingClaimVenuePhone: String = ""
    @Published var pendingClaimVenueWebsite: String = ""
    @Published var pendingClaimPrimarySport: String = ""
    /// Switched to Account tab + venue auth sheet from Discover claim intent (consumed by ``MainTabView`` / ``SettingsScreen``).
    @Published var switchToAccountForVenueClaim: Bool = false
    @Published var openVenueOwnerAuthSheetFromClaimFlow: Bool = false
    @Published var venueCoverPhotoURL = ""
    @Published var venueCoverPhotoThumbnailURL = ""
    var pendingVenueCoverPhotoVenueID: UUID?
    var pendingVenueCoverPhotoURL: String?
    var pendingVenueCoverPhotoThumbnailURL: String?
    @Published var venueCrowdPhotoURL = ""
    @Published var venueTVWallPhotoURL = ""
    @Published var venueMenuPhotoURL = ""
    @Published var venueMenuPhotoThumbnailURL = ""
    var pendingVenueMenuPhotoVenueID: UUID?
    var pendingVenueMenuPhotoURL: String?
    var pendingVenueMenuPhotoThumbnailURL: String?
    @Published var venueSpecialsPhotoURL = ""
    @Published var ownerVenueScreenCount: Int = 1
    @Published var ownerVenueServesFood: Bool = false
    @Published var ownerVenueHasWifi: Bool = false
    @Published var ownerVenueHasGarden: Bool = false
    @Published var ownerVenueHasProjector: Bool = false
    @Published var ownerVenuePetFriendly: Bool = false
    @Published var venueEventInterestIDs: Set<UUID> = []
    @Published var venueEventInterestCounts: [UUID: Int] = [:] {
        didSet {
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "venueEventInterestCounts")
        }
    }
    let venueGameCardSnapshotStore = VenueGameCardSnapshotStore()
    var venueGameCardInitialGoingRefreshTask: Task<Void, Never>?
    var venueGameCardInitialGoingRefreshLastIDs: [UUID] = []
    let venueGameCardGoingSnapshotTTL: TimeInterval = 25
    @Published var venueEventPredictionSummaries: [UUID: VenueEventPredictionSummary] = [:]
    var venueEventPredictionRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    var venueEventPredictionRealtimeChannels: [UUID: RealtimeChannelV2] = [:]
    var venueEventPredictionRealtimeRefreshTasks: [UUID: Task<Void, Never>] = [:]
    let fanUpdatesStore = FanUpdatesRealtimeStore()

    var venueEventComments: [UUID: [VenueEventCommentRow]] {
        get { fanUpdatesStore.venueEventComments }
        set { fanUpdatesStore.venueEventComments = newValue }
    }
    /// Comment ids the signed-in fan has already reported (from successful submit, duplicate constraint, or REST sync).
    var commentIDsReportedByCurrentUser: Set<UUID> {
        get { fanUpdatesStore.commentIDsReportedByCurrentUser }
        set { fanUpdatesStore.commentIDsReportedByCurrentUser = newValue }
    }
    /// Per-thread realtime listener tasks for venue-event fan updates.
    var venueEventCommentsRealtimeTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentsRealtimeTasks }
        set { fanUpdatesStore.venueEventCommentsRealtimeTasks = newValue }
    }
    var venueEventCommentsRealtimeChannels: [UUID: RealtimeChannelV2] {
        get { fanUpdatesStore.venueEventCommentsRealtimeChannels }
        set { fanUpdatesStore.venueEventCommentsRealtimeChannels = newValue }
    }
    var venueEventCommentsRealtimeListenerTokens: [UUID: UUID] {
        get { fanUpdatesStore.venueEventCommentsRealtimeListenerTokens }
        set { fanUpdatesStore.venueEventCommentsRealtimeListenerTokens = newValue }
    }
    var venueEventCommentsRealtimeReadyIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentsRealtimeReadyIDs }
        set { fanUpdatesStore.venueEventCommentsRealtimeReadyIDs = newValue }
    }
    var venueEventCommentsRealtimeSubscribeStartedAt: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentsRealtimeSubscribeStartedAt }
        set { fanUpdatesStore.venueEventCommentsRealtimeSubscribeStartedAt = newValue }
    }
    var venueEventCommentsRealtimeLastEventAt: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentsRealtimeLastEventAt }
        set { fanUpdatesStore.venueEventCommentsRealtimeLastEventAt = newValue }
    }
    var venueEventCommentRealtimeReceivedServerIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentRealtimeReceivedServerIDs }
        set { fanUpdatesStore.venueEventCommentRealtimeReceivedServerIDs = newValue }
    }
    var venueEventCommentInsertSuccessTimesByServerID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentInsertSuccessTimesByServerID }
        set { fanUpdatesStore.venueEventCommentInsertSuccessTimesByServerID = newValue }
    }
    var venueEventCommentRealtimeFallbackTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentRealtimeFallbackTasks }
        set { fanUpdatesStore.venueEventCommentRealtimeFallbackTasks = newValue }
    }
    var fanChatReceiverRefreshBurstTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanChatReceiverRefreshBurstTasks }
        set { fanUpdatesStore.fanChatReceiverRefreshBurstTasks = newValue }
    }
    var fanChatAutoRefreshInFlightIDs: Set<UUID> {
        get { fanUpdatesStore.fanChatAutoRefreshInFlightIDs }
        set { fanUpdatesStore.fanChatAutoRefreshInFlightIDs = newValue }
    }
    var venueEventCommentReactionRealtimeTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeTasks }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeTasks = newValue }
    }
    var venueEventCommentReactionRealtimeChannels: [UUID: RealtimeChannelV2] {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeChannels }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeChannels = newValue }
    }
    var venueEventCommentReactionRealtimeReadyIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeReadyIDs }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeReadyIDs = newValue }
    }
    var venueEventCommentReactionRealtimeTrackedCommentIDs: [UUID: [UUID]] {
        get { fanUpdatesStore.venueEventCommentReactionRealtimeTrackedCommentIDs }
        set { fanUpdatesStore.venueEventCommentReactionRealtimeTrackedCommentIDs = newValue }
    }
    var venueEventCommentReactionDebounceTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentReactionDebounceTasks }
        set { fanUpdatesStore.venueEventCommentReactionDebounceTasks = newValue }
    }
    var venueEventCommentReactionFallbackPollTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.venueEventCommentReactionFallbackPollTasks }
        set { fanUpdatesStore.venueEventCommentReactionFallbackPollTasks = newValue }
    }
    var venueEventCommentDebugSendTapDatesByLocalID: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentDebugSendTapDatesByLocalID }
        set { fanUpdatesStore.venueEventCommentDebugSendTapDatesByLocalID = newValue }
    }
    var venueEventCommentDebugSendTapTimesByServerID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentDebugSendTapTimesByServerID }
        set { fanUpdatesStore.venueEventCommentDebugSendTapTimesByServerID = newValue }
    }
    var venueEventCommentDebugReceivedDatesByServerID: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentDebugReceivedDatesByServerID }
        set { fanUpdatesStore.venueEventCommentDebugReceivedDatesByServerID = newValue }
    }
    var venueEventCommentDebugFallbackCommentIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentDebugFallbackCommentIDs }
        set { fanUpdatesStore.venueEventCommentDebugFallbackCommentIDs = newValue }
    }
    var venueEventCommentLatencySendTimesByLocalID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencySendTimesByLocalID }
        set { fanUpdatesStore.venueEventCommentLatencySendTimesByLocalID = newValue }
    }
    var venueEventCommentLatencySendTimesByServerID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencySendTimesByServerID }
        set { fanUpdatesStore.venueEventCommentLatencySendTimesByServerID = newValue }
    }
    var venueEventCommentLatencyLastSendTimeByEventID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencyLastSendTimeByEventID }
        set { fanUpdatesStore.venueEventCommentLatencyLastSendTimeByEventID = newValue }
    }
    var venueEventCommentLatencyInsertStartTimesByLocalID: [UUID: CFAbsoluteTime] {
        get { fanUpdatesStore.venueEventCommentLatencyInsertStartTimesByLocalID }
        set { fanUpdatesStore.venueEventCommentLatencyInsertStartTimesByLocalID = newValue }
    }
    @Published var venueEventIDsByKey: [String: UUID] = [:]
    @Published var visibleLatitudeDelta: Double = 0.55
    @Published var userProfilesByEmail: [String: UserProfileRow] = [:]
    @Published var reportedComments: [CommentReportRow] = []
    @Published var reportedCommentDisplays: [ReportedCommentDisplay] = []
    var venueEventVibeCounts: [UUID: [String: Int]] {
        get { fanUpdatesStore.venueEventVibeCounts }
        set { fanUpdatesStore.venueEventVibeCounts = newValue }
    }
    var myVenueEventVibes: [UUID: Set<String>] {
        get { fanUpdatesStore.myVenueEventVibes }
        set { fanUpdatesStore.myVenueEventVibes = newValue }
    }
    var venueEventVibeWriteInFlightKeys: Set<String> {
        get { fanUpdatesStore.venueEventVibeWriteInFlightKeys }
        set { fanUpdatesStore.venueEventVibeWriteInFlightKeys = newValue }
    }
    var venueEventCommentLikeCountsByID: [UUID: Int] {
        get { fanUpdatesStore.venueEventCommentLikeCountsByID }
        set { fanUpdatesStore.venueEventCommentLikeCountsByID = newValue }
    }
    var venueEventCommentDownReactionCountsByID: [UUID: Int] {
        get { fanUpdatesStore.venueEventCommentDownReactionCountsByID }
        set { fanUpdatesStore.venueEventCommentDownReactionCountsByID = newValue }
    }
    var venueEventCommentIDsLikedByCurrentUser: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentIDsLikedByCurrentUser }
        set { fanUpdatesStore.venueEventCommentIDsLikedByCurrentUser = newValue }
    }
    var venueEventCommentViewerReactionsByID: [UUID: FanChatCommentReactionType] {
        get { fanUpdatesStore.venueEventCommentViewerReactionsByID }
        set { fanUpdatesStore.venueEventCommentViewerReactionsByID = newValue }
    }
    var venueEventCommentLikeWriteInFlightIDs: Set<UUID> {
        get { fanUpdatesStore.venueEventCommentLikeWriteInFlightIDs }
        set { fanUpdatesStore.venueEventCommentLikeWriteInFlightIDs = newValue }
    }
    
    let notificationSettingsStore = NotificationSettingsStore()

    var notifyBeforeGame: Bool {
        get { notificationSettingsStore.notifyBeforeGame }
        set { notificationSettingsStore.notifyBeforeGame = newValue }
    }

    var reminderMinutesBefore: Int {
        get { notificationSettingsStore.reminderMinutesBefore }
        set { notificationSettingsStore.reminderMinutesBefore = newValue }
    }

    var repeatGameReminder: Bool {
        get { notificationSettingsStore.repeatGameReminder }
        set { notificationSettingsStore.repeatGameReminder = newValue }
    }

    var repeatEveryMinutes: Int {
        get { notificationSettingsStore.repeatEveryMinutes }
        set { notificationSettingsStore.repeatEveryMinutes = newValue }
    }

    var syncGoingGamesToAppleCalendar: Bool {
        get { notificationSettingsStore.syncGoingGamesToAppleCalendar }
        set { notificationSettingsStore.syncGoingGamesToAppleCalendar = newValue }
    }
    
    @Published var events: [SportsEvent] = SampleData.events
    @Published var isLoadingEvents: Bool = false
    /// True while schedule data is re-fetched but existing ``events``/UI should stay visible (Phase 1 perf).
    @Published var isRefreshingDiscoverEvents: Bool = false
    @Published var liveMatches: [LiveMatch] = []
    @Published var isLoadingLiveMatches: Bool = false
    @Published var liveMatchesLoadError: String?
    /// DEBUG-only hint when Live Games is empty (provider/cache diagnostics).
    @Published var liveMatchesEmptyDebugHint: String?
    @Published var isUpdatingMapGames: Bool = false
    @Published var mapStatusText: String?
    @Published var socialActionToastText: String?
    @Published var socialActionToastIsError: Bool = false
    var notificationPermissionMessage: String {
        get { notificationSettingsStore.notificationPermissionMessage }
        set { notificationSettingsStore.notificationPermissionMessage = newValue }
    }
    @Published var currentUserFanXP: FanXPState = .rookie
    @Published var currentUserFanIdentityPreferences: FanIdentityPreferences = .empty
    /// Bumped after Open To save so an open public profile sheet can reload fresh RPC data.
    @Published var publicProfileOpenToRevision: Int = 0
    /// Bumped after Home Crowd set/clear so an open public profile sheet can reload fresh RPC data.
    @Published var publicProfileHomeCrowdRevision: Int = 0
    /// Bumped after bio save so an open public profile sheet can reload fresh identity data.
    @Published var publicProfileBioRevision: Int = 0
    @Published var currentUserHomeCrowdVenueId: UUID?
    @Published var currentUserHomeCrowdVenue: HomeCrowdVenueSummary?
    @Published var fanXPRewardOverlay = FanXPRewardOverlayManager()
    /// When set, ``PublicProfileOverlayWindowPresenter`` shows ``PublicUserProfilePreviewView`` in a top-level UIWindow (not a SwiftUI sheet).
    @Published var publicProfileSheetUserId: UUID?
    /// Latest avatar-tap context for presentation debug (not shown in UI).
    @Published var publicProfilePresentationContext: String?
    @Published var eventLoadError: String?
    @Published var bars: [BarVenue] = [] {
        didSet {
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "bars")
        }
    }
    @Published var isLoadingMapVenues: Bool = false
    /// True while map venues are re-fetched but existing ``bars`` should stay visible (Phase 1 perf).
    @Published var isRefreshingMapVenues: Bool = false
    @Published var calendarUsesVisibleMapRegionOnly: Bool = false
    @Published var mapDisplayMode: DiscoverMapDisplayMode = .allSpots {
        didSet {
            guard oldValue != mapDisplayMode else { return }
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "mapDisplayMode")
        }
    }
    @Published var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
            span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.55)
        )
    )
    /// Last known GPS fix for the signed-in user (Discover weather, “my location”, startup centering).
    @Published var currentUserLocation: CLLocationCoordinate2D?
    @Published var calendarSyncMessage: String = ""
    @Published var venueEventRows: [VenueEventRow] = [] {
        didSet {
            scheduleFanChatAppLevelRealtimeForLoadedVenueEvents()
            scheduleDiscoverMapRenderSnapshotRebuild(reason: "venueEventRows")
#if DEBUG
            print("[VenueGameCardStoreDebug] initialTrigger source=venueEventRows")
#endif
            scheduleInitialVenueGameCardGoingRefresh(reason: "venueEventRows")
        }
    }
    @Published private(set) var discoverMapRenderSnapshot = DiscoverMapRenderSnapshot.empty
    /// Monotonic fence for detached Discover map snapshot builds; only the latest request may publish.
    var discoverMapRenderSnapshotGeneration: UInt64 = 0
    /// Bottom-tab Calendar selected (updated by ``MainTabView``); gates calendar-only preload/enrichment while tab is preserved off-screen.
    var isCalendarTabSelected = false
    /// When true, ``scheduleDiscoverMapRenderSnapshotRebuild(reason:)`` is a no-op until a single ``flushDiscoverMapRenderSnapshotRebuild(reason:)``.
    var suppressDiscoverSnapshotRebuilds = false
    /// Currently running detached Discover map snapshot build; cancelled when a newer rebuild supersedes it.
    var activeDiscoverSnapshotTask: Task<DiscoverMapSnapshotDetachedOutput?, Never>?
    var discoverSnapshotRebuildCoalesceTask: Task<Void, Never>?
    var discoverSnapshotPendingRebuildReason: String?
    let discoverSnapshotRebuildCoalesceNanoseconds: UInt64 = 100_000_000
    /// Start-of-day keys for calendar green dots (region + sport aware via ``eventsForCalendarDots``).
    @Published var calendarDotDates: Set<Date> = []
    /// Discover calendar overlay: venue ``venue_events`` days from RPC (green dots; Venues map mode only).
    @Published var venueGameCalendarDotDates: Set<Date> = []
    /// Discover calendar overlay: pickup ``game_start_at`` days in the month window (blue dots; Pickup games map mode only).
    @Published var pickupGameCalendarDotDates: Set<Date> = []
    /// Discover map calendar: venue-game dot RPC in flight (see ``loadVenueGameCalendarDotsForDiscover``).
    @Published var isLoadingVenueCalendarDots: Bool = false
    /// Discover map calendar: pickup-game dot fetch in flight (see ``loadPickupGameCalendarDotsForDiscover``).
    @Published var isLoadingPickupCalendarDots: Bool = false
    @Published var calendarDotStatusText: String?
    @Published var currentUserDisplayName: String = ""
    /// Stored without `@`, lowercase — public FanGeo handle.
    @Published var currentUserUsername: String = ""
    @Published var currentUserBio: String = ""
    @Published var currentUserIsBusinessAccount: Bool = false
    @Published var currentUserAvatarURL: String = ""
    @Published var currentUserAvatarThumbnailURL: String = ""
    @Published var currentUserNationalTeam: NationalTeamIdentity?
    @Published var isAuthSessionRestoringForProfilePresentation: Bool = false
    @Published var isUserProfileLoadingForPresentation: Bool = false
    @Published var hasLoadedUserProfileForPresentation: Bool = false
    @Published var userProfileExistsForPresentation: Bool = false
    @Published var currentUserLiveVisibilityEnabled: Bool = true
    @Published var currentUserLiveVisibilityMode: LiveVisibilityMode = .allFriends
    @Published var currentUserSelectedLiveVisibilityFriendIDs: Set<UUID> = []
    @Published var currentUserDiscoverableByFans: Bool = true
    @Published var isUpdatingLiveVisibilitySetting: Bool = false
    @Published var isUpdatingProfileDiscoverabilitySetting: Bool = false
    /// Bumped after avatar profile save (and related clears) so UI uses a new `?v=` display URL while stored URLs stay canonical.
    @Published var currentUserAvatarDisplayRefreshToken: UUID = UUID()
    var authenticatedBusinessDisplayNameForSocialFeatures: String {
        if isVenueOwnerLoggedIn {
            if let firstNamed = ownedBusinesses
                .map(\.display_name)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { !$0.isEmpty }) {
                return firstNamed
            }
            let ownerEmail = OwnerBusinessEmail.normalized(venueOwnerEmail)
            if !ownerEmail.isEmpty {
                return ownerEmail
            }
        }
        return ""
    }
    var authenticatedSocialDisplayName: String {
        if !authenticatedBusinessDisplayNameForSocialFeatures.isEmpty {
            return authenticatedBusinessDisplayNameForSocialFeatures
        }
        let current = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }
        let email = authenticatedSocialEmailForUI
        let local = email.split(separator: "@").first.map(String.init) ?? ""
        return local.isEmpty ? "" : local
    }

    /// Blocks app entry until a new fan sets display name + @handle (empty profile row after signup).
    var needsBlockingFanIdentitySetup: Bool {
        guard isLoggedIn, !isVenueOwnerLoggedIn else { return false }
        guard !isAuthSessionRestoringForProfilePresentation,
              !isUserProfileLoadingForPresentation,
              hasLoadedUserProfileForPresentation,
              userProfileExistsForPresentation else { return false }
        let name = currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let handle = currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty && handle.isEmpty
    }

    var profileEditPresentationEvaluationKey: String {
        [
            isLoggedIn ? "loggedIn" : "loggedOut",
            isVenueOwnerLoggedIn ? "venueOwner" : "fan",
            isAuthSessionRestoringForProfilePresentation ? "restoring" : "restored",
            isUserProfileLoadingForPresentation ? "loading" : "notLoading",
            hasLoadedUserProfileForPresentation ? "loaded" : "notLoaded",
            userProfileExistsForPresentation ? "profileExists" : "profileMissing",
            currentUserAuthId?.uuidString.lowercased() ?? "noAuthId",
            currentUserDisplayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "noName" : "hasName",
            currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "noHandle" : "hasHandle"
        ].joined(separator: "|")
    }

    /// True when no persisted @handle — existing users may still have a display name.
    var needsFanHandleSelection: Bool {
        guard isLoggedIn, !isVenueOwnerLoggedIn else { return false }
        return currentUserUsername.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var currentUserPublicHandleLine: String {
        FanGeoHandleRules.publicHandleLine(
            storedUsername: currentUserUsername,
            email: currentUserEmail
        )
    }
    /// Best-effort current auth email for social UI decisions (comment ownership, friend chips, etc.).
    var authenticatedSocialEmailForUI: String {
        let fan = OwnerBusinessEmail.normalized(currentUserEmail)
        if OwnerBusinessEmail.isValidStrict(fan) { return fan }
        let business = OwnerBusinessEmail.normalized(venueOwnerEmail)
        if OwnerBusinessEmail.isValidStrict(business) { return business }
        return ""
    }
    @Published var goingUserProfiles: [UserProfileRow] = []
    @Published var venueSearchResults: [BarVenue] = []
    /// True while a debounced Discover query is fetching `venues` from Supabase (see ``MapViewModel+DiscoverSearch``).
    @Published var isDiscoverVenueSearchLoading: Bool = false
    /// Discover login gate: set to `true` to switch ``MainTabView`` to Account so the user can sign in (cleared by MainTabView).
    @Published var discoverNavigateToAccountForUserAuth: Bool = false
    /// Account / profile → Discover: focus a venue on the map and open its detail sheet.
    @Published var discoverFocusVenueId: UUID?
    /// Profile empty Home Crowd CTA → switch to Discover tab (cleared by MainTabView).
    @Published var requestDiscoverTabForHomeCrowd = false
    /// When set, ``SettingsScreen`` presents ``SettingsUserAuthSheet`` (same fan sheet as Account tab). Cleared when handled.
    @Published var presentFanUserAuthSheetFromDiscover: Bool = false
    /// Initial mode for ``SettingsUserAuthSheet`` when opened from Discover guest prompts.
    @Published var fanUserAuthSheetOpenInRegisterMode: Bool = false
    /// Following → Saved Venues: Discover tab consumes this to focus the map (see ``MapViewModel+FollowingMapNavigation``).
    @Published var pendingFollowingMapVenueID: UUID?
    /// Venue snapshot from Following so navigation works when ``bars`` does not yet include this id (map region elsewhere).
    @Published var pendingFollowingMapVenueSnapshot: BarVenue?
    /// Brief user-visible hint when opening a saved venue on the map fails (geocode / missing row).
    @Published var followingMapNavigationMessage: String?
    /// Per-venue-event interest avatars (Discover game rows). See ``loadGoingUserProfiles(for:)``.
    @Published var goingProfilesByVenueEventID: [UUID: [UserProfileRow]] = [:]
    var venueEventCommentPreviewCounts: [UUID: Int] {
        get { fanUpdatesStore.venueEventCommentPreviewCounts }
        set { fanUpdatesStore.venueEventCommentPreviewCounts = newValue }
    }
    var venueEventCommentPreviews: [UUID: [VenueEventCommentRow]] {
        get { fanUpdatesStore.venueEventCommentPreviews }
        set { fanUpdatesStore.venueEventCommentPreviews = newValue }
    }
    var fanChatAppLevelRealtimeTask: Task<Void, Never>? {
        get { fanUpdatesStore.fanChatAppLevelRealtimeTask }
        set { fanUpdatesStore.fanChatAppLevelRealtimeTask = newValue }
    }
    var fanChatAppLevelRealtimeChannel: RealtimeChannelV2? {
        get { fanUpdatesStore.fanChatAppLevelRealtimeChannel }
        set { fanUpdatesStore.fanChatAppLevelRealtimeChannel = newValue }
    }
    var fanChatAppLevelRealtimeTrackedEventIDs: [UUID] {
        get { fanUpdatesStore.fanChatAppLevelRealtimeTrackedEventIDs }
        set { fanUpdatesStore.fanChatAppLevelRealtimeTrackedEventIDs = newValue }
    }
    var fanChatAppLevelLastScheduleRequestedEventIDs: [UUID] {
        get { fanUpdatesStore.fanChatAppLevelLastScheduleRequestedEventIDs }
        set { fanUpdatesStore.fanChatAppLevelLastScheduleRequestedEventIDs = newValue }
    }
    var fanChatAppLevelRealtimeResubscribeTask: Task<Void, Never>? {
        get { fanUpdatesStore.fanChatAppLevelRealtimeResubscribeTask }
        set { fanUpdatesStore.fanChatAppLevelRealtimeResubscribeTask = newValue }
    }
    var fanChatAppLevelSeenCommentIDs: Set<UUID> {
        get { fanUpdatesStore.fanChatAppLevelSeenCommentIDs }
        set { fanUpdatesStore.fanChatAppLevelSeenCommentIDs = newValue }
    }
    var fanChatCommentCountReconcileTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanChatCommentCountReconcileTasks }
        set { fanUpdatesStore.fanChatCommentCountReconcileTasks = newValue }
    }
    var fanUpdatesCommentPrefetchTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanUpdatesCommentPrefetchTasks }
        set { fanUpdatesStore.fanUpdatesCommentPrefetchTasks = newValue }
    }
    var fanUpdatesVibePrefetchTasks: [UUID: Task<Void, Never>] {
        get { fanUpdatesStore.fanUpdatesVibePrefetchTasks }
        set { fanUpdatesStore.fanUpdatesVibePrefetchTasks = newValue }
    }
    var discoverVisibleSocialPrefetchTasksByKey: [String: Task<Void, Never>] = [:]
    var fanUpdatesGoingProfilePrefetchTasks: [UUID: Task<Void, Never>] = [:]
    var fanUpdatesCommentPrefetchedAt: [UUID: Date] {
        get { fanUpdatesStore.fanUpdatesCommentPrefetchedAt }
        set { fanUpdatesStore.fanUpdatesCommentPrefetchedAt = newValue }
    }
    var fanUpdatesVibePrefetchedAt: [UUID: Date] {
        get { fanUpdatesStore.fanUpdatesVibePrefetchedAt }
        set { fanUpdatesStore.fanUpdatesVibePrefetchedAt = newValue }
    }
    var venueEventCommentReactionLastRefreshAt: [UUID: Date] {
        get { fanUpdatesStore.venueEventCommentReactionLastRefreshAt }
        set { fanUpdatesStore.venueEventCommentReactionLastRefreshAt = newValue }
    }
    var fanUpdatesGoingProfilePrefetchedAt: [UUID: Date] = [:]

    // MARK: - Pickup games (fan-created; see ``MapViewModel+PickupGames``)

    @Published var pickupGamesForDiscoverMap: [PickupGameRow] = []
    @Published var selectedPickupGameForMap: PickupGameRow?
    @Published var myPickupGamesForSettings: [PickupGameRow] = []
    /// Organizer soft-deleted games (`status = removed`), shown under History in Settings.
    @Published var myRemovedPickupGamesForSettings: [PickupGameRow] = []
    @Published var isLoadingPickupGamesForMap: Bool = false
    /// Phase 2: pending / approved join request counts per game (organizer only; keyed by `pickup_games.id`).
    @Published var pickupOrganizerJoinStatsByGameId: [UUID: PickupOrganizerJoinStats] = [:]
    /// Join requests in `cancelled` / `withdrawn` state for games the user hosts (Settings → My pickup games).
    @Published var pickupOrganizerWithdrawnRequestsByGameId: [UUID: [PickupGameRequestRow]] = [:]
    /// Approved joiner user ids per hosted game (Settings roster strip); ordered from `pickup_game_requests` without extra joins.
    @Published var pickupOrganizerApprovedJoinerUserIdsByGameId: [UUID: [UUID]] = [:]
    /// Fan pickup creators: total `pending` join requests across their active games (Account tab avatar badge).
    @Published var pendingPickupGameJoinRequestCount: Int = 0
    /// Phase 2: latest join request from the current user per game (Discover detail / button state).
    @Published var pickupMyLatestJoinRequestByGameId: [UUID: PickupGameRequestRow] = [:]
    /// Phase 2: resolved creator display names for pickup detail (never stores email in UI).
    @Published var pickupCreatorDisplayNameByUserId: [UUID: String] = [:]
    /// Creator profile fields from `user_profiles` for pickup detail avatar (no schema change).
    @Published var pickupCreatorAvatarThumbnailURLByUserId: [UUID: String] = [:]
    @Published var pickupCreatorAvatarURLByUserId: [UUID: String] = [:]
    @Published var pickupCreatorEmailByUserId: [UUID: String] = [:]
    @Published var pickupCreatorAvatarTokenByUserId: [UUID: UUID] = [:]
    /// Join-request requester rows from `user_profiles` (Settings → My pickup games → Manage Requests).
    @Published var pickupJoinRequesterProfileByUserId: [UUID: UserProfileRow] = [:]
    /// Bumped when a join-requester profile loads so ``UserAvatarView`` refreshes thumbnails.
    @Published var pickupJoinRequesterAvatarTokenByUserId: [UUID: UUID] = [:]
    /// Discover map segmented control: venue clusters vs pickup pins only.
    @Published var discoverMapContentMode: DiscoverMapContentMode = .venues
    /// When `true`, entering pickup map mode should run ``refreshPickupGamesForDiscoverMap()`` (cleared after a successful refresh).
    var pickupDiscoverCoordinatorDirty: Bool = true

    // MARK: - Following tab (global; independent of Discover map region)

    /// Saved venues resolved from `favorite_venues` + `venues` by id (not filtered through ``bars``).
    @Published var followingTabSavedVenues: [BarVenue] = []
    /// Last successful ``refreshFollowingTabDataGlobally()`` completion (not published — avoids tab body churn).
    var lastFollowingTabGlobalRefreshAt: Date?
    /// Debounced Following Going-list reconcile after Discover card toggles (not published).
    var followingTabGoingReconcileTask: Task<Void, Never>?
    /// Games the user is going / interested in, loaded from Supabase + venue rows, independent of ``venueEventRows``.
    @Published var followingTabGoingItems: [FollowingGoingDisplayItem] = []
    /// Going / interest counts for ``followingTabGoingItems`` ids only (does not depend on map-visible interest fetch).
    @Published var followingTabGoingInterestCounts: [UUID: Int] = [:]
    /// All `venue_event_interests` rows for the current user (global), for Following attendance UI.
    @Published var followingTabUserVenueEventInterestIDs: Set<UUID> = []
    /// Following → Games to Play: pickup join requests for the current user (see ``loadMyPickupGameJoinRequestsForFollowing()``).
    @Published var myPickupGameJoinRequestCards: [PickupGameJoinRequestCardDisplay] = []
    /// Latest join request row per pickup game for the signed-in fan (includes declined/rejected; excludes nothing except empty fetch). Following / pickup detail surfaces.
    @Published var pickupJoinRequestLatestByPickupGameIdForFan: [UUID: PickupGameRequestRow] = [:]
    /// Bumped when join-request rows affecting organizer summaries may have changed (realtime / withdraw); drives ``PickupOrganizerRequestsSheet`` reload.
    @Published var pickupOrganizerRequestsSyncGeneration: UInt64 = 0
    /// Bumped after join-request mutations so pickup detail sheets reload request + counts.
    @Published var pickupJoinRequestUiRevision: UInt64 = 0
    /// Orange Following-tab / Games-to-Play activity: join/game field changed since last viewed Games to Play.
    @Published var hasUnreadPickupActivity: Bool = false
    /// Count of pickup games with unread activity (segment badge + tab hint).
    @Published var pickupActivityCount: Int = 0
    /// Account-tab badge when incoming pokes are newer than last acknowledgment.
    @Published var hasUnseenPokes: Bool = false
    @Published var unseenPokesCount: Int = 0
    /// Latest incoming poke timestamp from the most recent fetch (badge + acknowledgment).
    var latestTrackedIncomingPokeAt: Date?
    /// Last successful Following pickup join-card reload; non-published so tab freshness checks do not redraw roots.
    var lastSuccessfulFollowingJoinRequestsRefreshAt: Date?
    var lastSuccessfulFollowingJoinRequestsRefreshUserId: UUID?
    /// Last successful Following pickup join-list reload (Games to Play).
    @Published var lastJoinStatusRefreshAt: Date?
    /// Latest join request status string per pickup game id after the last reload (`pending`, `approved`, …).
    @Published var lastKnownJoinStatus: [UUID: String] = [:]
    /// Global pull-to-refresh / timer in progress for Games to Play list.
    @Published var isPickupFollowingJoinListRefreshing: Bool = false
    /// Per-game unread activity (card dot) until user opens Games to Play or refreshes that card.
    @Published var pickupFollowingUnreadActivityGameIds: Set<UUID> = []
    /// Manual per-card refresh spinner.
    @Published var pickupFollowingCardRefreshSpinGameId: UUID?
    /// Ensures ``resolvedPickupGameRow(for:)`` can open detail from Following when the game is not on the Discover map cache.
    var pickupGamesFollowingTabCache: [UUID: PickupGameRow] = [:]
    /// Organizer pickup trust line (avg stars + count); from ``pickup_creator_public_rating_stats`` RPC.
    @Published var pickupCreatorPublicRatingStatsByUserId: [UUID: PickupCreatorPublicRatingStats] = [:]
    /// Pickup games the current user has already submitted an organizer rating for.
    @Published var pickupGameIdsWithMyCreatorRating: Set<UUID> = []

    // MARK: - Venue owner analytics (realtime)

    /// Postgres changes listener for ``VenueOwnerDashboardView`` analytics tab.
    var venueOwnerAnalyticsRealtimeTask: Task<Void, Never>?
    var venueOwnerAnalyticsRealtimeChannel: RealtimeChannelV2?
    var venueOwnerAnalyticsDebounceTask: Task<Void, Never>?
    /// Realtime: ``pickup_game_requests`` for the signed-in fan creator’s game ids (tab-bar pending badge).
    var pickupJoinRequestBadgeRealtimeTask: Task<Void, Never>?
    var pickupJoinRequestBadgeRealtimeChannel: RealtimeChannelV2?
    var pickupJoinRequestBadgeDebounceTask: Task<Void, Never>?
    /// Realtime: requester’s join rows + followed pickup games (Following → Games to Play).
    var pickupFollowingRealtimeTask: Task<Void, Never>?
    var pickupFollowingRealtimeChannel: RealtimeChannelV2?
    /// Fan single-device session enforcement (`user_profiles.active_session_id`).
    var fanSingleSessionRealtimeChannel: RealtimeChannelV2?
    var fanSingleSessionRealtimeTask: Task<Void, Never>?
    var fanSingleSessionRealtimeDebounceTask: Task<Void, Never>?
    var isPerformingSingleSessionLogout = false
    var singleSessionIgnoreRealtimeUntil: Date?
    var pickupFollowingRealtimeDebounceTask: Task<Void, Never>?
    /// First successful Games-to-Play load completed; suppresses marking everything unread on cold start.
    var pickupFollowingActivityPrimed: Bool = false
    /// Per-game signature last acknowledged by the user (Games to Play visible or per-card refresh).
    var pickupFollowingSeenActivitySignatureByGameId: [UUID: String] = [:]
    /// User’s 1–5 star rating per venue (local only).
    @Published var venueUserStarRatings: [UUID: Int] = [:]
    /// How many times the user saved a rating (drives review count display).
    @Published var venueRatingContributionCount: [UUID: Int] = [:]

    enum MapPinDisplayMode {
        case simple
        case compact
        case detailed
    }

    let eventStore = EKEventStore()
    
    let sports = SampleData.sports
    let venueEvents = SampleData.venueEvents
    let venueExperiences = SampleData.venueExperiences
    let reminderMinuteOptions = [15, 30, 60, 120, 180, 1440]
    let repeatMinuteOptions = [15, 30, 60, 120]

    init() {
        #if DEBUG
        print("[FanUpdatesStoreMigrationDebug] RemovedMapViewModelBridge=true")
        #endif
    }

    func applyDiscoverMapRenderSnapshot(_ snapshot: DiscoverMapRenderSnapshot) {
        discoverMapRenderSnapshot = snapshot
    }

    // MARK: - Discover / map venue_events fetch cache (region + sport + date window)

    /// In-memory reuse for identical region/sport/window fetches (see ``MapViewModel+VenueAndGameData``).
    var discoverVenueEventsFetchCache: (key: String, rows: [VenueEventRow], fetchedAt: Date)?
    /// Short-lived viewport cache for lightweight Discover venue rows (Phase 1 pins).
    var discoverViewportVenueRowsCache: [String: DiscoverViewportVenueRowsCacheEntry] = [:]
    /// Short-lived selected-day cache for visible Discover venue events (date + sport + visible venue context).
    var discoverSelectedDayVenueEventsCache: [String: (rows: [VenueEventRow], fetchedAt: Date)] = [:]
    /// Latest visible Discover venue context so date changes can reuse current pins without reloading venues.
    var discoverCurrentVisibleVenueRows: [VenueRow] = []
    var discoverCurrentVisibleVenueIds: [UUID] = []
    var discoverCurrentVisibleOwnerEmails: [String] = []
    var discoverCurrentVisibleVenueNames: [String] = []

    /// Memo for ``clusteredBars()`` so SwiftUI map body does not rebuild clusters every frame.
    var discoverClusteredBarsCacheKey: String?
    var discoverClusteredBarsCache: [VenueCluster]?
    /// Memo for ``clusteredPickupGamesForDiscoverMap(rows:)`` (pickup map mode only).
    var discoverPickupClustersCacheKey: String?
    var discoverPickupClustersCache: [PickupGameCluster]?

    /// Cancels stale debounced Discover search updates when ``searchText`` changes quickly.
    var discoverSearchDebounceTask: Task<Void, Never>?

    /// Discover-only: when set, ``pruneSelectionIfNeededAfterFilterChange()`` keeps ``selectedBar`` even if this id is absent from ``bars`` (remote text search venue with no games — not a default map pin).
    var discoverRemotePreviewHoldVenueId: UUID?

    /// Set when ``renderCachedDiscoverCore()`` (async) applied a disk snapshot this launch; suppresses empty-state loading chrome until fresh fetches finish.
    var discoverSnapshotRestoredThisLaunch = false

    /// Startup Discover: one-shot location + 15 mi region; ``defer`` arms preload completion logging even if the task is cancelled mid-await.
    var didFinishStartupDiscoverPrepare = false
    /// When true, the next ``refreshDiscoverCoreInBackground()`` logs ``[StartupDiscover] preloadCompleted`` (DEBUG).
    var startupDiscoverPreloadCompletionLogPending = false

    /// After the first successful Supabase games load, prefer ``isRefreshingDiscoverEvents`` over blocking ``isLoadingEvents``.
    var didCompleteSuccessfulGamesFetch = false

    /// Coalesces overlapping ``loadGamesFromSupabase()`` / ``refreshDiscoverCoreInBackground`` schedule work onto one serial chain.
    var loadGamesCoalesceTask: Task<Void, Never>?
    var loadGamesCoalesceNeedsAnotherPass = false
    /// Coalesces Calendar Live refreshes; no continuous UI polling.
    var liveMatchesRefreshTask: Task<Void, Never>?
    /// Fire-and-forget phase-3 Discover enrichment after pins are visible.
    var discoverFullEnrichmentTask: Task<Void, Never>?
    /// One-shot pickup calendar + map-row warmup after enrichment (not triggered by map pan).
    var discoverPickupMetadataPreloadTask: Task<Void, Never>?
    var discoverPickupMetadataPreloadCompleted = false
    var loadVenuesRequestID: UUID?
    var discoverSelectedDayRefreshTask: Task<Void, Never>?
    var discoverSelectedDayRefreshRequestID: UUID?
    var venueCalendarDotLoadTask: Task<Void, Never>?
    var pickupCalendarDotLoadTask: Task<Void, Never>?
    var venueCalendarDotLoadRequestID: UUID?
    var pickupCalendarDotLoadRequestID: UUID?
    /// Serializes overlapping ``refreshPickupGamesForDiscoverMap`` calls so calendar open + dot preload do not stack duplicate Supabase fetches.
    var refreshPickupGamesForDiscoverMapCoalescingTask: Task<Void, Never>?
    var pickupDiscoverEnrichmentRequestID: UUID?
    var mapStatusDismissTask: Task<Void, Never>?
    var socialActionToastDismissTask: Task<Void, Never>?

    /// Bumped when schedule-related data changes so calendar caches and dot fingerprints invalidate cheaply.
    var scheduleDataGeneration: UInt64 = 0

    /// Last inputs used for ``calendarDotDates``; avoids rescanning ``events`` when nothing relevant changed.
    var lastCalendarDotRecomputeKey: String?

    /// Short-lived Calendar tab list cache (see ``calendarScreenDisplayedEvents``; key includes ``CalendarTabGameFilter``).
    var calendarEventsListCache: [String: (storedAt: Date, events: [SportsEvent])] = [:]
    var venueGameCalendarDotDatesCache: [String: (dates: Set<Date>, fetchedAt: Date)] = [:]
    var pickupGameCalendarDotDatesCache: [String: (dates: Set<Date>, fetchedAt: Date)] = [:]
}
