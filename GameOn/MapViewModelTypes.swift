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

enum CompactGameTimeFormatter {
    static func timeWithZone(for date: Date, timeZoneOption: TimeZoneOption) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone(for: timeZoneOption)
        formatter.dateFormat = "h:mm a"
        return "\(formatter.string(from: date)) \(timeZoneOption.abbreviation)"
    }

    static func timeWithZone(rawTime: String?, timeZoneOption: TimeZoneOption) -> String {
        let raw = rawTime?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else { return "Time TBD" }

        let cleaned = compactTimeText(raw)
        guard !cleaned.isEmpty, cleaned.lowercased() != "time tbd" else {
            return "Time TBD"
        }

        if endsWithKnownZone(cleaned) {
            return cleaned
        }
        return "\(cleaned) \(timeZoneOption.abbreviation)"
    }

    static func timeZone(for option: TimeZoneOption) -> TimeZone {
        TimeZone(identifier: option.identifier) ?? .current
    }

    private static func compactTimeText(_ raw: String) -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if value.lowercased().hasPrefix("started ") {
            value.removeFirst("Started ".count)
        }

        for replacement in verboseTimezoneReplacements {
            value = value.replacingOccurrences(
                of: replacement,
                with: "",
                options: [.caseInsensitive]
            )
        }

        value = value
            .replacingOccurrences(of: "(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return value
    }

    private static func endsWithKnownZone(_ value: String) -> Bool {
        let uppercased = value.uppercased()
        return knownZoneAbbreviations.contains { uppercased.hasSuffix(" \($0)") }
    }

    private static let knownZoneAbbreviations = ["MT", "PT", "ET", "CT"]

    private static let verboseTimezoneReplacements = [
        "(MT)", "(PT)", "(ET)", "(CT)",
        "Local MT", "Local PT", "Local ET", "Local CT",
        "MST", "MDT", "PST", "PDT", "EST", "EDT", "CST", "CDT",
        "Mountain Time", "Pacific Time", "Eastern Time", "Central Time"
    ]
}

/// Discover tab map layer: venue pins vs pickup game pins (session-only; not persisted).
enum DiscoverMapContentMode: String, CaseIterable, Identifiable, Equatable {
    case venues
    case pickupGames

    var id: String { rawValue }
}

/// Pickup-only map layer: user-created games vs physical places to play.
enum DiscoverPickupSubMode: String, CaseIterable, Identifiable, Equatable {
    case games
    case places

    var id: String { rawValue }

    var title: String {
        switch self {
        case .games: return "Games"
        case .places: return "Places"
        }
    }
}

/// Discover/Calendar day markers: green (venue games), orange (pickup games), red (pro games).
enum DiscoverCalendarDotPalette: Equatable {
    case venueGames
    case pickupGames
    case proGames
}

/// Bottom-tab Calendar: filter list + day dots (session-only; not persisted).
enum CalendarTabGameFilter: String, CaseIterable, Identifiable, Equatable {
    case venueGames
    case pickupGames
    case proGames

    var id: String { rawValue }

    var segmentTitle: String {
        switch self {
        case .venueGames: return "Venues"
        case .pickupGames: return "Pickup"
        case .proGames: return "Pro"
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
    let home_team: String?
    let away_team: String?
    let external_league: String?
    let event_date: String
    let event_time: String
    let external_game_id: String?
    let external_source: String?
    let imported_from_api: Bool
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
    /// Hours after start when purge may remove fan data. Venue-owner creation now always writes 12.
    let cleanup_delay_hours: Int
}

/// Retention duration for venue games (`venue_events.cleanup_delay_hours`; `purge_after_at` is generated server-side).
nonisolated enum VenueOwnerGameDataRetentionHours {
    static let fixedHoursAfterStart: Int = 12
    static let legacyOptions: [Int] = [6, 18, 24, 48, 72]

    static var allPersistedValues: Set<Int> {
        Set([fixedHoursAfterStart] + legacyOptions)
    }
}

/// Business venue game retention (`venue_events.cleanup_delay_hours` + generated `purge_after_at`).
/// Global cleanup: `purge_expired_venue_events()` hard-deletes the row and cascades interests/comments/vibes.
nonisolated enum VenueGameExpiration {
    /// How expired rows leave the system when the purge job runs (not a soft archive on `venue_events`).
    static let globalCleanupMode = "hard_delete_via_purge_expired_venue_events"

    static func purgeAfterDate(for row: VenueEventRow, now: Date = Date()) -> Date? {
        if let raw = row.purge_after_at?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let parsed = SupabaseTimestampParsing.parseTimestamptz(raw) {
            return parsed
        }
        guard let start = scheduledStartDate(for: row) else { return nil }
        let hours = normalizedCleanupDelayHours(row.cleanup_delay_hours)
        return Calendar.current.date(byAdding: .hour, value: hours, to: start)
    }

    static func scheduledStartDate(for row: VenueEventRow) -> Date? {
        if let raw = row.scheduled_start_at?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty,
           let parsed = SupabaseTimestampParsing.parseTimestamptz(raw) {
            return parsed
        }
        return legacyStartFromEventDateTime(row: row)
    }

    /// True when `now` is at or past the venue auto-close window (`purge_after_at`).
    static func isPastBusinessClearWindow(row: VenueEventRow, now: Date = Date()) -> Bool {
        guard let purge = purgeAfterDate(for: row, now: now) else { return false }
        return now >= purge
    }

    /// Map, Discover, Calendar venue slices, and Live venue rows — hidden after the clear window (until purge RPC runs).
    static func isActiveOnDiscoverSurfaces(row: VenueEventRow, now: Date = Date()) -> Bool {
        !isPastBusinessClearWindow(row: row, now: now)
    }

    /// Going tab → I’m Going: show greyed “Ended” cards after the clear window.
    static func isWatchingCompleted(row: VenueEventRow, now: Date = Date()) -> Bool {
        isPastBusinessClearWindow(row: row, now: now)
    }

#if DEBUG
    static func logAuditOncePerEvaluation(row: VenueEventRow, eventID: UUID?) {
        guard WatchingExpiredVenueGameDiagnostics.enabled else { return }
        let fieldSummary: String = {
            var parts: [String] = []
            if row.scheduled_start_at != nil { parts.append("scheduled_start_at") }
            if row.cleanup_delay_hours != nil { parts.append("cleanup_delay_hours") }
            if row.purge_after_at != nil { parts.append("purge_after_at") }
            if parts.isEmpty { parts.append("event_date+event_time_fallback") }
            return parts.joined(separator: "+")
        }()
        print("[VenueGameExpirationAudit] field=\(fieldSummary)")
        print("[VenueGameExpirationAudit] cleanupMode=\(globalCleanupMode)")
        if let eventID {
            print("[VenueGameExpirationAudit] event_id=\(eventID.uuidString.lowercased()) purge_after=\(purgeAfterDate(for: row)?.description ?? "nil") completed=\(isWatchingCompleted(row: row))")
        }
    }
#endif

    private static func normalizedCleanupDelayHours(_ raw: Int?) -> Int {
        guard let raw, VenueOwnerGameDataRetentionHours.allPersistedValues.contains(raw) else {
            return VenueOwnerGameDataRetentionHours.fixedHoursAfterStart
        }
        return raw
    }

    private static func legacyStartFromEventDateTime(row: VenueEventRow) -> Date? {
        guard let dateRaw = row.event_date?.trimmingCharacters(in: .whitespacesAndNewlines),
              !dateRaw.isEmpty else {
            return nil
        }
        let dayFormatter = DateFormatter()
        dayFormatter.locale = Locale(identifier: "en_US_POSIX")
        dayFormatter.timeZone = TimeZone.current
        dayFormatter.dateFormat = "yyyy-MM-dd"
        guard let day = dayFormatter.date(from: String(dateRaw.prefix(10))) else { return nil }

        let timeRaw = row.event_time?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !timeRaw.isEmpty, timeRaw.lowercased() != "time tbd" else {
            return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
        }

        let timeFormatter = DateFormatter()
        timeFormatter.locale = Locale(identifier: "en_US_POSIX")
        timeFormatter.timeZone = TimeZone.current
        for format in ["h:mm a", "HH:mm", "h:mm"] {
            timeFormatter.dateFormat = format
            if let timeOnly = timeFormatter.date(from: timeRaw) {
                let parts = Calendar.current.dateComponents([.hour, .minute], from: timeOnly)
                return Calendar.current.date(
                    bySettingHour: parts.hour ?? 12,
                    minute: parts.minute ?? 0,
                    second: 0,
                    of: day
                )
            }
        }
        return Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: day)
    }
}

/// Row from `public.businesses` (multi-venue owner Phase B1).
struct BusinessRow: Decodable, Equatable, Identifiable {
    let id: UUID
    let display_name: String
    let owner_email: String?
    let owner_user_id: UUID?
    let admin_status: String
    let business_origin: String?
    let created_at: String?
    let entitlement_updated_at: String?
    let free_active_venues_selected_at: String?
}

enum BusinessOrigin {
    static let ownedAccount = "owned_account"
    static let communitySeed = "community_seed"
    static let claimedCommunity = "claimed_community"

    static let loginOwnedValues = [ownedAccount, claimedCommunity]

    static func isLoginOwned(_ rawValue: String?) -> Bool {
        loginOwnedValues.contains(rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "")
    }
}

struct AdminBusinessVenueOverrideSummary: Decodable, Identifiable, Equatable {
    let business_id: UUID
    let display_name: String?
    let owner_email: String?
    let plan_type: String?
    let plan_status: String?
    let computed_is_pro: Bool
    let venue_limit: Int
    let effective_venue_limit: Int?
    let admin_active_venue_limit_override: Int?
    let approved_count: Int
    let active_count: Int
    let locked_count: Int

    var id: UUID { business_id }
}

struct AdminBusinessVenueOverrideVenue: Decodable, Identifiable, Equatable {
    let venue_id: UUID
    let business_id: UUID
    let venue_name: String?
    let city: String?
    let state: String?
    let admin_status: String?
    let created_at: String?

    var id: UUID { venue_id }
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
    let supporter_country: String?
    let address: String
    let address_line1: String
    let address_line2: String?
    let city: String
    let state: String
    let zip_code: String
    let region: String?
    let postal_code: String?
    let country: String
    let formatted_address: String?
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
    let supporter_country: String?
    let address: String
    let address_line1: String
    let address_line2: String?
    let city: String
    let state: String
    let zip_code: String
    let region: String?
    let postal_code: String?
    let country: String
    let formatted_address: String?
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
    let supporter_country: String?
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

struct VenueSupporterCountryUpdate: Encodable {
    let supporter_country: String?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if let supporter_country {
            try container.encode(supporter_country, forKey: .supporter_country)
        } else {
            try container.encodeNil(forKey: .supporter_country)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case supporter_country
    }
}

struct VenueProfileRow: Decodable {
    let id: UUID?
    let owner_email: String?
    /// `public.venues.business_id` when present (multi-venue owner Phase B1); omitted in older API responses decodes as nil.
    let business_id: UUID?
    /// Duplicate-protection identity key used for safe venue dedupe / merge logic.
    let venue_identity_key: String?
    /// `community` venues are released back to marketplace; `business` venues may be hard-deleted.
    let origin_type: String?
    /// `public.venues.admin_status` (`active` / `plan_locked` / `archived`); omitted in older payloads.
    let admin_status: String?
    /// Community place category, e.g. `play` for physical places to play sports.
    let community_type: String?
    /// Optional place subtype, e.g. `basketball_court` / `soccer_field`.
    let place_type: String?
    /// Sports supported by community play places.
    let sport_tags: [String]?
    let supporter_country: String?
    let venue_name: String?
    let address: String?
    let address_line1: String?
    let address_line2: String?
    let city: String?
    let state: String?
    let zip_code: String?
    let region: String?
    let postal_code: String?
    let country: String?
    let formatted_address: String?
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
    let created_at: String?
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
    /// `community` venues are released back to marketplace; `business` venues may be hard-deleted.
    let origin_type: String?
    /// `public.venues.admin_status` (`active` / `plan_locked` / `archived`); omitted in older payloads.
    let admin_status: String?
    /// Community place category, e.g. `play` for physical places to play sports.
    let community_type: String?
    /// Optional place subtype, e.g. `basketball_court` / `soccer_field`.
    let place_type: String?
    /// Sports supported by community play places.
    let sport_tags: [String]?
    let supporter_country: String?
    let venue_name: String?
    let address: String?
    let address_line1: String?
    let address_line2: String?
    let city: String?
    let state: String?
    let zip_code: String?
    let region: String?
    let postal_code: String?
    let country: String?
    let formatted_address: String?
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

struct CitySearchVenueDebugContext {
    let query: String
    let resolvedCoordinate: CLLocationCoordinate2D
    let resolvedCity: String
    let resolvedState: String
    let radiusMiles: Double
    let bounds: DiscoverMapBoundsWindow
}

enum LiveVenueNavigationFeatureFlags {
    static let liveVenueDiscoverNavigationEnabled = false
}

struct DiscoverViewportVenueRowsCacheEntry {
    let key: String
    let source: String
    let requestedBounds: DiscoverMapBoundsWindow
    let coverageBounds: DiscoverMapBoundsWindow
    let queryLimit: Int
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

    var toggled: DiscoverMapDisplayMode {
        switch self {
        case .allSpots: return .gamesOnly
        case .gamesOnly: return .allSpots
        }
    }
}

/// Full-field payload for Settings → Add location → ``venue_claims`` (no public ``venues`` row until admin approval).
struct AddLocationClaimForm: Codable, Sendable {
    let venueName: String
    let address: String
    let addressLine2: String
    let city: String
    let state: String
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
    let easyParking: Bool
    let handicapParking: Bool
    let liveMusic: Bool
    let poolTables: Bool
    let rooftop: Bool
    let djNights: Bool
    let karaoke: Bool
    let cocktails: Bool
    let craftBeer: Bool
    let coverPhotoURL: String
    let menuPhotoURL: String
    let latitude: Double?
    let longitude: Double?
    let formattedAddress: String?

    init(
        venueName: String,
        address: String,
        addressLine2: String,
        city: String,
        state: String,
        country: String,
        zip: String,
        phone: String,
        website: String,
        description: String,
        proofNote: String,
        screenCount: Int,
        servesFood: Bool,
        hasWifi: Bool,
        hasGarden: Bool,
        hasProjector: Bool,
        petFriendly: Bool,
        familyFriendly: Bool,
        parkingAvailable: Bool,
        easyParking: Bool = false,
        handicapParking: Bool = false,
        liveMusic: Bool = false,
        poolTables: Bool = false,
        rooftop: Bool = false,
        djNights: Bool = false,
        karaoke: Bool = false,
        cocktails: Bool = false,
        craftBeer: Bool = false,
        coverPhotoURL: String,
        menuPhotoURL: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        formattedAddress: String? = nil
    ) {
        self.venueName = venueName
        self.address = address
        self.addressLine2 = addressLine2
        self.city = city
        self.state = state
        self.country = country
        self.zip = zip
        self.phone = phone
        self.website = website
        self.description = description
        self.proofNote = proofNote
        self.screenCount = screenCount
        self.servesFood = servesFood
        self.hasWifi = hasWifi
        self.hasGarden = hasGarden
        self.hasProjector = hasProjector
        self.petFriendly = petFriendly
        self.familyFriendly = familyFriendly
        self.parkingAvailable = parkingAvailable
        self.easyParking = easyParking
        self.handicapParking = handicapParking
        self.liveMusic = liveMusic
        self.poolTables = poolTables
        self.rooftop = rooftop
        self.djNights = djNights
        self.karaoke = karaoke
        self.cocktails = cocktails
        self.craftBeer = craftBeer
        self.coverPhotoURL = coverPhotoURL
        self.menuPhotoURL = menuPhotoURL
        self.latitude = latitude
        self.longitude = longitude
        self.formattedAddress = formattedAddress
    }

    /// Human-readable feature line stored in ``venue_claims.venue_features`` (schema has no separate columns for parking / family).
    func mergedVenueFeaturesLine() -> String {
        venueMergedRawFeaturesLine(
            existingRawFeatures: "",
            familyFriendly: familyFriendly,
            parkingAvailable: parkingAvailable,
            easyParking: easyParking,
            handicapParking: handicapParking,
            liveMusic: liveMusic,
            poolTables: poolTables,
            rooftop: rooftop,
            djNights: djNights,
            karaoke: karaoke,
            cocktails: cocktails,
            craftBeer: craftBeer
        )
    }
}

/// Combined signup: organization display name plus the first `venue_claims` row (`venue_id` nil until admin links a venue).
struct BusinessOwnerSignupPayload: Codable, Sendable {
    let businessDisplayName: String
    let firstLocation: AddLocationClaimForm
}

struct PendingFanEmailSignupDraft: Sendable {
    let email: String
    let profile: FanSignupProfileInput
    let recordFanGuidelinesAcceptance: Bool
}

struct PendingBusinessEmailSignupDraft: Codable, Sendable {
    let email: String
    let signup: BusinessOwnerSignupPayload
    let coverPhotoJPEGData: Data?
    let menuPhotoJPEGData: Data?
    let recordVenueGuidelinesAcceptance: Bool
}

struct VenueClaimInsert: Encodable {
    let owner_email: String
    /// ``public.businesses.id`` when the claim is filed under a multi-venue business (Phase C1 add-location); omit or nil for legacy / Discover-only claims.
    let business_id: UUID?
    /// When set (Discover “Claim this business”), matches ``public.venues.id`` on ``public.venue_claims.venue_id``.
    let venue_id: UUID?
    let venue_name: String
    let venue_address: String
    let venue_address_line2: String?
    let venue_city: String
    let venue_state: String
    let venue_country: String
    let venue_zip_code: String
    let venue_formatted_address: String?
    let venue_latitude: Double?
    let venue_longitude: Double?
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
    let venue_address_line2: String?
    let venue_city: String
    let venue_state: String
    let venue_country: String
    let venue_zip_code: String
    let venue_formatted_address: String?
    let venue_latitude: Double?
    let venue_longitude: Double?
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
    var business_name: String? = nil
    var previous_status: String? = nil
    var new_status: String? = nil
    var cancelled_at: String? = nil
    var cancellation_note: String? = nil
}

/// Subset of ``public.venue_claims`` for Settings “Pending locations” (Phase C1).
struct VenueClaimPendingSettingsRow: Decodable, Identifiable, Equatable {
    let id: UUID
    let business_id: UUID?
    let venue_id: UUID?
    let venue_name: String?
    let venue_address: String?
    let venue_address_line2: String?
    let venue_city: String?
    let venue_state: String?
    let venue_country: String?
    let approval_status: String?
    let rejection_acknowledged_at: String?
    let created_at: String?
}

struct ApprovedVenueOwnershipSummary: Equatable {
    let businessId: UUID?
    let ownerEmail: String?
}

/// In-memory snapshot for the lightweight Business Dashboard preload.
/// This is session-only and intentionally excludes social/comment/prediction data.
struct BusinessDashboardPreloadSnapshot {
    let key: String
    let businessId: UUID?
    let selectedVenueId: UUID?
    let managedVenueCount: Int
    let selectedVenue: VenueProfileRow?
    let entitlementStatus: BusinessVenueGamePostingStatus?
    let favoriteTeamCount: Int
    let scheduledGames: [VenueEventRow]
    let loadedAt: Date
}

struct BusinessApprovedVenueClaimMetadata: Decodable, Equatable {
    let claimId: UUID
    let venueId: UUID?
    let businessId: UUID?
    let ownerEmail: String?
    let approvedAtRaw: String?
    let createdAtRaw: String?

    private enum CodingKeys: String, CodingKey {
        case claimId = "id"
        case venueId = "venue_id"
        case businessId = "business_id"
        case ownerEmail = "owner_email"
        case approvedAtRaw = "approved_at"
        case createdAtRaw = "created_at"
    }
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

    init(venue_event_id: UUID, user_email: String) {
        self.venue_event_id = venue_event_id
        self.user_email = user_email
    }

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

enum LiveVisibilityMode: String, Codable, CaseIterable, Identifiable {
    case allFriends = "all_friends"
    case selectedFriends = "selected_friends"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .allFriends:
            return "All Friends"
        case .selectedFriends:
            return "Selected Friends"
        }
    }
}

struct UserProfileRow: Decodable {
    let id: UUID?
    let email: String?
    let display_name: String?
    let username: String?
    let bio: String?
    let avatar_url: String?
    let avatar_thumbnail_url: String?
    let is_business_account: Bool?
    let admin_status: String?
    let live_visibility_enabled: Bool?
    let live_visibility_mode: String?
    let selected_live_visibility_friend_ids: [UUID]?
    let discoverable_by_fans: Bool?
    let is_deleted: Bool?
    let created_at: String?
    let last_seen_at: String?
    let national_team_country_code: String?
    let national_team_country_name: String?
    let national_team_flag: String?
    let national_team_supporter_label: String?
    let national_team_updated_at: String?
    let ad_free_enabled: Bool?

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case display_name
        case username
        case bio
        case avatar_url
        case avatar_thumbnail_url
        case is_business_account
        case admin_status
        case live_visibility_enabled
        case live_visibility_mode
        case selected_live_visibility_friend_ids
        case discoverable_by_fans
        case is_deleted
        case created_at
        case last_seen_at
        case national_team_country_code
        case national_team_country_name
        case national_team_flag
        case national_team_supporter_label
        case national_team_updated_at
        case ad_free_enabled
    }

    init(
        id: UUID?,
        email: String?,
        display_name: String?,
        username: String? = nil,
        bio: String? = nil,
        avatar_url: String?,
        avatar_thumbnail_url: String?,
        is_business_account: Bool? = nil,
        admin_status: String? = nil,
        live_visibility_enabled: Bool? = nil,
        live_visibility_mode: String? = nil,
        selected_live_visibility_friend_ids: [UUID]? = nil,
        discoverable_by_fans: Bool? = nil,
        is_deleted: Bool? = nil,
        created_at: String? = nil,
        last_seen_at: String? = nil,
        national_team_country_code: String? = nil,
        national_team_country_name: String? = nil,
        national_team_flag: String? = nil,
        national_team_supporter_label: String? = nil,
        national_team_updated_at: String? = nil,
        ad_free_enabled: Bool? = nil
    ) {
        self.id = id
        self.email = email
        self.display_name = display_name
        self.username = username
        self.bio = bio
        self.avatar_url = avatar_url
        self.avatar_thumbnail_url = avatar_thumbnail_url
        self.is_business_account = is_business_account
        self.admin_status = admin_status
        self.live_visibility_enabled = live_visibility_enabled
        self.live_visibility_mode = live_visibility_mode
        self.selected_live_visibility_friend_ids = selected_live_visibility_friend_ids
        self.discoverable_by_fans = discoverable_by_fans
        self.is_deleted = is_deleted
        self.created_at = created_at
        self.last_seen_at = last_seen_at
        self.national_team_country_code = national_team_country_code
        self.national_team_country_name = national_team_country_name
        self.national_team_flag = national_team_flag
        self.national_team_supporter_label = national_team_supporter_label
        self.national_team_updated_at = national_team_updated_at
        self.ad_free_enabled = ad_free_enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id)
        email = try c.decodeIfPresent(String.self, forKey: .email)
        display_name = try c.decodeIfPresent(String.self, forKey: .display_name)
        username = try c.decodeIfPresent(String.self, forKey: .username)
        bio = try c.decodeIfPresent(String.self, forKey: .bio)
        avatar_url = try c.decodeIfPresent(String.self, forKey: .avatar_url)
        avatar_thumbnail_url = try c.decodeIfPresent(String.self, forKey: .avatar_thumbnail_url)
        is_business_account = try c.decodeIfPresent(Bool.self, forKey: .is_business_account)
        admin_status = try c.decodeIfPresent(String.self, forKey: .admin_status)
        live_visibility_enabled = try c.decodeIfPresent(Bool.self, forKey: .live_visibility_enabled)
        live_visibility_mode = try c.decodeIfPresent(String.self, forKey: .live_visibility_mode)
        discoverable_by_fans = try c.decodeIfPresent(Bool.self, forKey: .discoverable_by_fans)
        is_deleted = try c.decodeIfPresent(Bool.self, forKey: .is_deleted)
        created_at = try c.decodeIfPresent(String.self, forKey: .created_at)
        last_seen_at = try c.decodeIfPresent(String.self, forKey: .last_seen_at)
        national_team_country_code = try c.decodeIfPresent(String.self, forKey: .national_team_country_code)
        national_team_country_name = try c.decodeIfPresent(String.self, forKey: .national_team_country_name)
        national_team_flag = try c.decodeIfPresent(String.self, forKey: .national_team_flag)
        national_team_supporter_label = try c.decodeIfPresent(String.self, forKey: .national_team_supporter_label)
        national_team_updated_at = try c.decodeIfPresent(String.self, forKey: .national_team_updated_at)
        ad_free_enabled = try c.decodeIfPresent(Bool.self, forKey: .ad_free_enabled)

        if let ids = try? c.decodeIfPresent([UUID].self, forKey: .selected_live_visibility_friend_ids) {
            selected_live_visibility_friend_ids = ids
        } else if let raw = try? c.decodeIfPresent([String].self, forKey: .selected_live_visibility_friend_ids) {
            selected_live_visibility_friend_ids = raw.compactMap(UUID.init(uuidString:))
        } else {
            selected_live_visibility_friend_ids = nil
        }
    }

    var isBusinessIdentity: Bool {
        is_business_account == true
    }

    var adFreeEnabled: Bool {
        ad_free_enabled == true
    }

    func isRegularFanProfile(excludingBusinessOwnerUserIDs businessOwnerUserIDs: Set<UUID> = []) -> Bool {
        if isDeletedAccount { return false }
        if admin_status != nil, admin_status != "active" { return false }
        if isBusinessIdentity { return false }
        if let id, businessOwnerUserIDs.contains(id) { return false }
        return true
    }

    var isVisibleForLiveFriendPresence: Bool {
        liveVisibilityEnabled
    }

    var liveVisibilityEnabled: Bool {
        live_visibility_enabled ?? true
    }

    var discoverableByFans: Bool {
        discoverable_by_fans ?? true
    }

    var isDeletedAccount: Bool {
        if is_deleted == true { return true }
        let normalizedEmail = OwnerBusinessEmail.normalized(email ?? "")
        return normalizedEmail.hasSuffix("@deleted.fangeo.local")
    }

    var liveVisibilityMode: LiveVisibilityMode {
        LiveVisibilityMode(rawValue: live_visibility_mode ?? "") ?? .allFriends
    }

    var selectedLiveVisibilityFriendIDs: Set<UUID> {
        Set(selected_live_visibility_friend_ids ?? [])
    }

    var nationalTeamIdentity: NationalTeamIdentity? {
        NationalTeamIdentity.fromProfile(
            countryCode: national_team_country_code,
            countryName: national_team_country_name,
            flag: national_team_flag,
            supporterLabel: national_team_supporter_label
        )
    }

    func isVisibleForLiveFriendPresence(to viewerUserID: UUID?) -> Bool {
        isFanVisibleForLivePresence(to: viewerUserID)
    }

    func isFanVisibleForLivePresence(to viewerUserID: UUID?) -> Bool {
        guard isRegularFanProfile() else { return false }
        guard liveVisibilityEnabled else { return false }
        switch liveVisibilityMode {
        case .allFriends:
            return true
        case .selectedFriends:
            guard let viewerUserID else { return false }
            return selectedLiveVisibilityFriendIDs.contains(viewerUserID)
        }
    }
}

struct UserProfileInsert: Encodable {
    /// Must equal `auth.users.id` (`user_profiles_id_fkey`).
    let id: UUID
    let email: String
    let display_name: String
    let username: String?
    let bio: String?
    let avatar_url: String
    let avatar_thumbnail_url: String?
    let live_visibility_enabled: Bool
    let live_visibility_mode: String
    let selected_live_visibility_friend_ids: [String]
    let discoverable_by_fans: Bool

    private enum CodingKeys: String, CodingKey {
        case id
        case email
        case display_name
        case username
        case bio
        case avatar_url
        case avatar_thumbnail_url
        case live_visibility_enabled
        case live_visibility_mode
        case selected_live_visibility_friend_ids
        case discoverable_by_fans
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(email, forKey: .email)
        try c.encode(display_name, forKey: .display_name)
        try c.encodeIfPresent(username, forKey: .username)
        if let bio {
            try c.encode(bio, forKey: .bio)
        } else {
            try c.encodeNil(forKey: .bio)
        }
        try c.encode(avatar_url, forKey: .avatar_url)
        try c.encodeIfPresent(avatar_thumbnail_url, forKey: .avatar_thumbnail_url)
        try c.encode(live_visibility_enabled, forKey: .live_visibility_enabled)
        try c.encode(live_visibility_mode, forKey: .live_visibility_mode)
        try c.encode(selected_live_visibility_friend_ids, forKey: .selected_live_visibility_friend_ids)
        try c.encode(discoverable_by_fans, forKey: .discoverable_by_fans)
    }
}

/// Initial `user_profiles` row when auth exists but no row yet (`insert` only — never random `id`).
struct UserProfileBootstrapInsert: Encodable {
    let id: UUID
    let email: String
    let display_name: String
    let bio: String?
    /// Empty string when the column is `NOT NULL` and no asset yet.
    let avatar_url: String
    let avatar_thumbnail_url: String?
    let live_visibility_enabled: Bool
    let live_visibility_mode: String
    let selected_live_visibility_friend_ids: [String]
    let discoverable_by_fans: Bool
}

struct UserLiveVisibilityPatch: Encodable {
    let live_visibility_enabled: Bool
    let live_visibility_mode: String
    let selected_live_visibility_friend_ids: [String]
}

struct UserLiveVisibilityEnabledPatch: Encodable {
    let live_visibility_enabled: Bool
}

struct UserProfileDiscoverabilityPatch: Encodable {
    let discoverable_by_fans: Bool
}

struct UserProfileNationalTeamPatch: Encodable {
    let national_team_country_code: String?
    let national_team_country_name: String?
    let national_team_flag: String?
    let national_team_supporter_label: String?
    let national_team_updated_at: String?
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

    var isActiveGoingTabPlan: Bool {
        isServerGoing || isInterestedOnlyLocal
    }

    var goingTabStatusDebugValue: String {
        if isServerGoing { return "going" }
        if isInterestedOnlyLocal { return "interested" }
        return "nil"
    }
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
        case .declined: return "Rejected"
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

enum FanChatCommentReactionType: String, Codable, Equatable {
    case up
    case down
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
    let upReactionCount: Int
    let downReactionCount: Int
    let viewerReaction: FanChatCommentReactionType?

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
        delivery_state: VenueEventCommentDeliveryState = .sent,
        upReactionCount: Int = 0,
        downReactionCount: Int = 0,
        viewerReaction: FanChatCommentReactionType? = nil
    ) {
        self.id = id
        self.venue_event_id = venue_event_id
        self.user_email = user_email
        self.comment = comment
        self.created_at = created_at
        self.is_moderation_hidden = is_moderation_hidden
        self.delivery_state = delivery_state
        self.upReactionCount = upReactionCount
        self.downReactionCount = downReactionCount
        self.viewerReaction = viewerReaction
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
        upReactionCount = 0
        downReactionCount = 0
        viewerReaction = nil
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

    var likeCount: Int { upReactionCount }
    var isLikedByCurrentUser: Bool { viewerReaction == .up }

    func withReactionMetadata(
        upCount: Int,
        downCount: Int,
        viewerReaction: FanChatCommentReactionType?
    ) -> VenueEventCommentRow {
        VenueEventCommentRow(
            id: id,
            venue_event_id: venue_event_id,
            user_email: user_email,
            comment: comment,
            created_at: created_at,
            is_moderation_hidden: is_moderation_hidden,
            delivery_state: delivery_state,
            upReactionCount: upCount,
            downReactionCount: downCount,
            viewerReaction: viewerReaction
        )
    }

    func withAuthorEmail(_ email: String?) -> VenueEventCommentRow {
        VenueEventCommentRow(
            id: id,
            venue_event_id: venue_event_id,
            user_email: email,
            comment: comment,
            created_at: created_at,
            is_moderation_hidden: is_moderation_hidden,
            delivery_state: delivery_state,
            upReactionCount: upReactionCount,
            downReactionCount: downReactionCount,
            viewerReaction: viewerReaction
        )
    }

    func withLikeMetadata(likeCount: Int, isLikedByCurrentUser: Bool) -> VenueEventCommentRow {
        withReactionMetadata(
            upCount: likeCount,
            downCount: downReactionCount,
            viewerReaction: isLikedByCurrentUser ? .up : viewerReaction
        )
    }
}

struct VenueEventCommentInsert: Encodable {
    let venue_event_id: UUID
    let user_email: String
    let comment: String
}

struct VenueEventCommentLikeRow: Decodable {
    let comment_id: UUID?
    let user_id: UUID?
}

struct VenueEventCommentLikeInsert: Encodable {
    let comment_id: UUID
    let user_id: UUID
}

struct VenueEventCommentReactionRow: Decodable {
    let comment_id: UUID?
    let user_id: UUID?
    let reaction_type: String?
}

struct VenueEventCommentReactionInsert: Encodable {
    let comment_id: UUID
    let user_id: UUID
    let reaction_type: String
}

struct VenueEventCommentReactionUpdate: Encodable {
    let reaction_type: String
    let updated_at: String
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

struct VenueSupporterCountryDisplay: Equatable {
    let storedCountry: String
    let countryCode: String?
    let countryName: String
    let flag: String
    let wording: String

    var title: String {
        "\(flag) \(countryName) \(wording)"
    }
}

enum VenueSupporterCountryMode {
    static let allowedCountryNames: [String] = [
        "Brazil",
        "USA",
        "Mexico",
        "Canada",
        "Costa Rica",
        "Bolivia",
        "France",
        "Belgium",
        "Argentina",
        "England",
        "Spain",
        "Germany",
        "Italy",
        "Portugal",
        "Netherlands",
        "Colombia",
        "Uruguay",
        "Chile",
        "Japan",
        "South Korea",
        "Australia"
    ]

    private static let countryCodeOverrides: [String: String] = [
        "USA": "US",
        "England": "GB",
        "South Korea": "KR"
    ]

    private static let aliasToCanonical: [String: String] = [
        "brasil": "Brazil",
        "us": "USA",
        "u.s.": "USA",
        "u.s.a.": "USA",
        "united states": "USA",
        "united states of america": "USA",
        "méxico": "Mexico",
        "belgique": "Belgium",
        "belgie": "Belgium",
        "espana": "Spain",
        "españa": "Spain",
        "deutschland": "Germany",
        "italia": "Italy",
        "the netherlands": "Netherlands",
        "holland": "Netherlands",
        "korea republic": "South Korea",
        "republic of korea": "South Korea",
        "korea, republic of": "South Korea"
    ]

    static func normalizedStorageValue(_ country: String?) -> String? {
        let trimmed = country?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        let key = normalizedLookupKey(trimmed)
        if let canonical = allowedCountryNames.first(where: { normalizedLookupKey($0) == key }) {
            return canonical
        }
        return aliasToCanonical[key]
    }

    static func display(for storedCountry: String?, languageCode: String) -> VenueSupporterCountryDisplay? {
        guard let stored = normalizedStorageValue(storedCountry) else { return nil }
        let code = countryCodeOverrides[stored] ?? CountryFlagHelper.countryCode(for: stored)
        let flag = safeAllowedFlag(for: stored, countryCode: code)
        let displayName = supporterDisplayName(storedCountry: stored, countryCode: code, languageCode: languageCode)
        return VenueSupporterCountryDisplay(
            storedCountry: stored,
            countryCode: code,
            countryName: displayName,
            flag: flag,
            wording: supporterWording(countryCode: code, countryName: displayName)
        )
    }

    static func allowedOptions(matching query: String, languageCode: String) -> [NationalTeamCountryOption] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return allowedCountryNames.compactMap { name in
            let code = countryCodeOverrides[name] ?? CountryFlagHelper.countryCode(for: name)
            guard let code else { return nil }
            let flag = safeAllowedFlag(for: name, countryCode: code)
            return NationalTeamCountryOption(code: code, name: name, flag: flag, isPopular: true)
        }
        .filter { option in
            trimmed.isEmpty
                || option.name.localizedCaseInsensitiveContains(trimmed)
                || option.code.localizedCaseInsensitiveContains(trimmed)
        }
    }

    private static func supporterDisplayName(storedCountry: String, countryCode: String?, languageCode: String) -> String {
        if storedCountry == "USA" {
            return "USA"
        }
        if storedCountry.count <= 3, let countryCode {
            if countryCode == "US" { return "USA" }
            let localeIdentifier = L10n.normalizedLanguageCode(languageCode)
            return Locale(identifier: localeIdentifier).localizedString(forRegionCode: countryCode) ?? storedCountry
        }
        if countryCode == "US", storedCountry.localizedCaseInsensitiveContains("united states") {
            return "USA"
        }
        return storedCountry
    }

    private static func supporterWording(countryCode: String?, countryName: String) -> String {
        switch countryCode {
        case "MX":
            return "Supporters"
        case "US":
            return "Watch Spot"
        case "FR", "BR", "ES", "PT":
            return "Fan Zone"
        case "AR":
            return "Crowd"
        default:
            return countryName.count <= 8 ? "Crowd" : "Supporters"
        }
    }

    private static func normalizedLookupKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .lowercased()
    }

    private static func safeAllowedFlag(for name: String, countryCode: String?) -> String {
        TeamTheme.safeFlag(CountryFlagHelper.flag(for: name))
            ?? TeamTheme.safeFlag(countryCode.flatMap { CountryFlagHelper.flag(for: $0) })
            ?? "🏟️"
    }
}

enum VenueCrowdReactionCatalog {
    static let storagePrefix = "crowd_reaction"

    static let reactions: [(id: String, label: String)] = [
        ("goal", "⚽ GOALLLL"),
        ("save", "😱 WHAT A SAVE"),
        ("robbed", "😡 ROBBED"),
        ("chaos", "🤯 CHAOS"),
        ("vamos", "🔥 VAMOS"),
        ("usa_lets_go", "🇺🇸 LET’S GOOO")
    ]

    static func storageValue(for reactionID: String) -> String {
        "\(storagePrefix).\(reactionID).\(UUID().uuidString.lowercased())"
    }

    static func normalizedCountKey(for rawVibeType: String) -> String {
        guard rawVibeType.hasPrefix("\(storagePrefix).") else { return rawVibeType }
        let pieces = rawVibeType.split(separator: ".")
        guard pieces.count >= 2 else { return rawVibeType }
        return "\(storagePrefix).\(pieces[1])"
    }

    static func countKey(for reactionID: String) -> String {
        "\(storagePrefix).\(reactionID)"
    }
}
