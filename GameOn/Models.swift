import Foundation
import CoreLocation

struct SportsEvent: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let sport: String
    let league: String
    let date: Date
    let time: String
    let country: String

    init(id: UUID = UUID(), title: String, sport: String, league: String, date: Date, time: String, country: String) {
        self.id = id
        self.title = title
        self.sport = sport
        self.league = league
        self.date = date
        self.time = time
        self.country = country
    }
}

struct BarVenue: Identifiable, Equatable {
    let id: UUID
    let name: String
    let address: String
    let phone: String
    let primarySport: String
    let distance: String
    let rating: Double
    let tags: [String]
    let games: [String]
    let coordinate: CLLocationCoordinate2D
    let goingCounts: [String: Int]
    let screenCount: Int
    let servesFood: Bool
    let hasWifi: Bool
    let hasGarden: Bool
    let hasProjector: Bool
    let petFriendly: Bool

    // New photo URLs
    let coverPhotoURL: String?
    let menuPhotoURL: String?
    let coverPhotoThumbnailURL: String?
    let menuPhotoThumbnailURL: String?

    /// Supabase `venues.owner_email` when known (Discover scoped queries / venue_event lookup).
    let ownerEmail: String?
    /// Supabase `venues.business_id` when known (multi-venue businesses).
    let businessId: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        address: String,
        phone: String,
        primarySport: String,
        distance: String,
        rating: Double,
        tags: [String],
        games: [String],
        coordinate: CLLocationCoordinate2D,
        goingCounts: [String: Int],
        screenCount: Int = 2,
        servesFood: Bool = true,
        hasWifi: Bool = true,
        hasGarden: Bool = false,
        hasProjector: Bool = false,
        petFriendly: Bool = false,
        coverPhotoURL: String? = nil,
        menuPhotoURL: String? = nil,
        coverPhotoThumbnailURL: String? = nil,
        menuPhotoThumbnailURL: String? = nil,
        ownerEmail: String? = nil,
        businessId: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.phone = phone
        self.primarySport = primarySport
        self.distance = distance
        self.rating = rating
        self.tags = tags
        self.games = games
        self.coordinate = coordinate
        self.goingCounts = goingCounts
        self.screenCount = screenCount
        self.servesFood = servesFood
        self.hasWifi = hasWifi
        self.hasGarden = hasGarden
        self.hasProjector = hasProjector
        self.petFriendly = petFriendly
        self.coverPhotoURL = coverPhotoURL
        self.menuPhotoURL = menuPhotoURL
        self.coverPhotoThumbnailURL = coverPhotoThumbnailURL
        self.menuPhotoThumbnailURL = menuPhotoThumbnailURL
        self.ownerEmail = ownerEmail
        self.businessId = businessId
    }

    static func == (lhs: BarVenue, rhs: BarVenue) -> Bool {
        lhs.id == rhs.id
    }
}

struct VenueEvent: Identifiable, Equatable {
    let id: UUID
    let venueName: String
    let eventTitle: String
    let confirmedShowing: Bool
    let soundOn: Bool
    let special: String?
    let goingCount: Int

    init(
        id: UUID = UUID(),
        venueName: String,
        eventTitle: String,
        confirmedShowing: Bool,
        soundOn: Bool,
        special: String?,
        goingCount: Int
    ) {
        self.id = id
        self.venueName = venueName
        self.eventTitle = eventTitle
        self.confirmedShowing = confirmedShowing
        self.soundOn = soundOn
        self.special = special
        self.goingCount = goingCount
    }
}

struct VenueClaim: Identifiable, Equatable {
    let id: UUID
    let venueName: String
    let address: String
    let businessEmail: String
    let phone: String
    let website: String
    let proofNote: String
    let primarySport: String
    var status: VenueClaimStatus
}

enum VenueClaimStatus: String {
    case pending = "Pending Review"
    case approved = "Approved"
    case rejected = "Rejected"
}

enum VenueAudioType: String, CaseIterable, Identifiable, Codable {
    case full = "Game audio everywhere"
    case partial = "Some TVs with audio"
    case none = "No confirmed game audio"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .full:
            return "speaker.wave.2.fill"
        case .partial:
            return "speaker.wave.1.fill"
        case .none:
            return "speaker.slash.fill"
        }
    }
}

struct VenueExperience: Identifiable, Equatable {
    let id: UUID
    let venueName: String
    let atmosphere: String
    let crowdLevel: String
    let teamFanbases: [String]
    let hasAudio: Bool
    let drinkSpecials: String
    let availableSeating: String
    let coverCharge: String
    let reservationsAvailable: Bool
    let waitlistAvailable: Bool
    let socialCoordination: String
    let liveOccupancy: String

    init(
        id: UUID = UUID(),
        venueName: String,
        atmosphere: String,
        crowdLevel: String,
        teamFanbases: [String],
        hasAudio: Bool,
        drinkSpecials: String,
        availableSeating: String,
        coverCharge: String,
        reservationsAvailable: Bool,
        waitlistAvailable: Bool,
        socialCoordination: String,
        liveOccupancy: String
    ) {
        self.id = id
        self.venueName = venueName
        self.atmosphere = atmosphere
        self.crowdLevel = crowdLevel
        self.teamFanbases = teamFanbases
        self.hasAudio = hasAudio
        self.drinkSpecials = drinkSpecials
        self.availableSeating = availableSeating
        self.coverCharge = coverCharge
        self.reservationsAvailable = reservationsAvailable
        self.waitlistAvailable = waitlistAvailable
        self.socialCoordination = socialCoordination
        self.liveOccupancy = liveOccupancy
    }
}

struct VenueClaimRow: Codable {
    let id: String?
    let created_at: String?
    let owner_email: String?
    /// ``public.venues.id`` when present; nil for legacy claims (Phase B1 column).
    let venue_id: UUID?
    let venue_name: String?
    let venue_address: String?
    let venue_phone: String?
    let venue_website: String?
    let proof_note: String?
    let approval_status: String?
    /// Set when the business owner dismisses a rejection in Settings (claim remains in DB).
    let rejection_acknowledged_at: String?
}

struct VenueEventRow: Codable {
    let id: UUID?

    /// Canonical link to ``venues.id`` when set; legacy matching uses ``owner_email`` / ``venue_name`` when nil.
    let venue_id: UUID?

    let owner_email: String?
    let venue_name: String?
    
    let event_title: String?
    let sport: String?
    
    let event_date: String?
    let event_time: String?
    
    let sound_on: Bool?
    
    let drink_special: String?
    let cover_charge: String?
    
    let expected_crowd: String?
    let available_seating: String?
    
    let reservations_available: Bool?
    let waitlist_available: Bool?
    
    let audio_type: String?

    /// Present when selected from Supabase; Discover fetch includes this column for debugging.
    let admin_status: String?
}

struct GameRow: Codable, Identifiable {
    let id: String?
    let external_id: String?
    let source: String?
    let title: String?
    let league: String?
    let sport: String?
    let game_date: String?
    let game_time: String?
    let timezone: String?
    let home_team: String?
    let away_team: String?
    let status: String?
}

struct UserNotificationSettings: Codable, Equatable {
    var notifyBeforeGame: Bool
    var reminderMinutesBefore: Int
    var repeatReminder: Bool
    var repeatEveryMinutes: Int
}
