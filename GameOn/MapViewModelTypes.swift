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

/// Discover tab map layer: venue pins vs pickup game pins (session-only; not persisted).
enum DiscoverMapContentMode: String, CaseIterable, Identifiable, Equatable {
    case venues
    case pickupGames

    var id: String { rawValue }
}

/// Discover overlay calendar day markers: green (venue games) vs blue (pickup games).
enum DiscoverCalendarDotPalette: Equatable {
    case venueGames
    case pickupGames
}

/// Bottom-tab Calendar: filter list + day dots (session-only; not persisted).
enum CalendarTabGameFilter: String, CaseIterable, Identifiable, Equatable {
    case all
    case venue
    case pickup

    var id: String { rawValue }

    var segmentTitle: String {
        switch self {
        case .all: return "All"
        case .venue: return "Venue games"
        case .pickup: return "Pickup games"
        }
    }
}

/// UI / intent only. Split `interest_status` values require DB migration `20260630_0002_venue_event_interests_interest_status.sql`.
enum VenueEventInterestStatusKind: String, Codable, Equatable, CaseIterable {
    case interested
    case going
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
    /// ISO 8601 timestamptz string (UTC offset) for retention and Scheduled tab queries.
    let scheduled_start_at: String
    /// Hours after start when purge may remove fan data (Manage Games: 6/12/18; legacy DB rows may be 24/48/72).
    let cleanup_delay_hours: Int
}

struct VenueEventCleanupDelayPatch: Encodable {
    let cleanup_delay_hours: Int
}

/// Retention duration for venue games (`venue_events.cleanup_delay_hours`; `purge_after_at` is generated server-side).
nonisolated enum VenueOwnerGameDataRetentionHours {
    static let standardOptions: [Int] = [6, 12, 18]
    static let legacyOptions: [Int] = [24, 48, 72]
    static let defaultPickerHours: Int = 12

    static var allPersistedValues: Set<Int> {
        Set(standardOptions + legacyOptions)
    }

    /// Segmented picker: 6 / 12 / 18, plus the row’s current value when it is a legacy hour so SwiftUI selection stays valid.
    static func segmentedPickerHours(currentSaved: Int?) -> [Int] {
        let base = standardOptions
        guard let h = currentSaved, !base.contains(h), allPersistedValues.contains(h) else {
            return base
        }
        return (base + [h]).sorted()
    }

    static func segmentedLabel(for hours: Int) -> String {
        switch hours {
        case 6: return "6hr"
        case 12: return "12hr"
        case 18: return "18hr"
        default: return "\(hours)hr"
        }
    }

    static func longLabel(for hours: Int) -> String {
        switch hours {
        case 6: return "6hr after start"
        case 12: return "12hr after start"
        case 18: return "18hr after start"
        default: return "\(hours)hr after start"
        }
    }
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

/// Partial `venues` update for FanGeo-approved listings: omits identity, address, and coordinates so they cannot be changed from the client.
struct VenueProfileOperationalUpdate: Encodable {
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
    let cover_photo_url: String
    let menu_photo_url: String
    let cover_photo_thumbnail_url: String?
    let menu_photo_thumbnail_url: String?
}

/// PATCH only `latitude` / `longitude` on `public.venues` (e.g. approved listings missing geocode in DB).
struct VenueCoordinatesPatch: Encodable {
    let latitude: Double
    let longitude: Double
}

struct VenueProfileRow: Decodable {
    let id: UUID?
    let owner_email: String?
    /// `public.venues.business_id` when present (multi-venue owner Phase B1); omitted in older API responses decodes as nil.
    let business_id: UUID?
    /// Duplicate-protection identity key used for safe venue dedupe / merge logic.
    let venue_identity_key: String?
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
    /// Present when `venues` row includes coordinates (guest Discover relies on these).
    let latitude: Double?
    let longitude: Double?
    let cover_photo_url: String?
    let menu_photo_url: String?
    let cover_photo_thumbnail_url: String?
    let menu_photo_thumbnail_url: String?
}

/// Embedded `public.businesses` row from PostgREST when selecting `businesses!venues_business_id_fkey(...)` on `venues`.
struct VenueRowBusinessEmbed: Decodable, Equatable {
    let owner_email: String?
    let admin_status: String?
}

struct VenueRow: Decodable {
    let id: UUID?
    let owner_email: String?
    /// Multi-venue businesses (nullable / omitted for legacy rows).
    let business_id: UUID?
    /// Duplicate-protection identity key used for safe venue dedupe / merge logic.
    let venue_identity_key: String?
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
    let latitude: Double?
    let longitude: Double?
    let cover_photo_url: String?
    let menu_photo_url: String?
    let cover_photo_thumbnail_url: String?
    let menu_photo_thumbnail_url: String?
    /// Present when venue queries embed `businesses!venues_business_id_fkey(...)`.
    let businesses: VenueRowBusinessEmbed?
}

struct DiscoverMapBoundsWindow: Equatable {
    let minLat: Double
    let maxLat: Double
    let minLon: Double
    let maxLon: Double

    var centerLat: Double { (minLat + maxLat) / 2 }
    var centerLon: Double { (minLon + maxLon) / 2 }
    var latSpan: Double { maxLat - minLat }
    var lonSpan: Double { maxLon - minLon }

    func contains(_ other: DiscoverMapBoundsWindow) -> Bool {
        minLat <= other.minLat
            && maxLat >= other.maxLat
            && minLon <= other.minLon
            && maxLon >= other.maxLon
    }
}

struct DiscoverViewportVenueRowsCacheEntry {
    let key: String
    let source: String
    let requestedBounds: DiscoverMapBoundsWindow
    let coverageBounds: DiscoverMapBoundsWindow
    let rows: [VenueRow]
    let fetchedAt: Date
}

/// Drives Settings → Business → Location status row (icon / tint) without inferring approval from legacy claim flags alone.
enum BusinessSettingsLocationChrome: Equatable {
    case needsBusinessAccountFirst
    case archivedBusinessAccount
    case approved
    case pendingReview
    case rejected
    case noLocationsYet
}

enum DiscoverMapDisplayMode: String, CaseIterable, Equatable {
    case allSpots
    case gamesOnly

    var title: String {
        switch self {
        case .allSpots:
            return "All Spots"
        case .gamesOnly:
            return "Games Only"
        }
    }
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
nonisolated struct VenueClaimAdminNotifyPayload: Encodable {
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
    let venue_address: String?
    let venue_city: String?
    let venue_state: String?
    let approval_status: String?
    let rejection_acknowledged_at: String?
}

struct ApprovedVenueOwnershipSummary: Equatable {
    let businessId: UUID?
    let ownerEmail: String?
}

enum VenueOwnershipClaimStatus: Equatable {
    case unclaimed
    case pendingReview
    case approved
    case alreadyClaimedByOtherBusiness
    case rejected
}

struct VenueEventInterestInsert: Encodable {
    let venue_event_id: UUID
    let user_email: String

    enum CodingKeys: String, CodingKey {
        case venue_event_id
        case user_email
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(venue_event_id.uuidString.lowercased(), forKey: .venue_event_id)
        try c.encode(user_email, forKey: .user_email)
    }
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

/// Aggregated join-request counts for a pickup game (organizer Settings UI).
struct PickupOrganizerJoinStats: Equatable {
    var pending: Int
    var approved: Int
}

/// Discover map: grid-bucketed pickup games at one coordinate (see ``MapViewModel/clusteredPickupGamesForDiscoverMap(rows:)``).
struct PickupGameCluster: Identifiable {
    let id: String
    let rows: [PickupGameRow]
    let coordinate: CLLocationCoordinate2D

    var count: Int { rows.count }
}

struct UserProfileRow: Decodable {
    let id: UUID?
    let email: String?
    let display_name: String?
    let avatar_url: String?
    let avatar_thumbnail_url: String?
    let is_business_account: Bool?
    let admin_status: String?

    init(
        id: UUID?,
        email: String?,
        display_name: String?,
        avatar_url: String?,
        avatar_thumbnail_url: String?,
        is_business_account: Bool? = nil,
        admin_status: String? = nil
    ) {
        self.id = id
        self.email = email
        self.display_name = display_name
        self.avatar_url = avatar_url
        self.avatar_thumbnail_url = avatar_thumbnail_url
        self.is_business_account = is_business_account
        self.admin_status = admin_status
    }

    var isBusinessIdentity: Bool {
        is_business_account == true
    }
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
    /// Total `venue_event_interests` rows for this event (legacy schema: one bucket).
    let attendeeCount: Int
    /// `true` when the current user has a server `venue_event_interests` row (UI pill: “Going”).
    let isServerGoing: Bool
    /// Interested via UserDefaults only (no server row); UI pill: “Interested”.
    let isInterestedOnlyLocal: Bool
}

/// Status pill for Following → “Games to Play” pickup join cards (`rejected` maps to ``declined``).
enum PickupFollowingJoinRequestPillKind: String, Equatable {
    case pending
    case approved
    case declined
    case cancelled
    case withdrawing
    case canceledByOrganizer

    var title: String {
        switch self {
        case .pending: return "Pending"
        case .approved: return "Approved"
        case .declined: return "Declined"
        case .cancelled: return "Cancelled"
        case .withdrawing: return "Withdrawing…"
        case .canceledByOrganizer: return "Canceled"
        }
    }
}

/// Compact pickup join summary for the Following tab (requester perspective).
struct PickupGameJoinRequestCardDisplay: Identifiable, Equatable {
    /// Join request row id.
    let id: UUID
    let pickupGameId: UUID
    let title: String
    let sport: String
    /// Raw `pickup_games.game_start_at` for post-start UI (Following cards).
    let game_start_at: String
    let dateTimeLine: String
    let locationLine: String
    let organizerUserId: UUID
    let organizerName: String
    let pill: PickupFollowingJoinRequestPillKind
    let spotsRemainingSummary: String?
}

enum VenueEventCommentDeliveryState: String, Equatable {
    case pending
    case sent
    case failed
}

struct VenueEventCommentRow: Decodable, Identifiable {
    let id: UUID?
    let venue_event_id: UUID?
    let user_email: String?
    let comment: String?
    let created_at: String?
    /// When true, row is kept for audit but hidden from fan threads (see ``ModerationService/hiddenAfterReportsThreshold``).
    let is_moderation_hidden: Bool?
    let delivery_state: VenueEventCommentDeliveryState

    private enum CodingKeys: String, CodingKey {
        case id
        case venue_event_id
        case user_email
        case comment
        case created_at
        case is_moderation_hidden
    }

    init(
        id: UUID?,
        venue_event_id: UUID?,
        user_email: String?,
        comment: String?,
        created_at: String?,
        is_moderation_hidden: Bool?,
        delivery_state: VenueEventCommentDeliveryState = .sent
    ) {
        self.id = id
        self.venue_event_id = venue_event_id
        self.user_email = user_email
        self.comment = comment
        self.created_at = created_at
        self.is_moderation_hidden = is_moderation_hidden
        self.delivery_state = delivery_state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id)
        venue_event_id = try container.decodeIfPresent(UUID.self, forKey: .venue_event_id)
        user_email = try container.decodeIfPresent(String.self, forKey: .user_email)
        comment = try container.decodeIfPresent(String.self, forKey: .comment)
        created_at = try container.decodeIfPresent(String.self, forKey: .created_at)
        is_moderation_hidden = try container.decodeIfPresent(Bool.self, forKey: .is_moderation_hidden)
        delivery_state = .sent
    }

    var isHiddenFromThread: Bool {
        is_moderation_hidden == true
    }

    var isPendingSend: Bool {
        delivery_state == .pending
    }

    var isFailedSend: Bool {
        delivery_state == .failed
    }

    var serverCommentID: UUID? {
        delivery_state == .sent ? id : nil
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
