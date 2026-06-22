import Foundation
import Supabase

// MARK: - Model

struct FanGeoAnnouncement: Identifiable, Equatable, Sendable {
    let id: UUID
    let title: String
    let subtitle: String?
    let announcementDescription: String?
    let imageURL: String?
    let secondaryImageURL: String?
    let ctaLabel: String?
    let ctaAction: String?
    let audienceFans: Bool
    let audienceBusinesses: Bool
    let displayType: String
    let status: String
    let startDate: Date?
    let endDate: Date?
    let priority: Int
    let createdAt: Date?
    let updatedAt: Date?
    let targetCountry: String?
    let targetState: String?
    let targetCity: String?
    let dismissVersion: Int
    let promotionType: String?
    let promotedVenueId: UUID?
    let targetRadiusMiles: Double?
    let promoOfferType: String?
    let promoOfferChip: String?
    let deletedAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case subtitle
        case announcementDescription = "description"
        case imageURL = "image_url"
        case secondaryImageURL = "secondary_image_url"
        case ctaLabel = "cta_label"
        case ctaAction = "cta_action"
        case audienceFans = "audience_fans"
        case audienceBusinesses = "audience_businesses"
        case displayType = "display_type"
        case status
        case startDate = "start_date"
        case endDate = "end_date"
        case priority
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case targetCountry = "target_country"
        case targetState = "target_state"
        case targetCity = "target_city"
        case dismissVersion = "dismiss_version"
        case promotionType = "promotion_type"
        case promotedVenueId = "promoted_venue_id"
        case targetRadiusMiles = "target_radius_miles"
        case promoOfferType = "promo_offer_type"
        case promoOfferChip = "promo_offer_chip"
        case deletedAt = "deleted_at"
    }

    var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedSubtitle: String {
        subtitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedDescription: String {
        announcementDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedPromoOfferChip: String {
        promoOfferChip?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var bodyText: String {
        if !trimmedSubtitle.isEmpty { return trimmedSubtitle }
        return trimmedDescription
    }

    var trimmedCTALabel: String {
        ctaLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var trimmedCTAAction: String {
        ctaAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    var shouldShowDiscoverBannerCTA: Bool {
        guard !trimmedCTALabel.isEmpty else { return false }
        if isSponsoredDiscoverPromotion {
            return true
        }
        let action = trimmedCTAAction
        guard !action.isEmpty else { return false }
        return action.lowercased() != "none"
    }

    var resolvedImageURL: URL? {
        Self.resolvedURL(from: imageURL)
    }

    var resolvedSecondaryImageURL: URL? {
        Self.resolvedURL(from: secondaryImageURL)
    }

    private static func resolvedURL(from raw: String?) -> URL? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return URL(string: trimmed)
    }

    var isPresentable: Bool {
        isValidDiscoverBannerCandidate && (
            !trimmedTitle.isEmpty
                || !trimmedSubtitle.isEmpty
                || !trimmedDescription.isEmpty
                || resolvedImageURL != nil
        )
    }

    var normalizedPromotionType: String {
        promotionType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_") ?? ""
    }

    var isValidDiscoverBannerCandidate: Bool {
        true
    }

    var isSponsoredDiscoverPromotion: Bool {
        switch normalizedPromotionType {
        case "venue", "sponsored", "venue_promotion":
            return true
        default:
            return false
        }
    }

    static func discoverCarouselSort(_ lhs: FanGeoAnnouncement, _ rhs: FanGeoAnnouncement) -> Bool {
        if lhs.isSponsoredDiscoverPromotion != rhs.isSponsoredDiscoverPromotion {
            return !lhs.isSponsoredDiscoverPromotion
        }
        let lhsCreated = lhs.createdAt ?? .distantPast
        let rhsCreated = rhs.createdAt ?? .distantPast
        return lhsCreated > rhsCreated
    }

    func matchesAudience(isBusinessUser: Bool) -> Bool {
        if isBusinessUser {
            return audienceBusinesses
        }
        return audienceFans
    }

    var isGlobalGeoTarget: Bool {
        FanGeoAnnouncementGeoMatcher.normalized(targetCountry).isEmpty
            && FanGeoAnnouncementGeoMatcher.normalized(targetState).isEmpty
            && FanGeoAnnouncementGeoMatcher.normalized(targetCity).isEmpty
    }

    func matchesGeography(userLocation: FanGeoAnnouncementUserLocation) -> Bool {
        FanGeoAnnouncementGeoMatcher.matchesAnnouncement(self, userLocation: userLocation)
    }

    func isActive(at date: Date = Date()) -> Bool {
        activeExclusionReason(at: date) == nil
    }

    func activeExclusionReason(at date: Date = Date()) -> String? {
        if deletedAt != nil {
            return "deleted"
        }
        let normalizedStatus = status.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedStatus == "active" else {
            return "status(\(status))"
        }
        if let startDate, date < startDate {
            return "beforeStart(\(Self.debugDateString(startDate)))"
        }
        if let endDate, date > endDate {
            return "afterEnd(\(Self.debugDateString(endDate)))"
        }
        return nil
    }

    static func discoverFetchExclusionReason(for row: FanGeoAnnouncement, at date: Date = Date()) -> String? {
        if row.deletedAt != nil { return "deleted" }
        if !row.isPresentable { return "notPresentable" }
        return row.activeExclusionReason(at: date)
    }

    static func discoverSelectionExclusionReason(
        for row: FanGeoAnnouncement,
        isBusinessUser: Bool,
        userLocation: FanGeoAnnouncementUserLocation,
        at date: Date = Date()
    ) -> String? {
        if let fetchReason = discoverFetchExclusionReason(for: row, at: date) {
            return fetchReason
        }
        if !row.matchesAudience(isBusinessUser: isBusinessUser) {
            return "audienceMismatch"
        }
        if !row.matchesGeography(userLocation: userLocation) {
            return "geoMismatch"
        }
        if FanGeoAnnouncementDismissStore.isDismissed(row, now: date) {
            return "dismissed"
        }
        return nil
    }

#if DEBUG
    static func logDiscoverAnnouncementEvaluation(
        row: FanGeoAnnouncement,
        phase: String,
        included: Bool,
        reason: String?,
        isBusinessUser: Bool? = nil,
        userLocation: FanGeoAnnouncementUserLocation? = nil
    ) {
        let audienceUser = isBusinessUser.map { $0 ? "business" : "fan" } ?? "unknown"
        let targetSummary: String = {
            if row.isGlobalGeoTarget { return "global" }
            return [
                row.targetCountry.map { "country=\($0)" },
                row.targetState.map { "state=\($0)" },
                row.targetCity.map { "city=\($0)" }
            ]
            .compactMap { $0 }
            .joined(separator: " ")
        }()
        let userGeoSummary = userLocation.map {
            "country=\($0.country) region=\($0.region) city=\($0.city)"
        } ?? "unknown"
        print(
            "[AnnouncementDebug] phase=\(phase) included=\(included) reason=\(reason ?? "none") " +
            "id=\(row.id.uuidString.lowercased()) title=\(row.trimmedTitle) " +
            "promotionType=\(row.promotionType ?? "nil") normalized=\(row.normalizedPromotionType) " +
            "status=\(row.status) deletedAt=\(debugDateString(row.deletedAt)) startDate=\(debugDateString(row.startDate)) endDate=\(debugDateString(row.endDate)) " +
            "audienceFans=\(row.audienceFans) audienceBusinesses=\(row.audienceBusinesses) audienceUser=\(audienceUser) " +
            "target=\(targetSummary) userGeo=\(userGeoSummary) " +
            "promotedVenueId=\(row.promotedVenueId?.uuidString.lowercased() ?? "nil") " +
            "sponsored=\(row.isSponsoredDiscoverPromotion)"
        )
    }

    static func debugDateString(_ date: Date?) -> String {
        guard let date else { return "nil" }
        return debugDateFormatter.string(from: date)
    }

    private static let debugDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        return formatter
    }()
#endif
}

extension FanGeoAnnouncement: Decodable {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decodeIfPresent(String.self, forKey: .title) ?? ""
        subtitle = try container.decodeIfPresent(String.self, forKey: .subtitle)
        announcementDescription = try container.decodeIfPresent(String.self, forKey: .announcementDescription)
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL)
        secondaryImageURL = try container.decodeIfPresent(String.self, forKey: .secondaryImageURL)
        ctaLabel = try container.decodeIfPresent(String.self, forKey: .ctaLabel)
        ctaAction = try container.decodeIfPresent(String.self, forKey: .ctaAction)
        audienceFans = try container.decodeIfPresent(Bool.self, forKey: .audienceFans) ?? false
        audienceBusinesses = try container.decodeIfPresent(Bool.self, forKey: .audienceBusinesses) ?? false
        displayType = try container.decodeIfPresent(String.self, forKey: .displayType) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        startDate = Self.decodeOptionalBoundDate(from: container, key: .startDate, boundary: .start)
        endDate = Self.decodeOptionalBoundDate(from: container, key: .endDate, boundary: .end)
        priority = try container.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        createdAt = Self.decodeOptionalDate(from: container, key: .createdAt)
        updatedAt = Self.decodeOptionalDate(from: container, key: .updatedAt)
        targetCountry = try container.decodeIfPresent(String.self, forKey: .targetCountry)
        targetState = try container.decodeIfPresent(String.self, forKey: .targetState)
        targetCity = try container.decodeIfPresent(String.self, forKey: .targetCity)
        dismissVersion = max(1, try container.decodeIfPresent(Int.self, forKey: .dismissVersion) ?? 1)
        promotionType = try container.decodeIfPresent(String.self, forKey: .promotionType)
        promotedVenueId = Self.decodeOptionalUUID(from: container, key: .promotedVenueId)
        targetRadiusMiles = Self.decodeOptionalDouble(from: container, key: .targetRadiusMiles)
        promoOfferType = try container.decodeIfPresent(String.self, forKey: .promoOfferType)
        promoOfferChip = try container.decodeIfPresent(String.self, forKey: .promoOfferChip)
        deletedAt = Self.decodeOptionalDate(from: container, key: .deletedAt)
    }

    private enum AnnouncementDateBoundary {
        case start
        case end
    }

    private static func decodeOptionalUUID(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> UUID? {
        if let uuid = try? container.decodeIfPresent(UUID.self, forKey: key) {
            return uuid
        }
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return UUID(uuidString: trimmed)
        }
        return nil
    }

    private static func decodeOptionalBoundDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys,
        boundary: AnnouncementDateBoundary
    ) -> Date? {
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if let dateOnly = normalizedDateOnlyComponent(from: trimmed) {
                return localDayBoundary(forDateOnly: dateOnly, boundary: boundary)
            }
            return SupabaseTimestampParsing.parseTimestamptz(trimmed)
        }
        if let raw = try? container.decodeIfPresent(Date.self, forKey: key) {
            return raw
        }
        return nil
    }

    private static func normalizedDateOnlyComponent(from raw: String) -> String? {
        if isDateOnlyString(raw) {
            return raw
        }
        guard raw.count >= 10 else { return nil }
        let datePrefix = String(raw.prefix(10))
        guard isDateOnlyString(datePrefix) else { return nil }

        let suffix = String(raw.dropFirst(10))
        guard suffix.isEmpty
            || suffix == "T00:00:00"
            || suffix == "T00:00:00Z"
            || suffix == "T00:00:00.000Z"
            || suffix == "T00:00:00+00:00"
            || suffix == "T00:00:00.000+00:00"
            || suffix == " 00:00:00"
            || suffix == " 00:00:00+00"
            || suffix == " 00:00:00+00:00" else {
            return nil
        }
        return datePrefix
    }

    private static func isDateOnlyString(_ raw: String) -> Bool {
        raw.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil
    }

    private static func localDayBoundary(forDateOnly raw: String, boundary: AnnouncementDateBoundary) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = Calendar.current.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard let parsedDay = formatter.date(from: raw) else { return nil }

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: parsedDay)
        switch boundary {
        case .start:
            return dayStart
        case .end:
            return calendar.date(bySettingHour: 23, minute: 59, second: 59, of: dayStart)
                ?? dayStart.addingTimeInterval(86_399)
        }
    }

    private static func decodeOptionalDouble(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Double? {
        if let value = try? container.decodeIfPresent(Double.self, forKey: key) {
            return value
        }
        if let stringValue = try? container.decodeIfPresent(String.self, forKey: key),
           let parsed = Double(stringValue.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return parsed
        }
        if let intValue = try? container.decodeIfPresent(Int.self, forKey: key) {
            return Double(intValue)
        }
        return nil
    }

    private static func decodeOptionalDate(
        from container: KeyedDecodingContainer<CodingKeys>,
        key: CodingKeys
    ) -> Date? {
        if let raw = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            return SupabaseTimestampParsing.parseTimestamptz(trimmed)
        }
        if let raw = try? container.decodeIfPresent(Date.self, forKey: key) {
            return raw
        }
        return nil
    }
}

// MARK: - Geographic targeting

struct FanGeoAnnouncementUserLocation: Equatable, Sendable {
    let country: String
    let region: String
    let city: String

    var selectionKey: String {
        [
            FanGeoAnnouncementGeoMatcher.normalized(country),
            FanGeoAnnouncementGeoMatcher.normalized(region),
            FanGeoAnnouncementGeoMatcher.normalized(city)
        ].joined(separator: "|")
    }

    var hasKnownLocation: Bool {
        !FanGeoAnnouncementGeoMatcher.normalized(country).isEmpty
            || !FanGeoAnnouncementGeoMatcher.normalized(region).isEmpty
            || !FanGeoAnnouncementGeoMatcher.normalized(city).isEmpty
    }
}

enum FanGeoAnnouncementGeoMatcher {
    static func normalized(_ value: String?) -> String {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased() ?? ""
    }

    static func matchesAnnouncement(
        _ announcement: FanGeoAnnouncement,
        userLocation: FanGeoAnnouncementUserLocation
    ) -> Bool {
        if announcement.isGlobalGeoTarget {
            return true
        }

        guard userLocation.hasKnownLocation else {
            return false
        }

        let targetCountry = normalized(announcement.targetCountry)
        let targetState = normalized(announcement.targetState)
        let targetCity = normalized(announcement.targetCity)

        if !targetCountry.isEmpty, !fieldMatches(userLocation.country, targetCountry) {
            return false
        }
        if !targetState.isEmpty, !fieldMatches(userLocation.region, targetState) {
            return false
        }
        if !targetCity.isEmpty, !fieldMatches(userLocation.city, targetCity) {
            return false
        }
        return true
    }

    private static func fieldMatches(_ userValue: String, _ targetValue: String) -> Bool {
        let user = normalized(userValue)
        guard !user.isEmpty else { return false }
        return user == targetValue
    }
}

// MARK: - Dismiss persistence (24 hours)

enum FanGeoAnnouncementDismissStore {
    private static let keyPrefix = "fangeo.announcement.dismissed.until."
    private static let dismissDuration: TimeInterval = 24 * 60 * 60

    static func dismissStorageKey(for announcement: FanGeoAnnouncement) -> String {
        storageKey(for: announcement.id, dismissVersion: announcement.dismissVersion)
    }

    static func isDismissed(_ announcement: FanGeoAnnouncement, now: Date = Date()) -> Bool {
        isDismissed(id: announcement.id, dismissVersion: announcement.dismissVersion, now: now)
    }

    static func isDismissed(id: UUID, dismissVersion: Int, now: Date = Date()) -> Bool {
        let until = UserDefaults.standard.double(forKey: storageKey(for: id, dismissVersion: dismissVersion))
        guard until > 0 else { return false }
        return now.timeIntervalSince1970 < until
    }

    static func dismiss(_ announcement: FanGeoAnnouncement, now: Date = Date()) {
        dismiss(id: announcement.id, dismissVersion: announcement.dismissVersion, now: now)
    }

    static func dismiss(id: UUID, dismissVersion: Int, now: Date = Date()) {
        let until = now.timeIntervalSince1970 + dismissDuration
        UserDefaults.standard.set(until, forKey: storageKey(for: id, dismissVersion: dismissVersion))
    }

    private static func storageKey(for id: UUID, dismissVersion: Int) -> String {
        let version = max(1, dismissVersion)
        return keyPrefix + id.uuidString.lowercased() + ".v\(version)"
    }
}

// MARK: - Fetch

struct FanGeoAnnouncementService {
    private static let selectColumns = """
    id,title,subtitle,description,image_url,secondary_image_url,cta_label,cta_action,audience_fans,audience_businesses,display_type,status,start_date,end_date,priority,created_at,updated_at,target_country,target_state,target_city,dismiss_version,promotion_type,promoted_venue_id,target_radius_miles,promo_offer_type,promo_offer_chip,deleted_at
    """

    private static let selectColumnsWithoutDeletedAt = """
    id,title,subtitle,description,image_url,secondary_image_url,cta_label,cta_action,audience_fans,audience_businesses,display_type,status,start_date,end_date,priority,created_at,updated_at,target_country,target_state,target_city,dismiss_version,promotion_type,promoted_venue_id,target_radius_miles,promo_offer_type,promo_offer_chip
    """

    private static let selectColumnsWithoutOptionalFields = """
    id,title,subtitle,description,image_url,cta_label,cta_action,audience_fans,audience_businesses,display_type,status,start_date,end_date,priority,created_at,updated_at,target_country,target_state,target_city,dismiss_version,promotion_type,promoted_venue_id,target_radius_miles,promo_offer_type,promo_offer_chip
    """

    @MainActor
    func fetchDiscoverBannerCandidates() async -> [FanGeoAnnouncement]? {
        for scope in FetchColumnScope.allCases {
            if let rows = await fetchDiscoverBannerCandidates(columnScope: scope) {
                return rows
            }
        }
        return nil
    }

    private enum FetchColumnScope: CaseIterable {
        case withDeletedAt
        case withoutDeletedAt
        case withoutOptionalFields

        var selectColumns: String {
            switch self {
            case .withDeletedAt:
                return FanGeoAnnouncementService.selectColumns
            case .withoutDeletedAt:
                return FanGeoAnnouncementService.selectColumnsWithoutDeletedAt
            case .withoutOptionalFields:
                return FanGeoAnnouncementService.selectColumnsWithoutOptionalFields
            }
        }

        var appliesDeletedAtFilter: Bool {
            self == .withDeletedAt
        }

        var debugLabel: String {
            switch self {
            case .withDeletedAt: return "withDeletedAtColumn"
            case .withoutDeletedAt: return "withoutDeletedAtColumn"
            case .withoutOptionalFields: return "withoutOptionalFields"
            }
        }
    }

    @MainActor
    private func fetchDiscoverBannerCandidates(columnScope: FetchColumnScope) async -> [FanGeoAnnouncement]? {
        do {
            var query = supabase
                .from("announcements")
                .select(columnScope.selectColumns)
                .eq("display_type", value: "discover_banner")
                .eq("status", value: "active")

            if columnScope.appliesDeletedAtFilter {
                query = query.is("deleted_at", value: nil)
            }

            let rows: [FanGeoAnnouncement] = try await query
                .order("priority", ascending: false)
                .order("created_at", ascending: false)
                .limit(20)
                .execute()
                .value
#if DEBUG
            for row in rows {
                FanGeoAnnouncement.logDiscoverAnnouncementEvaluation(
                    row: row,
                    phase: "fetchRaw",
                    included: true,
                    reason: nil
                )
            }
#endif
            return rows.filter { row in
                let reason = FanGeoAnnouncement.discoverFetchExclusionReason(for: row)
                let included = reason == nil
#if DEBUG
                FanGeoAnnouncement.logDiscoverAnnouncementEvaluation(
                    row: row,
                    phase: "fetchFiltered",
                    included: included,
                    reason: reason
                )
#endif
                return included
            }
        } catch {
#if DEBUG
            print(
                "[AnnouncementDebug] fetchFailed scope=\(columnScope.debugLabel) " +
                "error=\(error.localizedDescription)"
            )
#endif
            return nil
        }
    }
}

// MARK: - CTA routing

enum FanGeoAnnouncementCTAOutcome: Equatable {
    case openExternalURL(URL)
    case navigateToTab(String)
    case openVenue(UUID)
}

enum FanGeoAnnouncementCTAAction {
    /// Maps stored `cta_action` values to ``MainTabView/AppTab`` raw values.
    /// Includes admin canonical values (`discover`, `live`, `calendar`, `going`, `profile`)
    /// and legacy aliases saved before dashboard normalization.
    private static let tabDestinationByAction: [String: String] = [
        "discover": "discover",
        "explore": "discover",
        "live": "live",
        "live_games": "live",
        "live_game": "live",
        "view_games": "live",
        "calendar": "calendar",
        "learn_more": "calendar",
        "going": "following",
        "following": "following",
        "open_pickup": "following",
        "profile": "account",
        "account": "account",
        "open_profile": "account"
    ]

    static func perform(
        _ rawAction: String?,
        promotedVenueId: UUID? = nil,
        onOutcome: (FanGeoAnnouncementCTAOutcome) -> Void
    ) {
        let trimmed = rawAction?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return }

        let lower = trimmed.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: trimmed) else { return }
            onOutcome(.openExternalURL(url))
            return
        }

        let normalized = lower
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        if normalized == "open_venue" {
            if let promotedVenueId {
                onOutcome(.openVenue(promotedVenueId))
            } else {
                onOutcome(.navigateToTab("discover"))
            }
            return
        }

        guard let tabRaw = resolvedTabRaw(for: normalized) else { return }
        onOutcome(.navigateToTab(tabRaw))
    }

    static func resolvedTabRaw(for normalizedAction: String) -> String? {
        let key = normalizedAction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "-", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        guard !key.isEmpty else { return nil }
        return tabDestinationByAction[key]
    }
}
