import Foundation

/// Automatic removal: `remove_after_at` is always `game_start_at` + this many hours (DB trigger + app payloads).
enum PickupGameAutoRemoval {
    static let hoursAfterGameStart: Int = 24
}

// MARK: - `public.pickup_games` (Supabase snake_case matches Codable)

struct PickupGameRow: Codable, Identifiable, Equatable, Hashable {
    let id: UUID
    let creator_user_id: UUID
    let creator_email: String?
    let title: String
    let sport: String
    let description: String?
    /// Stored tokens: `casual`, `beginner_friendly`, `intermediate`, `competitive`.
    let skill_level: String
    let game_start_at: String
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

struct PickupGameInsert: Encodable {
    let creator_user_id: UUID
    let creator_email: String?
    let title: String
    let sport: String
    let description: String?
    let skill_level: String
    let game_start_at: String
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
}

struct PickupGameFullUpdate: Encodable {
    let title: String
    let sport: String
    let description: String?
    let skill_level: String
    let game_start_at: String
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
        case "cancelled": return "Cancelled"
        default: return status.capitalized
        }
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
        case "cancelled":
            guard let date = organizerDecisionDate else { return "Cancelled" }
            let stamp = compactWidth
                ? Self.organizerStampShort.string(from: date)
                : Self.organizerStampLong.string(from: date)
            return "Cancelled \(stamp)"
        default:
            return statusDisplayTitle
        }
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
}

enum PickupGameModels {
    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoParserNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoEncoder: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let moneyFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 2
        return f
    }()

    static func parseSupabaseTimestamptz(_ raw: String) -> Date? {
        if let d = isoParser.date(from: raw) { return d }
        return isoParserNoFrac.date(from: raw)
    }

    static func encodeSupabaseTimestamptz(_ date: Date) -> String {
        isoEncoder.string(from: date)
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

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to manage pickup games."
        case .missingRowAfterWrite:
            return "Couldn’t read the saved pickup game. Try again in a moment."
        case .businessAccountsCannotUsePickupGames:
            return BusinessFanGateCopy.pickupFanOnly
        }
    }
}
