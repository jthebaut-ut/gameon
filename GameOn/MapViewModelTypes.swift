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
    let venue_id: UUID?
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
    /// Discover / owner loaders filter on `active`; set explicitly so inserts never rely on DB default drift.
    let admin_status: String
}

/// Row from `public.businesses` (multi-venue owner Phase B1).
struct BusinessRow: Decodable, Equatable, Identifiable {
    let id: UUID
    let display_name: String
    let owner_email: String?
    let owner_user_id: UUID?
    let admin_status: String
    let created_at: String?
}

/// Client insert for `public.businesses` during business-owner signup (no `venues` row yet).
struct BusinessInsertPayload: Encodable {
    let display_name: String
    let owner_email: String
    let owner_user_id: UUID
    let admin_status: String
}

struct InsertedBusinessIdRow: Decodable {
    let id: UUID
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
    let cover_photo_thumbnail_url: String?
    let menu_photo_thumbnail_url: String?
}

/// PATCH body for `venues` when updating an existing row by id (multi-venue owner Phase B2 — no upsert on `owner_email`).
struct VenueProfileUpdate: Encodable {
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
    let cover_photo_thumbnail_url: String?
    let menu_photo_thumbnail_url: String?
}

struct VenueProfileRow: Decodable {
    let id: UUID?
    let owner_email: String?
    /// `public.venues.business_id` when present (multi-venue owner Phase B1); omitted in older API responses decodes as nil.
    let business_id: UUID?
    /// `public.venues.admin_status` (`active` / `archived`); omitted in older payloads.
    let admin_status: String?
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
    let cover_photo_thumbnail_url: String?
    let menu_photo_thumbnail_url: String?
}

struct VenueRow: Decodable {
    let id: UUID?
    let owner_email: String?
    /// Multi-venue businesses (nullable / omitted for legacy rows).
    let business_id: UUID?
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
    let cover_photo_thumbnail_url: String?
    let menu_photo_thumbnail_url: String?
}

/// Drives Settings → Business → Location status row (icon / tint) without inferring approval from legacy claim flags alone.
enum BusinessSettingsLocationChrome: Equatable {
    case needsBusinessAccountFirst
    case approved
    case pendingReview
    case rejected
    case noLocationsYet
}

/// Full-field payload for Settings → Add location → ``venue_claims`` (no public ``venues`` row until admin approval).
struct AddLocationClaimForm: Sendable {
    let venueName: String
    let address: String
    let city: String
    let state: String
    /// Stored as 2-letter US abbreviation (e.g. `UT`, `CA`).
    let country: String
    let zip: String
    let phone: String
    let website: String
    let description: String
    let proofNote: String
    let screenCount: Int
    let servesFood: Bool
    let hasWifi: Bool
    let hasGarden: Bool
    let hasProjector: Bool
    let petFriendly: Bool
    let familyFriendly: Bool
    let parkingAvailable: Bool
    let coverPhotoURL: String
    let menuPhotoURL: String

    /// Human-readable feature line stored in ``venue_claims.venue_features`` (schema has no separate columns for parking / family).
    func mergedVenueFeaturesLine() -> String {
        var bits: [String] = []
        if servesFood { bits.append("Food & drinks") }
        if hasWifi { bits.append("Wi‑Fi") }
        if hasGarden { bits.append("Outdoor / patio") }
        if hasProjector { bits.append("Projector") }
        if petFriendly { bits.append("Pet friendly") }
        if familyFriendly { bits.append("Family friendly") }
        if parkingAvailable { bits.append("Parking") }
        return bits.joined(separator: " · ")
    }
}

/// Combined signup: organization display name plus the first `venue_claims` row (`venue_id` nil until admin links a venue).
struct BusinessOwnerSignupPayload: Sendable {
    let businessDisplayName: String
    let firstLocation: AddLocationClaimForm
}

struct VenueClaimInsert: Encodable {
    let owner_email: String
    /// ``public.businesses.id`` when the claim is filed under a multi-venue business (Phase C1 add-location); omit or nil for legacy / Discover-only claims.
    let business_id: UUID?
    /// When set (Discover “Claim this business”), matches ``public.venues.id`` on ``public.venue_claims.venue_id``.
    let venue_id: UUID?
    let venue_name: String
    let venue_address: String
    let venue_city: String
    let venue_state: String
    let venue_country: String
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

/// Payload for Edge Function ``notify-venue-claim`` (admin email with claim details).
struct VenueClaimAdminNotifyPayload: Encodable {
    let claim_id: String
    let business_id: String?
    let venue_id: String?
    /// `new_location` | `discover_claim` | `owner_venue_claim`
    let claim_kind: String
    let owner_email: String
    let venue_name: String
    let venue_address: String
    let venue_city: String
    let venue_state: String
    let venue_country: String
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
    let family_friendly: Bool
    let parking_available: Bool
    let proof_note: String
    let cover_photo_url: String
    let menu_photo_url: String
    let photo_urls: [String]
    let created_at: String
    let approval_status: String
}

/// Subset of ``public.venue_claims`` for Settings “Pending locations” (Phase C1).
struct VenueClaimPendingSettingsRow: Decodable, Identifiable, Equatable {
    let id: UUID
    let business_id: UUID?
    let venue_id: UUID?
    let venue_name: String?
    let venue_city: String?
    let venue_state: String?
    let approval_status: String?
    let rejection_acknowledged_at: String?
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
    let avatar_thumbnail_url: String?
    let is_business_account: Bool?
    let admin_status: String?
}

struct UserProfileInsert: Encodable {
    /// Must equal `auth.users.id` (`user_profiles_id_fkey`).
    let id: UUID
    let email: String
    let display_name: String
    let avatar_url: String
    let avatar_thumbnail_url: String?
}

/// Initial `user_profiles` row when auth exists but no row yet (`insert` only — never random `id`).
struct UserProfileBootstrapInsert: Encodable {
    let id: UUID
    let email: String
    let display_name: String
    /// Empty string when the column is `NOT NULL` and no asset yet.
    let avatar_url: String
    let avatar_thumbnail_url: String?
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

/// One row in the Following tab “I’m Going” list (global fetch; not tied to Discover map region).
struct FollowingGoingDisplayItem: Identifiable {
    let id: UUID
    let venueEvent: VenueEventRow
    let bar: BarVenue
    let attendeeCount: Int
    /// `true` when the user has a `venue_event_interests` row; `false` when only tracked locally as Interested.
    let isServerGoing: Bool
}

struct VenueEventCommentRow: Decodable, Identifiable {
    let id: UUID?
    let venue_event_id: UUID?
    let user_email: String?
    let comment: String?
    let created_at: String?
    /// When true, row is kept for audit but hidden from fan threads (see ``ModerationService/hiddenAfterReportsThreshold``).
    let is_moderation_hidden: Bool?

    var isHiddenFromThread: Bool {
        is_moderation_hidden == true
    }
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
