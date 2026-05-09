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
    @Published var favoriteVenueIDs: Set<UUID> = []
    @Published var interestedVenueEventKeys: Set<String> = []
    @Published var selectedTimeZone: TimeZoneOption = .mountain
    @Published var isLoggedIn: Bool = false
    @Published var currentUserEmail: String = ""
    /// Supabase Auth user id; mirrors ``supabase.auth.session.user.id`` when signed in (fan session).
    @Published var currentUserAuthId: UUID?
    @Published var venueOwnerMode: Bool = false
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
    @Published var eventLoadError: String?
    @Published var bars: [BarVenue] = []
    @Published var isLoadingMapVenues: Bool = false
    @Published var calendarUsesVisibleMapRegionOnly: Bool = false
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
    @Published var currentUserDisplayName: String = ""
    @Published var currentUserAvatarURL: String = ""
    @Published var currentUserAvatarThumbnailURL: String = ""
    /// Bumped after avatar profile save (and related clears) so UI uses a new `?v=` display URL while stored URLs stay canonical.
    @Published var currentUserAvatarDisplayRefreshToken: UUID = UUID()
    @Published var goingUserProfiles: [UserProfileRow] = []
    @Published var venueSearchResults: [BarVenue] = []
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

    /// Memo for ``clusteredBars()`` so SwiftUI map body does not rebuild clusters every frame.
    var discoverClusteredBarsCacheKey: String?
    var discoverClusteredBarsCache: [VenueCluster]?
}
