import Foundation

/// Automatic removal: `remove_after_at` is always `game_start_at` + this many hours (DB trigger + app payloads).
nonisolated enum PickupGameAutoRemoval {
    static let hoursAfterGameStart: Int = 12
}

/// DEBUG: pickup expiration fields immediately before Supabase insert/update (edit + roster sync).
enum PickupExpirationEditDebug {
    static func log(oldGameStartAt: String?, newGameStartAt: String, cleanupDelayHours: Int, computedRemoveAfterAt: String) {
#if DEBUG
        print("[PickupExpirationEditDebug] oldGameStartAt=\(oldGameStartAt ?? "nil")")
        print("[PickupExpirationEditDebug] newGameStartAt=\(newGameStartAt)")
        print("[PickupExpirationEditDebug] cleanupDelayHours=\(cleanupDelayHours)")
        print("[PickupExpirationEditDebug] computedRemoveAfterAt=\(computedRemoveAfterAt)")
#endif
    }
}

enum GameType: String, Codable, CaseIterable {
    case pickup
    case practice
    case scrimmage

    var displayTitle: String {
        switch self {
        case .pickup:
            return "Pickup"
        case .practice:
            return "Practice"
        case .scrimmage:
            return "Scrimmage"
        }
    }

    var badgeTitle: String {
        displayTitle.uppercased()
    }
}

// MARK: - `public.pickup_games` (Supabase snake_case matches Codable)

struct PickupGameRow: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let creator_user_id: UUID
    let creator_email: String?
    let title: String
    let sport: String
    let description: String?
    let game_format: String
    /// Stored tokens: `casual`, `beginner_friendly`, `intermediate`, `competitive`.
    let skill_level: String
    let game_start_at: String
    /// Optional scheduled end. Older rows may be nil; UI falls back to `game_start_at + 2h`.
    let end_time: String?
    let address: String?
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let is_visible: Bool
    let players_needed: Int
    let play_environment: String
    let participant_preference: String
    let is_free: Bool
    let entry_fee_amount: Double?
    let max_players: Int?
    let status: String
    /// Joiners with `approved` status (Phase 2); maintained server-side.
    let approved_join_count: Int?
    let cleanup_delay_hours: Int
    let remove_after_at: String?
    let created_at: String?
    let updated_at: String?
}

extension PickupGameRow {
    /// Local optimistic patch (e.g. after joiner withdraw) before server row is re-fetched.
    func replacingApprovedJoinCount(_ newApprovedJoinCount: Int?) -> PickupGameRow {
        PickupGameRow(
            id: id,
            creator_user_id: creator_user_id,
            creator_email: creator_email,
            title: title,
            sport: sport,
            description: description,
            game_format: game_format,
            skill_level: skill_level,
            game_start_at: game_start_at,
            end_time: end_time,
            address: address,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude,
            is_visible: is_visible,
            players_needed: players_needed,
            play_environment: play_environment,
            participant_preference: participant_preference,
            is_free: is_free,
            entry_fee_amount: entry_fee_amount,
            max_players: max_players,
            status: status,
            approved_join_count: newApprovedJoinCount,
            cleanup_delay_hours: cleanup_delay_hours,
            remove_after_at: remove_after_at,
            created_at: created_at,
            updated_at: updated_at
        )
    }

    /// When this row should disappear from **Settings → My pickup games → History** (and matches organizer History footer math).
    /// Prefers `remove_after_at` from the server; otherwise `game_start_at` + retention hours.
    func pickupHistoryClientCleanupDeadline() -> Date? {
        if let rem = remove_after_at, let d = PickupGameModels.parseSupabaseTimestamptz(rem) {
            return d
        }
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at) else { return nil }
        let hours = cleanup_delay_hours > 0 ? cleanup_delay_hours : PickupGameAutoRemoval.hoursAfterGameStart
        let clamped = max(1, min(168, hours))
        return start.addingTimeInterval(Double(clamped) * 3600)
    }

    var pickupCompactTimeRange: String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at),
              let end = PickupGameModels.endDate(for: self),
              end > start else {
            return nil
        }
        return "\(start.formatted(date: .omitted, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
    }

    var pickupCompactDurationLabel: String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at),
              let end = PickupGameModels.endDate(for: self),
              end > start else {
            return nil
        }
        let minutes = Int((end.timeIntervalSince(start) / 60).rounded())
        guard minutes > 0 else { return nil }
        if minutes % 60 == 0 {
            return "\(minutes / 60)h game"
        }
        return "\(minutes / 60)h \(minutes % 60)m game"
    }

    var pickupDateWithCompactTimeRange: String? {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at) else { return nil }
        let dateText = start.formatted(date: .abbreviated, time: .omitted)
        if let range = pickupCompactTimeRange {
            return "\(dateText) • \(range)"
        }
        return start.formatted(date: .abbreviated, time: .shortened)
    }

    var gameFormat: GameType {
        GameType(rawValue: game_format) ?? .pickup
    }
}

struct PickupGameInsert: Encodable {
    let creator_user_id: UUID
    let creator_email: String?
    let title: String
    let sport: String
    let description: String?
    let game_format: String
    let skill_level: String
    let game_start_at: String
    let end_time: String
    let address: String?
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let is_visible: Bool
    let players_needed: Int
    let play_environment: String
    let participant_preference: String
    let is_free: Bool
    let entry_fee_amount: Double?
    let max_players: Int?
    let cleanup_delay_hours: Int
    /// Always `game_start_at` + 12h; sent on every write so `remove_after_at` never lags behind an edited start time.
    let remove_after_at: String

    /// Write payload with canonical 12h pickup retention and forced Discover visibility.
    func withCanonicalPickupCleanupDelay() -> PickupGameInsert {
        let remove = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: game_start_at)
        return PickupGameInsert(
            creator_user_id: creator_user_id,
            creator_email: creator_email,
            title: title,
            sport: sport,
            description: description,
            game_format: game_format,
            skill_level: skill_level,
            game_start_at: game_start_at,
            end_time: end_time,
            address: address,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude,
            is_visible: true,
            players_needed: players_needed,
            play_environment: play_environment,
            participant_preference: participant_preference,
            is_free: is_free,
            entry_fee_amount: entry_fee_amount,
            max_players: max_players,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: remove
        )
    }
}

struct PickupGameFullUpdate: Encodable {
    let title: String
    let sport: String
    let description: String?
    let game_format: String
    let skill_level: String
    let game_start_at: String
    let end_time: String
    let address: String?
    let city: String?
    let state: String?
    let latitude: Double?
    let longitude: Double?
    let is_visible: Bool
    let players_needed: Int
    let play_environment: String
    let participant_preference: String
    let is_free: Bool
    let entry_fee_amount: Double?
    let max_players: Int?
    let cleanup_delay_hours: Int
    /// Always `game_start_at` + 12h; sent on full edit so expiration tracks the edited start instant.
    let remove_after_at: String

    /// Write payload with canonical 12h pickup retention and forced Discover visibility.
    func withCanonicalPickupCleanupDelay() -> PickupGameFullUpdate {
        let remove = PickupGameModels.encodedPickupRemoveAfterAt(forEncodedGameStart: game_start_at)
        return PickupGameFullUpdate(
            title: title,
            sport: sport,
            description: description,
            game_format: game_format,
            skill_level: skill_level,
            game_start_at: game_start_at,
            end_time: end_time,
            address: address,
            city: city,
            state: state,
            latitude: latitude,
            longitude: longitude,
            is_visible: true,
            players_needed: players_needed,
            play_environment: play_environment,
            participant_preference: participant_preference,
            is_free: is_free,
            entry_fee_amount: entry_fee_amount,
            max_players: max_players,
            cleanup_delay_hours: PickupGameAutoRemoval.hoursAfterGameStart,
            remove_after_at: remove
        )
    }
}

/// Post-start roster patch: includes `game_start_at` / expiration columns so DB + PostgREST always re-sync `remove_after_at`
/// to the saved start time + 12h (covers legacy `UPDATE OF …` triggers that skipped roster-only updates).
struct PickupGameRosterCapacityUpdate: Encodable {
    let players_needed: Int
    let max_players: Int?
    let game_start_at: String
    let cleanup_delay_hours: Int
    let remove_after_at: String
}

/// Organizer soft-delete: hide from Discover/Calendar and allow bulk-cancel of join requests.
struct PickupGameSoftRemoveUpdate: Encodable {
    let status: String
    let is_visible: Bool
    let remove_after_at: String
}

// MARK: - Pickup creator ratings (`public.pickup_game_creator_ratings`)

nonisolated struct PickupCreatorPublicRatingStats: Equatable {
    let avgRating: Double
    let ratingCount: Int

    var trustDisplayLine: String {
        let avg = String(format: "%.1f", avgRating)
        let n = ratingCount == 1 ? "1 rating" : "\(ratingCount) ratings"
        return "★ \(avg) · \(n)"
    }

    /// Public pickup UI: star summary when rated, otherwise **New organizer** (no private feedback).
    var organizerTrustSummaryLine: String {
        guard ratingCount > 0 else { return "New organizer" }
        return trustDisplayLine
    }

    /// Pickup game **detail** sheet: always includes a leading star; uses “reviews” wording.
    var pickupOrganizerDetailRatingLine: String {
        if ratingCount > 0 {
            let avg = String(format: "%.1f", avgRating)
            let reviews = ratingCount == 1 ? "1 review" : "\(ratingCount) reviews"
            return "★ \(avg) · \(reviews)"
        }
        return "★ New organizer · No ratings yet"
    }

    /// Optional tier for public profile (derived from existing ``ratingCount`` / ``avgRating`` only).
    var publicProfileOrganizerTierLabel: String? {
        guard ratingCount > 0 else { return nil }
        if ratingCount >= 15, avgRating >= 4.7 { return "Top host" }
        if ratingCount >= 8, avgRating >= 4.5 { return "Trusted host" }
        if ratingCount >= 3 { return "Rated host" }
        return nil
    }

    /// Short trust copy for public profile organizer card.
    var publicProfileOrganizerTrustCopy: String {
        guard ratingCount > 0 else {
            return "This host is just getting started."
        }
        if avgRating >= 4.5, ratingCount >= 5 {
            return "Trusted by local players."
        }
        if avgRating >= 4.0 {
            return "Well rated by local players."
        }
        return "Building a pickup reputation."
    }

    var hasPublicOrganizerRatings: Bool {
        ratingCount > 0
    }
}

/// DEBUG: public profile pickup organizer reputation card.
enum PickupOrganizerReputationDebug {
    static func log(creatorUserId: UUID, stats: PickupCreatorPublicRatingStats?) {
#if DEBUG
        let resolved = stats ?? PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        print("[PickupOrganizerReputationDebug] userId=\(creatorUserId.uuidString.lowercased())")
        print("[PickupOrganizerReputationDebug] existingRatingLine=\(resolved.pickupOrganizerDetailRatingLine)")
        if resolved.ratingCount > 0 {
            print("[PickupOrganizerReputationDebug] avgRating=\(String(format: "%.1f", resolved.avgRating))")
            print("[PickupOrganizerReputationDebug] ratingCount=\(resolved.ratingCount)")
        } else {
            print("[PickupOrganizerReputationDebug] avgRating=n/a")
            print("[PickupOrganizerReputationDebug] ratingCount=0")
        }
#endif
    }
}

/// DEBUG: organizer identity resolved for pickup preview/detail cards.
enum PickupOrganizerDebug {
    static func log(organizerUserId: UUID, organizerAvatarUrl: String, organizerDisplayName: String) {
#if DEBUG
        print("[PickupOrganizerDebug] organizerUserId=\(organizerUserId.uuidString.lowercased())")
        print("[PickupOrganizerDebug] organizerAvatarUrl=\(organizerAvatarUrl)")
        print("[PickupOrganizerDebug] organizerDisplayName=\(organizerDisplayName)")
#endif
    }
}

/// Decodes JSON number or string for `numeric` columns from RPC.
struct PickupRPCNumericOrString: Decodable {
    let doubleValue: Double?

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let d = try? c.decode(Double.self) {
            doubleValue = d
        } else if let s = try? c.decode(String.self), let d = Double(s) {
            doubleValue = d
        } else {
            doubleValue = nil
        }
    }
}

/// RPC `pickup_creator_public_rating_stats` row (PostgREST JSON).
nonisolated struct PickupCreatorPublicRatingStatsRPCRow: Decodable {
    let avg_rating: PickupRPCNumericOrString?
    let rating_count: Int64

    nonisolated func toPublicStats() -> PickupCreatorPublicRatingStats? {
        if rating_count == 0 {
            return PickupCreatorPublicRatingStats(avgRating: 0, ratingCount: 0)
        }
        guard let avg = avg_rating?.doubleValue else { return nil }
        return PickupCreatorPublicRatingStats(avgRating: avg, ratingCount: Int(rating_count))
    }
}

struct PickupGameCreatorRatingUpsert: Encodable {
    let pickup_game_id: UUID
    let creator_user_id: UUID
    let rater_user_id: UUID
    let rating: Int
    let feedback: String?
}

/// DEBUG: organizer rating line on FanGeo pickup detail (matches UI copy).
enum PickupOrganizerRatingDebug {
    static func log(creatorUserId: UUID, stats: PickupCreatorPublicRatingStats?) {
#if DEBUG
        print("[PickupOrganizerRatingDebug] creatorUserId=\(creatorUserId.uuidString.lowercased())")
        if let stats, stats.ratingCount > 0 {
            print("[PickupOrganizerRatingDebug] avgRating=\(String(format: "%.1f", stats.avgRating))")
            print("[PickupOrganizerRatingDebug] ratingCount=\(stats.ratingCount)")
            print("[PickupOrganizerRatingDebug] shownOnDetail=\(stats.pickupOrganizerDetailRatingLine)")
        } else if let stats {
            print("[PickupOrganizerRatingDebug] avgRating=n/a")
            print("[PickupOrganizerRatingDebug] ratingCount=\(stats.ratingCount)")
            print("[PickupOrganizerRatingDebug] shownOnDetail=\(stats.pickupOrganizerDetailRatingLine)")
        } else {
            print("[PickupOrganizerRatingDebug] avgRating=nil")
            print("[PickupOrganizerRatingDebug] ratingCount=nil")
            print("[PickupOrganizerRatingDebug] shownOnDetail=nil")
        }
#endif
    }
}

enum PickupCreatorRatingDebug {
    static func log(
        pickupGameId: UUID,
        creatorUserId: UUID,
        raterUserId: UUID?,
        rating: Int?,
        submitSucceeded: Bool?,
        alreadyRated: Bool?
    ) {
#if DEBUG
        print("[PickupCreatorRatingDebug] pickupGameId=\(pickupGameId.uuidString.lowercased())")
        print("[PickupCreatorRatingDebug] creatorUserId=\(creatorUserId.uuidString.lowercased())")
        print("[PickupCreatorRatingDebug] raterUserId=\(raterUserId?.uuidString.lowercased() ?? "nil")")
        print("[PickupCreatorRatingDebug] rating=\(rating.map(String.init) ?? "nil")")
        print("[PickupCreatorRatingDebug] submitSucceeded=\(submitSucceeded.map { $0 ? "true" : "false" } ?? "nil")")
        print("[PickupCreatorRatingDebug] alreadyRated=\(alreadyRated.map { $0 ? "true" : "false" } ?? "nil")")
#endif
    }
}

// MARK: - `public.pickup_game_requests` (Phase 2 join workflow)

struct PickupGameRequestRow: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let pickup_game_id: UUID
    let requester_user_id: UUID
    let requester_email: String?
    let requester_display_name: String?
    let requester_skill_level: String
    let message: String?
    let status: String
    let created_at: String?
    let updated_at: String?
    let responded_at: String?
}

struct PickupGameRequestInsert: Encodable {
    let pickup_game_id: UUID
    let requester_user_id: UUID
    let requester_email: String?
    let requester_display_name: String?
    let requester_skill_level: String
    let message: String?
}

struct PickupJoinRequestStatusUpdate: Encodable {
    let status: String
}

extension PickupGameRequestRow {
    var requesterSkillLevelEnum: PickupGameSkillLevel {
        PickupGameSkillLevel.fromStored(requester_skill_level)
    }

    var statusDisplayTitle: String {
        switch status.lowercased() {
        case "pending": return "Pending"
        case "approved": return "Approved"
        case "rejected": return "Rejected"
        case "cancelled": return "Withdrawn"
        case "withdrawn": return "Withdrawn"
        default: return status.capitalized
        }
    }

    /// Prefer `updated_at` over `created_at` when multiple join rows exist for the same game (re-requests).
    var pickupJoinRequestRecencyInstant: Date {
        let u = updated_at.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
        let c = created_at.flatMap { PickupGameModels.parseSupabaseTimestamptz($0) }
        return u ?? c ?? .distantPast
    }

    /// One row per `pickup_game_id`: the most recently touched request for that game.
    static func pickupLatestRequestByGameId(_ rows: [PickupGameRequestRow]) -> [UUID: PickupGameRequestRow] {
        var best: [UUID: PickupGameRequestRow] = [:]
        for r in rows {
            guard let existing = best[r.pickup_game_id] else {
                best[r.pickup_game_id] = r
                continue
            }
            let nr = r.pickupJoinRequestRecencyInstant
            let er = existing.pickupJoinRequestRecencyInstant
            if nr > er {
                best[r.pickup_game_id] = r
            } else if nr == er, r.id.uuidString > existing.id.uuidString {
                best[r.pickup_game_id] = r
            }
        }
        return best
    }

    var requesterNameForUI: String {
        let n = requester_display_name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !n.isEmpty { return n }
        return "Player"
    }

    /// Best-effort instant the organizer (or requester cancel) last changed terminal status (`responded_at`, else `updated_at`).
    var organizerDecisionDate: Date? {
        let st = status.lowercased()
        guard st != "pending" else { return nil }
        if let r = responded_at, let d = PickupGameModels.parseSupabaseTimestamptz(r) { return d }
        if let u = updated_at, let d = PickupGameModels.parseSupabaseTimestamptz(u) { return d }
        return nil
    }

    private static let organizerStampLong: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "MMM d, yyyy 'at' h:mm a"
        return f
    }()

    private static let organizerStampShort: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "MMM d · h:mm a"
        return f
    }()

    /// Apple-style copy for the organizer requests list (e.g. `Requested May 14, 2026 at 3:42 PM`).
    func organizerRequestedCaption(compactWidth: Bool) -> String {
        guard let created_at, let date = PickupGameModels.parseSupabaseTimestamptz(created_at) else {
            return "Requested"
        }
        let stamp = compactWidth
            ? Self.organizerStampShort.string(from: date)
            : Self.organizerStampLong.string(from: date)
        return "Requested \(stamp)"
    }

    /// Second line under the request: pending vs terminal status + decision time when known.
    func organizerDecisionStatusCaption(compactWidth: Bool) -> String {
        switch status.lowercased() {
        case "pending":
            return "Waiting for your decision"
        case "approved":
            guard let date = organizerDecisionDate else { return "Approved" }
            let stamp = compactWidth
                ? Self.organizerStampShort.string(from: date)
                : Self.organizerStampLong.string(from: date)
            return "Approved \(stamp)"
        case "rejected":
            guard let date = organizerDecisionDate else { return "Rejected" }
            let stamp = compactWidth
                ? Self.organizerStampShort.string(from: date)
                : Self.organizerStampLong.string(from: date)
            return "Rejected \(stamp)"
        case "withdrawn":
            return "Player changed their mind"
        case "cancelled":
            if responded_at == nil {
                return "Player withdrew their request"
            }
            return "Player changed their mind"
        default:
            return statusDisplayTitle
        }
    }

    /// Organizer-facing line for Settings “Can’t make it” list (fan withdrew / cancelled join).
    func organizerFanWithdrawnSubtitle() -> String {
        let st = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if st == "withdrawn" { return "Player changed their mind" }
        if st == "cancelled", responded_at != nil { return "Player changed their mind" }
        return "Player withdrew their request"
    }

    func organizerFanWithdrawnTimestampLine(compactWidth: Bool) -> String? {
        guard let date = organizerDecisionDate else { return nil }
        let stamp = compactWidth
            ? Self.organizerStampShort.string(from: date)
            : Self.organizerStampLong.string(from: date)
        return "Updated \(stamp)"
    }
}

// MARK: - Pickup option enums (raw values match DB CHECK constraints)

enum PickupPlayEnvironment: String, CaseIterable, Identifiable {
    case indoor
    case outdoor
    case either

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .indoor: return "Indoor"
        case .outdoor: return "Outdoor"
        case .either: return "Indoor or Outdoor"
        }
    }

    var shortLabel: String {
        switch self {
        case .indoor: return "Indoor"
        case .outdoor: return "Outdoor"
        case .either: return "In or Out"
        }
    }
}

enum PickupGameSkillLevel: String, CaseIterable, Identifiable {
    case casual
    case beginner_friendly
    case intermediate
    case competitive

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .casual: return "Casual"
        case .beginner_friendly: return "Beginner Friendly"
        case .intermediate: return "Intermediate"
        case .competitive: return "Competitive"
        }
    }

    static func fromStored(_ raw: String?) -> PickupGameSkillLevel {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .casual
        }
        return PickupGameSkillLevel(rawValue: raw) ?? .casual
    }
}

enum PickupParticipantPreference: String, CaseIterable, Identifiable {
    case everyone
    case women_only
    case men_only
    case adults_only
    case teens_welcome

    var id: String { rawValue }

    var displayTitle: String {
        switch self {
        case .everyone: return "Everyone Welcome"
        case .women_only: return "Women Only"
        case .men_only: return "Men Only"
        case .adults_only: return "Adults Only"
        case .teens_welcome: return "Teens Welcome"
        }
    }

    var shortLabel: String {
        switch self {
        case .everyone: return "All welcome"
        case .women_only: return "Women"
        case .men_only: return "Men"
        case .adults_only: return "Adults"
        case .teens_welcome: return "Teens OK"
        }
    }

    static func fromStored(_ raw: String?) -> PickupParticipantPreference {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !raw.isEmpty else {
            return .everyone
        }
        return PickupParticipantPreference(rawValue: raw) ?? .everyone
    }
}

extension PickupGameRow {
    var approvedJoinCount: Int {
        approved_join_count ?? 0
    }

    /// Open join slots (joiners only; creator is separate from this count).
    var pickupOpenSlotsRemaining: Int {
        max(0, playersNeededClamped - approvedJoinCount)
    }

    var isPickupFullForDiscover: Bool {
        approvedJoinCount >= playersNeededClamped
    }

    var playersNeededClamped: Int {
        min(20, max(1, players_needed))
    }

    var lookingForPlayersLine: String {
        let n = playersNeededClamped
        return n == 1 ? "Looking for 1 player" : "Looking for \(n) players"
    }

    var playEnvironmentEnum: PickupPlayEnvironment {
        PickupPlayEnvironment(rawValue: play_environment) ?? .either
    }

    var skillLevelEnum: PickupGameSkillLevel {
        PickupGameSkillLevel.fromStored(skill_level)
    }

    var participantPreferenceEnum: PickupParticipantPreference {
        PickupParticipantPreference.fromStored(participant_preference)
    }

    /// One line for list rows: "Free" or "$12 entry" (USD).
    var entryFeeDisplayLine: String {
        if is_free { return "Free" }
        guard let amt = entry_fee_amount else { return "Paid" }
        return PickupGameModels.currencyEntryString(amount: amt)
    }

    /// Compact Discover chip, e.g. "$12".
    var entryFeeChipTitle: String {
        if is_free { return "Free" }
        guard let amt = entry_fee_amount else { return "Paid" }
        return PickupGameModels.currencyChipString(amount: amt)
    }

    var maxPlayersChipTitle: String? {
        guard let max = max_players else { return nil }
        return "Max \(max)"
    }

    /// True when local time has reached or passed the scheduled start (`now >= game_start_at`).
    func hasPickupGameStarted(now: Date = Date()) -> Bool {
        guard let start = PickupGameModels.parseSupabaseTimestamptz(game_start_at) else { return false }
        return now >= start
    }

    /// After start, or after the listing `remove_after_at` moment (post-window), show post-game organizer rating UI.
    func isPickupCreatorRatingPromptEligible(now: Date = Date()) -> Bool {
        if hasPickupGameStarted(now: now) { return true }
        if let rem = remove_after_at,
           let remDate = PickupGameModels.parseSupabaseTimestamptz(rem),
           now >= remDate {
            return true
        }
        return false
    }
}

/// DEBUG lines for pickup post-start organizer UX (see product spec).
enum PickupGameStartedStateDebug {
    private static let logNowFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func log(row: PickupGameRow, now: Date, allowedActions: String) {
#if DEBUG
        let isStarted = row.hasPickupGameStarted(now: now)
        print("[PickupGameStartedStateDebug] gameId=\(row.id.uuidString.lowercased())")
        print("[PickupGameStartedStateDebug] game_start_at=\(row.game_start_at)")
        print("[PickupGameStartedStateDebug] now=\(logNowFormatter.string(from: now))")
        print("[PickupGameStartedStateDebug] isStarted=\(isStarted)")
        print("[PickupGameStartedStateDebug] allowedActions=\(allowedActions)")
#endif
    }
}

enum PickupGameModels {
    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    nonisolated static func parseSupabaseTimestamptz(_ raw: String) -> Date? {
        SupabaseTimestampParsing.parseTimestamptz(raw)
    }

    nonisolated static func encodeSupabaseTimestamptz(_ date: Date) -> String {
        SupabaseTimestampParsing.encodeTimestamptz(date)
    }

    nonisolated static func defaultPickupEndTime(forStart start: Date) -> Date {
        start.addingTimeInterval(2 * 3600)
    }

    nonisolated static func endDate(for row: PickupGameRow) -> Date? {
        if let raw = row.end_time, let end = parseSupabaseTimestamptz(raw) {
            return end
        }
        guard let start = parseSupabaseTimestamptz(row.game_start_at) else { return nil }
        return defaultPickupEndTime(forStart: start)
    }

    nonisolated static func encodedDefaultEndTime(forStart start: Date) -> String {
        encodeSupabaseTimestamptz(defaultPickupEndTime(forStart: start))
    }

    /// Encoded `remove_after_at` for `pickup_games`: `game_start_at` + fixed pickup retention (12h).
    nonisolated static func encodedPickupRemoveAfterAt(forEncodedGameStart gameStartISO: String) -> String {
        let start = parseSupabaseTimestamptz(gameStartISO) ?? Date(timeIntervalSince1970: 0)
        let end = start.addingTimeInterval(Double(PickupGameAutoRemoval.hoursAfterGameStart) * 3600)
        return encodeSupabaseTimestamptz(end)
    }

    static func currencyEntryString(amount: Double) -> String {
        let n = NSNumber(value: amount)
        let base = moneyFormatter.string(from: n) ?? "$\(String(format: "%.2f", amount))"
        return base + " entry"
    }

    static func currencyChipString(amount: Double) -> String {
        let n = NSNumber(value: amount)
        return moneyFormatter.string(from: n) ?? "$\(String(format: "%.2f", amount))"
    }
}

enum PickupGameClientError: LocalizedError {
    case notSignedIn
    case missingRowAfterWrite
    case businessAccountsCannotUsePickupGames
    case pickupGameNotFound
    case pickupGameNotOrganizer

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to manage pickup games."
        case .missingRowAfterWrite:
            return "Couldn’t read the saved pickup game. Try again in a moment."
        case .businessAccountsCannotUsePickupGames:
            return BusinessFanGateCopy.pickupFanOnly
        case .pickupGameNotFound:
            return "Couldn’t find this pickup game to update. Try refreshing My pickup games."
        case .pickupGameNotOrganizer:
            return "Only the organizer can cancel this pickup game."
        }
    }
}
