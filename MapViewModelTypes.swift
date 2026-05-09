import Foundation
import CoreLocation

enum TimeZoneOption: String, CaseIterable, Identifiable {
    case mountain = "Mountain Time"
    case pacific = "Pacific Time"
    case central = "Central Time"
    case eastern = "Eastern Time"
    case utc = "UTC"

    var id: String { rawValue }

    var abbreviation: String {
        switch self {
        case .mountain: return "MT"
        case .pacific: return "PT"
        case .central: return "CT"
        case .eastern: return "ET"
        case .utc: return "UTC"
        }
    }

    var identifier: String {
        switch self {
        case .mountain: return "America/Denver"
        case .pacific: return "America/Los_Angeles"
        case .central: return "America/Chicago"
        case .eastern: return "America/New_York"
        case .utc: return "UTC"
        }
    }
}

struct VenueEventInsert: Encodable {
    let owner_email: String
    let venue_name: String
    let event_title: String
    let sport: String
    let event_date: String
    let event_time: String
    let sound_on: Bool
    let audio_type: String
    let drink_special: String
    let cover_charge: String
    let expected_crowd: String
    let available_seating: String
    let reservations_available: Bool
    let waitlist_available: Bool
   
}

struct VenueProfileInsert: Encodable {
    let owner_email: String
    let venue_name: String
    let address: String
    let city: String
    let state: String
    let zip_code: String
    let phone: String
    let website: String
    let description: String
    let features: String
    let screen_count: Int
    let serves_food: Bool
    let has_wifi: Bool
    let has_garden: Bool
    let has_projector: Bool
    let pet_friendly: Bool
    let latitude: Double?
    let longitude: Double?
    let cover_photo_url: String
    let menu_photo_url: String
}

struct VenueProfileRow: Decodable {
    let owner_email: String?
    let venue_name: String?
    let address: String?
    let city: String?
    let state: String?
    let zip_code: String?
    let phone: String?
    let website: String?
    let description: String?
    let features: String?
    let screen_count: Int?
    let serves_food: Bool?
    let has_wifi: Bool?
    let has_garden: Bool?
    let has_projector: Bool?
    let pet_friendly: Bool?
    let cover_photo_url: String?
    let menu_photo_url: String?
}

struct VenueRow: Decodable {
    let id: UUID?
    let owner_email: String?
    let venue_name: String?
    let address: String?
    let city: String?
    let state: String?
    let zip_code: String?
    let phone: String?
    let website: String?
    let description: String?
    let features: String?
    let screen_count: Int?
    let serves_food: Bool?
    let has_wifi: Bool?
    let has_garden: Bool?
    let has_projector: Bool?
    let pet_friendly: Bool?
    let latitude: Double?
    let longitude: Double?
    let cover_photo_url: String?
    let menu_photo_url: String?
}

struct VenueClaimInsert: Encodable {
    let owner_email: String
    let venue_name: String
    let venue_address: String
    let venue_city: String
    let venue_state: String
    let venue_zip_code: String
    let venue_phone: String
    let venue_website: String
    let venue_description: String
    let venue_features: String
    let screen_count: Int
    let serves_food: Bool
    let has_wifi: Bool
    let has_garden: Bool
    let has_projector: Bool
    let pet_friendly: Bool
    let cover_photo_url: String
    let menu_photo_url: String
    let proof_note: String
}

struct VenueEventInterestInsert: Encodable {
    let venue_event_id: UUID
    let user_email: String
}

struct VenueEventInterestRow: Decodable {
    let id: String?
    let venue_event_id: UUID?
    let user_email: String?
}

struct VenueCluster: Identifiable {
    /// Stable across renders so `ForEach` / Map annotations can diff instead of recreating every frame.
    let id: String
    let bars: [BarVenue]
    let coordinate: CLLocationCoordinate2D

    var count: Int {
        bars.count
    }
}
struct UserProfileRow: Decodable {
    let id: UUID?
    let email: String?
    let display_name: String?
    let avatar_url: String?
}

struct UserProfileInsert: Encodable {
    let email: String
    let display_name: String
    let avatar_url: String
}

struct FavoriteVenueRow: Decodable {
    let id: UUID?
    let user_email: String?
    let venue_id: UUID?
}

struct FavoriteVenueInsert: Encodable {
    let user_email: String
    let venue_id: UUID
}

struct VenueEventCommentRow: Decodable, Identifiable {
    let id: UUID?
    let venue_event_id: UUID?
    let user_email: String?
    let comment: String?
    let created_at: String?
}

struct VenueEventCommentInsert: Encodable {
    let venue_event_id: UUID
    let user_email: String
    let comment: String
}

struct CommentReportInsert: Encodable {
    let comment_id: UUID
    let venue_event_id: UUID
    let reporter_email: String
    let reason: String
}

struct CommentReportRow: Decodable, Identifiable {
    let id: UUID?
    let comment_id: UUID?
    let venue_event_id: UUID?
    let reporter_email: String?
    let reason: String?
    let created_at: String?
}

struct ReportedCommentDisplay: Identifiable {
    let id = UUID()

    let reportID: UUID?
    let commentID: UUID?

    let commentText: String

    let reporterEmail: String
    let reporterName: String

    let reportedAt: String

    let commenterName: String
    let commenterAvatarURL: String

    let venueName: String
    let eventTitle: String
}

struct VenueEventVibeRow: Decodable {
    let id: UUID?
    let venue_event_id: UUID?
    let user_email: String?
    let vibe_type: String?
    let created_at: String?
}

struct VenueEventVibeInsert: Encodable {
    let venue_event_id: UUID
    let user_email: String
    let vibe_type: String
}
