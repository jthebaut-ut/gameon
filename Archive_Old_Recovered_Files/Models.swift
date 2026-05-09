import Foundation
import CoreLocation

struct SportsEvent: Identifiable, Equatable {
    let id: UUID
    let title: String
    let sport: String
    let league: String
    let date: Date
    let time: String
    let country: String
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
}

struct VenueClaimRow: Codable {
    let id: String?
    let created_at: String?
    let owner_email: String?
    let venue_name: String?
    let venue_address: String?
    let venue_phone: String?
    let venue_website: String?
    let proof_note: String?
    let approval_status: String?
}

struct VenueEventRow: Codable {
    let id: UUID?
    
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
