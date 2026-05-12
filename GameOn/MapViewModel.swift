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
    
    @Published var selectedDate: Date = SampleData.makeDate(year: 2026, month: 6, day: 25)
    @Published var selectedSport: String = "All"
    @Published var selectedEvent: SportsEvent?
    @Published var selectedBar: BarVenue?
    @Published var searchText: String = ""
    /// Debounced copy of ``searchText`` for Discover map/event filtering and live venue suggestions (see ``MapViewModel+DiscoverSearch``).
    @Published var debouncedDiscoverSearchText: String = ""
    @Published var favoriteVenueIDs: Set<UUID> = []
    @Published var interestedVenueEventKeys: Set<String> = []
    /// Prevents overlapping save/remove writes for the same venue while keeping the UI on the optimistic state.
    var favoriteVenueWriteInFlightIDs: Set<UUID> = []
    /// Prevents overlapping going/interested writes for the same event while keeping the UI on the optimistic state.
    var venueEventInterestWriteInFlightIDs: Set<UUID> = []
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
    @Published var ownerVenueCity: String = ""
    @Published var ownerVenueState: String = "UT"
    @Published var ownerVenueZipCode: String = ""
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
    @Published var venueCrowdPhotoURL = ""
    @Published var venueTVWallPhotoURL = ""
    @Published var venueMenuPhotoURL = ""
    @Published var venueMenuPhotoThumbnailURL = ""
    @Published var venueSpecialsPhotoURL = ""
    @Published var ownerVenueScreenCount: Int = 1
    @Published var ownerVenueServesFood: Bool = false
    @Published var ownerVenueHasWifi: Bool = false
    @Published var ownerVenueHasGarden: Bool = false
    @Published var ownerVenueHasProjector: Bool = false
    @Published var ownerVenuePetFriendly: Bool = false
    @Published var venueEventInterestIDs: Set<UUID> = []
    @Published var venueEventInterestCounts: [UUID: Int] = [:]
    @Published var venueEventComments: [UUID: [VenueEventCommentRow]] = [:]
    /// Comment ids the signed-in fan has already reported (from successful submit, duplicate constraint, or REST sync).
    @Published var commentIDsReportedByCurrentUser: Set<UUID> = []
    /// Per-thread realtime listener tasks for venue-event fan updates.
    var venueEventCommentsRealtimeTasks: [UUID: Task<Void, Never>] = [:]
    var venueEventCommentsRealtimeChannels: [UUID: RealtimeChannelV2] = [:]
    var venueEventCommentsRealtimeListenerTokens: [UUID: UUID] = [:]
    @Published var venueEventIDsByKey: [String: UUID] = [:]
    @Published var visibleLatitudeDelta: Double = 0.55
    @Published var userProfilesByEmail: [String: UserProfileRow] = [:]
    @Published var reportedComments: [CommentReportRow] = []
    @Published var reportedCommentDisplays: [ReportedCommentDisplay] = []
    @Published var venueEventVibeCounts: [UUID: [String: Int]] = [:]
    @Published var myVenueEventVibes: [UUID: Set<String>] = [:]
    
    @AppStorage("notifyBeforeGame")
    var notifyBeforeGame: Bool = true

    @AppStorage("reminderMinutesBefore")
    var reminderMinutesBefore: Int = 60

    @AppStorage("repeatGameReminder")
    var repeatGameReminder: Bool = false

    @AppStorage("repeatEveryMinutes")
    var repeatEveryMinutes: Int = 30

    @AppStorage("syncGoingGamesToAppleCalendar")
    var syncGoingGamesToAppleCalendar: Bool = false
    
    @Published var events: [SportsEvent] = SampleData.events
    @Published var isLoadingEvents: Bool = false
    /// True while schedule data is re-fetched but existing ``events``/UI should stay visible (Phase 1 perf).
    @Published var isRefreshingDiscoverEvents: Bool = false
    @Published var isUpdatingMapGames: Bool = false
    @Published var mapStatusText: String?
    @Published var socialActionToastText: String?
    @Published var socialActionToastIsError: Bool = false
    @Published var eventLoadError: String?
    @Published var bars: [BarVenue] = []
    @Published var isLoadingMapVenues: Bool = false
    /// True while map venues are re-fetched but existing ``bars`` should stay visible (Phase 1 perf).
    @Published var isRefreshingMapVenues: Bool = false
    @Published var calendarUsesVisibleMapRegionOnly: Bool = false
    @Published var mapDisplayMode: DiscoverMapDisplayMode = .allSpots
    @Published var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
            span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.55)
        )
    )
    @Published var calendarSyncMessage: String = ""
    @Published var venueEventRows: [VenueEventRow] = []
    /// Start-of-day keys for calendar green dots (region + sport aware via ``eventsForCalendarDots``).
    @Published var calendarDotDates: Set<Date> = []
    /// Discover calendar-only: narrow month-scoped dot dates loaded from nearby venues without waiting for full schedule hydration.
    @Published var discoverCalendarDotDates: Set<Date> = []
    @Published var isLoadingCalendarDots: Bool = false
    @Published var calendarDotStatusText: String?
    @Published var currentUserDisplayName: String = ""
    @Published var currentUserAvatarURL: String = ""
    @Published var currentUserAvatarThumbnailURL: String = ""
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
    /// Following → Saved Venues: Discover tab consumes this to focus the map (see ``MapViewModel+FollowingMapNavigation``).
    @Published var pendingFollowingMapVenueID: UUID?
    /// Venue snapshot from Following so navigation works when ``bars`` does not yet include this id (map region elsewhere).
    @Published var pendingFollowingMapVenueSnapshot: BarVenue?
    /// Brief user-visible hint when opening a saved venue on the map fails (geocode / missing row).
    @Published var followingMapNavigationMessage: String?
    /// Per-venue-event interest avatars (Discover game rows). See ``loadGoingUserProfiles(for:)``.
    @Published var goingProfilesByVenueEventID: [UUID: [UserProfileRow]] = [:]

    // MARK: - Following tab (global; independent of Discover map region)

    /// Saved venues resolved from `favorite_venues` + `venues` by id (not filtered through ``bars``).
    @Published var followingTabSavedVenues: [BarVenue] = []
    /// Games the user is going / interested in, loaded from Supabase + venue rows, independent of ``venueEventRows``.
    @Published var followingTabGoingItems: [FollowingGoingDisplayItem] = []
    /// Going / interest counts for ``followingTabGoingItems`` ids only (does not depend on map-visible interest fetch).
    @Published var followingTabGoingInterestCounts: [UUID: Int] = [:]
    /// All `venue_event_interests` rows for the current user (global), for Following attendance UI.
    @Published var followingTabUserVenueEventInterestIDs: Set<UUID> = []

    // MARK: - Venue owner analytics (realtime)

    /// Postgres changes listener for ``VenueOwnerDashboardView`` analytics tab.
    var venueOwnerAnalyticsRealtimeTask: Task<Void, Never>?
    var venueOwnerAnalyticsRealtimeChannel: RealtimeChannelV2?
    var venueOwnerAnalyticsDebounceTask: Task<Void, Never>?
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

    /// Cancels stale debounced Discover search updates when ``searchText`` changes quickly.
    var discoverSearchDebounceTask: Task<Void, Never>?

    /// Discover-only: when set, ``pruneSelectionIfNeededAfterFilterChange()`` keeps ``selectedBar`` even if this id is absent from ``bars`` (remote text search venue with no games — not a default map pin).
    var discoverRemotePreviewHoldVenueId: UUID?

    /// Set when ``renderCachedDiscoverCore()`` applied a disk snapshot this launch; suppresses empty-state loading chrome until fresh fetches finish.
    var discoverSnapshotRestoredThisLaunch = false

    /// After the first successful Supabase games load, prefer ``isRefreshingDiscoverEvents`` over blocking ``isLoadingEvents``.
    var didCompleteSuccessfulGamesFetch = false

    /// Coalesces overlapping ``loadGamesFromSupabase()`` / ``refreshDiscoverCoreInBackground`` schedule work onto one serial chain.
    var loadGamesCoalesceTask: Task<Void, Never>?
    var loadGamesCoalesceNeedsAnotherPass = false
    /// Fire-and-forget phase-3 Discover enrichment after pins are visible.
    var discoverFullEnrichmentTask: Task<Void, Never>?
    var discoverSelectedDayRefreshTask: Task<Void, Never>?
    var discoverSelectedDayRefreshRequestID: UUID?
    var discoverCalendarDotLoadTask: Task<Void, Never>?
    var discoverCalendarDotLoadRequestID: UUID?
    var mapStatusDismissTask: Task<Void, Never>?
    var socialActionToastDismissTask: Task<Void, Never>?

    /// Bumped when schedule-related data changes so calendar caches and dot fingerprints invalidate cheaply.
    var scheduleDataGeneration: UInt64 = 0

    /// Last inputs used for ``calendarDotDates``; avoids rescanning ``events`` when nothing relevant changed.
    var lastCalendarDotRecomputeKey: String?

    /// Short-lived Calendar tab list cache (see ``calendarScreenDisplayedEvents``).
    var calendarEventsListCache: [String: (storedAt: Date, events: [SportsEvent])] = [:]
    var calendarDotDatesCache: [String: (dates: Set<Date>, fetchedAt: Date)] = [:]
}
