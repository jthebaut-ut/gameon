import Foundation
import SwiftUI
import MapKit
import Combine
import CoreLocation
import EventKit

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
    @Published var venueCrowdPhotoURL = ""
    @Published var venueTVWallPhotoURL = ""
    @Published var venueMenuPhotoURL = ""
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
    @Published var calendarUsesVisibleMapRegionOnly: Bool = false
    @Published var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 40.3916, longitude: -111.8508),
            span: MKCoordinateSpan(latitudeDelta: 0.55, longitudeDelta: 0.55)
        )
    )
    @Published var calendarSyncMessage: String = ""
    @Published var venueEventRows: [VenueEventRow] = []
    @Published var currentUserDisplayName: String = ""
    @Published var currentUserAvatarURL: String = ""
    @Published var goingUserProfiles: [UserProfileRow] = []
    @Published var venueSearchResults: [BarVenue] = []

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
    
}
