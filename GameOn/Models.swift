import Foundation
import CoreLocation

nonisolated struct SportsEvent: Identifiable, Equatable, Codable {
    let id: UUID
    let title: String
    let sport: String
    let league: String
    let date: Date
    let time: String
    let country: String
    /// Legacy field; Calendar tab pickup listings are public-only and ignore this. Following / Discover detail use join state elsewhere.
    var calendarPickupJoinStatus: String?

    init(
        id: UUID = UUID(),
        title: String,
        sport: String,
        league: String,
        date: Date,
        time: String,
        country: String,
        calendarPickupJoinStatus: String? = nil
    ) {
        self.id = id
        self.title = title
        self.sport = sport
        self.league = league
        self.date = date
        self.time = time
        self.country = country
        self.calendarPickupJoinStatus = calendarPickupJoinStatus
    }
}

nonisolated struct BarVenue: Identifiable, Equatable {
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
    /// Nil = unverified/unknown (typical for community venues). Non-nil = business-confirmed.
    let screenCount: Int?
    let servesFood: Bool?
    let hasWifi: Bool?
    let hasGarden: Bool?
    let hasProjector: Bool?
    let petFriendly: Bool?
    /// Raw public `venues.features` text; used for configured features that do not have dedicated columns yet.
    let rawVenueFeatures: String?

    // New photo URLs
    let coverPhotoURL: String?
    let menuPhotoURL: String?
    let coverPhotoThumbnailURL: String?
    let menuPhotoThumbnailURL: String?

    /// Public contact email after client validation (Discover: strict `venues.owner_email`, else strict embedded `businesses.owner_email` when business is not archived).
    let ownerEmail: String?
    /// Supabase `venues.business_id` when known (multi-venue businesses).
    let businessId: UUID?
    /// Supabase `venues.admin_status` when available; nil stays legacy-safe for old rows/snapshots.
    let adminStatus: String?
    /// Raw `venues.owner_email` from the last venue row fetch (DEBUG / diagnostics; may be invalid or empty).
    let venueOwnerEmailRaw: String?
    /// Raw `businesses.owner_email` from embedded fetch when `business_id` is set (DEBUG / diagnostics).
    let businessOwnerEmailRaw: String?
    /// Reserved for a future public `contact_email`-style column; always nil today.
    let contactEmailRaw: String?

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
        screenCount: Int? = nil,
        servesFood: Bool? = nil,
        hasWifi: Bool? = nil,
        hasGarden: Bool? = nil,
        hasProjector: Bool? = nil,
        petFriendly: Bool? = nil,
        rawVenueFeatures: String? = nil,
        coverPhotoURL: String? = nil,
        menuPhotoURL: String? = nil,
        coverPhotoThumbnailURL: String? = nil,
        menuPhotoThumbnailURL: String? = nil,
        ownerEmail: String? = nil,
        businessId: UUID? = nil,
        adminStatus: String? = nil,
        venueOwnerEmailRaw: String? = nil,
        businessOwnerEmailRaw: String? = nil,
        contactEmailRaw: String? = nil
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
        self.rawVenueFeatures = rawVenueFeatures
        self.coverPhotoURL = coverPhotoURL
        self.menuPhotoURL = menuPhotoURL
        self.coverPhotoThumbnailURL = coverPhotoThumbnailURL
        self.menuPhotoThumbnailURL = menuPhotoThumbnailURL
        self.ownerEmail = ownerEmail
        self.businessId = businessId
        self.adminStatus = adminStatus
        self.venueOwnerEmailRaw = venueOwnerEmailRaw
        self.businessOwnerEmailRaw = businessOwnerEmailRaw
        self.contactEmailRaw = contactEmailRaw
    }

    static func == (lhs: BarVenue, rhs: BarVenue) -> Bool {
        lhs.id == rhs.id
    }

    /// Linked to a verified business account — amenity columns are treated as owner-confirmed true/false.
    var hasBusinessVerifiedFeatures: Bool {
        if businessId != nil { return true }
        let activeOrLegacy = (adminStatus ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard activeOrLegacy.isEmpty || activeOrLegacy == "active" else { return false }
        let candidates = [ownerEmail, venueOwnerEmailRaw, businessOwnerEmailRaw]
        return candidates.contains { raw in
            OwnerBusinessEmail.isValidStrict(OwnerBusinessEmail.normalized(raw ?? ""))
        }
    }

    /// Seeded/imported community map venue (no business owner on file).
    var isCommunityVenue: Bool {
        !hasBusinessVerifiedFeatures
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
    let venue_address_line2: String?
    let venue_city: String?
    let venue_state: String?
    let venue_country: String?
    let venue_zip_code: String?
    let venue_formatted_address: String?
    let venue_phone: String?
    let venue_website: String?
    let proof_note: String?
    let approval_status: String?
    /// Set when the business owner dismisses a rejection in Settings (claim remains in DB).
    let rejection_acknowledged_at: String?
}

nonisolated struct VenueEventRow: Codable {
    let id: UUID?

    /// Canonical link to ``venues.id`` when set; legacy matching uses ``owner_email`` / ``venue_name`` when nil.
    let venue_id: UUID?

    let owner_email: String?
    let venue_name: String?
    
    let event_title: String?
    let sport: String?
    let home_team: String?
    let away_team: String?
    let external_league: String?
    
    let event_date: String?
    let event_time: String?
    let external_game_id: String?
    let external_source: String?
    let imported_from_api: Bool?
    
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

    let scheduled_start_at: String?
    let cleanup_delay_hours: Int?
    /// Generated column `scheduled_start_at + cleanup_delay_hours` when present in API responses.
    let purge_after_at: String?
    let created_at: String?
}

/// Row from ``public.business_game_history`` (post-purge metadata for business owners).
struct BusinessGameHistoryRow: Decodable, Identifiable {
    let id: UUID
    let original_venue_event_id: UUID
    let business_id: UUID?
    let venue_id: UUID?
    let venue_name: String?
    let event_title: String?
    let sport: String?
    let scheduled_start_at: String?
    let event_date: String?
    let cleanup_delay_hours: Int?
    let attendance_count: Int?
    let comment_count: Int?
    let created_at: String?
    let purged_at: String?
}

/// Shared rules for business “Add / update game” scheduling in the device’s local calendar/time zone.
enum VenueOwnerGameScheduleValidation {
    static let futureDateTimeMessage = "Game time must be in the future."

    /// Calendar date + clock time from two pickers, interpreted in `calendar`’s local time zone.
    static func combinedLocalStart(gameDate: Date, gameStartTime: Date, calendar: Calendar = .current) -> Date {
        var dc = calendar.dateComponents([.year, .month, .day], from: gameDate)
        let timeParts = calendar.dateComponents([.hour, .minute, .second], from: gameStartTime)
        dc.hour = timeParts.hour ?? 0
        dc.minute = timeParts.minute ?? 0
        dc.second = timeParts.second ?? 0
        if let merged = calendar.date(from: dc) {
            return merged
        }
        let h = timeParts.hour ?? 0
        let m = timeParts.minute ?? 0
        let s = timeParts.second ?? 0
        let sod = calendar.startOfDay(for: gameDate)
        return calendar.date(bySettingHour: h, minute: m, second: s, of: sod) ?? sod
    }

    /// `true` when the scheduled start is **before** `now` (invalid for publish).
    static func isPastSchedule(gameDate: Date, gameStartTime: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        combinedLocalStart(gameDate: gameDate, gameStartTime: gameStartTime, calendar: calendar) < now
    }

    /// If the combined start is in the past, snap pickers forward. Never moves a **future calendar day** on `gameDate` back to today.
    static func clampGameDateAndTimeToMinimumNow(
        gameDate: Date,
        gameStartTime: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> (Date, Date) {
        if !isPastSchedule(gameDate: gameDate, gameStartTime: gameStartTime, now: now, calendar: calendar) {
            return (gameDate, gameStartTime)
        }
        let sodGame = calendar.startOfDay(for: gameDate)
        let sodNow = calendar.startOfDay(for: now)
        if calendar.compare(sodGame, to: sodNow, toGranularity: .day) == .orderedDescending {
            if let atSeven = calendar.date(bySettingHour: 19, minute: 0, second: 0, of: sodGame),
               !isPastSchedule(gameDate: gameDate, gameStartTime: atSeven, now: now, calendar: calendar) {
                return (gameDate, atSeven)
            }
            return (gameDate, gameStartTime)
        }
        let dayStart = calendar.startOfDay(for: now)
        return (dayStart, now)
    }

    /// After the Game Date picker changes: same local calendar day as `now` → `now + 1 hour` rounded **up** to a 15-minute boundary (still on that game day; capped if `+1h` crosses midnight); strictly later local day → 7:00 PM on `newGameDate`.
    static func recommendedStartTimeAfterGameDateChange(
        newGameDate: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date {
        let sodNew = calendar.startOfDay(for: newGameDate)
        let sodNow = calendar.startOfDay(for: now)
        let order = calendar.compare(sodNew, to: sodNow, toGranularity: .day)
        if order == .orderedDescending {
            return calendar.date(bySettingHour: 19, minute: 0, second: 0, of: sodNew) ?? newGameDate
        }
        return defaultStartTimeSameLocalDayAsGameDate(gameDate: newGameDate, now: now, calendar: calendar)
    }

    /// `now + 1 hour`, rounded up to the next 15-minute tick, on `gameDate`’s calendar day; guaranteed `> now` when possible.
    private static func defaultStartTimeSameLocalDayAsGameDate(gameDate: Date, now: Date, calendar: Calendar) -> Date {
        let sod = calendar.startOfDay(for: gameDate)
        guard let oneHourLater = calendar.date(byAdding: .hour, value: 1, to: now) else {
            return calendar.date(bySettingHour: 19, minute: 0, second: 0, of: sod) ?? gameDate
        }

        // If +1h crosses into the next calendar day, cap to a late-evening slot on `gameDate` that is still after `now`.
        if calendar.startOfDay(for: oneHourLater) != sod {
            if let late = calendar.date(bySettingHour: 23, minute: 45, second: 0, of: sod), late > now {
                return late
            }
            return calendar.date(byAdding: .minute, value: 1, to: now) ?? oneHourLater
        }

        let h = calendar.component(.hour, from: oneHourLater)
        let min = calendar.component(.minute, from: oneHourLater)
        let total = h * 60 + min
        let roundedCeil15 = ((total + 14) / 15) * 15
        var nh = roundedCeil15 / 60
        var nm = roundedCeil15 % 60
        if nh >= 24 {
            nh = 23
            nm = 45
        }
        guard var merged = calendar.date(bySettingHour: nh, minute: nm, second: 0, of: sod) else {
            return oneHourLater
        }
        if merged <= now {
            merged = calendar.date(byAdding: .minute, value: 1, to: now) ?? merged
        }
        return merged
    }

#if DEBUG
    static func logBusinessAddGameTimeDateChange(
        oldGameDate: Date,
        newGameDate: Date,
        startTimeBefore: Date,
        startTimeAfter: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) {
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let combined = combinedLocalStart(gameDate: newGameDate, gameStartTime: startTimeAfter, calendar: calendar)
        let isFuture = combined > now
        print("[BusinessAddGameTimeDebug] dateChanged oldDate=\(iso.string(from: oldGameDate))")
        print("[BusinessAddGameTimeDebug] dateChanged newDate=\(iso.string(from: newGameDate))")
        print("[BusinessAddGameTimeDebug] dateChanged startTimeBefore=\(iso.string(from: startTimeBefore))")
        print("[BusinessAddGameTimeDebug] dateChanged startTimeAfter=\(iso.string(from: startTimeAfter))")
        print("[BusinessAddGameTimeDebug] dateChanged combinedStartDateTime=\(iso.string(from: combined))")
        print("[BusinessAddGameTimeDebug] dateChanged now=\(iso.string(from: now))")
        print("[BusinessAddGameTimeDebug] dateChanged isFuture=\(isFuture)")
    }
#endif

    static func logBusinessAddGameSaveDebug(
        gameDate: Date,
        gameStartTime: Date,
        now: Date,
        calendar: Calendar
    ) {
#if DEBUG
        let combined = combinedLocalStart(gameDate: gameDate, gameStartTime: gameStartTime, calendar: calendar)
        let past = isPastSchedule(gameDate: gameDate, gameStartTime: gameStartTime, now: now, calendar: calendar)
        let iso = ISO8601DateFormatter()
        iso.timeZone = calendar.timeZone
        iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        print("[BusinessAddGameSaveDebug] gameDate=\(iso.string(from: gameDate))")
        print("[BusinessAddGameSaveDebug] gameStartTime=\(iso.string(from: gameStartTime))")
        print("[BusinessAddGameSaveDebug] combinedStartDateTime=\(iso.string(from: combined))")
        print("[BusinessAddGameSaveDebug] now=\(iso.string(from: now))")
        print("[BusinessAddGameSaveDebug] isPastSchedule=\(past)")
#endif
    }
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
